// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers [CalibratedGainModel] against a synthetic but realistic sensor profile.
 *
 * The colour matrices are of the shape and magnitude a real phone sensor publishes, so the
 * assertions below are about behaviour the maths has to have on any sensor, not about the exact
 * numbers this particular profile produces.
 */
class CalibratedGainModelTest {
  private val model = CalibratedGainModel(calibration(withForwardMatrices = false))
  private val modelWithForward = CalibratedGainModel(calibration(withForwardMatrices = true))

  @Test
  fun gainsFor_boostsBlueForAWarmIlluminant() {
    val gains = model.gainsFor(2700.0, 0.0)
    assertTrue("blue gain should exceed red at 2700K", gains.blue > gains.red)
    assertSmallestChannelIsOne(gains)
  }

  @Test
  fun gainsFor_boostsRedForACoolIlluminant() {
    val gains = model.gainsFor(9000.0, 0.0)
    assertTrue("red gain should exceed blue at 9000K", gains.red > gains.blue)
    assertSmallestChannelIsOne(gains)
  }

  /**
   * Which channel is the smallest depends on the sensor, unlike the sRGB based model where it is
   * always red or blue, so assert on the minimum rather than on a particular channel.
   */
  private fun assertSmallestChannelIsOne(gains: Gains) {
    assertEquals(
        "the smallest channel is normalised to 1.0",
        1.0,
        minOf(gains.red, gains.green, gains.blue),
        1e-9,
    )
  }

  @Test
  fun gainsFor_isMonotonicAcrossTheWholeRange() {
    // The regression test for the old sRGB based model, which saturated below ~2225K and made
    // every temperature under that indistinguishable. Working in the sensor's own space, the blue
    // gain keeps climbing all the way down to 1800K.
    var previous = Double.MAX_VALUE
    for (temperature in 1800..9800 step 100) {
      val ratio = model.gainsFor(temperature.toDouble(), 0.0).let { it.blue / it.red }
      assertTrue("blue/red not decreasing at ${temperature}K", ratio < previous)
      previous = ratio
    }
  }

  @Test
  fun gainsFor_staysWithinTheSupportedRange() {
    for (temperature in 1800..9800 step 100) {
      for (tint in -50..50 step 25) {
        val gains = model.gainsFor(temperature.toDouble(), tint.toDouble())
        for (gain in listOf(gains.red, gains.green, gains.blue)) {
          assertTrue(
              "gain $gain out of range at ${temperature}K / tint $tint",
              gain in 1.0..CalibratedGainModel.MAX_GAIN,
          )
        }
      }
    }
  }

  @Test
  fun gainsFor_positiveTintHoldsBackGreen() {
    val neutral = model.gainsFor(5000.0, 0.0)
    val magenta = model.gainsFor(5000.0, 50.0)
    val green = model.gainsFor(5000.0, -50.0)
    // Compare each green against its own frame's red, since normalising to the smallest channel
    // rescales all three.
    assertTrue(magenta.green / magenta.red < neutral.green / neutral.red)
    assertTrue(green.green / green.red > neutral.green / neutral.red)
  }

  @Test
  fun temperatureAndTintFor_roundTrips() {
    // Reporting has to agree with setting: a value read off the auto white balance and fed back in
    // must not change the image.
    for (temperature in 1900..9700 step 300) {
      for (tint in -40..40 step 20) {
        val gains = model.gainsFor(temperature.toDouble(), tint.toDouble())
        val result = WhiteBalanceConverter.temperatureAndTintFor(gains, model)
        assertNotNull("no round trip at ${temperature}K / tint $tint", result)
        assertEquals(
            "temperature at ${temperature}K / tint $tint",
            temperature.toDouble(),
            result!!.first,
            2.0,
        )
        assertEquals("tint at ${temperature}K / tint $tint", tint.toDouble(), result.second, 1.0)
      }
    }
  }

  @Test
  fun colorCorrectionTransformFor_mapsWhiteToWhite() {
    // Camera2 requires it, and a matrix that does not is a visible colour cast on every frame.
    for (temperature in listOf(2000.0, 2700.0, 4000.0, 5500.0, 6500.0, 9000.0)) {
      for (candidate in listOf(model, modelWithForward)) {
        val transform = candidate.colorCorrectionTransformFor(temperature, 0.0)
        assertNotNull("no transform at ${temperature}K", transform)
        for (row in 0 until 3) {
          val sum = transform!!.matrix[row, 0] + transform.matrix[row, 1] + transform.matrix[row, 2]
          assertEquals("row $row at ${temperature}K", 1.0, sum, 1e-9)
        }
      }
    }
  }

  @Test
  fun colorCorrectionTransformFor_keepsTheDiagonalDominant() {
    // A sane sensor-to-sRGB matrix leaves each output channel driven mostly by its own input.
    // A wildly off-diagonal one usually means an inverse or an adaptation went the wrong way.
    for (candidate in listOf(model, modelWithForward)) {
      val matrix = candidate.colorCorrectionTransformFor(5000.0, 0.0)!!.matrix
      for (channel in 0 until 3) {
        assertTrue(
            "channel $channel is not diagonal dominant",
            matrix[channel, channel] > 0.5,
        )
      }
    }
  }

  @Test
  fun colorCorrectionTransformFor_isNullForASingularProfile() {
    // Nothing to invert, so the manager must fall back rather than send a meaningless matrix.
    val singular = Matrix3(doubleArrayOf(1.0, 2.0, 3.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0))
    val broken =
        CalibratedGainModel(
            SensorCalibration(
                ReferenceIlluminant(2850.0, singular, Matrix3.identity, null),
                null,
            ))
    assertNull(broken.colorCorrectionTransformFor(5000.0, 0.0))
  }

  @Test
  fun gainsFor_fallsBackToNeutralWhenTheChromaticityIsUnavailable() {
    // `targetXyz` can refuse a temperature that lands off the locus; a neutral set of gains is a
    // no-op rather than a crash.
    val gains = model.gainsFor(Double.NaN, 0.0)
    assertEquals(1.0, gains.red, 1e-9)
    assertEquals(1.0, gains.green, 1e-9)
    assertEquals(1.0, gains.blue, 1e-9)
  }

  private fun calibration(withForwardMatrices: Boolean): SensorCalibration {
    val warm = pole(2850.0, STANDARD_A_COLOR_TRANSFORM, withForwardMatrices)
    val cool = pole(6500.0, D65_COLOR_TRANSFORM, withForwardMatrices)
    return SensorCalibration(warm, cool)
  }

  private fun pole(
      temperature: Double,
      colorTransform: Matrix3,
      withForwardMatrix: Boolean,
  ): ReferenceIlluminant =
      ReferenceIlluminant(
          correlatedColorTemperature = temperature,
          colorTransform = colorTransform,
          calibrationTransform = CALIBRATION_TRANSFORM,
          forwardMatrix = if (withForwardMatrix) forwardMatrixFor(colorTransform) else null,
      )

  /**
   * A forward matrix consistent with `colorTransform`.
   *
   * DNG requires `forward * (1, 1, 1) == XYZ(D50)`, which is exactly what inverting the colour
   * transform and folding in its own D50 neutral response gives.
   */
  private fun forwardMatrixFor(colorTransform: Matrix3): Matrix3 {
    val neutral = colorTransform * D50_WHITE
    return colorTransform.inverse()!! * Matrix3.diagonal(neutral.x, neutral.y, neutral.z)
  }

  private companion object {
    /** CIE XYZ of the D50 white point, the reference DNG colour transforms are defined against. */
    val D50_WHITE = Vec3(0.9642, 1.0, 0.8249)

    /** `SENSOR_COLOR_TRANSFORM1`, of the shape a sensor publishes for a Standard A reference. */
    val STANDARD_A_COLOR_TRANSFORM =
        Matrix3(
            doubleArrayOf(
                1.0554,
                -0.4487,
                -0.0954,
                -0.4675,
                1.2833,
                0.2072,
                -0.0908,
                0.2237,
                0.5551,
            ))

    /** `SENSOR_COLOR_TRANSFORM2`, for a D65 reference. */
    val D65_COLOR_TRANSFORM =
        Matrix3(
            doubleArrayOf(
                0.9648,
                -0.3164,
                -0.0833,
                -0.4948,
                1.2494,
                0.2679,
                -0.0978,
                0.2269,
                0.5951,
            ))

    /** A per-unit calibration close to, but not exactly, the identity. */
    val CALIBRATION_TRANSFORM = Matrix3.diagonal(1.02, 1.0, 0.98)
  }
}
