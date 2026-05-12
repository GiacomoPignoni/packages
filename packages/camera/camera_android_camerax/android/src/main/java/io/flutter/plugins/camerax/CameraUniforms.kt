// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Per-draw shader uniforms.
 *
 * Field-for-field port of `CameraUniforms` in `CameraShaderTypes.h`; the comments there explain
 * what each one means and are not repeated in full here.
 *
 * Instances are snapshotted before a frame is submitted so that a concurrent
 * [CameraEffectsManager.setEffectsValues] can never tear a value mid-frame.
 */
data class CameraUniforms(
    var vignetteIntensity: Float = 0f,
    /** Center-anchored UV transform: shrink (< 1) to crop the sampled sub-rect. */
    var uvScaleX: Float = 1f,
    var uvScaleY: Float = 1f,
    /** Inner-rect capture scale on top of the aspect-ratio crop; 1.0 means no extra narrowing. */
    var captureScale: Float = 1f,
    /** 0 for capture passes; ~0.4 dims the area outside the scaled rect in preview passes. */
    var darkenOutside: Float = 0f,
    /** width/height of the rendered output, so the vignette stays circular in pixel space. */
    var outputAspect: Float = 1f,
    var grainOpacity: Float = 0f,
    var grainOffsetX: Float = 0f,
    var grainOffsetY: Float = 0f,
    var grainUVScaleX: Float = 1f,
    var grainUVScaleY: Float = 1f,
    /** 1.0 swaps the grain sampling axes for sensor-orientation photo buffers. */
    var grainSwapUV: Float = 0f,
    var lutIntensity: Float = 0f,
    var captureCornerRadius: Float = 0f,
    var resolution: Float = 0f,
    var colorShift: Float = 0f,
    var mist: Float = 0f,
    /** 0 = overlay grain, 1 = dark-only. */
    var grainBehavior: Float = 0f,
    var cheapFisheye: Float = 0f,
    var prism: Float = 0f,
    var bloom: Float = 0f,
    var diffusion: Float = 0f,
    /**
     * Whether the final 8-bit quantization is dithered; 1.0 for every ordinary pass.
     *
     * The one field with no counterpart in `CameraShaderTypes.h`, because it answers a question
     * only this platform's still path asks. Dither exists to break up the contours the effect
     * chain's linear-light arithmetic leaves behind when it is quantized back to 8 bits, and it is
     * worth ±1 LSB of noise to be rid of them. A pass with every effect off has no such contours to
     * break up and nothing worth trading noise for - see [CameraEffectsManager.neutralPlan], which
     * is the only place this is 0.
     */
    var dither: Float = 1f,
) {
  /** Whether the old-camera pre-pass needs to run before the main pass. */
  val needsPreBlurPass: Boolean
    get() = resolution > 0f

  /** Whether the bloom bright-pass and its blur need to run. */
  val needsBloomPass: Boolean
    get() = bloom > 0f

  /** Whether the shared mist/diffusion frame blur needs to run. */
  val needsFrameBlurPass: Boolean
    get() = mist > 0f || diffusion > 0f

  /**
   * Overwrites every field with `other`'s.
   *
   * The allocation-free equivalent of [copy], for the per-frame path: a fresh instance per frame
   * per output is steady-state garbage on the render thread, where a collection shows up as a
   * dropped frame. [copy] is still the right choice off that path, such as for a still capture.
   */
  fun setFrom(other: CameraUniforms) {
    vignetteIntensity = other.vignetteIntensity
    uvScaleX = other.uvScaleX
    uvScaleY = other.uvScaleY
    captureScale = other.captureScale
    darkenOutside = other.darkenOutside
    outputAspect = other.outputAspect
    grainOpacity = other.grainOpacity
    grainOffsetX = other.grainOffsetX
    grainOffsetY = other.grainOffsetY
    grainUVScaleX = other.grainUVScaleX
    grainUVScaleY = other.grainUVScaleY
    grainSwapUV = other.grainSwapUV
    lutIntensity = other.lutIntensity
    captureCornerRadius = other.captureCornerRadius
    resolution = other.resolution
    colorShift = other.colorShift
    mist = other.mist
    grainBehavior = other.grainBehavior
    cheapFisheye = other.cheapFisheye
    prism = other.prism
    bloom = other.bloom
    diffusion = other.diffusion
    dither = other.dither
  }

  /**
   * Copies the effect-controlled fields out of `values`, leaving the geometry fields alone.
   *
   * `EffectsValues` on the Dart side only enforces its documented `[0.0, 1.0]` ranges with an
   * `assert`, which release builds strip, so an out-of-range or non-finite value can reach here
   * uncaught. Each field goes through [clampedIntensity] rather than being trusted, to keep a bad
   * value a no-op instead of a broken-looking frame.
   */
  fun applyEffects(values: PlatformEffectsValues) {
    vignetteIntensity = values.vignetteIntensity.clampedIntensity()
    grainOpacity =
        if (values.grainNoisePath == null) 0f else values.grainOpacity.clampedIntensity()
    grainBehavior = if (values.grainBehavior == PlatformGrainBehavior.DARK_ONLY) 1f else 0f
    lutIntensity = if (values.lutFilePath == null) 0f else values.lutIntensity.clampedIntensity()
    resolution = values.resolution.clampedIntensity()
    colorShift = values.colorShift.clampedIntensity()
    mist = values.mist.clampedIntensity()
    prism = values.prism.clampedIntensity()
    cheapFisheye = if (values.cheapFisheye) 1f else 0f
    bloom = values.bloom.clampedIntensity()
    diffusion = values.diffusion.clampedIntensity()
  }

  /**
   * Clamps a `[0.0, 1.0]`-documented effect value into that range, treating a non-finite input as
   * off.
   *
   * Plain [coerceIn] does not do this: it compiles to the primitive `<`/`>` operators, which are
   * false for every comparison against NaN, so `Float.NaN.coerceIn(0f, 1f)` returns NaN unchanged
   * rather than a clamped value.
   */
  private fun Double.clampedIntensity(): Float {
    val value = toFloat()
    return if (value.isNaN()) 0f else value.coerceIn(0f, 1f)
  }

  companion object {
    /**
     * How much the preview dims the area outside the capture-scale rect.
     *
     * Matches `VideoFrameRenderer`'s preview override, so the same capture scale reads the same on
     * both platforms.
     */
    const val PREVIEW_DARKEN_OUTSIDE = 0.4f
  }
}

/** Geometry shared by the preview, video and still-capture paths. */
object CameraGeometry {
  /**
   * Rounds to an even pixel count, never below 2.
   *
   * H.264/HEVC encoders refuse odd dimensions on most configurations.
   */
  fun evenRound(v: Float): Int {
    val r = v.roundToInt()
    return max(2, r - (r % 2))
  }

  /** Output dimensions and UV scale for a center-crop to `targetRatio` (width/height). */
  data class Crop(val width: Int, val height: Int, val uvScaleX: Float, val uvScaleY: Float)

  /**
   * Re-orients `targetRatio` to the orientation of a `sourceWidth` x `sourceHeight` frame.
   *
   * The ratio Dart hands down describes the *shape* of the wanted rectangle in the user's
   * orientation - below 1 portrait, above 1 landscape. A frame that arrives turned the other way
   * (the preview is delivered in sensor orientation, which is landscape on nearly every device) has
   * to crop to the inverted shape for the result to read as the requested one once it is rotated
   * for display. Port of `DefaultCamera.effectiveAspectRatio`.
   */
  fun effectiveAspectRatio(targetRatio: Double?, sourceWidth: Int, sourceHeight: Int): Double? {
    if (targetRatio == null || targetRatio <= 0.0 || !targetRatio.isFinite()) {
      return targetRatio
    }
    if (sourceWidth <= 0 || sourceHeight <= 0 || targetRatio == 1.0) {
      return targetRatio
    }
    val sourceIsLandscape = sourceWidth > sourceHeight
    val ratioIsLandscape = targetRatio > 1.0
    return if (sourceIsLandscape == ratioIsLandscape) targetRatio else 1.0 / targetRatio
  }

  /**
   * Center-crops `sourceWidth` x `sourceHeight` to `targetRatio`.
   *
   * Returns the source size with an identity UV scale when `targetRatio` is null or not a usable
   * positive ratio, which is how "no crop" is expressed. It is also a no-op when the source already
   * has the target's shape, which is what keeps the still-capture crop idempotent against the
   * `ViewPort` crop CameraX may already have applied upstream.
   */
  fun croppedDimensions(sourceWidth: Int, sourceHeight: Int, targetRatio: Double?): Crop {
    if (sourceWidth <= 0 ||
        sourceHeight <= 0 ||
        targetRatio == null ||
        targetRatio <= 0.0 ||
        !targetRatio.isFinite()) {
      // Still round to even so an odd source dimension does not reach the encoder.
      return Crop(evenRound(sourceWidth.toFloat()), evenRound(sourceHeight.toFloat()), 1f, 1f)
    }

    val sourceRatio = sourceWidth.toDouble() / sourceHeight.toDouble()
    var outWidth = sourceWidth
    var outHeight = sourceHeight
    when {
      // Target wider than source: crop top and bottom.
      targetRatio > sourceRatio -> outHeight = evenRound((sourceWidth / targetRatio).toFloat())
      // Target taller: crop left and right.
      targetRatio < sourceRatio -> outWidth = evenRound((sourceHeight * targetRatio).toFloat())
      else -> {
        outWidth = evenRound(outWidth.toFloat())
        outHeight = evenRound(outHeight.toFloat())
      }
    }
    return Crop(
        outWidth,
        outHeight,
        outWidth.toFloat() / sourceWidth.toFloat(),
        outHeight.toFloat() / sourceHeight.toFloat(),
    )
  }

  /**
   * The grain UV scale for the given output dimensions and grain size.
   *
   * `grainSize` is a linear fraction of the shorter output dimension: 0.1 tiles at 10% of the
   * shorter side (fine, the default), 1.0 makes one tile fill it, and above 1.0 the tile grows
   * larger than the frame. Deriving it from the output size is what keeps the grain the same visual
   * size in the preview, in a photo and in a video despite their different resolutions.
   *
   * Pure geometry: this lays out square cells and knows nothing about the tile that fills them or
   * which way round the output is. The axis swap and the tile's own aspect are applied on top by
   * `CameraEffectsManager.applyGrainScale`.
   */
  fun grainUvScale(grainSize: Float, outputWidth: Int, outputHeight: Int): Pair<Float, Float> {
    val gs = max(grainSize, 0.001f)
    val dw = outputWidth.toFloat()
    val dh = outputHeight.toFloat()
    val cellPx = max(gs * min(dw, dh), 1f)
    return (dw / cellPx) to (dh / cellPx)
  }
}
