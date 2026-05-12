// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.RggbChannelVector
import android.os.SystemClock
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.plugins.camerax.WhiteBalanceCalibrationReader.toColorSpaceTransform
import io.flutter.plugins.camerax.WhiteBalanceCalibrationReader.toMatrix3

/**
 * Manages the white balance of a camera.
 *
 * CameraX has no white balance control of its own, so both locking the white balance and observing
 * what the auto algorithm picks go through Camera2 interop.
 */
@OptIn(markerClass = [ExperimentalCamera2Interop::class])
class WhiteBalanceManager(private val api: WhiteBalanceManagerProxyApi) {
  /**
   * What was last asked for, or null when white balance has never been set on this camera.
   *
   * A single immutable snapshot behind one `@Volatile` reference, so the capture thread always
   * reads a consistent set of values rather than a half-updated one.
   */
  @Volatile private var requested: RequestedState? = null

  /**
   * Whether the *current* camera actually has a manual lock applied right now.
   *
   * Deliberately not derived from `requested?.isLocked`: [attachToCamera] can fail to reapply a
   * lock to a newly bound camera (e.g. a lens switch to one without `CONTROL_AWB_MODE_OFF`), in
   * which case that camera is left running its own auto algorithm while [requested] still holds
   * onto the user's ask for a possible future camera that does support it. Gating
   * [onAutoWhiteBalanceResult] on [requested] in that situation would suppress the auto white
   * balance stream forever for a camera that was never actually locked.
   */
  @Volatile private var lockActive = false

  /**
   * Earliest `SystemClock.elapsedRealtime()` at which the next auto white balance event may be
   * emitted.
   *
   * The capture callback fires at the frame rate; matching the iOS throttle keeps the event volume
   * the same on both platforms.
   */
  @Volatile private var nextEmissionUptimeMillis = 0L

  /**
   * The most recent colour matrix the device reported while running its own auto white balance.
   *
   * The only device-correct matrix available on a camera that publishes no calibration. See
   * [PlanckianGainModel].
   */
  @Volatile private var observedAutoTransform: ColorTransform? = null

  /** The camera [gainModel] was built for, so a lens switch rebuilds it. */
  private var modelCameraId: String? = null

  @Volatile private var gainModel: GainModel = PlanckianGainModel()

  /**
   * The Camera2 capture callback that reports the auto white balance gains.
   *
   * Attached to the preview's capture requests at `Preview.Builder` time, because that is the only
   * hook Camera2 interop offers for reading capture results.
   */
  val captureCallback: CameraCaptureSession.CaptureCallback =
      object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureCompleted(
            session: CameraCaptureSession,
            request: CaptureRequest,
            result: TotalCaptureResult,
        ) {
          onAutoWhiteBalanceResult(result)
        }
      }

  /**
   * Whether locking the white balance to a chosen temperature and tint will actually do something
   * on `cameraInfo`'s camera.
   *
   * Two things are needed, and a camera can advertise one without the other:
   * * `CONTROL_AWB_MODE_OFF`, without which the auto algorithm cannot be turned off at all;
   * * `MANUAL_POST_PROCESSING`, which is what documents `COLOR_CORRECTION_TRANSFORM` and
   *   `COLOR_CORRECTION_GAINS` as honoured. A camera that only has the former can be locked, but
   *   locks to whatever the auto algorithm had last chosen rather than to the requested
   *   temperature, which is not white balance control in any sense a caller can use.
   *
   * Reported for the benefit of a UI deciding whether to offer the control. [setWhiteBalance] stays
   * deliberately more permissive: it refuses only what it can prove impossible, so a camera that
   * under-advertises still works for an app that asks anyway.
   */
  fun isWhiteBalanceSupported(cameraInfo: Camera2CameraInfo): Boolean =
      supportsAwbMode(cameraInfo, CameraMetadata.CONTROL_AWB_MODE_OFF) &&
          supportsManualPostProcessing(cameraInfo)

  /**
   * Locks the white balance to `temperature` Kelvin and `tint`, or returns the camera to auto white
   * balance when both are null.
   *
   * Throws [UnsupportedOperationException] when the camera does not support the requested mode,
   * matching the `setWhiteBalanceFailed` error AVFoundation reports. The returned future completes
   * once the camera has accepted the new capture request options.
   */
  fun setWhiteBalance(
      cameraControl: Camera2CameraControl,
      cameraInfo: Camera2CameraInfo,
      temperature: Double?,
      tint: Double?,
  ): ListenableFuture<Void?> {
    val state = RequestedState(temperature, tint, cameraInfo.getCameraId())
    // Apply before recording the state: an unsupported mode throws here, and the manager should
    // then be left exactly as it was rather than believing in a lock the camera never took.
    val future = apply(cameraControl, cameraInfo, state)
    requested = state
    lockActive = state.isLocked
    if (!state.isLocked) {
      nextEmissionUptimeMillis = 0L
    }
    return future
  }

  /**
   * Forgets everything learned about the camera this manager was last attached to.
   *
   * The manager outlives any one camera - it belongs to the plugin, not to a `create`/`dispose`
   * cycle - so without this the lock requested for a disposed camera would be re-sent to the next
   * one by [attachToCamera], which every `bindToLifecycle` runs. The new camera would silently come
   * up locked while Dart believed it was in auto mode.
   *
   * Does not touch the camera: there is no camera to touch at the point this is called, and the
   * fresh one starts in its own default state anyway.
   */
  fun reset() {
    requested = null
    lockActive = false
    modelCameraId = null
    observedAutoTransform = null
    gainModel = PlanckianGainModel()
    nextEmissionUptimeMillis = 0L
  }

  /**
   * Refreshes the calibration for `cameraInfo` and re-sends the last requested white balance, if
   * any, to a freshly bound camera.
   *
   * `Camera2CameraControl` options live on the `Camera` instance and every `bindToLifecycle`
   * produces a new one, so without this a lock would be silently lost on any resolution change,
   * viewport change, preview resume or lens switch.
   */
  fun attachToCamera(cameraControl: Camera2CameraControl, cameraInfo: Camera2CameraInfo) {
    val cameraId = cameraInfo.getCameraId()
    // Always refresh the model: a lens switch means a different sensor with its own calibration.
    modelFor(cameraInfo)
    // Nothing has ever been requested, so there is no reason to touch the camera's own defaults.
    val state = requested ?: return
    val reapplied = state.copy(cameraId = cameraId)
    try {
      apply(cameraControl, cameraInfo, reapplied)
    } catch (e: Throwable) {
      // The new camera never accepted the lock, so it is actually running its own auto white
      // balance; stop suppressing the auto white balance stream even though `requested` is kept
      // around in case a later camera switch lands on hardware that does support it.
      lockActive = false
      throw e
    }
    requested = reapplied
    lockActive = reapplied.isLocked
  }

  private fun apply(
      cameraControl: Camera2CameraControl,
      cameraInfo: Camera2CameraInfo,
      state: RequestedState,
  ): ListenableFuture<Void?> {
    val builder = CaptureRequestOptions.Builder()
    if (state.isLocked) {
      if (!supportsAwbMode(cameraInfo, CameraMetadata.CONTROL_AWB_MODE_OFF)) {
        throw UnsupportedOperationException("Device does not support manual white balance")
      }
      warnIfManualPostProcessingUnsupported(cameraInfo)

      val model = modelFor(cameraInfo)
      builder.setCaptureRequestOption(
          CaptureRequest.CONTROL_AWB_MODE,
          CameraMetadata.CONTROL_AWB_MODE_OFF,
      )

      val transform = model.colorCorrectionTransformFor(state.temperature!!, state.tint!!)
      if (transform != null) {
        val gains = model.gainsFor(state.temperature, state.tint)
        // TRANSFORM_MATRIX is the only mode in which COLOR_CORRECTION_GAINS is honoured, and in it
        // the device applies the matrix from the request. Asking for the mode without supplying a
        // matrix leaves whatever was there before in force, which is why the transform and the
        // gains are always set together.
        builder
            .setCaptureRequestOption(
                CaptureRequest.COLOR_CORRECTION_MODE,
                CameraMetadata.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX,
            )
            .setCaptureRequestOption(
                CaptureRequest.COLOR_CORRECTION_TRANSFORM,
                transform.matrix.toColorSpaceTransform(),
            )
            .setCaptureRequestOption(
                CaptureRequest.COLOR_CORRECTION_GAINS,
                RggbChannelVector(
                    gains.red.toFloat(),
                    gains.green.toFloat(),
                    gains.green.toFloat(),
                    gains.blue.toFloat(),
                ),
            )
      } else {
        // No matrix to send. Most devices respond to AWB_MODE_OFF alone by holding the last auto
        // result, which is at least a stable and correctly coloured image, rather than the wrong
        // one an unspecified matrix would give.
        Log.w(TAG, "No colour matrix available; locking white balance without one.")
      }
    } else {
      if (!supportsAwbMode(cameraInfo, CameraMetadata.CONTROL_AWB_MODE_AUTO)) {
        throw UnsupportedOperationException("Device does not support auto white balance")
      }
      builder
          .setCaptureRequestOption(
              CaptureRequest.CONTROL_AWB_MODE,
              CameraMetadata.CONTROL_AWB_MODE_AUTO,
          )
          // Hands colour correction back to the device. The gains and transform set by a previous
          // lock stay in the merged bundle, but Camera2 documents both as used only in
          // TRANSFORM_MATRIX mode, so they are inert. Do not "reset" them to neutral values: on a
          // device that wrongly honours them in FAST mode, neutral gains are a visibly broken
          // image,
          // whereas the stale ones are at least plausible.
          .setCaptureRequestOption(
              CaptureRequest.COLOR_CORRECTION_MODE,
              CameraMetadata.COLOR_CORRECTION_MODE_FAST,
          )
    }

    // Merge rather than replace. `setCaptureRequestOptions` clears the whole bundle, which would
    // wipe the `CONTROL_AE_LOCK` set by `setExposureMode` and the
    // `CONTROL_VIDEO_STABILIZATION_MODE` set by `setVideoStabilizationMode`.
    return cameraControl.addCaptureRequestOptions(builder.build())
  }

  @VisibleForTesting
  internal fun onAutoWhiteBalanceResult(result: CaptureResult) {
    if (lockActive) {
      // While locked the capture results echo back the gains we asked for, so reporting them would
      // be a pointless round trip, and would contradict the platform interface, which documents
      // the stream as emitting only in auto mode.
      return
    }

    // The device's own view of the mode, not just ours: a request still in flight, or anything
    // else that touches AWB, must not be read as an auto reading. Absent on some devices, in which
    // case there is nothing to check against.
    val mode = result.get(CaptureResult.CONTROL_AWB_MODE)
    if (mode != null && mode != CameraMetadata.CONTROL_AWB_MODE_AUTO) {
      return
    }

    // Only report a settled reading. SEARCHING and INACTIVE frames are mid-convergence and would
    // make the stream jitter through values that never appear on screen.
    val state = result.get(CaptureResult.CONTROL_AWB_STATE)
    if (state != null &&
        state != CaptureResult.CONTROL_AWB_STATE_CONVERGED &&
        state != CaptureResult.CONTROL_AWB_STATE_LOCKED) {
      return
    }

    val now = SystemClock.elapsedRealtime()
    if (now < nextEmissionUptimeMillis) {
      return
    }

    // Cache the device's matrix while it is the one in charge. Reached only after the mode check
    // above, so the frames just after a lock is released, which still echo the manual transform,
    // cannot poison it.
    result.get(CaptureResult.COLOR_CORRECTION_TRANSFORM)?.let {
      observedAutoTransform = ColorTransform(it.toMatrix3())
    }

    // Many devices leave this null unless COLOR_CORRECTION_MODE is TRANSFORM_MATRIX, which is
    // never the case in auto mode. There is no other way to read the chosen white balance, so
    // those devices simply never emit.
    val vector = result.get(CaptureResult.COLOR_CORRECTION_GAINS) ?: return
    val gains =
        Gains(
            red = vector.red.toDouble(),
            // The two green gains are per-Bayer-row and are equal in practice; average them so a
            // device that does distinguish them does not bias the result.
            green = (vector.greenEven.toDouble() + vector.greenOdd.toDouble()) / 2.0,
            blue = vector.blue.toDouble(),
        )
    val (temperature, tint) =
        WhiteBalanceConverter.temperatureAndTintFor(gains, gainModel) ?: return
    nextEmissionUptimeMillis = now + AUTO_WHITE_BALANCE_MIN_INTERVAL_MILLIS
    api.reportAutoWhiteBalanceChanged(this, temperature, tint)
  }

  /**
   * The gain model to use for `cameraInfo`, rebuilt whenever the camera changes.
   *
   * Prefers the sensor's own calibration. Falls back to the Planckian approximation, handing it the
   * device's observed colour matrix when one has been seen.
   *
   * Deliberately does *not* also use the observed *gains* to anchor the approximation. That would
   * be a one point calibration, and tempting, but it would make `setWhiteBalance(5000K)` depend on
   * what the room looked like when the app started, so the same call would give different results
   * on different launches.
   */
  private fun modelFor(cameraInfo: Camera2CameraInfo): GainModel {
    val cameraId = cameraInfo.getCameraId()
    if (cameraId != modelCameraId) {
      val calibration = WhiteBalanceCalibrationReader.read(cameraInfo)
      if (calibration == null) {
        Log.i(TAG, "Camera $cameraId publishes no colour calibration; approximating white balance.")
      }
      gainModel = calibration?.let { CalibratedGainModel(it) } ?: PlanckianGainModel()
      modelCameraId = cameraId
      // A different sensor's matrix is meaningless here.
      observedAutoTransform = null
    }
    val model = gainModel
    if (model is PlanckianGainModel) {
      // The observed matrix arrives asynchronously, so rebuild the fallback model whenever a newer
      // one has turned up rather than only when the camera changes.
      val observed = observedAutoTransform
      if (observed != null) {
        val refreshed = PlanckianGainModel(observed)
        gainModel = refreshed
        return refreshed
      }
    }
    return model
  }

  private fun supportsAwbMode(cameraInfo: Camera2CameraInfo, mode: Int): Boolean {
    val modes =
        cameraInfo.getCameraCharacteristic(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES)
            // Absent characteristic means the device did not advertise its modes. AUTO is mandatory
            // for
            // every camera, so assume it works and let anything else fail loudly at request time.
            ?: return mode == CameraMetadata.CONTROL_AWB_MODE_AUTO
    return modes.contains(mode)
  }

  /**
   * Whether the camera claims `MANUAL_POST_PROCESSING`, the capability that documents the colour
   * correction keys as honoured.
   *
   * An absent characteristic is taken as support: it is mandatory, so a camera omitting it has
   * already stopped telling the truth about itself, and refusing the control on that basis would
   * only be a guess in the other direction.
   */
  private fun supportsManualPostProcessing(cameraInfo: Camera2CameraInfo): Boolean {
    val capabilities =
        cameraInfo.getCameraCharacteristic(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
            ?: return true
    return capabilities.contains(
        CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING)
  }

  /**
   * Warns when the camera does not claim `MANUAL_POST_PROCESSING`.
   *
   * Such a camera may list `CONTROL_AWB_MODE_OFF` and still ignore the colour correction keys, so
   * the lock quietly does nothing. Not grounds to refuse the request - see
   * [isWhiteBalanceSupported] - but worth being able to spot in a bug report.
   */
  private fun warnIfManualPostProcessingUnsupported(cameraInfo: Camera2CameraInfo) {
    if (!supportsManualPostProcessing(cameraInfo)) {
      Log.w(
          TAG,
          "Camera ${cameraInfo.getCameraId()} does not support MANUAL_POST_PROCESSING; " +
              "the white balance lock may have no effect.",
      )
    }
  }

  /** What was last asked for. A null [temperature] means auto white balance. */
  private data class RequestedState(
      val temperature: Double?,
      val tint: Double?,
      val cameraId: String,
  ) {
    val isLocked: Boolean
      get() = temperature != null && tint != null
  }

  companion object {
    private const val TAG = "WhiteBalanceManager"

    /** Matches `DefaultCamera.autoWhiteBalanceMinInterval` on iOS. */
    private const val AUTO_WHITE_BALANCE_MIN_INTERVAL_MILLIS = 100L
  }
}
