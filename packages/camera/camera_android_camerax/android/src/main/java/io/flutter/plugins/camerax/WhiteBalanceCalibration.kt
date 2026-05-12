// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import kotlin.math.abs
import kotlin.math.hypot

/** A row-major 3x3 matrix of doubles. */
data class Matrix3(val m: DoubleArray) {
  init {
    require(m.size == 9) { "A Matrix3 needs exactly 9 elements, got ${m.size}" }
  }

  operator fun get(row: Int, column: Int): Double = m[row * 3 + column]

  operator fun times(other: Matrix3): Matrix3 {
    val result = DoubleArray(9)
    for (row in 0 until 3) {
      for (column in 0 until 3) {
        var sum = 0.0
        for (k in 0 until 3) {
          sum += this[row, k] * other[k, column]
        }
        result[row * 3 + column] = sum
      }
    }
    return Matrix3(result)
  }

  operator fun times(v: Vec3): Vec3 =
      Vec3(
          m[0] * v.x + m[1] * v.y + m[2] * v.z,
          m[3] * v.x + m[4] * v.y + m[5] * v.z,
          m[6] * v.x + m[7] * v.y + m[8] * v.z,
      )

  /** The inverse of this matrix, or null when it is singular. */
  fun inverse(): Matrix3? {
    val c00 = m[4] * m[8] - m[5] * m[7]
    val c01 = m[5] * m[6] - m[3] * m[8]
    val c02 = m[3] * m[7] - m[4] * m[6]
    val determinant = m[0] * c00 + m[1] * c01 + m[2] * c02
    if (abs(determinant) < SINGULAR_DETERMINANT) {
      return null
    }
    val inverseDeterminant = 1.0 / determinant
    return Matrix3(
        doubleArrayOf(
            c00 * inverseDeterminant,
            (m[2] * m[7] - m[1] * m[8]) * inverseDeterminant,
            (m[1] * m[5] - m[2] * m[4]) * inverseDeterminant,
            c01 * inverseDeterminant,
            (m[0] * m[8] - m[2] * m[6]) * inverseDeterminant,
            (m[2] * m[3] - m[0] * m[5]) * inverseDeterminant,
            c02 * inverseDeterminant,
            (m[1] * m[6] - m[0] * m[7]) * inverseDeterminant,
            (m[0] * m[4] - m[1] * m[3]) * inverseDeterminant,
        ))
  }

  // `data class` generates these off the array identity, which is never what a caller wants.
  override fun equals(other: Any?): Boolean =
      this === other || (other is Matrix3 && m.contentEquals(other.m))

  override fun hashCode(): Int = m.contentHashCode()

  companion object {
    /** Below this absolute determinant a matrix is treated as non-invertible. */
    private const val SINGULAR_DETERMINANT = 1e-12

    val identity: Matrix3
      get() = Matrix3(doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0))

    /** A matrix that scales each channel independently. */
    fun diagonal(x: Double, y: Double, z: Double): Matrix3 =
        Matrix3(doubleArrayOf(x, 0.0, 0.0, 0.0, y, 0.0, 0.0, 0.0, z))

    /** `weight * a + (1 - weight) * b`, element by element. */
    fun lerp(a: Matrix3, b: Matrix3, weight: Double): Matrix3 =
        Matrix3(DoubleArray(9) { weight * a.m[it] + (1.0 - weight) * b.m[it] })
  }
}

/** A three component vector, used here for CIE XYZ tristimulus values and sensor responses. */
data class Vec3(val x: Double, val y: Double, val z: Double)

/**
 * One of the two poles of a sensor's DNG colour calibration.
 *
 * Cameras that publish a calibration describe their colour response at one or two reference
 * illuminants; the response at any other illuminant is interpolated between them.
 */
data class ReferenceIlluminant(
    /** The correlated colour temperature of the reference illuminant, in Kelvin. */
    val correlatedColorTemperature: Double,
    /** `SENSOR_COLOR_TRANSFORM_n`: CIE XYZ to the reference sensor's colour space. */
    val colorTransform: Matrix3,
    /**
     * `SENSOR_CALIBRATION_TRANSFORM_n`: the reference sensor's space to this individual device's.
     */
    val calibrationTransform: Matrix3,
    /**
     * `SENSOR_FORWARD_MATRIX_n`: white balanced reference space to CIE XYZ under D50, when known.
     */
    val forwardMatrix: Matrix3?,
)

/** A sensor's colour calibration. [second] is absent on single illuminant profiles. */
data class SensorCalibration(val first: ReferenceIlluminant, val second: ReferenceIlluminant?) {
  /**
   * This calibration evaluated at `temperature`.
   *
   * Interpolation is linear in reciprocal temperature, which is what DNG's
   * `dng_color_spec::FindXYZtoCamera` does. Note that the DNG algorithm iterates, because it
   * derives the temperature from a white point that itself depends on the interpolated matrix; here
   * the caller supplies the temperature outright, so a single pass is exact.
   */
  fun interpolate(temperature: Double): InterpolatedCalibration {
    val other =
        second
            ?: return InterpolatedCalibration(
                xyzToCamera = first.calibrationTransform * first.colorTransform,
                calibration = first.calibrationTransform,
                colorTransform = first.colorTransform,
                forward = first.forwardMatrix,
            )

    // The first illuminant is not required to be the warmer one, so order them explicitly.
    val warm: ReferenceIlluminant
    val cool: ReferenceIlluminant
    if (first.correlatedColorTemperature <= other.correlatedColorTemperature) {
      warm = first
      cool = other
    } else {
      warm = other
      cool = first
    }

    val weight =
        when {
          temperature <= warm.correlatedColorTemperature -> 1.0
          temperature >= cool.correlatedColorTemperature -> 0.0
          else ->
              (1.0 / temperature - 1.0 / cool.correlatedColorTemperature) /
                  (1.0 / warm.correlatedColorTemperature - 1.0 / cool.correlatedColorTemperature)
        }

    val colorTransform = Matrix3.lerp(warm.colorTransform, cool.colorTransform, weight)
    val calibration = Matrix3.lerp(warm.calibrationTransform, cool.calibrationTransform, weight)
    val forward =
        if (warm.forwardMatrix != null && cool.forwardMatrix != null) {
          Matrix3.lerp(warm.forwardMatrix, cool.forwardMatrix, weight)
        } else {
          null
        }
    return InterpolatedCalibration(
        xyzToCamera = calibration * colorTransform,
        calibration = calibration,
        colorTransform = colorTransform,
        forward = forward,
    )
  }
}

/** A sensor's calibration evaluated at one particular colour temperature. */
data class InterpolatedCalibration(
    /** CIE XYZ to this device's sensor space: `calibration * colorTransform`. */
    val xyzToCamera: Matrix3,
    /** The interpolated `SENSOR_CALIBRATION_TRANSFORM`. */
    val calibration: Matrix3,
    /** The interpolated `SENSOR_COLOR_TRANSFORM`. */
    val colorTransform: Matrix3,
    /** The interpolated `SENSOR_FORWARD_MATRIX`, when both poles published one. */
    val forward: Matrix3?,
)

/**
 * The colour science behind the white balance: where a colour temperature sits on the Planckian
 * locus, and how a sensor's DNG calibration is evaluated there.
 *
 * Everything here is pure so that it can be unit tested without an Android runtime. Reading the
 * calibration off a camera lives in [WhiteBalanceCalibrationReader].
 */
object WhiteBalanceCalibration {
  /** Bounds mirroring the ones `WhiteBalanceValues` enforces on the Dart side. */
  const val MIN_TEMPERATURE = 1800.0

  const val MAX_TEMPERATURE = 9800.0
  const val MIN_TINT = -50.0
  const val MAX_TINT = 50.0

  /**
   * Full scale tint, matching AVFoundation's `[-150, 150]` convention.
   *
   * The platform interface clamps tint to `[-50, 50]`, so a tint at either end of the supported
   * range lands a third of the way up this scale, exactly as it would on iOS.
   */
  const val TINT_FULL_SCALE = 150.0

  /**
   * The distance from the Planckian locus, in CIE 1960 uv, that a full scale tint corresponds to.
   *
   * 0.05 is roughly where the green/magenta shift stops reading as a white balance adjustment and
   * starts reading as a colour cast, which makes it a reasonable end stop.
   */
  private const val DUV_FULL_SCALE = 0.05

  /** How far either side of a temperature the locus is sampled to get its tangent. */
  private const val TANGENT_STEP_KELVIN = 25.0

  /**
   * The correlated colour temperature of a `CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT_n`
   * value, or null when the constant is one this code does not recognise.
   *
   * These are the temperatures Adobe's DNG SDK assigns to the EXIF light source constants that
   * Camera2 reuses. The fluorescent entries are the midpoints of their respective ranges, since the
   * standard names a range rather than a single temperature.
   */
  fun illuminantCct(constant: Int): Double? =
      when (constant) {
        ILLUMINANT_STANDARD_A,
        ILLUMINANT_TUNGSTEN -> 2850.0
        ILLUMINANT_WARM_WHITE_FLUORESCENT -> 2925.0 // "L", 2600K-3250K.
        ILLUMINANT_ISO_STUDIO_TUNGSTEN -> 3200.0
        ILLUMINANT_WHITE_FLUORESCENT -> 3525.0 // "WW", 3250K-3800K.
        ILLUMINANT_FLUORESCENT,
        ILLUMINANT_COOL_WHITE_FLUORESCENT -> 4150.0 // "W", 3800K-4500K.
        ILLUMINANT_DAY_WHITE_FLUORESCENT -> 5050.0 // "N", 4600K-5500K.
        ILLUMINANT_D50 -> 5000.0
        ILLUMINANT_STANDARD_B,
        ILLUMINANT_D55,
        ILLUMINANT_DAYLIGHT,
        ILLUMINANT_FINE_WEATHER,
        ILLUMINANT_FLASH -> 5500.0
        ILLUMINANT_DAYLIGHT_FLUORESCENT -> 6400.0 // "D", 5700K-7100K.
        ILLUMINANT_STANDARD_C,
        ILLUMINANT_D65,
        ILLUMINANT_CLOUDY_WEATHER -> 6500.0
        ILLUMINANT_D75,
        ILLUMINANT_SHADE -> 7500.0
        else -> null
      }

  /**
   * The chromaticity of a `temperature` Kelvin black body, in CIE 1931 xy.
   *
   * Uses Kim et al.'s cubic fit of the Planckian locus, which is accurate over 1667K-25000K, well
   * beyond the range the platform interface permits. Returns null off the locus.
   */
  fun planckianXy(temperature: Double): Pair<Double, Double>? {
    val t = temperature.coerceIn(MIN_TEMPERATURE, MAX_TEMPERATURE)
    val t2 = t * t
    val t3 = t2 * t
    val x =
        if (t < 4000.0) {
          -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
        } else {
          -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
        }
    val x2 = x * x
    val x3 = x2 * x
    val y =
        when {
          t < 2222.0 -> -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
          t < 4000.0 -> -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
          else -> 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
        }
    if (!y.isFinite() || y <= 0.0) {
      return null
    }
    return x to y
  }

  /**
   * The CIE XYZ tristimulus values, normalised to `Y == 1`, of the illuminant the user asked for.
   *
   * `tint` shifts the result perpendicular to the Planckian locus in CIE 1960 uv, which is how
   * green/magenta is defined everywhere else in photography.
   *
   * Note the inversion: this describes the *illuminant*, and the gains derived from it neutralise
   * that illuminant. Positive tint, which renders magenta, therefore moves the target toward the
   * green side of the locus.
   */
  fun targetXyz(temperature: Double, tint: Double): Vec3? {
    val (x, y) = planckianXy(temperature) ?: return null
    var (u, v) = xyToUv(x, y)

    if (tint != 0.0) {
      // Take the tangent numerically rather than analytically: the locus is a piecewise cubic
      // fit, so a closed form derivative would be more code for no more accuracy, and this stays
      // perpendicular at every temperature.
      val below = planckianXy(temperature - TANGENT_STEP_KELVIN)
      val above = planckianXy(temperature + TANGENT_STEP_KELVIN)
      if (below != null && above != null) {
        val (uBelow, vBelow) = xyToUv(below.first, below.second)
        val (uAbove, vAbove) = xyToUv(above.first, above.second)
        val tangentU = uAbove - uBelow
        val tangentV = vAbove - vBelow
        val length = hypot(tangentU, tangentV)
        if (length > 0.0) {
          // Rotate the tangent a quarter turn to get the normal, then orient it toward higher v,
          // which is the green side of the locus. Deriving the direction rather than hardcoding a
          // sign keeps this correct whichever way the tangent happens to point.
          var normalU = -tangentV / length
          var normalV = tangentU / length
          if (normalV < 0.0) {
            normalU = -normalU
            normalV = -normalV
          }
          // Positive tint renders magenta, which is achieved by assuming a *greener* illuminant:
          // the gains that neutralise it hold the green channel back, and the image comes out
          // magenta. Moving the target toward magenta would do exactly the opposite.
          val duv = (tint / TINT_FULL_SCALE) * DUV_FULL_SCALE
          u += duv * normalU
          v += duv * normalV
        }
      }
    }

    val (shiftedX, shiftedY) = uvToXy(u, v)
    if (!shiftedY.isFinite() || shiftedY <= 0.0) {
      return null
    }
    return Vec3(shiftedX / shiftedY, 1.0, (1.0 - shiftedX - shiftedY) / shiftedY)
  }

  /** CIE 1931 xy to CIE 1960 uv. */
  private fun xyToUv(x: Double, y: Double): Pair<Double, Double> {
    val denominator = -2.0 * x + 12.0 * y + 3.0
    return (4.0 * x / denominator) to (6.0 * y / denominator)
  }

  /** CIE 1960 uv back to CIE 1931 xy. */
  private fun uvToXy(u: Double, v: Double): Pair<Double, Double> {
    val denominator = 2.0 * u - 8.0 * v + 4.0
    return (3.0 * u / denominator) to (2.0 * v / denominator)
  }

  // The `CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT_n` constants, spelled out rather than
  // referenced so that this file stays free of Android imports and unit testable on the JVM.
  const val ILLUMINANT_DAYLIGHT = 1
  const val ILLUMINANT_FLUORESCENT = 2
  const val ILLUMINANT_TUNGSTEN = 3
  const val ILLUMINANT_FLASH = 4
  const val ILLUMINANT_FINE_WEATHER = 9
  const val ILLUMINANT_CLOUDY_WEATHER = 10
  const val ILLUMINANT_SHADE = 11
  const val ILLUMINANT_DAYLIGHT_FLUORESCENT = 12
  const val ILLUMINANT_DAY_WHITE_FLUORESCENT = 13
  const val ILLUMINANT_COOL_WHITE_FLUORESCENT = 14
  const val ILLUMINANT_WHITE_FLUORESCENT = 15
  const val ILLUMINANT_STANDARD_A = 17
  const val ILLUMINANT_STANDARD_B = 18
  const val ILLUMINANT_STANDARD_C = 19
  const val ILLUMINANT_D55 = 20
  const val ILLUMINANT_D65 = 21
  const val ILLUMINANT_D75 = 22
  const val ILLUMINANT_D50 = 23
  const val ILLUMINANT_ISO_STUDIO_TUNGSTEN = 24
  const val ILLUMINANT_WARM_WHITE_FLUORESCENT = 16
}
