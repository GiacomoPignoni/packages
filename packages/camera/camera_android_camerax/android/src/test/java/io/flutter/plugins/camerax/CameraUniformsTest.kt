// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraUniformsTest {
  @Test
  fun applyEffects_clampsOutOfRangeValuesRatherThanPassingThemThrough() {
    // `EffectsValues` only enforces its documented [0.0, 1.0] ranges with a Dart `assert`, which
    // release builds strip, so a value outside the range can reach here.
    val uniforms = CameraUniforms()

    uniforms.applyEffects(effectsValues(bloom = 5.0, diffusion = -3.0))

    assertEquals(1f, uniforms.bloom, 0f)
    assertEquals(0f, uniforms.diffusion, 0f)
  }

  @Test
  fun applyEffects_treatsANonFiniteValueAsOff() {
    // Plain `coerceIn` would let a NaN input through unchanged: the primitive `<`/`>` comparisons
    // it compiles to are false for every comparison against NaN.
    val uniforms = CameraUniforms()

    uniforms.applyEffects(
        effectsValues(vignetteIntensity = Double.NaN, mist = Double.POSITIVE_INFINITY))

    assertEquals(0f, uniforms.vignetteIntensity, 0f)
    assertEquals(1f, uniforms.mist, 0f)
  }

  @Test
  fun applyEffects_leavesTheOverlayOffWhenNoPathIsSet() {
    // The blend mode is still recorded, so setting a path later does not need the mode resent.
    val uniforms = CameraUniforms()

    uniforms.applyEffects(
        effectsValues(overlayFilePath = null, overlayBlendMode = PlatformOverlayBlendMode.MULTIPLY))

    assertEquals(0f, uniforms.overlayEnabled, 0f)
    assertEquals(PlatformOverlayBlendMode.MULTIPLY.raw.toFloat(), uniforms.overlayBlendMode, 0f)
  }

  @Test
  fun applyEffects_enablesTheOverlayAndCarriesTheBlendModeIndex() {
    // The raw index is the wire format shared with the shader's `kBlend*` constants and with
    // `CameraShaderBlendMode` on iOS, so it has to cross unchanged.
    val uniforms = CameraUniforms()

    uniforms.applyEffects(
        effectsValues(
            overlayFilePath = "/tmp/overlay.png",
            overlayBlendMode = PlatformOverlayBlendMode.SOFT_LIGHT,
        ))

    assertEquals(1f, uniforms.overlayEnabled, 0f)
    assertEquals(8f, uniforms.overlayBlendMode, 0f)
  }

  @Test
  fun setFrom_copiesTheOverlayFields() {
    // `setFrom` is the allocation-free per-frame copy; a field missed here is a field that silently
    // reverts to its default on every rendered frame.
    val source =
        CameraUniforms().apply {
          overlayEnabled = 1f
          overlayBlendMode = 5f
          overlayQuarterTurns = 3f
        }

    val destination = CameraUniforms()
    destination.setFrom(source)

    assertEquals(1f, destination.overlayEnabled, 0f)
    assertEquals(5f, destination.overlayBlendMode, 0f)
    assertEquals(3f, destination.overlayQuarterTurns, 0f)
  }

  @Test
  fun clearEffects_zeroesEveryEffectAndKeepsTheGeometry() {
    val uniforms =
        CameraUniforms().apply {
          applyEffects(effectsValues(vignetteIntensity = 1.0, mist = 1.0, bloom = 1.0))
          overlayEnabled = 1f
          captureScale = 0.5f
          captureCornerRadius = 0.25f
        }

    uniforms.clearEffects()

    assertEquals(0f, uniforms.vignetteIntensity, 0f)
    assertEquals(0f, uniforms.mist, 0f)
    assertEquals(0f, uniforms.bloom, 0f)
    assertEquals(0f, uniforms.overlayEnabled, 0f)
    assertEquals(0.5f, uniforms.captureScale, 0f)
    assertEquals(0.25f, uniforms.captureCornerRadius, 0f)
  }

  @Test
  fun applyEffects_encodesEachGrainBehavior() {
    val expected =
        mapOf(
            PlatformGrainBehavior.OVERLAY to 0f,
            PlatformGrainBehavior.DARK_ONLY to 1f,
            PlatformGrainBehavior.FADE to 2f,
        )

    for ((behavior, encoded) in expected) {
      val uniforms = CameraUniforms()
      uniforms.applyEffects(effectsValues(grainBehavior = behavior))

      assertEquals(encoded, uniforms.grainBehavior, 0f)
    }
  }

  private fun effectsValues(
      grainBehavior: PlatformGrainBehavior = PlatformGrainBehavior.OVERLAY,
      vignetteIntensity: Double = 0.0,
      lutIntensity: Double = 0.0,
      overlayFilePath: String? = null,
      overlayBlendMode: PlatformOverlayBlendMode = PlatformOverlayBlendMode.SRC_OVER,
      resolution: Double = 0.0,
      colorShift: Double = 0.0,
      mist: Double = 0.0,
      prism: Double = 0.0,
      bloom: Double = 0.0,
      diffusion: Double = 0.0,
  ) =
      PlatformEffectsValues(
          vignetteIntensity = vignetteIntensity,
          grainNoisePath = null,
          grainOpacity = 0.0,
          grainSize = 0.1,
          grainBehavior = grainBehavior,
          lutFilePath = null,
          lutIntensity = lutIntensity,
          overlayFilePath = overlayFilePath,
          overlayBlendMode = overlayBlendMode,
          resolution = resolution,
          colorShift = colorShift,
          mist = mist,
          prism = prism,
          cheapFisheye = false,
          bloom = bloom,
          diffusion = diffusion,
      )
}
