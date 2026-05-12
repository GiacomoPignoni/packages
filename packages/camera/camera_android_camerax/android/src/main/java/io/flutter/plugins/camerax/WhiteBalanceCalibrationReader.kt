// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.params.ColorSpaceTransform
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import kotlin.math.roundToInt

/**
 * Reads a sensor's DNG colour calibration off a camera.
 *
 * This is the only place `android.hardware.camera2.params` types are touched, which keeps the
 * colour maths in [WhiteBalanceCalibration] and [WhiteBalanceConverter] pure and unit testable on a
 * plain JVM.
 */
@OptIn(markerClass = [ExperimentalCamera2Interop::class])
object WhiteBalanceCalibrationReader {
  /**
   * The colour calibration `cameraInfo` publishes, or null when it does not publish one.
   *
   * These characteristics are only guaranteed on cameras advertising the RAW capability, so this
   * gates on the reads themselves succeeding rather than on the capability. That is strictly more
   * permissive: some cameras publish the calibration without claiming RAW support, and there is no
   * reason to refuse it when they do.
   */
  fun read(cameraInfo: Camera2CameraInfo): SensorCalibration? {
    val first =
        readIlluminant(
            cameraInfo,
            CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT1,
            CameraCharacteristics.SENSOR_COLOR_TRANSFORM1,
            CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM1,
            CameraCharacteristics.SENSOR_FORWARD_MATRIX1,
        ) ?: return null
    val second =
        readIlluminant(
            cameraInfo,
            CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT2,
            CameraCharacteristics.SENSOR_COLOR_TRANSFORM2,
            CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM2,
            CameraCharacteristics.SENSOR_FORWARD_MATRIX2,
        )
    return SensorCalibration(first, second)
  }

  private fun readIlluminant(
      cameraInfo: Camera2CameraInfo,
      illuminantKey: CameraCharacteristics.Key<*>,
      colorTransformKey: CameraCharacteristics.Key<ColorSpaceTransform>,
      calibrationTransformKey: CameraCharacteristics.Key<ColorSpaceTransform>,
      forwardMatrixKey: CameraCharacteristics.Key<ColorSpaceTransform>,
  ): ReferenceIlluminant? {
    // The two keys are not the same type: `SENSOR_REFERENCE_ILLUMINANT1` is an Integer and
    // `SENSOR_REFERENCE_ILLUMINANT2` a Byte. Reading either as a Number sidesteps the asymmetry,
    // and tolerates a device that boxes it as the other type.
    val illuminant = cameraInfo.getCameraCharacteristic(illuminantKey) as? Number ?: return null
    val temperature = WhiteBalanceCalibration.illuminantCct(illuminant.toInt()) ?: return null
    val colorTransform =
        cameraInfo.getCameraCharacteristic(colorTransformKey)?.toMatrix3() ?: return null
    // DNG treats an absent camera calibration as the identity, which is also what a sensor whose
    // individual units are not separately calibrated effectively has.
    val calibrationTransform =
        cameraInfo.getCameraCharacteristic(calibrationTransformKey)?.toMatrix3() ?: Matrix3.identity
    val forwardMatrix = cameraInfo.getCameraCharacteristic(forwardMatrixKey)?.toMatrix3()
    return ReferenceIlluminant(
        correlatedColorTemperature = temperature,
        colorTransform = colorTransform,
        calibrationTransform = calibrationTransform,
        forwardMatrix = forwardMatrix,
    )
  }

  /**
   * A [ColorSpaceTransform] read out row by row.
   *
   * `getElement` takes `(column, row)`, which is the opposite argument order to the row-major
   * `Rational[]` the class is constructed from. Spelling both indices out means the convention
   * cannot be got backwards by accident.
   */
  @VisibleForTesting
  internal fun ColorSpaceTransform.toMatrix3(): Matrix3 {
    val elements = DoubleArray(9)
    for (row in 0 until 3) {
      for (column in 0 until 3) {
        val rational = getElement(column, row)
        elements[row * 3 + column] =
            if (rational.denominator == 0) 0.0
            else rational.numerator.toDouble() / rational.denominator.toDouble()
      }
    }
    return Matrix3(elements)
  }

  /** A matrix as rationals over a fixed denominator, which is what the HAL expects. */
  internal fun Matrix3.toColorSpaceTransform(): ColorSpaceTransform {
    val elements = IntArray(18)
    for (i in 0 until 9) {
      elements[i * 2] = (m[i] * DENOMINATOR).roundToInt()
      elements[i * 2 + 1] = DENOMINATOR
    }
    return ColorSpaceTransform(elements)
  }

  /** Fine enough that the rounding is far below what the colour pipeline can resolve. */
  private const val DENOMINATOR = 10_000
}
