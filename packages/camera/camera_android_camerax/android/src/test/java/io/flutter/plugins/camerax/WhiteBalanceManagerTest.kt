// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.params.RggbChannelVector
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import com.google.common.util.concurrent.Futures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.ArgumentCaptor
import org.mockito.ArgumentMatchers
import org.mockito.Mockito.atLeastOnce
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
@OptIn(markerClass = [ExperimentalCamera2Interop::class])
class WhiteBalanceManagerTest {
  private val api = mock(WhiteBalanceManagerProxyApi::class.java)

  @Test
  fun setWhiteBalance_sendsGainsAndAMatrixTogether() {
    // The bug this whole class exists to avoid: requesting TRANSFORM_MATRIX mode without also
    // supplying a matrix leaves whatever was last in the request in force, so the gains land on
    // top of an arbitrary colour transform.
    val manager = WhiteBalanceManager(api)
    val cameraControl = mockCameraControl()
    val cameraInfo = mockCameraInfo(withCalibration = true)

    manager.setWhiteBalance(cameraControl, cameraInfo, 3000.0, 0.0)

    val options = captureOptions(cameraControl)
    assertEquals(
        CameraMetadata.CONTROL_AWB_MODE_OFF,
        options.getCaptureRequestOption(CaptureRequest.CONTROL_AWB_MODE),
    )
    assertEquals(
        CameraMetadata.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX,
        options.getCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_MODE),
    )
    assertNotNull(
        "a colour matrix must accompany the gains",
        options.getCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_TRANSFORM),
    )
    val gains = options.getCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_GAINS)
    assertNotNull(gains)
    // 3000K is warm, so blue is the boosted channel.
    assertTrue(gains!!.blue > gains.red)
  }

  @Test
  fun setWhiteBalance_mergesRatherThanReplacingTheOptions() {
    // `setCaptureRequestOptions` clears the whole bundle, which would drop the AE lock set by
    // `setExposureMode` and the stabilization mode set by `setVideoStabilizationMode`.
    val manager = WhiteBalanceManager(api)
    val cameraControl = mockCameraControl()

    manager.setWhiteBalance(cameraControl, mockCameraInfo(), 5000.0, 0.0)

    verify(cameraControl).addCaptureRequestOptions(any())
    verify(cameraControl, never()).setCaptureRequestOptions(any())
  }

  @Test
  fun setWhiteBalance_returnsToAutoWithoutWritingNeutralGains() {
    // Both keys are inert in FAST mode, and writing neutral values would be a visibly broken image
    // on any device that wrongly honours them.
    val manager = WhiteBalanceManager(api)
    val cameraControl = mockCameraControl()
    val cameraInfo = mockCameraInfo(withCalibration = true)

    manager.setWhiteBalance(cameraControl, cameraInfo, 3000.0, 0.0)
    manager.setWhiteBalance(cameraControl, cameraInfo, null, null)

    val options = captureOptions(cameraControl, invocation = 1)
    assertEquals(
        CameraMetadata.CONTROL_AWB_MODE_AUTO,
        options.getCaptureRequestOption(CaptureRequest.CONTROL_AWB_MODE),
    )
    assertEquals(
        CameraMetadata.COLOR_CORRECTION_MODE_FAST,
        options.getCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_MODE),
    )
    assertNull(options.getCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_GAINS))
    assertNull(options.getCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_TRANSFORM))
  }

  @Test
  fun setWhiteBalance_throwsWhenManualWhiteBalanceIsUnsupported() {
    val manager = WhiteBalanceManager(api)
    val cameraInfo = mockCameraInfo(awbModes = intArrayOf(CameraMetadata.CONTROL_AWB_MODE_AUTO))

    assertThrows(UnsupportedOperationException::class.java) {
      manager.setWhiteBalance(mockCameraControl(), cameraInfo, 5000.0, 0.0)
    }
  }

  @Test
  fun setWhiteBalance_assumesAutoIsSupportedWhenTheModesAreUnknown() {
    // AUTO is mandatory for every camera, so an absent characteristic is not a reason to refuse
    // returning to it. Anything else still has to fail loudly.
    val manager = WhiteBalanceManager(api)
    val cameraInfo = mockCameraInfo(awbModes = null)

    manager.setWhiteBalance(mockCameraControl(), cameraInfo, null, null)

    assertThrows(UnsupportedOperationException::class.java) {
      manager.setWhiteBalance(mockCameraControl(), cameraInfo, 5000.0, 0.0)
    }
  }

  @Test
  fun setWhiteBalance_leavesTheStateAloneWhenTheRequestThrows() {
    // The manager must not believe in a lock the camera never took, or it would stop reporting
    // auto readings while the camera is still in auto.
    val manager = WhiteBalanceManager(api)
    val cameraInfo = mockCameraInfo(awbModes = intArrayOf(CameraMetadata.CONTROL_AWB_MODE_AUTO))

    assertThrows(UnsupportedOperationException::class.java) {
      manager.setWhiteBalance(mockCameraControl(), cameraInfo, 5000.0, 0.0)
    }

    manager.onAutoWhiteBalanceResult(autoResult())
    verify(api).reportAutoWhiteBalanceChanged(eq(manager), anyDouble(), anyDouble())
  }

  @Test
  fun isWhiteBalanceSupported_needsBothTheOffModeAndTheColourCorrectionKeys() {
    val manager = WhiteBalanceManager(api)

    assertTrue(
        manager.isWhiteBalanceSupported(
            mockCameraInfo(capabilities = intArrayOf(MANUAL_POST_PROCESSING))))
  }

  @Test
  fun isWhiteBalanceSupported_isFalseWhenTheAutoAlgorithmCannotBeTurnedOff() {
    val manager = WhiteBalanceManager(api)

    assertFalse(
        manager.isWhiteBalanceSupported(
            mockCameraInfo(
                awbModes = intArrayOf(CameraMetadata.CONTROL_AWB_MODE_AUTO),
                capabilities = intArrayOf(MANUAL_POST_PROCESSING),
            )))
  }

  @Test
  fun isWhiteBalanceSupported_isFalseWithoutManualPostProcessing() {
    // Such a camera can be locked, but only to whatever the auto algorithm last chose: the
    // requested temperature is ignored, which is not a control worth offering.
    val manager = WhiteBalanceManager(api)

    assertFalse(manager.isWhiteBalanceSupported(mockCameraInfo(capabilities = intArrayOf())))
  }

  @Test
  fun isWhiteBalanceSupported_assumesTheKeysAreHonouredWhenTheCapabilitiesAreUnknown() {
    // The characteristic is mandatory, so a camera omitting it is already misreporting itself;
    // guessing "unsupported" from that would only hide a control that probably works.
    val manager = WhiteBalanceManager(api)

    assertTrue(manager.isWhiteBalanceSupported(mockCameraInfo()))
  }

  @Test
  fun attachToCamera_doesNothingBeforeAnythingIsRequested() {
    // Forcing AWB_AUTO on every rebind would stomp whatever the device does by default.
    val manager = WhiteBalanceManager(api)
    val cameraControl = mockCameraControl()

    manager.attachToCamera(cameraControl, mockCameraInfo())

    verify(cameraControl, never()).addCaptureRequestOptions(any())
  }

  @Test
  fun attachToCamera_reappliesTheLockToTheNewCamera() {
    // Capture request options live on the `Camera` instance, so without this a lock is dropped on
    // every resolution change, viewport change and preview resume.
    val manager = WhiteBalanceManager(api)
    val cameraInfo = mockCameraInfo(withCalibration = true)
    manager.setWhiteBalance(mockCameraControl(), cameraInfo, 3000.0, 0.0)

    val rebound = mockCameraControl()
    manager.attachToCamera(rebound, cameraInfo)

    val options = captureOptions(rebound)
    assertEquals(
        CameraMetadata.CONTROL_AWB_MODE_OFF,
        options.getCaptureRequestOption(CaptureRequest.CONTROL_AWB_MODE),
    )
    assertNotNull(options.getCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_TRANSFORM))
    assertNotNull(options.getCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_GAINS))
  }

  @Test
  fun attachToCamera_reappliesAutoToo() {
    // Returning to auto is a request like any other, and a rebind resets the camera to its own
    // default rather than to the one that was asked for.
    val manager = WhiteBalanceManager(api)
    val cameraInfo = mockCameraInfo()
    manager.setWhiteBalance(mockCameraControl(), cameraInfo, null, null)

    val rebound = mockCameraControl()
    manager.attachToCamera(rebound, cameraInfo)

    assertEquals(
        CameraMetadata.CONTROL_AWB_MODE_AUTO,
        captureOptions(rebound).getCaptureRequestOption(CaptureRequest.CONTROL_AWB_MODE),
    )
  }

  @Test
  fun attachToCamera_recomputesTheGainsForADifferentSensor() {
    // A lens switch means a different sensor, whose calibration produces different gains for the
    // same temperature.
    val manager = WhiteBalanceManager(api)
    val front = mockCameraInfo(cameraId = "0", withCalibration = true)
    val frontControl = mockCameraControl()
    manager.setWhiteBalance(frontControl, front, 3000.0, 0.0)
    val frontGains = gainsSentTo(frontControl)

    val back = mockCameraInfo(cameraId = "1", withCalibration = true, warmPoleScale = 2.0)
    val backControl = mockCameraControl()
    manager.attachToCamera(backControl, back)
    val backGains = gainsSentTo(backControl)

    assertTrue(
        "the gains should differ between sensors",
        frontGains.blue != backGains.blue || frontGains.red != backGains.red,
    )
  }

  @Test
  fun attachToCamera_stopsSuppressingAutoReadingsWhenTheRelockFails() {
    // A lens switch to hardware that cannot honour the lock leaves that camera running its own
    // auto algorithm; the manager must not keep believing it is locked and go silent forever.
    val manager = WhiteBalanceManager(api)
    val locked = mockCameraInfo(cameraId = "0", withCalibration = true)
    manager.setWhiteBalance(mockCameraControl(), locked, 5000.0, 0.0)

    val unsupported =
        mockCameraInfo(cameraId = "1", awbModes = intArrayOf(CameraMetadata.CONTROL_AWB_MODE_AUTO))
    assertThrows(UnsupportedOperationException::class.java) {
      manager.attachToCamera(mockCameraControl(), unsupported)
    }

    manager.onAutoWhiteBalanceResult(autoResult())
    verify(api).reportAutoWhiteBalanceChanged(eq(manager), anyDouble(), anyDouble())
  }

  @Test
  fun onAutoWhiteBalanceResult_reportsASettledReading() {
    val manager = WhiteBalanceManager(api)

    manager.onAutoWhiteBalanceResult(autoResult())

    val temperature = ArgumentCaptor.forClass(Double::class.java)
    val tint = ArgumentCaptor.forClass(Double::class.java)
    verify(api).reportAutoWhiteBalanceChanged(eq(manager), temperature.capture(), tint.capture())
    assertTrue(temperature.value in 1800.0..9800.0)
    assertTrue(tint.value in -50.0..50.0)
  }

  @Test
  fun onAutoWhiteBalanceResult_ignoresFramesThatAreStillConverging() {
    // Reporting a SEARCHING frame makes the stream jitter through values that never reach the
    // screen.
    val manager = WhiteBalanceManager(api)

    manager.onAutoWhiteBalanceResult(
        autoResult(awbState = CaptureResult.CONTROL_AWB_STATE_SEARCHING))

    verify(api, never()).reportAutoWhiteBalanceChanged(any(), anyDouble(), anyDouble())
  }

  @Test
  fun onAutoWhiteBalanceResult_ignoresFramesWhereTheDeviceIsNotInAutoMode() {
    val manager = WhiteBalanceManager(api)

    manager.onAutoWhiteBalanceResult(autoResult(awbMode = CameraMetadata.CONTROL_AWB_MODE_OFF))

    verify(api, never()).reportAutoWhiteBalanceChanged(any(), anyDouble(), anyDouble())
  }

  @Test
  fun onAutoWhiteBalanceResult_isSilentWhileLocked() {
    // While locked the results echo back the gains we asked for, and the platform interface
    // documents the stream as emitting only in auto mode.
    val manager = WhiteBalanceManager(api)
    manager.setWhiteBalance(
        mockCameraControl(), mockCameraInfo(withCalibration = true), 4000.0, 0.0)

    manager.onAutoWhiteBalanceResult(autoResult())

    verify(api, never()).reportAutoWhiteBalanceChanged(any(), anyDouble(), anyDouble())
  }

  @Test
  fun onAutoWhiteBalanceResult_throttlesTheEmissions() {
    val manager = WhiteBalanceManager(api)

    repeat(5) { manager.onAutoWhiteBalanceResult(autoResult()) }

    // The capture callback fires at the frame rate; only the first of a burst gets through.
    verify(api).reportAutoWhiteBalanceChanged(eq(manager), anyDouble(), anyDouble())
  }

  @Test
  fun onAutoWhiteBalanceResult_ignoresFramesWithoutGains() {
    // Many devices never populate this outside TRANSFORM_MATRIX mode, so they simply never emit.
    val manager = WhiteBalanceManager(api)

    manager.onAutoWhiteBalanceResult(autoResult(gains = null))

    verify(api, never()).reportAutoWhiteBalanceChanged(any(), anyDouble(), anyDouble())
  }

  private fun mockCameraControl(): Camera2CameraControl {
    val cameraControl = mock(Camera2CameraControl::class.java)
    `when`(cameraControl.addCaptureRequestOptions(any())).thenReturn(Futures.immediateFuture(null))
    return cameraControl
  }

  private fun mockCameraInfo(
      cameraId: String = "0",
      awbModes: IntArray? =
          intArrayOf(CameraMetadata.CONTROL_AWB_MODE_AUTO, CameraMetadata.CONTROL_AWB_MODE_OFF),
      withCalibration: Boolean = false,
      warmPoleScale: Double = 1.0,
      capabilities: IntArray? = null,
  ): Camera2CameraInfo {
    val cameraInfo = mock(Camera2CameraInfo::class.java)
    `when`(cameraInfo.getCameraId()).thenReturn(cameraId)
    `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES))
        .thenReturn(awbModes)
    `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES))
        .thenReturn(capabilities)
    if (withCalibration) {
      `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT1))
          .thenReturn(WhiteBalanceCalibration.ILLUMINANT_STANDARD_A)
      `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_COLOR_TRANSFORM1))
          .thenReturn(
              with(WhiteBalanceCalibrationReader) {
                Matrix3.diagonal(warmPoleScale, 1.0, 1.0).toColorSpaceTransform()
              })
      `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT2))
          .thenReturn(WhiteBalanceCalibration.ILLUMINANT_D65.toByte())
      `when`(cameraInfo.getCameraCharacteristic(CameraCharacteristics.SENSOR_COLOR_TRANSFORM2))
          .thenReturn(
              with(WhiteBalanceCalibrationReader) { Matrix3.identity.toColorSpaceTransform() })
    }
    return cameraInfo
  }

  /** A capture result of the shape a camera running its own auto white balance produces. */
  private fun autoResult(
      awbMode: Int? = CameraMetadata.CONTROL_AWB_MODE_AUTO,
      awbState: Int? = CaptureResult.CONTROL_AWB_STATE_CONVERGED,
      gains: RggbChannelVector? = RggbChannelVector(1.9f, 1.0f, 1.0f, 1.6f),
  ): CaptureResult {
    val result = mock(CaptureResult::class.java)
    `when`(result.get(CaptureResult.CONTROL_AWB_MODE)).thenReturn(awbMode)
    `when`(result.get(CaptureResult.CONTROL_AWB_STATE)).thenReturn(awbState)
    `when`(result.get(CaptureResult.COLOR_CORRECTION_GAINS)).thenReturn(gains)
    return result
  }

  private fun gainsSentTo(cameraControl: Camera2CameraControl): RggbChannelVector =
      captureOptions(cameraControl).getCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_GAINS)!!

  private fun captureOptions(
      cameraControl: Camera2CameraControl,
      invocation: Int = 0,
  ): CaptureRequestOptions {
    val captor = ArgumentCaptor.forClass(CaptureRequestOptions::class.java)
    verify(cameraControl, atLeastOnce()).addCaptureRequestOptions(captor.capture() ?: unused())
    return captor.allValues[invocation]
  }

  // Mockito's matchers and captors return null for reference types, which Kotlin's null safety
  // rejects at the call site even though the value itself is never used.
  private fun <T> any(): T = ArgumentMatchers.any<T>() ?: unused()

  private fun <T> eq(value: T): T = ArgumentMatchers.eq(value) ?: unused()

  private fun anyDouble(): Double = ArgumentMatchers.anyDouble()

  @Suppress("UNCHECKED_CAST") private fun <T> unused(): T = null as T

  private companion object {
    const val MANUAL_POST_PROCESSING =
        CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING
  }
}
