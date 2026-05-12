// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Covers [PlanckianGainModel], the fallback used when a camera publishes no calibration. */
class WhiteBalanceConverterTest {
  private val model = PlanckianGainModel()

  @Test
  fun gainsFor_holdsBackRedForAWarmIlluminant() {
    // A warm illuminant reads strong in red, so red is the channel that gets held back and blue
    // the one that is boosted.
    val gains = model.gainsFor(2700.0, 0.0)
    assertTrue("blue gain should exceed red at 2700K", gains.blue > gains.red)
    assertEquals("the smallest channel is normalised to 1.0", 1.0, gains.red, 1e-6)
  }

  @Test
  fun gainsFor_holdsBackBlueForACoolIlluminant() {
    val gains = model.gainsFor(9000.0, 0.0)
    assertTrue("red gain should exceed blue at 9000K", gains.red > gains.blue)
    assertEquals("the smallest channel is normalised to 1.0", 1.0, gains.blue, 1e-6)
  }

  @Test
  fun gainsFor_isNearlyNeutralAtDaylight() {
    // 6500K is the sRGB white point, so correcting for it barely moves any channel.
    val gains = model.gainsFor(6500.0, 0.0)
    assertEquals(1.0, gains.red, 0.15)
    assertEquals(1.0, gains.green, 0.15)
    assertEquals(1.0, gains.blue, 0.15)
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
  fun gainsFor_neverGoesBelowOneOrAboveTheCeiling() {
    for (temperature in 1800..9800 step 100) {
      val gains = model.gainsFor(temperature.toDouble(), 0.0)
      for (gain in listOf(gains.red, gains.green, gains.blue)) {
        assertTrue(
            "gain $gain out of range at ${temperature}K",
            gain in 1.0..PlanckianGainModel.MAX_GAIN,
        )
      }
    }
  }

  @Test
  fun temperatureAndTintFor_roundTripsWhereTheGainsAreNotClipped() {
    // Solving the temperature from the blue/red ratio makes the inversion exact rather than
    // approximate: neither value bleeds into the other. Below the saturation point the gains
    // clip, so there is nothing left to invert — see the separate test for that.
    for (temperature in 2300..9800 step 200) {
      for (tint in -50..50 step 10) {
        val gains = model.gainsFor(temperature.toDouble(), tint.toDouble())
        val result = WhiteBalanceConverter.temperatureAndTintFor(gains, model)
        assertNotNull("no round trip at ${temperature}K / tint $tint", result)
        assertEquals(
            "temperature at ${temperature}K / tint $tint",
            temperature.toDouble(),
            result!!.first,
            1.0,
        )
        assertEquals("tint at ${temperature}K / tint $tint", tint.toDouble(), result.second, 0.5)
      }
    }
  }

  @Test
  fun temperatureAndTintFor_readsTheTemperatureIndependentlyOfTheTint() {
    // A green/magenta shift must not read as a warmer or cooler illuminant, which is the failure
    // mode of estimating the temperature from the full chromaticity.
    val neutral = WhiteBalanceConverter.temperatureAndTintFor(model.gainsFor(5500.0, 0.0), model)!!
    val tinted = WhiteBalanceConverter.temperatureAndTintFor(model.gainsFor(5500.0, 50.0), model)!!
    assertEquals(neutral.first, tinted.first, 1.0)
  }

  @Test
  fun gainsFor_saturatesBelowTheSupportedWarmLimit() {
    // sRGB primaries cannot express a very warm illuminant, so the blue gain clips and every
    // temperature under the limit collapses onto the same result. Callers get the warmest look
    // the model can produce rather than an error. `CalibratedGainModel` has no such limit.
    val atLimit = model.gainsFor(1900.0, 0.0)
    val wellBelow = model.gainsFor(1800.0, 0.0)
    assertEquals(atLimit.blue, wellBelow.blue, 1e-9)

    // Above the limit the mapping is still strictly monotonic.
    val warmer = model.gainsFor(3000.0, 0.0)
    val cooler = model.gainsFor(4000.0, 0.0)
    assertTrue(warmer.blue > cooler.blue)
  }

  @Test
  fun temperatureAndTintFor_reportsTheBottomOfTheRangeForClippedGains() {
    // A clipped set of gains carries no information about how warm the illuminant really was, so
    // the reading settles at the bottom of the supported range rather than somewhere arbitrary.
    for (temperature in listOf(1800.0, 2000.0, PlanckianGainModel.SATURATION_TEMPERATURE - 50)) {
      val result =
          WhiteBalanceConverter.temperatureAndTintFor(model.gainsFor(temperature, 0.0), model)
      assertNotNull(result)
      assertEquals("reading at ${temperature}K", 1800.0, result!!.first, 1.0)
    }
  }

  @Test
  fun temperatureAndTintFor_rejectsDegenerateGains() {
    // Capture results report zeroed gains transiently while a session is starting up.
    assertNull(
        WhiteBalanceConverter.temperatureAndTintFor(
            Gains(red = 0.0, green = 0.0, blue = 0.0), model))
    assertNull(
        WhiteBalanceConverter.temperatureAndTintFor(
            Gains(red = 1.0, green = -1.0, blue = 1.0), model))
  }

  @Test
  fun temperatureAndTintFor_clampsToTheSupportedRange() {
    // Whatever the hardware reports, the values handed to Dart have to satisfy the bounds
    // `WhiteBalanceValues` enforces, or constructing one throws.
    val extreme = Gains(red = 32.0, green = 1.0, blue = 1.0)
    val result = WhiteBalanceConverter.temperatureAndTintFor(extreme, model)
    assertNotNull(result)
    assertTrue(result!!.first in 1800.0..9800.0)
    assertTrue(result.second in -50.0..50.0)
  }

  @Test
  fun colorCorrectionTransformFor_isNullWithoutAnObservedMatrix() {
    // Nothing observed yet, so there is no matrix to send and the caller must not request
    // TRANSFORM_MATRIX mode.
    assertNull(model.colorCorrectionTransformFor(5000.0, 0.0))
  }

  @Test
  fun colorCorrectionTransformFor_reusesTheObservedMatrix() {
    val observed = ColorTransform(Matrix3.identity)
    assertEquals(observed, PlanckianGainModel(observed).colorCorrectionTransformFor(3500.0, 10.0))
  }
}
