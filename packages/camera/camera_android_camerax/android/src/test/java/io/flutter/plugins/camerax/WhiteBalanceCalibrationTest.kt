// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WhiteBalanceCalibrationTest {
  @Test
  fun illuminantCct_coversEveryKnownConstant() {
    // Every constant Camera2 can report has to map to a temperature, or the whole calibration is
    // rejected and the camera silently falls back to the approximation.
    val known =
        mapOf(
            WhiteBalanceCalibration.ILLUMINANT_DAYLIGHT to 5500.0,
            WhiteBalanceCalibration.ILLUMINANT_FLUORESCENT to 4150.0,
            WhiteBalanceCalibration.ILLUMINANT_TUNGSTEN to 2850.0,
            WhiteBalanceCalibration.ILLUMINANT_FLASH to 5500.0,
            WhiteBalanceCalibration.ILLUMINANT_FINE_WEATHER to 5500.0,
            WhiteBalanceCalibration.ILLUMINANT_CLOUDY_WEATHER to 6500.0,
            WhiteBalanceCalibration.ILLUMINANT_SHADE to 7500.0,
            WhiteBalanceCalibration.ILLUMINANT_DAYLIGHT_FLUORESCENT to 6400.0,
            WhiteBalanceCalibration.ILLUMINANT_DAY_WHITE_FLUORESCENT to 5050.0,
            WhiteBalanceCalibration.ILLUMINANT_COOL_WHITE_FLUORESCENT to 4150.0,
            WhiteBalanceCalibration.ILLUMINANT_WHITE_FLUORESCENT to 3525.0,
            WhiteBalanceCalibration.ILLUMINANT_WARM_WHITE_FLUORESCENT to 2925.0,
            WhiteBalanceCalibration.ILLUMINANT_STANDARD_A to 2850.0,
            WhiteBalanceCalibration.ILLUMINANT_STANDARD_B to 5500.0,
            WhiteBalanceCalibration.ILLUMINANT_STANDARD_C to 6500.0,
            WhiteBalanceCalibration.ILLUMINANT_D55 to 5500.0,
            WhiteBalanceCalibration.ILLUMINANT_D65 to 6500.0,
            WhiteBalanceCalibration.ILLUMINANT_D75 to 7500.0,
            WhiteBalanceCalibration.ILLUMINANT_D50 to 5000.0,
            WhiteBalanceCalibration.ILLUMINANT_ISO_STUDIO_TUNGSTEN to 3200.0,
        )
    for ((constant, temperature) in known) {
      assertEquals(
          "illuminant $constant",
          temperature,
          WhiteBalanceCalibration.illuminantCct(constant),
      )
    }
  }

  @Test
  fun illuminantCct_rejectsUnknownConstants() {
    // 0 is "unknown" in the EXIF table and 5..8 are unassigned; a profile keyed on one of those
    // cannot be placed on the locus, so it must be refused rather than guessed at.
    for (constant in listOf(0, 5, 6, 7, 8, 25, 255)) {
      assertNull("illuminant $constant", WhiteBalanceCalibration.illuminantCct(constant))
    }
  }

  @Test
  fun matrix3_inverseRoundTrips() {
    val matrix = Matrix3(doubleArrayOf(0.9, 0.1, -0.2, -0.3, 1.2, 0.05, 0.02, -0.15, 1.1))
    val product = matrix * matrix.inverse()!!
    for (row in 0 until 3) {
      for (column in 0 until 3) {
        assertEquals(if (row == column) 1.0 else 0.0, product[row, column], 1e-9)
      }
    }
  }

  @Test
  fun matrix3_inverseIsNullWhenSingular() {
    // Two identical rows: no inverse exists, and the caller has to fall back rather than divide
    // by a determinant of zero.
    val singular = Matrix3(doubleArrayOf(1.0, 2.0, 3.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0))
    assertNull(singular.inverse())
  }

  @Test
  fun matrix3_multipliesVectors() {
    val scaled = Matrix3.diagonal(2.0, 3.0, 4.0) * Vec3(1.0, 1.0, 1.0)
    assertEquals(2.0, scaled.x, 1e-12)
    assertEquals(3.0, scaled.y, 1e-12)
    assertEquals(4.0, scaled.z, 1e-12)
  }

  @Test
  fun interpolate_pinsToEachPoleOutsideTheRange() {
    val calibration = twoPoleCalibration()
    val warm = calibration.interpolate(2000.0)
    val cool = calibration.interpolate(9800.0)
    assertEquals(WARM_COLOR_TRANSFORM, warm.colorTransform)
    assertEquals(COOL_COLOR_TRANSFORM, cool.colorTransform)
    // At the poles themselves too, not just beyond them.
    assertEquals(WARM_COLOR_TRANSFORM, calibration.interpolate(2850.0).colorTransform)
    assertEquals(COOL_COLOR_TRANSFORM, calibration.interpolate(6500.0).colorTransform)
  }

  @Test
  fun interpolate_weightsByReciprocalTemperature() {
    // DNG interpolates in 1/K, not in K, so the halfway matrix sits at the reciprocal midpoint
    // rather than at 4675K.
    val calibration = twoPoleCalibration()
    val reciprocalMidpoint = 2.0 / (1.0 / 2850.0 + 1.0 / 6500.0)
    val midpoint = calibration.interpolate(reciprocalMidpoint)
    for (i in 0 until 9) {
      assertEquals(
          (WARM_COLOR_TRANSFORM.m[i] + COOL_COLOR_TRANSFORM.m[i]) / 2.0,
          midpoint.colorTransform.m[i],
          1e-9,
      )
    }
  }

  @Test
  fun interpolate_doesNotAssumeTheFirstPoleIsTheWarmerOne() {
    // Nothing requires a device to list its illuminants warm first.
    val forwards = twoPoleCalibration()
    val backwards = SensorCalibration(forwards.second!!, forwards.first)
    for (temperature in listOf(2000.0, 3200.0, 5000.0, 6500.0, 9000.0)) {
      assertEquals(
          "at ${temperature}K",
          forwards.interpolate(temperature).colorTransform,
          backwards.interpolate(temperature).colorTransform,
      )
    }
  }

  @Test
  fun interpolate_usesTheOnlyPoleOnASingleIlluminantProfile() {
    val single = SensorCalibration(warmPole(), null)
    val interpolated = single.interpolate(9000.0)
    assertEquals(WARM_COLOR_TRANSFORM, interpolated.colorTransform)
    assertEquals(Matrix3.identity, interpolated.calibration)
  }

  @Test
  fun interpolate_dropsTheForwardMatrixUnlessBothPolesHaveOne() {
    val mixed = SensorCalibration(warmPole().copy(forwardMatrix = Matrix3.identity), coolPole())
    assertNull(mixed.interpolate(5000.0).forward)
    val both =
        SensorCalibration(
            warmPole().copy(forwardMatrix = Matrix3.identity),
            coolPole().copy(forwardMatrix = Matrix3.identity),
        )
    assertNotNull(both.interpolate(5000.0).forward)
  }

  @Test
  fun targetXyz_isNormalisedToUnitLuminance() {
    for (temperature in 1800..9800 step 400) {
      val xyz = WhiteBalanceCalibration.targetXyz(temperature.toDouble(), 0.0)
      assertNotNull("no chromaticity at ${temperature}K", xyz)
      assertEquals(1.0, xyz!!.y, 1e-12)
    }
  }

  @Test
  fun targetXyz_movesTowardBlueAsTheTemperatureRises() {
    // A cool illuminant really is bluer; if this ever inverted, every lock would be backwards.
    val warm = WhiteBalanceCalibration.targetXyz(2700.0, 0.0)!!
    val cool = WhiteBalanceCalibration.targetXyz(9000.0, 0.0)!!
    assertTrue(cool.z / cool.x > warm.z / warm.x)
  }

  @Test
  fun targetXyz_shiftsTintPerpendicularToTheLocus() {
    val temperature = 5000.0
    val neutral = uvOf(temperature, 0.0)
    val magenta = uvOf(temperature, 50.0)
    val green = uvOf(temperature, -50.0)

    // This is the illuminant, not the rendering. Positive tint renders magenta, and it does so by
    // assuming a greener illuminant — the green side of the locus, which is higher v.
    assertTrue("positive tint should sit on the green side", magenta.second > neutral.second)
    assertTrue("negative tint should sit on the magenta side", green.second < neutral.second)

    // And the displacement is perpendicular: its dot product with the tangent is zero.
    val below = uvOf(temperature - 25.0, 0.0)
    val above = uvOf(temperature + 25.0, 0.0)
    val tangentU = above.first - below.first
    val tangentV = above.second - below.second
    val offsetU = magenta.first - neutral.first
    val offsetV = magenta.second - neutral.second
    val dot = tangentU * offsetU + tangentV * offsetV
    val scale = Math.hypot(tangentU, tangentV) * Math.hypot(offsetU, offsetV)
    assertTrue("offset is not perpendicular: ${abs(dot) / scale}", abs(dot) / scale < 1e-6)
  }

  @Test
  fun targetXyz_scalesTheOffsetWithTheTintMagnitude() {
    val neutral = uvOf(5000.0, 0.0)
    val half = uvOf(5000.0, 25.0)
    val full = uvOf(5000.0, 50.0)
    val halfDistance = Math.hypot(half.first - neutral.first, half.second - neutral.second)
    val fullDistance = Math.hypot(full.first - neutral.first, full.second - neutral.second)
    assertEquals(2.0, fullDistance / halfDistance, 1e-6)
  }

  @Test
  fun planckianXy_isNullRatherThanNanForANonFiniteTemperature() {
    // `coerceIn` and `<= 0.0` are both no-ops for NaN, so a naive guard would silently return NaN
    // instead of honouring the documented "returns null off the locus" contract.
    assertNull(WhiteBalanceCalibration.planckianXy(Double.NaN))
  }

  @Test
  fun targetXyz_isNullRatherThanNanForANonFiniteTint() {
    assertNull(WhiteBalanceCalibration.targetXyz(5000.0, Double.NaN))
  }

  private fun uvOf(temperature: Double, tint: Double): Pair<Double, Double> {
    val xyz = WhiteBalanceCalibration.targetXyz(temperature, tint)!!
    val sum = xyz.x + xyz.y + xyz.z
    val x = xyz.x / sum
    val y = xyz.y / sum
    val denominator = -2.0 * x + 12.0 * y + 3.0
    return (4.0 * x / denominator) to (6.0 * y / denominator)
  }

  private fun warmPole() =
      ReferenceIlluminant(
          correlatedColorTemperature = 2850.0,
          colorTransform = WARM_COLOR_TRANSFORM,
          calibrationTransform = Matrix3.identity,
          forwardMatrix = null,
      )

  private fun coolPole() =
      ReferenceIlluminant(
          correlatedColorTemperature = 6500.0,
          colorTransform = COOL_COLOR_TRANSFORM,
          calibrationTransform = Matrix3.identity,
          forwardMatrix = null,
      )

  private fun twoPoleCalibration() = SensorCalibration(warmPole(), coolPole())

  private companion object {
    val WARM_COLOR_TRANSFORM = Matrix3(doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0))
    val COOL_COLOR_TRANSFORM = Matrix3(doubleArrayOf(3.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 3.0))
  }
}
