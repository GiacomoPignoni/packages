// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.graphics.Bitmap
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import android.util.Log
import androidx.camera.core.CameraEffect
import androidx.camera.core.SurfaceProcessor
import androidx.core.util.Consumer
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random

/**
 * Owns the OpenGL ES pipeline that renders the camera frames.
 *
 * A single GL context and render thread back the preview, the recorded video and the still-capture
 * path, so all three see the same effects, crop and capture scale. This is the Android counterpart
 * of the shader-pipeline half of `DefaultCamera.swift`.
 *
 * One instance outlives every camera the plugin opens, and that is not an optimisation. CameraX
 * caches a `CameraUseCaseAdapter` per camera id and stores the bound effects on it; `unbindAll`
 * removes the use cases but never the effects, so an effect stays attached to that adapter for the
 * life of the process. Building a fresh manager per camera therefore leaves a trail of effects
 * pointing at pipelines whose GL context has been destroyed, and the next bind that picks one up
 * gets a `SurfaceProcessor` that silently drops every frame — a preview that goes black after a
 * frame or two. Keeping the manager alive means those retained references are always to a live
 * pipeline. It also spares each camera switch an EGL context and a shader compile.
 *
 * The public methods are called from the platform channel thread and hop to the render thread
 * internally; the uniform state is guarded so a setter can never tear a frame that is mid-render.
 */
class CameraEffectsManager(
    private val api: CameraEffectsManagerProxyApi,
    initialAspectRatio: Double?,
) {
  init {
    // Dart has no plugin-teardown hook to call `release` from, so the pipeline is tracked here and
    // torn down when the plugin detaches from the engine. Without it an engine restart would leak
    // this thread and its EGL context for the life of the process.
    liveManagers.add(this)
  }

  // Display priority, not the default. This thread draws every preview frame and, on a shutter
  // press, does the still capture's texture upload and its full-frame `glReadPixels` readback -
  // both CPU-bound on a 12MP photo. At the default priority the scheduler may put it on a little
  // core, which costs dropped preview frames as well as a slower photo.
  private val glThread =
      HandlerThread("CameraEffectsGl", Process.THREAD_PRIORITY_DISPLAY).apply { start() }
  /**
   * The last output identity logged by [uniformsForOutput], so the line there is not per frame.
   *
   * A single packed key rather than a growing set: only the most recent output ever needs
   * suppressing, since CameraX attaches an output once at bind and again when a recording starts.
   */
  private var lastLoggedOutputKey = -1L

  private val glHandler = Handler(glThread.looper)

  // Background priority, the opposite end from [glThread]: an overlay is a full-frame image, so
  // decoding one is a disk read and an 8 MB ARGB_8888 expansion, and nothing is waiting on the
  // result while the frame [glThread] is drawing very much is.
  private val overlayDecodeThread =
      HandlerThread("CameraEffectsOverlayDecode", Process.THREAD_PRIORITY_BACKGROUND).apply {
        start()
      }

  private val overlayDecodeHandler = Handler(overlayDecodeThread.looper)

  /**
   * The overlay image most recently asked for, or null for none.
   *
   * Checked again at each hop of [applyOverlay] so a load a later one has superseded is dropped
   * rather than applied out of order, the way `VideoFrameRenderer.pendingOverlayTexturePath` does.
   */
  @Volatile private var pendingOverlayPath: String? = null

  /**
   * Posts to the render thread, falling back to running inline once that thread has quit.
   *
   * CameraX invokes its surface-release callbacks on this executor and can do so well after
   * [release] has torn the pipeline down. Posting to a dead looper drops the work silently — apart
   * from a "dead thread" warning — and leaks the `Surface` the callback was meant to let go of. By
   * that point every GL object is already gone, so what is left to do is thread-agnostic.
   */
  private val glExecutor = Executor { command ->
    // CameraX's callbacks are not this plugin's code, and an exception escaping one on the render
    // thread would reach the process-wide default handler and kill the app rather than the frame.
    val guarded = Runnable {
      try {
        command.run()
      } catch (e: Exception) {
        Log.e(TAG, "A CameraX surface callback failed", e)
      }
    }
    if (!glHandler.post(guarded)) {
      guarded.run()
    }
  }

  private val eglCore: EglCore
  private val pipeline: CameraGlPipeline
  private val processor: CameraSurfaceProcessor

  private val uniformsLock = Any()
  private val uniforms = CameraUniforms()

  /**
   * Aspect ratio (width/height) of the center-crop, or null for no crop. Guarded by [uniformsLock].
   *
   * Only the still-capture path reads it. The preview and the encoder are cropped by the `ViewPort`
   * their use cases are bound with, which is the only way to make CameraX size the encoder's
   * surface to the crop rather than resample the crop into a surface of another shape.
   */
  private var aspectRatio: Double? = initialAspectRatio

  /** Size of the preview output surface, so [notifyPreviewSize] can re-emit it. */
  private var previewOutputSize: Pair<Int, Int>? = null

  /**
   * Grain tile size, kept separately because the UV scale depends on each output's dimensions.
   *
   * Read by [applyGrainScale] on the render thread, outside the [uniformsLock] that guards its
   * write in [setEffectsValues], so it needs its own visibility guarantee rather than the lock's.
   */
  @Volatile private var grainSize = 0.1f

  private var grainAnimationRunning = false

  /** Set by [release], so a second call cannot post to the looper the first one quit. */
  private var released = false

  /** The pending still-program warm-up, held so [release] can take it off the queue. */
  private var stillWarmUp: Runnable? = null

  private val grainAnimationTick =
      object : Runnable {
        override fun run() {
          synchronized(uniformsLock) {
            uniforms.grainOffsetX = Random.nextFloat()
            uniforms.grainOffsetY = Random.nextFloat()
          }
          if (grainAnimationRunning) {
            glHandler.postDelayed(this, GRAIN_ANIMATION_INTERVAL_MILLIS)
          }
        }
      }

  init {
    // The context has to exist before the processor can hand out EGL surfaces, and it must be
    // created on the thread that will use it.
    val setup = runOnGlThreadBlocking {
      val core = EglCore()
      // `EglCore` leaves its 1x1 surface current, so the programs can be built right away. Doing
      // it here rather than on the first frame means a driver problem surfaces at camera creation
      // with a clear stack, instead of as a dropped frame later.
      val glPipeline = CameraGlPipeline(core)
      glPipeline.warmUp()
      core to glPipeline
    }
    eglCore = setup.first
    pipeline = setup.second
    // Delayed rather than folded into the blocking setup above: the still-capture programs are not
    // needed until a shutter press, so compiling them must not hold up the camera opening.
    //
    // The delay is what does that, not the post. This is the same single render thread the preview
    // draws on, so a task posted here sits ahead of the first frames and the compile cost - four
    // large fragment shaders, tens of milliseconds each on some drivers - lands on camera startup
    // rather than on the first photo. Waiting until the preview is running moves it to a moment
    // when the thread is otherwise idle between frames, and still beats the user to the shutter
    // button by orders of magnitude.
    val warmUp = Runnable {
      try {
        eglCore.makeDefaultCurrent()
        pipeline.warmUpStillPrograms()
      } catch (e: Exception) {
        // Worth a slower first photo, not a dead camera: `render` compiles what it needs anyway.
        Log.e(TAG, "Warming up the still-capture programs failed", e)
      }
    }
    stillWarmUp = warmUp
    glHandler.postDelayed(warmUp, STILL_WARM_UP_DELAY_MILLIS)
    processor =
        CameraSurfaceProcessor(
            eglCore = eglCore,
            pipeline = pipeline,
            glHandler = glHandler,
            glExecutor = glExecutor,
            uniformsProvider = ::uniformsForOutput,
            onPreviewSizeChanged = ::reportPreviewSize,
            onPreviewOutputLost = ::reportPreviewOutputLost,
        )
  }

  private val cameraEffect: CameraEffect =
      ShaderCameraEffect(processor, glExecutor) { Log.e(TAG, "Camera effect failed", it) }

  /** The effect to bind alongside the camera's use cases. */
  fun getCameraEffect(): CameraEffect = cameraEffect

  /**
   * Snapshots the uniforms for one output into `snapshot`, which the caller owns and reuses.
   *
   * The aspect-ratio crop is deliberately *not* applied here. CameraX crops it upstream, from the
   * `ViewPort` the use cases are bound with, so every surface this processor is handed already has
   * the requested shape and the frame is drawn into it edge to edge. Cropping in the shader as well
   * would either double-crop or, on the encoder's fixed-size surface, bake a stretch into the
   * recording.
   */
  private fun uniformsForOutput(
      targets: Int,
      outputWidth: Int,
      outputHeight: Int,
      snapshot: CameraUniforms,
  ) {
    synchronized(uniformsLock) { snapshot.setFrom(uniforms) }
    // Equality, not a bit test: an output reporting more than PREVIEW is the shared one CameraX
    // hands out while a recording is in flight, and the preview-only decorations must not be baked
    // into the file. The preview loses its dimming and rounded border for the length of the
    // recording, which is the cheaper of the two errors.
    if (targets == CameraEffect.PREVIEW) {
      snapshot.darkenOutside = CameraUniforms.PREVIEW_DARKEN_OUTSIDE
      snapshot.overlayQuarterTurns = PREVIEW_OVERLAY_QUARTER_TURNS
    } else {
      snapshot.darkenOutside = 0f
      // Only the preview draws the rounded border, so the corner radius must not reach a recording.
      snapshot.captureCornerRadius = 0f
      snapshot.overlayQuarterTurns = RECORDING_OVERLAY_QUARTER_TURNS
    }
    // One line per output, and an output is attached once - at a bind, and again when a recording
    // starts and CameraX swaps in the shared surface. Enough to see which surfaces exist and what
    // shape each is, which is what the overlay's orientation turns on.
    val key = (targets.toLong() shl 48) or (outputWidth.toLong() shl 24) or outputHeight.toLong()
    if (key != lastLoggedOutputKey) {
      lastLoggedOutputKey = key
      Log.i(TAG, "output targets=$targets size=${outputWidth}x$outputHeight")
    }
    snapshot.outputAspect = outputWidth.toFloat() / outputHeight.toFloat()
    // The live outputs are drawn in sensor orientation, which is what the grain UV is authored
    // against, so no axis swap here - only the still-capture path needs one.
    applyGrainScale(snapshot, outputWidth, outputHeight, swapAxes = false)
  }

  /**
   * Writes the grain UV scale for one output into `uniforms`.
   *
   * Port of the same block in `VideoFrameRenderer`. Two corrections ride on top of the plain
   * `grainUvScale` geometry, in this order:
   * - `swapAxes` transposes the scale to follow the transposed UV the shader hands `applyGrain`
   *   when `grainSwapUV` is set.
   * - the tile's own aspect is folded into the y component *after* that swap, so it always corrects
   *   the y of whatever UV the shader ends up using. Without it a non-square grain image is
   *   squeezed into a square cell.
   */
  private fun applyGrainScale(
      uniforms: CameraUniforms,
      outputWidth: Int,
      outputHeight: Int,
      swapAxes: Boolean,
  ) {
    val (x, y) = CameraGeometry.grainUvScale(grainSize, outputWidth, outputHeight)
    uniforms.grainUVScaleX = if (swapAxes) y else x
    uniforms.grainUVScaleY = (if (swapAxes) x else y) * pipeline.grainTextureAspect
    uniforms.grainSwapUV = if (swapAxes) 1f else 0f
  }

  /**
   * Tells Dart the shape of the preview surface.
   *
   * Reported in the sensor-landscape convention (longer axis first) like
   * `DefaultCamera.landscapePreviewSize` on iOS, since `CameraPreview` inverts it for portrait. The
   * surface already carries the `ViewPort` crop, so this is the cropped shape.
   */
  private fun reportPreviewSize(outputWidth: Int, outputHeight: Int) {
    synchronized(uniformsLock) { previewOutputSize = outputWidth to outputHeight }
    api.reportPreviewSizeChanged(
        this,
        max(outputWidth, outputHeight),
        min(outputWidth, outputHeight),
    )
  }

  /**
   * Tells Dart the preview has nothing left to draw into, so it can re-bind and get a new surface.
   *
   * See [CameraSurfaceProcessor.retireAt]: by the time this runs the surface is already gone and
   * the camera is still happily producing frames, so nothing recovers without a re-bind.
   */
  private fun reportPreviewOutputLost() {
    synchronized(uniformsLock) { previewOutputSize = null }
    api.reportPreviewOutputLost(this)
  }

  /** Re-emits the preview size, or does nothing if no preview surface has arrived yet. */
  fun notifyPreviewSize() {
    val size = synchronized(uniformsLock) { previewOutputSize } ?: return
    reportPreviewSize(size.first, size.second)
  }

  fun setEffectsValues(values: PlatformEffectsValues) {
    synchronized(uniformsLock) {
      uniforms.applyEffects(values)
      grainSize = values.grainSize.toFloat()
    }
    // Uploading a texture can fail on a driver that has lost its context, and an exception escaping
    // a `HandlerThread` task kills the process. A grain or LUT image that will not load is worth a
    // log line, not that.
    glHandler.post {
      try {
        values.grainNoisePath?.let { pipeline.loadGrainTexture(it) } ?: pipeline.clearGrainTexture()
        values.lutFilePath?.let { pipeline.loadLutTexture(it) } ?: pipeline.clearLutTexture()
        updateGrainAnimation(values.grainNoisePath != null && values.grainOpacity > 0.0)
      } catch (e: Exception) {
        Log.e(TAG, "Applying effects values failed", e)
      }
    }
    // Not part of the block above: the overlay decodes on its own thread and only its upload is
    // posted to the render thread.
    applyOverlay(values.overlayFilePath)
    processor.redraw()
  }

  /**
   * Points the pipeline at the overlay image at `path`, or clears the overlay when it is null.
   *
   * Three hops, each of which drops the work if a later call has moved [pendingOverlayPath] on: the
   * caller's thread decides there is anything to do, [overlayDecodeThread] reads and decodes the
   * file, and [glHandler] uploads it. So a burst of switches costs one upload rather than one per
   * call, and switching back to an image already decoded costs no disk read at all.
   *
   * A path that fails to decode leaves [pendingOverlayPath] pointing at it, so it is not retried
   * until something else is asked for. That matches the pipeline's contract for a bad grain or LUT
   * image: the previous texture stays, and the failure is a log line.
   */
  private fun applyOverlay(path: String?) {
    if (path == pendingOverlayPath) {
      return
    }
    pendingOverlayPath = path
    if (path == null) {
      glHandler.post { pipeline.clearOverlayTexture() }
      processor.redraw()
      return
    }
    overlayDecodeHandler.post decode@{
      if (pendingOverlayPath != path) {
        return@decode
      }
      // Decoding touches no GL state, so a driver that has lost its context cannot throw here -
      // but a malformed file can, and an exception escaping a `HandlerThread` task kills the
      // process.
      val bitmap =
          try {
            pipeline.decodeOverlayBitmap(path)
          } catch (e: Exception) {
            Log.e(TAG, "Decoding the overlay image at '$path' failed", e)
            null
          } ?: return@decode
      glHandler.post upload@{
        if (pendingOverlayPath != path) {
          return@upload
        }
        try {
          pipeline.loadOverlayTexture(path, bitmap)
        } catch (e: Exception) {
          Log.e(TAG, "Uploading the overlay image at '$path' failed", e)
          return@upload
        }
        // The `redraw` in `setEffectsValues` ran before this decode finished, so without one here
        // a paused preview would keep showing the old overlay until something else moved.
        processor.redraw()
      }
    }
  }

  /**
   * Records the ratio the still-capture path should crop to.
   *
   * The live outputs are not touched here: they follow the `ViewPort`, and changing that means
   * re-binding the use cases, which the Dart side drives.
   */
  fun setAspectRatio(aspectRatio: Double?) {
    synchronized(uniformsLock) { this.aspectRatio = aspectRatio }
    processor.redraw()
  }

  fun setCaptureScale(scale: Double) {
    synchronized(uniformsLock) { uniforms.captureScale = scale.toFloat() }
    processor.redraw()
  }

  fun setCaptureCornerRadius(radius: Double) {
    synchronized(uniformsLock) { uniforms.captureCornerRadius = radius.toFloat() }
    processor.redraw()
  }

  /**
   * The uniforms and output size a still capture of `sourceWidth` x `sourceHeight` should use.
   *
   * Exposed for [CameraStillCaptureRenderer], which renders photos off the live pipeline.
   */
  internal fun stillCapturePlan(sourceWidth: Int, sourceHeight: Int): StillCapturePlan {
    val snapshot: CameraUniforms
    val ratio: Double?
    synchronized(uniformsLock) {
      snapshot = uniforms.copy()
      ratio = CameraGeometry.effectiveAspectRatio(aspectRatio, sourceWidth, sourceHeight)
    }
    val crop = CameraGeometry.croppedDimensions(sourceWidth, sourceHeight, ratio)
    // A capture pass renders the scaled rect itself, so its destination is the scaled size and
    // nothing is darkened - the opposite of the preview, which keeps the full crop and dims the
    // outside.
    snapshot.darkenOutside = 0f
    snapshot.captureCornerRadius = 0f
    snapshot.uvScaleX = crop.uvScaleX
    snapshot.uvScaleY = crop.uvScaleY

    val scaledWidth = CameraGeometry.evenRound(crop.width * snapshot.captureScale)
    val scaledHeight = CameraGeometry.evenRound(crop.height * snapshot.captureScale)
    snapshot.outputAspect = scaledWidth.toFloat() / scaledHeight.toFloat()
    // The live outputs are drawn in sensor orientation while the still-capture pass renders
    // upright, so the two frames differ by a quarter turn and the grain has to be transposed to
    // land the same way in the photo as it did in the preview.
    // `VideoFrameRenderer` passes `swapGrainAxes: true` on its photo path for the same reason.
    applyGrainScale(snapshot, scaledWidth, scaledHeight, swapAxes = true)
    // Same as the preview's: the still is turned upright before the shader sees it, so the overlay
    // is used exactly as authored in both.
    snapshot.overlayQuarterTurns = PREVIEW_OVERLAY_QUARTER_TURNS
    return StillCapturePlan(crop, scaledWidth, scaledHeight, snapshot)
  }

  internal data class StillCapturePlan(
      val crop: CameraGeometry.Crop,
      val outputWidth: Int,
      val outputHeight: Int,
      val uniforms: CameraUniforms,
  )

  /**
   * Renders `bitmap` through the pipeline and returns the result.
   *
   * `bitmap` is the capture as decoded, still in sensor orientation; `rotationDegrees` is the
   * quarter turn the shader applies to bring it upright.
   *
   * Runs on the render thread so it shares the compiled programs and the grain and LUT textures
   * with the live preview; a still capture therefore cannot drift from what the preview showed.
   */
  internal fun renderStill(bitmap: Bitmap, plan: StillCapturePlan, rotationDegrees: Int): Bitmap =
      runOnGlThreadBlocking {
        CameraStillCaptureRenderer.render(eglCore, pipeline, bitmap, plan, rotationDegrees)
      }

  /**
   * Renders an uncompressed capture through the pipeline.
   *
   * The YUV counterpart of [renderStill]; `fullRange` says how the device encoded the luma.
   */
  internal fun renderStill(
      yuv: CameraYuvImage,
      plan: StillCapturePlan,
      rotationDegrees: Int,
      fullRange: Boolean,
  ): Bitmap = runOnGlThreadBlocking {
    CameraStillCaptureRenderer.render(eglCore, pipeline, yuv, plan, rotationDegrees, fullRange)
  }

  /**
   * The same plan with every effect switched off, for the un-effected original.
   *
   * The crop, the capture scale and the output size are the plan's; nothing that changes a pixel's
   * colour survives. On the JPEG path the original was a CPU sub-rect of the decoded frame, which
   * an uncompressed capture has no equivalent of - the frame only becomes RGB in the sampler - so
   * it goes through the pipeline too, with a neutral uniform set.
   *
   * That makes this original the YUV frame as the sampler decoded it rather than a byte-for-byte
   * copy of anything, which the JPEG path's sub-rect was. The dither is switched off along with the
   * effects so the difference stops there: with every effect at zero the main pass reduces to a
   * sample and a write, and leaving the dither on would have signed ±1 LSB noise be the one thing
   * this path adds to a photo that is supposed to be untouched.
   */
  internal fun neutralPlan(plan: StillCapturePlan): StillCapturePlan {
    val neutral = CameraUniforms()
    neutral.uvScaleX = plan.uniforms.uvScaleX
    neutral.uvScaleY = plan.uniforms.uvScaleY
    neutral.captureScale = plan.uniforms.captureScale
    neutral.outputAspect = plan.uniforms.outputAspect
    neutral.dither = 0f
    return plan.copy(uniforms = neutral)
  }

  private fun updateGrainAnimation(active: Boolean) {
    if (active == grainAnimationRunning) {
      return
    }
    grainAnimationRunning = active
    glHandler.removeCallbacks(grainAnimationTick)
    if (active) {
      glHandler.post(grainAnimationTick)
    }
  }

  /**
   * Detaches the preview and encoder outputs, leaving the pipeline itself intact.
   *
   * What a camera's `dispose` calls. The manager deliberately outlives any one camera — see the
   * class doc — so the GL context, the compiled programs and the loaded grain and LUT textures are
   * all kept; only the surfaces belonging to the camera that is going away are let go.
   */
  fun detachOutputs() {
    if (released) {
      return
    }
    synchronized(uniformsLock) { previewOutputSize = null }
    try {
      runOnGlThreadBlocking(DETACH_WAIT_MILLIS) { processor.detachOutputs() }
    } catch (e: Exception) {
      // `dispose` calls this and then hands Flutter's texture back to the engine, and the rest of
      // that teardown matters more than this step succeeding. Letting the failure out would abort
      // the `CameraController.dispose` that is on its way to building the next camera, turning one
      // stuck surface into a plugin that never opens a camera again.
      Log.e(TAG, "Detaching the effects outputs failed", e)
    }
  }

  /**
   * Tears the pipeline down. Safe to call more than once.
   *
   * Idempotent because a second call would post to a looper this one already quit, and
   * [runOnGlThreadBlocking] has no way to complete that — it would be the platform thread waiting
   * on a thread that is never going to answer.
   */
  fun release() {
    if (released) {
      return
    }
    released = true
    liveManagers.remove(this)
    updateGrainAnimation(false)
    // A camera closed inside the warm-up delay would otherwise leave a task queued against a
    // pipeline this method is about to tear down.
    stillWarmUp?.let { glHandler.removeCallbacks(it) }
    stillWarmUp = null
    try {
      runOnGlThreadBlocking {
        processor.release()
        pipeline.release()
        eglCore.release()
      }
    } catch (e: Exception) {
      // Nothing the caller can do about a teardown that went wrong, and letting it out would fail
      // the `dispose` that is on its way to building the next camera.
      Log.e(TAG, "Tearing the effects pipeline down failed", e)
    } finally {
      // Always: a thread left running holds its EGL context, and the next camera makes another one.
      glThread.quitSafely()
      overlayDecodeThread.quitSafely()
    }
  }

  /**
   * Runs `block` on the render thread and waits up to `timeoutMillis` for it.
   *
   * Only used for setup, teardown and still capture — never on the per-frame path.
   *
   * The caller is normally the platform thread, so this must never wait on something that cannot
   * arrive. A rejected post means the render thread is gone and nothing will ever complete the
   * block, which is reported rather than waited out — blocking the platform thread forever is an
   * ANR, and the system answers those by killing the process.
   *
   * The timeout covers the case a rejected post does not: a render thread that is alive but stuck,
   * which `eglSwapBuffers` does whenever an output's buffer queue fills up and its consumer stops
   * draining it. `detachOutputs` runs from a camera's `dispose`, so without a bound wait a stalled
   * GPU consumer would hold the platform thread through every camera switch that follows — the
   * whole plugin wedged behind one surface. Giving up leaves GL objects for [release] to collect
   * and lets the teardown carry on, which is the better of the two failures.
   */
  private fun <T> runOnGlThreadBlocking(timeoutMillis: Long = GL_WAIT_MILLIS, block: () -> T): T {
    var result: Result<T>? = null
    val lock = Object()
    val posted =
        glHandler.post {
          val value = runCatching(block)
          synchronized(lock) {
            result = value
            lock.notifyAll()
          }
        }
    check(posted) { "The camera effects render thread has already quit" }
    val deadline = SystemClock.uptimeMillis() + timeoutMillis
    synchronized(lock) {
      while (result == null) {
        val remaining = deadline - SystemClock.uptimeMillis()
        check(remaining > 0) {
          "The camera effects render thread did not respond in ${timeoutMillis}ms"
        }
        lock.wait(remaining)
      }
    }
    return result!!.getOrThrow()
  }

  /**
   * `CameraEffect`'s constructor is protected, so applying a processor means subclassing it.
   *
   * Still capture is deliberately not a target: `takePictureWithEffects` has to produce an
   * un-effected original from the same shutter event, which an `IMAGE_CAPTURE` effect cannot do.
   *
   * The four-argument constructor deliberately: it is the only overload that leaves both the output
   * option and the transformation at their defaults. The five-argument one takes a
   * *transformation*, not an output option, and passing `OUTPUT_OPTION_ONE_FOR_EACH_TARGET` to it
   * silently reads as `TRANSFORMATION_CAMERA_AND_SURFACE_ROTATION`, which makes `StreamSharing`
   * hand this processor a rotated, uncropped edge the rest of the graph is not expecting.
   */
  private class ShaderCameraEffect(
      processor: SurfaceProcessor,
      executor: Executor,
      errorListener: Consumer<Throwable>,
  ) : CameraEffect(PREVIEW or VIDEO_CAPTURE, executor, processor, errorListener)

  companion object {
    private const val TAG = "CameraEffectsManager"

    /**
     * Quarter turns applied to the overlay's UV on the preview-only output. None.
     *
     * Both paths present the frame to the shader the same way up. The still is turned upright by
     * `CameraStillCaptureRenderer.uprightTransform` before it reaches the shader, and the live
     * outputs are upright already: `AndroidCameraCameraX._previewTargetRotation` asks CameraX for
     * the display's natural orientation, which makes it fold the whole sensor rotation into the
     * transform the processor samples through. So the overlay is used exactly as authored in both,
     * and this exists only to name that rather than leave it to the field's default.
     *
     * Metal is the one that needs a turn, on its photo path alone - see
     * `VideoFrameRenderer.photoOverlayQuarterTurns`.
     */
    private const val PREVIEW_OVERLAY_QUARTER_TURNS = 0f

    /**
     * Quarter turns applied to the overlay's UV on the output a recording is attached to.
     *
     * Its own constant rather than [PREVIEW_OVERLAY_QUARTER_TURNS] because the surface is not the
     * same one, nor even the same way round. Once a recording starts CameraX stops handing out a
     * preview-only output and swaps in a shared one serving both targets, and that surface is the
     * encoder's: sensor-landscape (1440x1080 where the preview is 1080x1440), with the turn back to
     * upright carried as rotation metadata on the file rather than applied to the pixels. So the
     * overlay is baked into a landscape frame that the player then rotates, overlay and all.
     *
     * Three, for the same reason `VideoFrameRenderer.photoOverlayQuarterTurns` is: this is the
     * identical geometry to an iOS photo, a portrait-authored overlay going onto a sensor-landscape
     * raster that is turned a quarter clockwise at display time. That maps display point `(x, y)`
     * to raster point `(y, 1 - x)`, so the fragment at raster UV `(u, v)` is displayed at `(1 - v,
     * u)` - which is where the overlay must be sampled, and is `rotateUv(uv, 3)`.
     *
     * It also explains why the preview turns the moment recording starts: the widget keeps showing
     * the shared surface, which is the encoder's landscape one.
     */
    private const val RECORDING_OVERLAY_QUARTER_TURNS = 3f

    /** 24 fps, matching the grain animation timer in `VideoFrameRenderer`. */
    private const val GRAIN_ANIMATION_INTERVAL_MILLIS = 1000L / 24L

    /**
     * How long the platform thread waits on the render thread.
     *
     * Generous, because the two things that use the default are a cold start — where it covers
     * building an EGL context and compiling the preview programs — and a still capture, which
     * renders the full sensor frame through every pass. Neither is anywhere near this on a working
     * device; the bound is there for one that is not.
     */
    private const val GL_WAIT_MILLIS = 5_000L

    /**
     * How long a camera's `dispose` waits for its outputs to be detached.
     *
     * Tighter than [GL_WAIT_MILLIS]: this one is on the camera-switch path, where the cost of
     * waiting is the user watching a dead screen, and the work being waited for is a handful of
     * `eglDestroySurface` calls.
     */
    private const val DETACH_WAIT_MILLIS = 2_000L

    /**
     * How long the still-capture programs wait before compiling themselves.
     *
     * Long enough for the preview to have started drawing, so the compile lands between frames
     * rather than in front of the first one; short enough that it is finished many times over
     * before a user can frame a shot and press the shutter.
     */
    private const val STILL_WARM_UP_DELAY_MILLIS = 1_000L

    /** Every pipeline that has not been released, so the plugin can tear them down on detach. */
    private val liveManagers: MutableSet<CameraEffectsManager> =
        Collections.newSetFromMap(ConcurrentHashMap())

    /**
     * Releases every pipeline still alive.
     *
     * Called when the plugin detaches from the engine, which is the only point at which a manager
     * is certain to be finished with: a camera's `dispose` only detaches its outputs, because the
     * next camera reuses the pipeline.
     */
    @JvmStatic
    fun releaseAll() {
      // Copied: `release` removes itself from the set.
      liveManagers.toList().forEach { it.release() }
    }
  }
}
