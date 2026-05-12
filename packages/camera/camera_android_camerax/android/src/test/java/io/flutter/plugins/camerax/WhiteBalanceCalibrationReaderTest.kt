// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.params.ColorSpaceTransform
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import io.flutter.plugins.camerax.WhiteBalanceCalibrationReader.toColorSpaceTransform
import io.flutter.plugins.camerax.WhiteBalanceCalibrationReader.toMatrix3
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.robolectric.RobolectricTestRunner

/**
 * Robolectric rather than plain JUnit because `android/build.gradle.kts` sets
 * `isReturnDefaultValues`, under which `Rational` and `ColorSpaceTransform` silently return zeros
 * instead of throwing — every assertion here would pass without testing anything.
 */
@RunWith(RobolectricTestRunner::class)
@OptIn(markerClass = [ExperimentalCamera2Interop::class])
class WhiteBalanceCalibrationReaderTest {
  @Test
  fun toMatrix3_readsRowMajorDespiteTheTransposedAccessor() {
    // `ColorSpaceTransform(Rational[])` is documented row-major, but `getElement` takes
    // (column, row). Getting this backwards transposes every matrix, which is subtly wrong rather
    // than obviously broken, so it is worth pinning down.
    val transform =
        ColorSpaceTransform(intArrayOf(1, 1, 2, 1, 3, 1, 4, 1, 5, 1, 6, 1, 7, 1, 8, 1, 9, 1))
    val matrix = transform.toMatrix3()
    for (row in 0 until 3) {
      for (column in 0 until 3) {
        assertEquals((row * 3 + column + 1).toDouble(), matrix[row, column], 1e-12)
      }
    }
  }

  @Test
  fun toColorSpaceTransform_roundTrips() {
    val original = Matrix3(doubleArrayOf(1.5, -0.25, 0.125, -0.5, 2.0, 0.0625, 0.75, -1.25, 1.0))
    val restored = original.toColorSpaceTransform().toMatrix3()
    for (i in 0 until 9) {
      // The rationals use a fixed denominator, so the round trip is exact to within its step.
      assertEquals(original.m[i], restored.m[i], 1e-4)
    }
  }

  @Test
  fun read_returnsBothPolesWhenTheCameraPublishesThem() {
    val cameraInfo = cameraInfoWith(firstPole = true, secondPole = true)
    val calibration = WhiteBalanceCalibrationReader.read(cameraInfo)
    assertNotNull(calibration)
    assertEquals(2850.0, calibration!!.first.correlatedColorTemperature, 1e-12)
    assertEquals(6500.0, calibration.second!!.correlatedColorTemperature, 1e-12)
    assertNotNull(calibration.first.forwardMatrix)
  }

  @Test
  fun read_toleratesASingleIlluminantProfile() {
    val calibration = WhiteBalanceCalibrationReader.read(cameraInfoWith(secondPole = false))
    assertNotNull(calibration)
    assertNull(calibration!!.second)
  }

  @Test
  fun read_returnsNullWithoutAnIlluminant() {
    // The overwhelmingly common case: a camera with no RAW capability publishes none of this.
    val cameraInfo = mock(Camera2CameraInfo::class.java)
    assertNull(WhiteBalanceCalibrationReader.read(cameraInfo))
  }

  @Test
  fun read_returnsNullForAnUnknownIlluminant() {
    val cameraInfo = cameraInfoWith(firstPole = true, secondPole = false)
    `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT1))
        .thenReturn(0)
    assertNull(WhiteBalanceCalibrationReader.read(cameraInfo))
  }

  @Test
  fun read_returnsNullWithoutAColorTransform() {
    // Without it there is no way to relate the sensor to CIE XYZ, so the profile is unusable.
    val cameraInfo = cameraInfoWith(firstPole = true, secondPole = false)
    `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_COLOR_TRANSFORM1))
        .thenReturn(null)
    assertNull(WhiteBalanceCalibrationReader.read(cameraInfo))
  }

  @Test
  fun read_defaultsAnAbsentCalibrationTransformToTheIdentity() {
    // DNG treats a missing camera calibration as the identity, as does a sensor whose individual
    // units are not separately calibrated.
    val cameraInfo = cameraInfoWith(firstPole = true, secondPole = false)
    `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM1))
        .thenReturn(null)
    val calibration = WhiteBalanceCalibrationReader.read(cameraInfo)
    assertEquals(Matrix3.identity, calibration!!.first.calibrationTransform)
  }

  @Test
  fun read_handlesBothIlluminantKeyTypes() {
    // The two keys are not the same type — illuminant 1 is an Integer and illuminant 2 a Byte —
    // so reading them has to be indifferent to the boxing.
    val calibration = WhiteBalanceCalibrationReader.read(cameraInfoWith(secondPole = true))!!
    assertEquals(2850.0, calibration.first.correlatedColorTemperature, 1e-12)
    assertEquals(6500.0, calibration.second!!.correlatedColorTemperature, 1e-12)
  }

  private fun cameraInfoWith(
      firstPole: Boolean = true,
      secondPole: Boolean,
  ): Camera2CameraInfo {
    val cameraInfo = mock(Camera2CameraInfo::class.java)
    if (firstPole) {
      `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT1))
          .thenReturn(WhiteBalanceCalibration.ILLUMINANT_STANDARD_A)
      `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_COLOR_TRANSFORM1))
          .thenReturn(identityTransform())
      `when`(
              cameraInfo.getCameraCharacteristic(
                  CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM1))
          .thenReturn(identityTransform())
      `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_FORWARD_MATRIX1))
          .thenReturn(identityTransform())
    }
    if (secondPole) {
      `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT2))
          .thenReturn(WhiteBalanceCalibration.ILLUMINANT_D65.toByte())
      `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_COLOR_TRANSFORM2))
          .thenReturn(identityTransform())
      `when`(
              cameraInfo.getCameraCharacteristic(
                  CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM2))
          .thenReturn(identityTransform())
    }
    return cameraInfo
  }

  private fun identityTransform(): ColorSpaceTransform = Matrix3.identity.toColorSpaceTransform()
}
