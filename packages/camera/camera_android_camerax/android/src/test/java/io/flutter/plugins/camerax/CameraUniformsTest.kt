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

  private fun effectsValues(
      vignetteIntensity: Double = 0.0,
      lutIntensity: Double = 0.0,
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
          grainBehavior = PlatformGrainBehavior.OVERLAY,
          lutFilePath = null,
          lutIntensity = lutIntensity,
          resolution = resolution,
          colorShift = colorShift,
          mist = mist,
          prism = prism,
          cheapFisheye = false,
          bloom = bloom,
          diffusion = diffusion,
      )
}
