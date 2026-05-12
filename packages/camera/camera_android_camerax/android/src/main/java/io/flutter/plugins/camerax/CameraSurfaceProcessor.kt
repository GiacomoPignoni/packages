// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.graphics.SurfaceTexture
import android.opengl.EGLSurface
import android.os.Handler
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraEffect
import androidx.camera.core.SurfaceOutput
import androidx.camera.core.SurfaceProcessor
import androidx.camera.core.SurfaceRequest
import java.util.concurrent.Executor

/**
 * Renders the camera stream through [CameraGlPipeline] on its way to the preview and the video
 * encoder.
 *
 * One input external texture fans out to every attached output, which is what lets the preview and
 * a recording share a single decode and a single set of effect passes — the same arrangement
 * `DefaultCamera` gets on iOS by driving both from one `VideoFrameRenderer`.
 *
 * All GL work happens on [glHandler]'s thread, which owns the EGL context.
 */
class CameraSurfaceProcessor(
    private val eglCore: EglCore,
    private val pipeline: CameraGlPipeline,
    private val glHandler: Handler,
    private val glExecutor: Executor,
    /**
     * Fills `into` with the uniforms for one output, given that output's target and size.
     *
     * Writes into a caller-owned instance rather than returning a new one so the per-frame path
     * allocates nothing.
     */
    private val uniformsProvider:
        (targets: Int, width: Int, height: Int, into: CameraUniforms) -> Unit,
    /** Called on the GL thread with the preview output's surface size when it changes. */
    private val onPreviewSizeChanged: (width: Int, height: Int) -> Unit,
    /**
     * Called on the GL thread when the preview output is dropped by [retireAt].
     *
     * Nothing downstream of here can get it back: see [retireAt].
     */
    private val onPreviewOutputLost: () -> Unit,
) : SurfaceProcessor {
  /**
   * The one external texture every input `SurfaceTexture` latches into.
   *
   * Created with the first input and owned by this processor for its whole life, never by an
   * individual request. Several requests can be in flight at once (see [onInputSurface]) and they
   * all share this, which is what makes it irrelevant *which* of them delivers a frame.
   *
   * 0 until the first input arrives.
   */
  private var inputTextureId = 0

  /**
   * The most recently created input `SurfaceTexture`, or null if none is outstanding.
   *
   * Used only by [redraw], which has no frame of its own to work from and needs some texture to
   * re-read the transform off. Frames are never routed through this — see [onInputSurface].
   */
  private var latestSurfaceTexture: SurfaceTexture? = null

  private var inputSize: Size = Size(0, 0)

  /**
   * The attached outputs, in no particular order.
   *
   * A list rather than a map keyed by `SurfaceOutput`: there are only ever a handful of these — a
   * preview and, while recording, an encoder — so a linear scan costs nothing, and an indexed walk
   * lets [drawFrame] iterate and remove without allocating an iterator or a defensive copy.
   */
  private val outputs = ArrayList<OutputSurface>()

  private val textureTransform = FloatArray(16)
  private val outputTransform = FloatArray(16)

  /** Refilled per output per frame; see [CameraGlPipeline.Source.set]. */
  private val source = CameraGlPipeline.Source()

  private var previewSize: Size = Size(0, 0)

  /**
   * Set by [release], after which no GL object this class handed out is still alive.
   *
   * Volatile because CameraX's surface-release callbacks can arrive after the render thread has
   * quit, and then run on whichever thread CameraX called from.
   */
  @Volatile private var released = false

  /**
   * Set by [detachOutputs] and cleared by the next [onInputSurface], so an output that arrives
   * after a camera has been torn down is refused rather than attached.
   *
   * `detachOutputs` runs during a camera's `dispose`, between the use cases being unbound and
   * Flutter's texture being handed back to the engine. CameraX delivers its callbacks
   * asynchronously, so an `onOutputSurface` can already be queued behind it, or arrive just after;
   * attaching it would put an EGL window surface over a `Surface` that is about to be released and
   * leave the next frame swapping a buffer at a closed `ImageReader`, which the engine answers with
   * a failed `CHECK`. The next camera opens with an input surface before any output, which is what
   * makes that the point to start accepting again.
   */
  private var detached = false

  /**
   * Whether [inputTextureId] holds a frame produced by the camera that is currently set up.
   *
   * Cleared by [provideInputSurface] and set by the first frame latched afterwards, so it answers
   * "is what is in the texture right now something this configuration produced".
   *
   * The input texture is shared by every `SurfaceTexture` and outlives all of them — see
   * [inputTextureId] — so after a camera is torn down and another is built it still holds the last
   * frame of the *previous* one, at that camera's resolution, and the fresh `SurfaceTexture` on top
   * of it reports an identity transform because nothing has been latched through it yet. [redraw]
   * has no frame of its own and works from exactly those two things, so drawing at that moment puts
   * a stale image through the wrong transform: the sensor rotation and the buffer flip that the
   * transform normally carries are both missing, and the result reaches the preview rotated and
   * stretched. It only lasts until the first real frame, but that is precisely the moment the user
   * is looking at the preview coming up.
   *
   * The window is wide open in practice. A caller that rebuilds its controller to change the
   * resolution preset typically re-applies its render settings straight afterwards, and every one
   * of those setters redraws so that a change lands on a preview that may be paused. The camera is
   * still configuring its capture session while that happens — the best part of a second — so the
   * redraws land first and the preview's opening frames are the stale ones.
   */
  private var hasCameraFrame = false

  private class OutputSurface(
      val surfaceOutput: SurfaceOutput,
      val eglSurface: EGLSurface,
      val size: Size,
      val targets: Int,
  ) {
    /** Reused every frame, so snapshotting the uniforms for this output allocates nothing. */
    val uniforms = CameraUniforms()
  }

  /** The index of `surfaceOutput` in [outputs], or -1 if it is not attached. */
  private fun indexOf(surfaceOutput: SurfaceOutput): Int {
    for (index in outputs.indices) {
      if (outputs[index].surfaceOutput === surfaceOutput) {
        return index
      }
    }
    return -1
  }

  /**
   * Posts GL work to the render thread, keeping a failure inside it off that thread's
   * uncaught-exception path.
   *
   * A [android.os.HandlerThread] installs no exception handler of its own, so anything thrown from
   * a posted task reaches the process-wide default one, which logs it and kills the process. The
   * work posted here is full of calls that fail for reasons outside this plugin's control - the
   * common one being a surface abandoned by its consumer between CameraX handing it over and the
   * frame that draws into it, which is exactly what switching lenses produces - and none of them is
   * worth taking the app down for. The frame is dropped and the next one tries again.
   *
   * A dead looper is not an error either: it means [release] has already run and there is nothing
   * left for the work to touch. `onDeclined` runs in that case instead, for a caller that was
   * handed something that needs to be let go of either way - see [onOutputSurface].
   */
  private fun postGlWork(description: String, onDeclined: () -> Unit = {}, work: () -> Unit) {
    val posted =
        glHandler.post {
          try {
            work()
          } catch (e: Exception) {
            Log.e(TAG, "$description failed", e)
          }
        }
    if (!posted) {
      Log.w(TAG, "Skipping $description: the render thread has already quit")
      onDeclined()
    }
  }

  /**
   * Stands up a `SurfaceTexture` for one request and hands CameraX a `Surface` over it.
   *
   * More than one request can be outstanding at a time, and this is the crux of the whole class.
   * CameraX opens a pipeline before it has finished retiring the previous one — a capture session
   * that fails and is retried, or an open request that is pruned in favour of a newer one, both do
   * it — so two `SurfaceTexture`s can exist at once and there is no way to know in advance which of
   * them the camera will actually fill. Nominating one as "current" and latching only that is what
   * leaves the preview on its last good frame: the frames arrive on the other one.
   *
   * So every `SurfaceTexture` is built on the *same* external texture, exactly as CameraX's own
   * `DefaultSurfaceProcessor` does, and [onFrameAvailable] latches whichever one signalled. The
   * shared texture belongs to this processor, not to any request, so a request completing can never
   * pull the texture out from under a live one. A request releases only the `SurfaceTexture` and
   * `Surface` it created.
   */
  override fun onInputSurface(request: SurfaceRequest) {
    // Not `postGlWork`: every request has to be answered, one way or the other. A `SurfaceRequest`
    // that is neither provided nor declined leaves CameraX waiting on a deferrable surface that
    // will never resolve, so the camera never starts and nothing times out or retries — a swallowed
    // exception here is a preview that is dead for the life of the camera.
    val posted =
        glHandler.post {
          try {
            provideInputSurface(request)
          } catch (e: Exception) {
            Log.e(TAG, "onInputSurface failed", e)
            request.willNotProvideSurface()
          }
        }
    if (!posted) {
      Log.w(TAG, "Declining an input surface: the render thread has already quit")
      request.willNotProvideSurface()
    }
  }

  private fun provideInputSurface(request: SurfaceRequest) {
    // A camera is being set up, so anything [detachOutputs] refused belonged to the previous one.
    detached = false
    // ...and so does whatever is in the shared texture. See [hasCameraFrame].
    hasCameraFrame = false
    inputSize = request.resolution
    // Creating the texture needs a context, and no output surface is bound yet.
    eglCore.makeDefaultCurrent()
    if (inputTextureId == 0) {
      inputTextureId = GlUtil.createExternalTexture()
    }

    val surfaceTexture =
        SurfaceTexture(inputTextureId).apply {
          setDefaultBufferSize(inputSize.width, inputSize.height)
        }
    val surface = Surface(surfaceTexture)
    // The listener is registered with `glHandler`, so this already runs on the render thread and
    // draws the frame where it lands. Posting again would put a whole message round trip between
    // every frame and its render, and would let a backlog of them build up whenever a frame costs
    // more than the interval between two - which is exactly what the heavier effects at a high
    // resolution do. The try/catch is here rather than in a wrapper for the same reason.
    surfaceTexture.setOnFrameAvailableListener(
        { signalled ->
          try {
            onFrameAvailable(signalled)
          } catch (e: Exception) {
            Log.e(TAG, "drawFrame failed", e)
          }
        },
        glHandler,
    )
    latestSurfaceTexture = surfaceTexture

    request.provideSurface(surface, glExecutor) {
      // CameraX is done with this request. Only what this request created is released; the shared
      // texture outlives it and is freed with the processor.
      surface.release()
      surfaceTexture.release()
      if (latestSurfaceTexture === surfaceTexture) {
        latestSurfaceTexture = null
      }
    }
  }

  override fun onOutputSurface(surfaceOutput: SurfaceOutput) {
    postGlWork("onOutputSurface", onDeclined = { surfaceOutput.close() }) {
      if (released || detached) {
        // See [detached]: the camera this belongs to is gone, and drawing into its surface after
        // Flutter has taken the texture back is not survivable.
        Log.w(TAG, "Refusing a camera effect output: the pipeline is not attached to a camera")
        surfaceOutput.close()
        return@postGlWork
      }
      if (indexOf(surfaceOutput) >= 0) {
        // Two entries would share one `SurfaceOutput`, so the first close would release the render
        // targets the second is still drawing into.
        Log.w(TAG, "Ignoring a camera effect output that is already attached")
        return@postGlWork
      }
      val surface =
          surfaceOutput.getSurface(glExecutor) {
            if (!released) {
              val index = indexOf(surfaceOutput)
              if (index >= 0) {
                // Unbind first: this may be the surface currently current, and EGL defers
                // destroying a bound surface until it stops being one.
                eglCore.makeDefaultCurrent()
                eglCore.releaseSurface(outputs.removeAt(index).eglSurface)
              }
              // The output keyed this set of render targets; nothing will draw into them again.
              pipeline.releaseTargets(surfaceOutput)
            }
            surfaceOutput.close()
          }
      val eglSurface =
          try {
            eglCore.createWindowSurface(surface)
          } catch (e: IllegalStateException) {
            // A surface can be abandoned between CameraX handing it over and this running.
            Log.w(TAG, "Skipping camera effect output: ${e.message}")
            surfaceOutput.close()
            return@postGlWork
          }
      outputs.add(
          OutputSurface(surfaceOutput, eglSurface, surfaceOutput.size, surfaceOutput.targets))

      // A bit test rather than equality: the effect targets both the preview and the encoder, and
      // an output can report either one or, with a shared surface, both at once.
      val isPreview = surfaceOutput.targets and CameraEffect.PREVIEW != 0
      if (isPreview) {
        // The replacement [retireAt] was waiting for.
        glHandler.removeCallbacks(previewOutputLostCheck)
        if (surfaceOutput.size != previewSize) {
          previewSize = surfaceOutput.size
          onPreviewSizeChanged(previewSize.width, previewSize.height)
        }
      }
    }
  }

  /**
   * Re-renders the most recent frame, so a change to the uniforms shows up on a paused preview.
   *
   * Does nothing until the camera being set up has produced a frame of its own. There is no frame
   * to re-render before that — only the previous camera's, under a transform that no longer
   * describes it — and showing it is worse than showing nothing: see [hasCameraFrame]. Nothing is
   * lost by waiting, because the uniforms this was called to publish are read again by the frame
   * that does arrive.
   *
   * "Nothing" is what the preview shows meanwhile, and that is deliberate. A camera rebuilt from
   * scratch comes with a new Flutter texture that has never been drawn into, so the preview is
   * blank until the first real frame, rather than briefly wrong. A preview re-bound on a running
   * camera keeps the texture it already had, so it holds its last good frame across the swap
   * instead of blinking.
   */
  fun redraw() {
    postGlWork("redraw") {
      if (!hasCameraFrame) {
        return@postGlWork
      }
      // The shared texture still holds the last frame latched into it, so there is nothing to
      // advance - this only needs some outstanding `SurfaceTexture` to re-read the transform from.
      latestSurfaceTexture?.let { drawFrame(it, advance = false) }
    }
  }

  /**
   * Renders the frame that has just arrived on `surfaceTexture`.
   *
   * Driven by whichever input signalled rather than by a nominated current one; see
   * [onInputSurface] for why that distinction is the difference between a live preview and a frozen
   * one.
   */
  private fun onFrameAvailable(surfaceTexture: SurfaceTexture) {
    drawFrame(surfaceTexture, advance = true)
  }

  private fun drawFrame(surfaceTexture: SurfaceTexture, advance: Boolean) {
    if (advance) {
      // Hoisted above the early return below: the buffer has to be consumed either way, or the
      // producer stalls once the queue fills up.
      surfaceTexture.updateTexImage()
      // Set even when nothing is attached to draw it. A latched frame leaves the texture holding
      // something *this* camera produced, which is all [redraw] asks about; only
      // [provideInputSurface] makes it stale again.
      hasCameraFrame = true
    }
    if (outputs.isEmpty()) {
      return
    }
    surfaceTexture.getTransformMatrix(textureTransform)
    val timestamp = surfaceTexture.timestamp

    // Walked by index so a dead output can be dropped in place: `retireAt` removes the current
    // element, and not advancing then lands on the one that shifted down into its slot. Nothing
    // here allocates - the source, the transform and each output's uniforms are all reused.
    var index = 0
    while (index < outputs.size) {
      val output = outputs[index]
      val surfaceOutput = output.surfaceOutput
      surfaceOutput.updateTransformMatrix(outputTransform, textureTransform)
      uniformsProvider(output.targets, output.size.width, output.size.height, output.uniforms)
      // `outputTransform` is handed over rather than copied: `render` samples it synchronously,
      // well before the next iteration overwrites it.
      source.set(inputTextureId, CameraGlPipeline.SourceKind.EXTERNAL, outputTransform)

      // Per output rather than around the loop: a consumer that has abandoned its surface must not
      // cost the other outputs their frame.
      try {
        eglCore.makeCurrent(output.eglSurface)
      } catch (e: IllegalStateException) {
        Log.w(TAG, "Dropping an output whose surface can no longer be made current: ${e.message}")
        retireAt(index)
        continue
      }
      // Keyed by the output rather than shared: the preview surface and the encoder's are different
      // sizes for the length of a recording, and one shared set would be reallocated twice a frame.
      pipeline.render(
          source,
          output.uniforms,
          output.size.width,
          output.size.height,
          framebuffer = 0,
          targetKey = surfaceOutput,
      )
      eglCore.setPresentationTime(output.eglSurface, timestamp)
      if (!eglCore.swapBuffers(output.eglSurface)) {
        // The consumer is gone. Retrying every frame is not harmless: when the consumer is
        // Flutter's `ImageReader`-backed surface producer, buffers pushed at a released reader are
        // what leave its raster thread reading closed images, and the engine treats that as fatal.
        Log.w(TAG, "eglSwapBuffers failed; dropping the output, its surface was abandoned")
        retireAt(index)
        continue
      }
      index++
    }
    // Leave a context current so work posted between frames still has one.
    eglCore.makeDefaultCurrent()
  }

  /**
   * Forgets the output at `index`, whose surface has died, so nothing renders into it again.
   *
   * CameraX still owns the `SurfaceOutput` and delivers its release callback in its own time; that
   * callback then finds nothing left to remove and just closes it.
   *
   * Retiring the preview's output *may* be reported upwards, because nothing here can undo it.
   * CameraX hands out a `SurfaceOutput` when it builds a preview pipeline and does not offer
   * another until something makes it build one again; the camera meanwhile keeps running and keeps
   * delivering frames, which now go nowhere. Left alone that is a preview frozen on its last good
   * frame for as long as the camera is open, with nothing in any log to say so.
   *
   * "May", because a preview output dying is usually not a problem at all: rebuilding the preview
   * pipeline is how CameraX applies a new view port, adds the encoder, or takes it away again, and
   * every one of those retires the old output moments before handing over its replacement. Frames
   * are still arriving while that happens, so the retirement is reached through a failed
   * `eglSwapBuffers` rather than through the tidy close callback. Reporting it would have Dart
   * re-bind on top of a re-bind already in flight — two of them racing over the same use case, and
   * whichever lands second decides what the preview looks like. So the report waits, and is dropped
   * if a replacement turns up.
   */
  private fun retireAt(index: Int) {
    val retired = outputs.removeAt(index)
    try {
      // The surface being retired may be the one currently bound — the `swapBuffers` path retires
      // the surface it has just drawn into. EGL defers destroying a bound surface until it stops
      // being current, but binding the always-available 1x1 one first keeps that off the driver's
      // hands.
      eglCore.makeDefaultCurrent()
    } finally {
      eglCore.releaseSurface(retired.eglSurface)
      pipeline.releaseTargets(retired.surfaceOutput)
    }
    if (retired.targets and CameraEffect.PREVIEW != 0) {
      // So the size is re-reported when a replacement arrives, even if it is the same size.
      previewSize = Size(0, 0)
      glHandler.removeCallbacks(previewOutputLostCheck)
      glHandler.postDelayed(previewOutputLostCheck, PREVIEW_OUTPUT_LOST_GRACE_MILLIS)
    }
  }

  /**
   * Reports a lost preview output, unless one has arrived in the meantime.
   *
   * Posted by [retireAt] rather than run there; see its documentation for why the wait is the whole
   * point. Runs on the render thread, so [outputs] is read from the thread that owns it.
   */
  private val previewOutputLostCheck = Runnable {
    if (!released && !detached && !hasPreviewOutput()) {
      Log.w(TAG, "The preview output was not replaced; asking for a new one")
      onPreviewOutputLost()
    }
  }

  private fun hasPreviewOutput(): Boolean = outputs.any { it.targets and CameraEffect.PREVIEW != 0 }

  /**
   * Drops every attached output without tearing the processor down. Must run on the GL thread.
   *
   * Used when a camera is disposed but the pipeline is going to be reused by the next one. After
   * this returns nothing can draw into the outputs' surfaces, which is what makes it safe to hand
   * Flutter's texture back to the engine.
   *
   * CameraX still owns the `SurfaceOutput`s and delivers their release callbacks in its own time;
   * those then find nothing left to remove and just close them again, which is idempotent.
   */
  fun detachOutputs() {
    // Sticky until the next camera's input surface arrives: see [detached].
    detached = true
    // The camera whose frame is in the shared texture is going away, so that frame no longer
    // describes anything. [provideInputSurface] would clear this too, but a [redraw] can arrive in
    // between and there is no reason to let it draw what is left over.
    hasCameraFrame = false
    // The camera these belonged to is going away; there is nothing left to ask for a new surface.
    glHandler.removeCallbacks(previewOutputLostCheck)
    // Unbind first: one of these surfaces is very likely the one currently current, and EGL defers
    // destroying a bound surface until it stops being one.
    eglCore.makeDefaultCurrent()
    outputs.forEach { output ->
      eglCore.releaseSurface(output.eglSurface)
      pipeline.releaseTargets(output.surfaceOutput)
      output.surfaceOutput.close()
    }
    outputs.clear()
    // So the next camera's preview surface is reported even if it happens to be the same size.
    previewSize = Size(0, 0)
  }

  /** Releases every GL object this processor owns. Must run on the GL thread. */
  fun release() {
    released = true
    glHandler.removeCallbacks(previewOutputLostCheck)
    outputs.forEach { output ->
      eglCore.releaseSurface(output.eglSurface)
      pipeline.releaseTargets(output.surfaceOutput)
      output.surfaceOutput.close()
    }
    outputs.clear()
    releaseInput()
  }

  /**
   * Releases the shared input texture.
   *
   * Only reached from [release], because the texture belongs to the processor rather than to any
   * request. The `SurfaceTexture`s and `Surface`s built on it are released by the completion of the
   * requests that created them, which needs no GL context and so is safe either side of this.
   */
  private fun releaseInput() {
    latestSurfaceTexture = null
    GlUtil.deleteTexture(inputTextureId)
    inputTextureId = 0
  }

  private companion object {
    const val TAG = "CameraSurfaceProcessor"

    /**
     * How long a retired preview output has to be replaced before the loss is reported.
     *
     * Comfortably longer than a re-bind: configuring a capture session is on the order of a hundred
     * milliseconds, and the whole swap a few hundred. Erring long costs a slightly later recovery
     * from a genuinely dead surface; erring short costs a spurious re-bind in the middle of a real
     * one, which is far worse.
     */
    const val PREVIEW_OUTPUT_LOST_GRACE_MILLIS = 1_500L
  }
}
