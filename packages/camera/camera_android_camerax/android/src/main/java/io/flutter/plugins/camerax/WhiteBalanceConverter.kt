// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import io.flutter.plugins.camerax.WhiteBalanceCalibration.MAX_TEMPERATURE
import io.flutter.plugins.camerax.WhiteBalanceCalibration.MAX_TINT
import io.flutter.plugins.camerax.WhiteBalanceCalibration.MIN_TEMPERATURE
import io.flutter.plugins.camerax.WhiteBalanceCalibration.MIN_TINT
import io.flutter.plugins.camerax.WhiteBalanceCalibration.TINT_FULL_SCALE
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/**
 * The colour matrix that accompanies a set of gains.
 *
 * Camera2 defines `CaptureRequest.COLOR_CORRECTION_TRANSFORM` as sensor RGB to linear sRGB, applied
 * *after* `COLOR_CORRECTION_GAINS`.
 */
data class ColorTransform(val matrix: Matrix3)

/**
 * Turns a colour temperature and tint into the per channel gains Camera2 expects in
 * `CaptureRequest.COLOR_CORRECTION_GAINS`, plus the colour matrix that has to go with them.
 *
 * There are two implementations, because Android exposes no single equivalent of AVFoundation's
 * `AVCaptureDevice.deviceWhiteBalanceGains(for:)`: [CalibratedGainModel] uses the sensor's own DNG
 * calibration when the camera publishes one, and [PlanckianGainModel] approximates from the
 * Planckian locus when it does not.
 */
interface GainModel {
  /** The gains that neutralise a scene lit at `temperature` Kelvin, shifted by `tint`. */
  fun gainsFor(temperature: Double, tint: Double): Gains

  /**
   * The colour matrix that belongs with [gainsFor] at the same values, or null when this model
   * cannot derive one.
   *
   * A null return means the caller must not request `COLOR_CORRECTION_MODE_TRANSFORM_MATRIX`: that
   * mode makes the device apply whatever matrix is in the request, so asking for it without
   * supplying a matrix produces an arbitrary colour cast.
   */
  fun colorCorrectionTransformFor(temperature: Double, tint: Double): ColorTransform?
}

/** Linear RGB channel gains, in the order Camera2's `RggbChannelVector` wants them. */
data class Gains(val red: Double, val green: Double, val blue: Double)

/**
 * Converts between a colour temperature/tint pair and Camera2's per channel gains.
 *
 * All functions here are pure so that they can be unit tested without an Android runtime.
 */
object WhiteBalanceConverter {
  /** Enough halvings of the 8000K range to land far inside a Kelvin. */
  private const val TEMPERATURE_STEPS = 30

  /**
   * Enough halvings of the 100 unit tint range to land far inside one unit.
   *
   * Kept smaller than [TEMPERATURE_STEPS] because this solve runs inside that one, so the two
   * multiply. Even so the whole inversion is a few hundred small matrix products, against a stream
   * throttled to 10 events a second.
   */
  private const val TINT_STEPS = 24

  /**
   * The temperature and tint that `gains` represents, according to `model`.
   *
   * Used to report what the hardware's auto white balance has settled on. Returns null when the
   * gains are degenerate (any channel at or below zero), which happens transiently while a capture
   * session is starting up.
   *
   * This inverts whichever model produced the gains rather than using a fixed formula, so that
   * feeding a reported reading straight back into `setWhiteBalance` is a no-op. Were the two to
   * disagree, a UI that seeds a slider from the auto reading would visibly jump the moment the user
   * touched it.
   *
   * Both steps work on channel *ratios*, which are invariant to the scaling [normalize] applies, so
   * the answer does not depend on which channel happened to be the smallest.
   */
  fun temperatureAndTintFor(gains: Gains, model: GainModel): Pair<Double, Double>? {
    if (gains.red <= 0.0 || gains.green <= 0.0 || gains.blue <= 0.0) {
      return null
    }

    val temperatureTarget = gains.blue / gains.red
    val tintTarget = gains.green / gains.red

    // Bisect on temperature, solving the tint afresh at every candidate. Tint and temperature are
    // not independent once a sensor calibration is in the path, because tint shifts the whole
    // chromaticity rather than just the green channel; solving them alternately converges on most
    // of the range but drifts to the end stops near the warm limit, whereas nesting the solves
    // makes each candidate self-consistent by construction.
    //
    // Driving the outer solve from blue/red rather than from the full chromaticity is what keeps a
    // green/magenta shift from reading as a warmer or cooler illuminant, which is the failure mode
    // of an estimate like McCamy's.
    var low = MIN_TEMPERATURE
    var high = MAX_TEMPERATURE
    repeat(TEMPERATURE_STEPS) {
      val mid = (low + high) / 2.0
      val neutral = model.gainsFor(mid, solveTint(tintTarget, mid, model))
      // The ratio falls monotonically as the illuminant gets cooler.
      if (neutral.blue / neutral.red > temperatureTarget) low = mid else high = mid
    }
    val temperature = ((low + high) / 2.0).coerceIn(MIN_TEMPERATURE, MAX_TEMPERATURE)
    return temperature to solveTint(tintTarget, temperature, model)
  }

  /** The tint whose green/red gain ratio matches `target` at a fixed `temperature`. */
  private fun solveTint(target: Double, temperature: Double, model: GainModel): Double {
    // Which way the ratio moves depends on the model, so establish it from the endpoints rather
    // than assuming a direction.
    val atMaxTint = model.gainsFor(temperature, MAX_TINT).let { it.green / it.red }
    val atMinTint = model.gainsFor(temperature, MIN_TINT).let { it.green / it.red }
    if (!atMaxTint.isFinite() || !atMinTint.isFinite() || atMaxTint == atMinTint) {
      return 0.0
    }
    val ratioIncreasesWithTint = atMaxTint > atMinTint
    var low = MIN_TINT
    var high = MAX_TINT
    repeat(TINT_STEPS) {
      val mid = (low + high) / 2.0
      val neutral = model.gainsFor(temperature, mid)
      val aboveTarget = (neutral.green / neutral.red) > target
      if (aboveTarget == ratioIncreasesWithTint) high = mid else low = mid
    }
    return ((low + high) / 2.0).coerceIn(MIN_TINT, MAX_TINT)
  }

  /** Scales `gains` so the smallest channel sits at 1.0, then clamps to `[1, maxGain]`. */
  internal fun normalize(gains: Gains, maxGain: Double): Gains {
    val smallest = min(gains.red, min(gains.green, gains.blue))
    if (smallest <= 0.0 || !smallest.isFinite()) {
      return Gains(1.0, 1.0, 1.0)
    }
    return Gains(
        (gains.red / smallest).coerceIn(1.0, maxGain),
        (gains.green / smallest).coerceIn(1.0, maxGain),
        (gains.blue / smallest).coerceIn(1.0, maxGain),
    )
  }

  /**
   * Rescales `matrix` so that a neutral input stays neutral.
   *
   * Camera2 requires `COLOR_CORRECTION_TRANSFORM` to map white to white, and clips its output to
   * `[0, 1]`. Returns null when a row sums to zero, which means the matrix is degenerate and the
   * caller should fall back rather than send it.
   */
  internal fun normalizeWhitePoint(matrix: Matrix3): ColorTransform? {
    val result = DoubleArray(9)
    for (row in 0 until 3) {
      val sum = matrix[row, 0] + matrix[row, 1] + matrix[row, 2]
      if (abs(sum) < DEGENERATE_ROW_SUM) {
        return null
      }
      for (column in 0 until 3) {
        result[row * 3 + column] = matrix[row, column] / sum
      }
    }
    return ColorTransform(Matrix3(result))
  }

  private const val DEGENERATE_ROW_SUM = 1e-9

  /** CIE XYZ to linear sRGB, D65 white point. */
  internal val XYZ_D65_TO_SRGB =
      Matrix3(
          doubleArrayOf(
              3.2406,
              -1.5372,
              -0.4986,
              -0.9689,
              1.8758,
              0.0415,
              0.0557,
              -0.2040,
              1.0570,
          ))

  /** CIE XYZ to linear sRGB, D50 white point (Bradford adapted). */
  internal val XYZ_D50_TO_SRGB =
      Matrix3(
          doubleArrayOf(
              3.1338561,
              -1.6168667,
              -0.4906146,
              -0.9787684,
              1.9161415,
              0.0334540,
              0.0719453,
              -0.2289914,
              1.4052427,
          ))

  /** The Bradford cone response matrix, used for chromatic adaptation. */
  private val BRADFORD =
      Matrix3(
          doubleArrayOf(
              0.8951,
              0.2664,
              -0.1614,
              -0.7502,
              1.7135,
              0.0367,
              0.0389,
              -0.0685,
              1.0296,
          ))

  /** CIE XYZ of the D65 white point, normalised to `Y == 1`. */
  internal val D65_WHITE = Vec3(0.95047, 1.0, 1.08883)

  /**
   * A von Kries chromatic adaptation in Bradford cone space, taking `from` to `to`.
   *
   * Returns null when either white point is degenerate.
   */
  internal fun bradfordAdaptation(from: Vec3, to: Vec3): Matrix3? {
    val sourceCone = BRADFORD * from
    val destinationCone = BRADFORD * to
    if (sourceCone.x == 0.0 ||
        sourceCone.y == 0.0 ||
        sourceCone.z == 0.0 ||
        !sourceCone.x.isFinite() ||
        !sourceCone.y.isFinite() ||
        !sourceCone.z.isFinite()) {
      return null
    }
    val inverseBradford = BRADFORD.inverse() ?: return null
    val scale =
        Matrix3.diagonal(
            destinationCone.x / sourceCone.x,
            destinationCone.y / sourceCone.y,
            destinationCone.z / sourceCone.z,
        )
    return inverseBradford * scale * BRADFORD
  }
}

/**
 * Derives the gains from the sensor's own DNG colour calibration.
 *
 * This is the Android counterpart of `AVCaptureDevice.deviceWhiteBalanceGains(for:)`: the
 * calibration describes how this particular sensor responds to light, so the gains it produces
 * actually neutralise the requested illuminant on this device rather than on an idealised one.
 */
class CalibratedGainModel(private val calibration: SensorCalibration) : GainModel {
  override fun gainsFor(temperature: Double, tint: Double): Gains {
    val response = sensorResponse(temperature, tint) ?: return Gains(1.0, 1.0, 1.0)
    // Gains are the reciprocal of the sensor's response: a channel the sensor reads strongly under
    // this illuminant is the one that has to be held back to bring the result back to neutral.
    return WhiteBalanceConverter.normalize(
        Gains(1.0 / response.x, 1.0 / response.y, 1.0 / response.z),
        MAX_GAIN,
    )
  }

  override fun colorCorrectionTransformFor(temperature: Double, tint: Double): ColorTransform? {
    val xyz = WhiteBalanceCalibration.targetXyz(temperature, tint) ?: return null
    val response = sensorResponse(temperature, tint) ?: return null
    val interpolated = calibration.interpolate(temperature)

    // The gains this model asks for are proportional to 1/response, so multiplying by the response
    // is what undoes them and gets back to un-white-balanced sensor space. The constant of
    // proportionality drops out in `normalizeWhitePoint` below.
    val undoGains = Matrix3.diagonal(response.x, response.y, response.z)

    val forward = interpolated.forward
    val sensorToXyz =
        if (forward != null) {
          // The forward matrix maps *white balanced reference* space to XYZ under D50, so there is
          // no adaptation to do: the D50 sRGB matrix finishes the job.
          val referenceNeutral = interpolated.colorTransform * xyz
          if (!referenceNeutral.x.isFinite() ||
              !referenceNeutral.y.isFinite() ||
              !referenceNeutral.z.isFinite() ||
              referenceNeutral.x == 0.0 ||
              referenceNeutral.y == 0.0 ||
              referenceNeutral.z == 0.0) {
            return null
          }
          val undoReferenceGains =
              Matrix3.diagonal(
                  1.0 / referenceNeutral.x,
                  1.0 / referenceNeutral.y,
                  1.0 / referenceNeutral.z,
              )
          val inverseCalibration = interpolated.calibration.inverse() ?: return null
          WhiteBalanceConverter.XYZ_D50_TO_SRGB *
              forward *
              undoReferenceGains *
              inverseCalibration *
              undoGains
        } else {
          // Without a forward matrix, inverting `xyzToCamera` lands in XYZ under the *requested*
          // illuminant. Adapting to D65 is not optional: skip it and a 3000K lock renders orange,
          // because the sRGB matrix would interpret tungsten-referenced XYZ as daylight-referenced.
          val cameraToXyz = interpolated.xyzToCamera.inverse() ?: return null
          val adaptation =
              WhiteBalanceConverter.bradfordAdaptation(xyz, WhiteBalanceConverter.D65_WHITE)
                  ?: return null
          WhiteBalanceConverter.XYZ_D65_TO_SRGB * adaptation * cameraToXyz * undoGains
        }

    return WhiteBalanceConverter.normalizeWhitePoint(sensorToXyz)
  }

  /** This sensor's raw response to a neutral patch under the requested illuminant. */
  private fun sensorResponse(temperature: Double, tint: Double): Vec3? {
    val xyz = WhiteBalanceCalibration.targetXyz(temperature, tint) ?: return null
    val response = calibration.interpolate(temperature).xyzToCamera * xyz
    if (!response.x.isFinite() || !response.y.isFinite() || !response.z.isFinite()) {
      return null
    }
    // A calibration matrix can push a channel to or below zero at the extremes of the range.
    // Flooring keeps the reciprocal finite; the clamp in `normalize` caps the resulting gain.
    return Vec3(
        max(response.x, MIN_RESPONSE),
        max(response.y, MIN_RESPONSE),
        max(response.z, MIN_RESPONSE),
    )
  }

  companion object {
    /**
     * Largest gain that will be requested for any channel.
     *
     * Working in the sensor's own space rather than through sRGB primaries keeps the gains modest
     * (a real sensor under an 1800K illuminant needs a blue gain of roughly 6-10x), so this ceiling
     * is never reached in practice across the range the platform interface allows. It exists only
     * to keep a pathological calibration from producing an absurd request.
     */
    const val MAX_GAIN = 16.0

    /** Smallest sensor response treated as non-zero, to keep its reciprocal finite. */
    private const val MIN_RESPONSE = 1e-4
  }
}

/**
 * Approximates the gains from the Planckian locus in linear sRGB.
 *
 * Used when a camera does not publish a DNG calibration. The result is close enough that the same
 * temperature looks roughly the same on both platforms, but it is not sensor calibrated: expect a
 * residual cast on some devices, and no useful difference between temperatures below
 * [SATURATION_TEMPERATURE].
 *
 * @param observedTransform the colour matrix the device reported while it was running its own auto
 *   white balance, if one has been seen. This model has no way to derive a matrix of its own, so
 *   borrowing the device's is the difference between a device-correct rendering and none at all.
 */
class PlanckianGainModel(private val observedTransform: ColorTransform? = null) : GainModel {
  override fun gainsFor(temperature: Double, tint: Double): Gains {
    val (r, g, b) = illuminantRgb(temperature)
    // Gains are the reciprocal of the illuminant's response: a warm (low Kelvin) illuminant reads
    // strong in red, so red is held back and blue is boosted to bring the result back to neutral.
    val tintFactor = exp(-tint / TINT_FULL_SCALE)
    return WhiteBalanceConverter.normalize(Gains(1.0 / r, tintFactor / g, 1.0 / b), MAX_GAIN)
  }

  /**
   * The device's own matrix, when one has been observed.
   *
   * The colour matrix varies slowly with temperature, so reusing the one seen at, say, 5000K when
   * locking to 3500K is a small error. Sending no matrix at all while asking for `TRANSFORM_MATRIX`
   * is a large one, and deriving one from the sRGB approximation would be little better than
   * identity.
   */
  override fun colorCorrectionTransformFor(temperature: Double, tint: Double): ColorTransform? =
      observedTransform

  /**
   * The linear sRGB response of a black body at `temperature` Kelvin, normalised to a peak of 1.
   */
  private fun illuminantRgb(temperature: Double): Triple<Double, Double, Double> {
    val xy = WhiteBalanceCalibration.planckianXy(temperature) ?: return Triple(1.0, 1.0, 1.0)
    val (x, y) = xy
    val xyz = Vec3(x / y, 1.0, (1.0 - x - y) / y)
    val rgb = WhiteBalanceConverter.XYZ_D65_TO_SRGB * xyz

    // The sRGB primaries do not cover the whole locus, so extreme temperatures can land slightly
    // outside the gamut. Floor rather than clamp to zero: a zero channel would divide by zero when
    // the gains are taken.
    val r = max(rgb.x, MIN_CHANNEL)
    val g = max(rgb.y, MIN_CHANNEL)
    val b = max(rgb.z, MIN_CHANNEL)

    val peak = max(r, max(g, b))
    return Triple(r / peak, g / peak, b / peak)
  }

  companion object {
    /**
     * Largest gain that will be requested for any channel.
     *
     * The blue gain a warm illuminant needs in sRGB space climbs steeply, past 100x by 2000K, so no
     * practical ceiling covers the whole range down to 1800K that the platform interface allows.
     * This one holds to about [SATURATION_TEMPERATURE].
     */
    const val MAX_GAIN = 32.0

    /**
     * Temperature below which [MAX_GAIN] clips the blue channel.
     *
     * Warmer settings than this are still applied, they simply stop getting warmer and stop being
     * distinguishable from one another. [CalibratedGainModel] has no such limit.
     */
    const val SATURATION_TEMPERATURE = 2225.0

    /**
     * Smallest linear sRGB channel value an illuminant is allowed to have.
     *
     * The sRGB primaries do not cover the whole Planckian locus, so the blue channel of a very warm
     * illuminant lands at or below zero. Flooring it keeps the reciprocal finite; too small a floor
     * would send the blue gain to five figures.
     */
    private const val MIN_CHANNEL = 1e-3
  }
}
