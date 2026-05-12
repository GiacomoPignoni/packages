// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.util.Log
import java.io.File
import kotlin.math.max

/**
 * The render pipeline: programs, auxiliary render targets, and the grain and LUT textures.
 *
 * Port of `VideoFrameRenderer.swift`. The Metal version fans out over three source pixel formats
 * and two command queues; this one has a single GL context and two source kinds (the camera's
 * external texture and a still-capture bitmap), which collapses most of that bookkeeping.
 *
 * Every method must run on the thread that owns the [EglCore] context.
 */
class CameraGlPipeline(private val eglCore: EglCore) {
  /** Which sampler a program's `sampleSource` reads from. */
  enum class SourceKind {
    /** The camera's `SurfaceTexture`, sampled through `samplerExternalOES`. */
    EXTERNAL,
    /** A decoded still-capture bitmap, sampled through `sampler2D`. */
    BITMAP,
    /**
     * An uncompressed `YUV_420_888` still capture, sampled as a luma and a chroma texture.
     *
     * What the still path uses. [BITMAP] remains for a device that will not give up a JPEG; see
     * `StillCaptureProcessor`.
     */
    YUV,
  }

  /**
   * A bound source frame.
   *
   * Deliberately carries no dimensions: after [transform] the frame lives in output space, and
   * every pass sizes itself from the output it is rendering into.
   */
  class Source(
      var textureId: Int = 0,
      var kind: SourceKind = SourceKind.EXTERNAL,
      /**
       * The chroma texture, for [SourceKind.YUV] only, where [textureId] is the luma plane.
       *
       * Ignored by every other kind, which carry their colour in one texture.
       */
      var chromaTextureId: Int = 0,
      /** Whether a [SourceKind.YUV] source's luma is full-range rather than studio swing. */
      var yuvFullRange: Boolean = true,
      /**
       * Output UV to source UV, or null for the identity.
       *
       * For the camera this is the matrix CameraX composes the sensor orientation, mirroring and
       * buffer crop into; for a still capture it is the quarter turn that brings the sensor's
       * buffer upright. Either way the shader has no orientation handling of its own.
       */
      var transform: FloatArray? = null,
  ) {
    /**
     * Mutable, and reused by the per-frame path.
     *
     * A fresh instance per frame per output is garbage on the one thread whose jitter shows up as
     * dropped frames. [render] consumes a source synchronously, so one instance can be refilled for
     * each output in turn.
     */
    fun set(textureId: Int, kind: SourceKind, transform: FloatArray?) {
      this.textureId = textureId
      this.kind = kind
      this.transform = transform
    }
  }

  private val programs = HashMap<Pair<String, SourceKind>, ShaderProgram>()

  // Held as the `lazy` delegate rather than only as the property so that `release` can ask whether
  // it was ever initialized. Touching the property to release it would otherwise *compile* the
  // program purely to delete it - and would throw from inside teardown if the context is gone.
  private val gaussianProgramDelegate = lazy {
    ShaderProgram(CameraShaderSource.VERTEX, CameraShaderSource.GAUSSIAN_FRAGMENT)
  }
  private val gaussianProgram by gaussianProgramDelegate

  /**
   * The off-screen targets, one set per output.
   *
   * Sized from the output being drawn, so a single shared set would be reallocated on every draw as
   * soon as two outputs of different sizes are attached - which is the normal state while
   * recording, where the preview surface and the encoder's rarely agree. Keying by output makes
   * each set stable at its own size instead.
   *
   * Keys are opaque tokens owned by the caller; see [render] and [releaseTargets].
   */
  private val targetSets = HashMap<Any, TargetSet>()

  private var grainTextureId = 0
  private var grainTexturePath: String? = null
  private var lutTextureId = 0
  private var lutTexturePath: String? = null

  /**
   * Width / height of the loaded grain tile, or 1 when none is loaded.
   *
   * The grain UV scale has to fold this in, or a non-square tile is stretched to fill a square
   * cell. Volatile because the still-capture path builds its uniforms on a CameraX executor thread
   * while this is written on the render thread.
   */
  @Volatile
  var grainTextureAspect: Float = 1f
    private set

  /**
   * A 1x1 stand-in bound to the grain and LUT samplers when no image is loaded.
   *
   * Held as its `lazy` delegate for the same reason as [gaussianProgramDelegate].
   */
  private val placeholderTextureDelegate = lazy {
    val bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
    bitmap.setPixel(0, 0, 0xFF808080.toInt())
    val id = GlUtil.createTextureFromBitmap(bitmap, GLES30.GL_CLAMP_TO_EDGE)
    bitmap.recycle()
    id
  }
  private val placeholderTexture: Int by placeholderTextureDelegate

  /**
   * Compiles the programs the live preview needs, so the first frame does not pay for it.
   *
   * Must be called with a context current. The remaining programs stay lazy: they belong to effects
   * that are usually off, and to the still-capture path.
   */
  fun warmUp() {
    program(CameraShaderSource.MAIN_FRAGMENT, SourceKind.EXTERNAL)
  }

  /**
   * Compiles the programs a still capture needs, so the first photo does not pay for it.
   *
   * The cache is keyed by source kind, and a still samples a `sampler2D` where the preview samples
   * a `samplerExternalOES` — so none of the preview's programs can be reused, and without this
   * every one of these compiles inside the first `render` a shutter press triggers. That is
   * measurable: these are large fragment shaders, and a driver takes tens of milliseconds over
   * each.
   *
   * The Gaussian is compiled here too. It is source-kind agnostic and so shared with the preview,
   * but the preview only reaches it once an effect that blurs is switched on, which may be after
   * the first photo.
   *
   * Must be called with a context current, off the capture path.
   */
  fun warmUpStillPrograms() {
    // The YUV kind only: that is what an uncompressed capture arrives as, and compiling the BITMAP
    // variants too would double a cost this exists to avoid. A device that falls back to JPEG
    // delivery compiles them on its first photo, as it did before.
    program(CameraShaderSource.MAIN_FRAGMENT, SourceKind.YUV)
    program(CameraShaderSource.PREPASS_H_FRAGMENT, SourceKind.YUV)
    program(CameraShaderSource.BLOOM_BRIGHT_FRAGMENT, SourceKind.YUV)
    program(CameraShaderSource.FRAME_BLUR_DOWNSAMPLE_FRAGMENT, SourceKind.YUV)
    gaussianProgram
  }

  /**
   * Renders one frame.
   *
   * `framebuffer` is 0 to draw into the current EGL surface, or an FBO handle for the still-capture
   * path. `targetKey` identifies the output for the purpose of [targetSets]: pass a token that is
   * stable for as long as the output is, and hand it to [releaseTargets] when the output goes away.
   *
   * `flipOutputY` rasterizes the final pass upside down, which is what the still-capture path uses
   * to cancel `glReadPixels`' bottom-up read. It applies to the main pass alone: the auxiliary
   * targets are read back through the shaders' own `renderedTargetUv` and must stay as they are.
   */
  fun render(
      source: Source,
      uniforms: CameraUniforms,
      outputWidth: Int,
      outputHeight: Int,
      framebuffer: Int,
      targetKey: Any,
      flipOutputY: Boolean = false,
  ) {
    // Every pass works in output space, not source space: `source.transform` may rotate the frame
    // on its way in (CameraX bakes the sensor orientation into it), so a target shaped like the
    // source would store a portrait frame in a landscape texture and stretch every blur along one
    // axis by the aspect ratio squared.
    //
    // The auxiliary blurs work at quarter resolution. They are heavy low-passes, so working small
    // costs nothing visually while cutting both the fill cost and the Gaussian sigma about 4x each
    // versus half resolution.
    val auxWidth = max(1, outputWidth / 4)
    val auxHeight = max(1, outputHeight / 4)
    val targets = targetSets.getOrPut(targetKey) { TargetSet() }

    if (uniforms.needsPreBlurPass) {
      renderPreBlurPass(source, uniforms, targets.preBlur, outputWidth, outputHeight)
    }
    if (uniforms.needsBloomPass) {
      renderAuxBlur(
          source = source,
          uniforms = uniforms,
          fragmentSource = CameraShaderSource.BLOOM_BRIGHT_FRAGMENT,
          first = targets.bloomA,
          second = targets.bloomB,
          width = auxWidth,
          height = auxHeight,
          // Matches AuxBlurKind.bloom's sigma in VideoFrameRenderer.
          sigma = max(2.0f, 0.02f * max(auxWidth, auxHeight)),
      )
    }
    if (uniforms.needsFrameBlurPass) {
      renderAuxBlur(
          source = source,
          uniforms = uniforms,
          fragmentSource = CameraShaderSource.FRAME_BLUR_DOWNSAMPLE_FRAGMENT,
          first = targets.frameBlurA,
          second = targets.frameBlurB,
          width = auxWidth,
          height = auxHeight,
          // Tighter than bloom's halo so diffusion reads as soft detail rather than defocus.
          sigma = max(1.5f, 0.015f * max(auxWidth, auxHeight)),
      )
    }

    val program = program(CameraShaderSource.MAIN_FRAGMENT, source.kind)
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer)
    GLES30.glViewport(0, 0, outputWidth, outputHeight)
    program.use(if (flipOutputY) FLIP_Y else NO_FLIP_Y)
    bindSource(program, source)
    bindUniforms(program, uniforms, outputWidth, outputHeight)

    program.bindTexture("uGrainTexture", 1, GLES30.GL_TEXTURE_2D, grainOrPlaceholder())
    program.bindTexture("uLutTexture", 2, GLES30.GL_TEXTURE_2D, lutOrPlaceholder())
    // A pass that did not run this frame gets the neutral placeholder rather than whatever its
    // target still holds from an earlier one. Every reader is gated on a uniform that is zero in
    // exactly those cases, so nothing samples it either way today - but a stale frame left bound is
    // a trap for the next ungated read to be added, and a 1x1 grey is not.
    program.bindTexture(
        "uPreBlurredTexture",
        3,
        GLES30.GL_TEXTURE_2D,
        if (uniforms.needsPreBlurPass) targets.preBlur.texture else placeholderTexture,
    )
    program.bindTexture(
        "uBloomTexture",
        4,
        GLES30.GL_TEXTURE_2D,
        if (uniforms.needsBloomPass) targets.bloomA.texture else placeholderTexture,
    )
    program.bindTexture(
        "uFrameBlurTexture",
        5,
        GLES30.GL_TEXTURE_2D,
        if (uniforms.needsFrameBlurPass) targets.frameBlurA.texture else placeholderTexture,
    )

    GlUtil.drawFullscreenTriangle()
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
  }

  /** Releases the target set held for `targetKey`, if any. */
  fun releaseTargets(targetKey: Any) {
    targetSets.remove(targetKey)?.release()
  }

  /** Horizontal half of the old-camera separable Gaussian, at full output resolution. */
  private fun renderPreBlurPass(
      source: Source,
      uniforms: CameraUniforms,
      target: RenderTarget,
      outputWidth: Int,
      outputHeight: Int,
  ) {
    target.ensure(outputWidth, outputHeight, eglCore.supportsHalfFloatTargets)
    val program = program(CameraShaderSource.PREPASS_H_FRAGMENT, source.kind)
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, target.framebuffer)
    GLES30.glViewport(0, 0, outputWidth, outputHeight)
    program.use(NO_FLIP_Y)
    bindSource(program, source)
    program.uniform2f("uUvScale", uniforms.uvScaleX, uniforms.uvScaleY)
    program.uniform1f("uResolution", uniforms.resolution)
    program.uniform2f("uSourceSize", outputWidth.toFloat(), outputHeight.toFloat())
    GlUtil.drawFullscreenTriangle()
  }

  /**
   * Renders `fragmentSource` into `first`, then blurs it separably through `second` and back.
   *
   * Ending in `first` means the main pass always samples the same texture whether or not the blur
   * ran an even number of passes.
   */
  private fun renderAuxBlur(
      source: Source,
      uniforms: CameraUniforms,
      fragmentSource: String,
      first: RenderTarget,
      second: RenderTarget,
      width: Int,
      height: Int,
      sigma: Float,
  ) {
    val halfFloat = eglCore.supportsHalfFloatTargets
    first.ensure(width, height, halfFloat)
    second.ensure(width, height, halfFloat)

    val extractProgram = program(fragmentSource, source.kind)
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, first.framebuffer)
    GLES30.glViewport(0, 0, width, height)
    extractProgram.use(NO_FLIP_Y)
    bindSource(extractProgram, source)
    extractProgram.uniform2f("uUvScale", uniforms.uvScaleX, uniforms.uvScaleY)
    // One aux texel in source-UV units: the pass renders the uvScale-cropped region across `width`
    // x `height` texels, so that is the span each of them covers. `sampleSourceBox` needs it to
    // average the footprint instead of point-sampling a corner of it.
    extractProgram.uniform2f("uAuxTexel", uniforms.uvScaleX / width, uniforms.uvScaleY / height)
    // Declared only by the bloom bright pass; the frame-blur variant has no threshold, so its
    // location comes back -1 and the set is a no-op.
    extractProgram.uniform1f("uBloomThreshold", BLOOM_THRESHOLD)
    GlUtil.drawFullscreenTriangle()

    blurPass(from = first, to = second, width, height, sigma, horizontal = true)
    blurPass(from = second, to = first, width, height, sigma, horizontal = false)
  }

  private fun blurPass(
      from: RenderTarget,
      to: RenderTarget,
      width: Int,
      height: Int,
      sigma: Float,
      horizontal: Boolean,
  ) {
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, to.framebuffer)
    GLES30.glViewport(0, 0, width, height)
    gaussianProgram.use(NO_FLIP_Y)
    // The shared vertex shader applies uUvScale; the blur covers the whole texture.
    gaussianProgram.uniform2f("uUvScale", 1f, 1f)
    gaussianProgram.uniform2f(
        "uBlurDirection",
        if (horizontal) 1f / width else 0f,
        if (horizontal) 0f else 1f / height,
    )
    gaussianProgram.uniform1f("uSigma", sigma)
    gaussianProgram.bindTexture("uBlurSource", 0, GLES30.GL_TEXTURE_2D, from.texture)
    GlUtil.drawFullscreenTriangle()
  }

  private fun bindSource(program: ShaderProgram, source: Source) {
    if (source.kind == SourceKind.YUV) {
      // Texture unit 6: units 0-5 are spoken for by the source and the grain, LUT, pre-blur, bloom
      // and frame-blur textures the main pass binds.
      program.bindTexture("uSourceY", 0, GLES30.GL_TEXTURE_2D, source.textureId)
      program.bindTexture("uSourceUV", 6, GLES30.GL_TEXTURE_2D, source.chromaTextureId)
      program.uniform1f("uYuvFullRange", if (source.yuvFullRange) 1f else 0f)
      program.uniformMatrix4("uSourceTransform", source.transform ?: IDENTITY_MATRIX)
      return
    }
    val target =
        if (source.kind == SourceKind.EXTERNAL) GLES11Ext.GL_TEXTURE_EXTERNAL_OES
        else GLES30.GL_TEXTURE_2D
    program.bindTexture("uSource", 0, target, source.textureId)
    // Both kinds now: a still capture arrives in sensor orientation and is turned upright by this
    // matrix rather than by rotating the Bitmap on the CPU.
    program.uniformMatrix4("uSourceTransform", source.transform ?: IDENTITY_MATRIX)
  }

  private fun bindUniforms(
      program: ShaderProgram,
      u: CameraUniforms,
      outputWidth: Int,
      outputHeight: Int,
  ) {
    program.uniform2f("uUvScale", u.uvScaleX, u.uvScaleY)
    program.uniform1f("uVignetteIntensity", u.vignetteIntensity)
    program.uniform1f("uCaptureScale", u.captureScale)
    program.uniform1f("uDarkenOutside", u.darkenOutside)
    program.uniform1f("uOutputAspect", u.outputAspect)
    program.uniform1f("uGrainOpacity", u.grainOpacity)
    program.uniform2f("uGrainOffset", u.grainOffsetX, u.grainOffsetY)
    program.uniform2f("uGrainUVScale", u.grainUVScaleX, u.grainUVScaleY)
    program.uniform1f("uGrainSwapUV", u.grainSwapUV)
    program.uniform1f("uLutIntensity", u.lutIntensity)
    program.uniform1f("uCaptureCornerRadius", u.captureCornerRadius)
    program.uniform1f("uResolution", u.resolution)
    program.uniform1f("uColorShift", u.colorShift)
    program.uniform1f("uMist", u.mist)
    program.uniform1f("uGrainBehavior", u.grainBehavior)
    program.uniform1f("uCheapFisheye", u.cheapFisheye)
    program.uniform1f("uPrism", u.prism)
    program.uniform1f("uBloom", u.bloom)
    program.uniform1f("uDiffusion", u.diffusion)
    program.uniform1f("uDither", u.dither)
    // The frame as this pass sees it, which is the output rather than the source once
    // `source.transform` has rotated the incoming buffer. Every pixel-space tap offset scales off
    // it, so the two must not be confused.
    program.uniform2f("uSourceSize", outputWidth.toFloat(), outputHeight.toFloat())
  }

  private fun program(fragmentSource: String, kind: SourceKind): ShaderProgram =
      programs.getOrPut(fragmentSource to kind) {
        val prefix =
            when (kind) {
              SourceKind.EXTERNAL -> CameraShaderSource.DEFINE_SOURCE_EXTERNAL
              SourceKind.BITMAP -> CameraShaderSource.DEFINE_SOURCE_2D
              SourceKind.YUV -> CameraShaderSource.DEFINE_SOURCE_YUV
            }
        ShaderProgram(CameraShaderSource.VERTEX, prefix + fragmentSource)
      }

  // ---------------------------------------------------------------------------
  // Grain texture
  // ---------------------------------------------------------------------------

  /**
   * Loads the grain image at `path`, replacing any previously loaded one.
   *
   * Reloading the same path is a no-op, so pushing an unchanged [EffectsValues] every frame does
   * not re-decode. On failure the previous texture is kept, matching the iOS behaviour.
   */
  fun loadGrainTexture(path: String) {
    if (path == grainTexturePath && grainTextureId != 0) {
      return
    }
    val bitmap = decodeBitmap(path) ?: return
    GlUtil.deleteTexture(grainTextureId)
    // GL_REPEAT matches Metal's address::repeat grain sampler: the tile is walked with fract() and
    // has to wrap seamlessly.
    grainTextureId = GlUtil.createTextureFromBitmap(bitmap, GLES30.GL_REPEAT)
    grainTexturePath = path
    grainTextureAspect = bitmap.width.toFloat() / bitmap.height.toFloat()
    bitmap.recycle()
  }

  fun clearGrainTexture() {
    GlUtil.deleteTexture(grainTextureId)
    grainTextureId = 0
    grainTexturePath = null
    grainTextureAspect = 1f
  }

  // ---------------------------------------------------------------------------
  // LUT texture
  // ---------------------------------------------------------------------------

  /**
   * Loads the 512x512 LUT atlas at `path`.
   *
   * The atlas is uploaded verbatim and indexed by the shader, so unlike the Metal version there is
   * no cube unpacking step here. A wrongly sized image is rejected rather than sampled, since the
   * tile arithmetic would silently produce a garbage grade.
   */
  fun loadLutTexture(path: String) {
    if (path == lutTexturePath && lutTextureId != 0) {
      return
    }
    val bitmap = decodeBitmap(path) ?: return
    if (bitmap.width != LUT_ATLAS_SIZE || bitmap.height != LUT_ATLAS_SIZE) {
      Log.e(
          TAG,
          "LUT image at '$path' is ${bitmap.width}x${bitmap.height}; expected exactly " +
              "${LUT_ATLAS_SIZE}x$LUT_ATLAS_SIZE (an 8x8 grid of 64x64 tiles)",
      )
      bitmap.recycle()
      return
    }
    GlUtil.deleteTexture(lutTextureId)
    lutTextureId = GlUtil.createTextureFromBitmap(bitmap, GLES30.GL_CLAMP_TO_EDGE)
    lutTexturePath = path
    bitmap.recycle()
  }

  fun clearLutTexture() {
    GlUtil.deleteTexture(lutTextureId)
    lutTextureId = 0
    lutTexturePath = null
  }

  private fun decodeBitmap(path: String): Bitmap? {
    val file = File(path)
    if (!file.isFile) {
      Log.e(TAG, "Cannot open image at '$path'")
      return null
    }
    // ARGB_8888 without pre-scaling: both the grain tile and the LUT atlas are data, and a density
    // scale would resample them.
    val options =
        BitmapFactory.Options().apply {
          inScaled = false
          inPreferredConfig = Bitmap.Config.ARGB_8888
        }
    val bitmap = BitmapFactory.decodeFile(path, options)
    if (bitmap == null) {
      Log.e(TAG, "Failed to decode image at '$path'")
    }
    return bitmap
  }

  fun release() {
    programs.values.forEach { it.release() }
    programs.clear()
    // Only if they were ever built: an effects-off session never compiles the Gaussian program or
    // uploads the placeholder, and creating one here just to delete it would be work at best and a
    // throw from inside teardown at worst.
    if (gaussianProgramDelegate.isInitialized()) {
      gaussianProgram.release()
    }
    targetSets.values.forEach { it.release() }
    targetSets.clear()
    clearGrainTexture()
    clearLutTexture()
    if (placeholderTextureDelegate.isInitialized()) {
      GlUtil.deleteTexture(placeholderTexture)
    }
  }

  private fun grainOrPlaceholder() = if (grainTextureId != 0) grainTextureId else placeholderTexture

  private fun lutOrPlaceholder() = if (lutTextureId != 0) lutTextureId else placeholderTexture

  private companion object {
    const val TAG = "CameraGlPipeline"
    const val LUT_ATLAS_SIZE = 512

    /**
     * Linear-light luminance a pixel has to clear before it blooms.
     *
     * See `uBloomThreshold` in [CameraShaderSource.BLOOM_BRIGHT_FRAGMENT] for why this is worth
     * being able to move. 0.75 is the value the Metal shader bakes in.
     */
    const val BLOOM_THRESHOLD = 0.75f

    /** `uFlipY` values: rasterize normally, or upside down. See [CameraShaderSource.VERTEX]. */
    const val NO_FLIP_Y = 1f

    const val FLIP_Y = -1f

    val IDENTITY_MATRIX =
        floatArrayOf(1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f)
  }
}

/**
 * The off-screen targets one output needs, sized and released as a unit.
 *
 * Every one of them is half float where the device can render to it. The pre-pass and frame blur
 * carry the whole tonal range in linear light, where 8 bits band in the shadows; the bloom halo is
 * LDR but only a few percent of full scale by the time the blur has spread it, which 8-bit linear
 * quantises to a handful of codes - visible as a stepped halo rather than a smooth one. This is
 * where the Metal renderer settles for `.rgba8Unorm` on the bloom pair.
 */
private class TargetSet {
  val preBlur = RenderTarget(halfFloat = true)
  val bloomA = RenderTarget(halfFloat = true)
  val bloomB = RenderTarget(halfFloat = true)
  val frameBlurA = RenderTarget(halfFloat = true)
  val frameBlurB = RenderTarget(halfFloat = true)

  fun release() {
    listOf(preBlur, bloomA, bloomB, frameBlurA, frameBlurB).forEach { it.release() }
  }
}

/** A lazily allocated off-screen colour target that reallocates when its size changes. */
private class RenderTarget(private val halfFloat: Boolean) {
  var texture = 0
    private set

  var framebuffer = 0
    private set

  private var width = 0
  private var height = 0

  fun ensure(width: Int, height: Int, halfFloatSupported: Boolean) {
    if (texture != 0 && this.width == width && this.height == height) {
      return
    }
    release()
    texture = GlUtil.createTargetTexture(width, height, halfFloat && halfFloatSupported)
    framebuffer = GlUtil.createFramebuffer(texture)
    this.width = width
    this.height = height
  }

  fun release() {
    GlUtil.deleteFramebuffer(framebuffer)
    GlUtil.deleteTexture(texture)
    framebuffer = 0
    texture = 0
    width = 0
    height = 0
  }
}

/** A linked program with a memoised uniform-location table. */
private class ShaderProgram(vertexSource: String, fragmentSource: String) {
  private val id = GlUtil.buildProgram(vertexSource, fragmentSource)
  private val locations = HashMap<String, Int>()

  /**
   * Binds the program and sets the one uniform every pass must decide on.
   *
   * `uFlipY` takes the flip as a required argument rather than defaulting, because an unset float
   * uniform is 0 and would collapse the fullscreen triangle to a line — a pass that forgot it would
   * render nothing at all.
   */
  fun use(flipY: Float) {
    GLES30.glUseProgram(id)
    uniform1f("uFlipY", flipY)
  }

  fun uniform1f(name: String, value: Float) {
    val location = location(name)
    if (location >= 0) GLES30.glUniform1f(location, value)
  }

  fun uniform2f(name: String, x: Float, y: Float) {
    val location = location(name)
    if (location >= 0) GLES30.glUniform2f(location, x, y)
  }

  fun uniformMatrix4(name: String, matrix: FloatArray) {
    val location = location(name)
    if (location >= 0) GLES30.glUniformMatrix4fv(location, 1, false, matrix, 0)
  }

  fun bindTexture(name: String, unit: Int, target: Int, texture: Int) {
    val location = location(name)
    if (location < 0) return
    GLES30.glActiveTexture(GLES30.GL_TEXTURE0 + unit)
    GLES30.glBindTexture(target, texture)
    GLES30.glUniform1i(location, unit)
  }

  // A location of -1 means the compiler optimised the uniform away because nothing reads it in
  // this variant; setting it is a no-op rather than an error.
  private fun location(name: String): Int =
      locations.getOrPut(name) { GLES30.glGetUniformLocation(id, name) }

  fun release() {
    GLES30.glDeleteProgram(id)
  }
}
