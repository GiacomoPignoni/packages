// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.util.Log
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraControl
import androidx.core.content.ContextCompat
import com.google.common.util.concurrent.FutureCallback
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * ProxyApi implementation for [WhiteBalanceManager]. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
@OptIn(markerClass = [ExperimentalCamera2Interop::class])
class WhiteBalanceManagerProxyApi(override val pigeonRegistrar: ProxyApiRegistrar) :
    PigeonApiWhiteBalanceManager(pigeonRegistrar) {
  override fun pigeon_defaultConstructor(): WhiteBalanceManager = WhiteBalanceManager(this)

  override fun isWhiteBalanceSupported(
      pigeon_instance: WhiteBalanceManager,
      cameraInfo: Camera2CameraInfo,
  ): Boolean = pigeon_instance.isWhiteBalanceSupported(cameraInfo)

  override fun reset(pigeon_instance: WhiteBalanceManager) {
    pigeon_instance.reset()
  }

  override fun setWhiteBalance(
      pigeon_instance: WhiteBalanceManager,
      cameraControl: Camera2CameraControl,
      cameraInfo: Camera2CameraInfo,
      temperature: Double?,
      tint: Double?,
      callback: (Result<Unit>) -> Unit,
  ) {
    try {
      // Wait for the camera to accept the options rather than reporting success as soon as they
      // are queued, so that a rejected request surfaces as `setWhiteBalanceFailed` in Dart. A
      // superseded request is not a rejection; see `completeWhenDone`.
      completeWhenDone(
          pigeon_instance.setWhiteBalance(cameraControl, cameraInfo, temperature, tint),
          callback,
      )
    } catch (exception: Throwable) {
      callback(Result.failure(exception))
    }
  }

  override fun attachToCamera(
      pigeon_instance: WhiteBalanceManager,
      cameraControl: Camera2CameraControl,
      cameraInfo: Camera2CameraInfo,
      callback: (Result<Unit>) -> Unit,
  ) {
    // A rebind is not something the user asked for, so a failure to restore the white balance must
    // not turn a resolution change into an exception. Log it and let the rebind finish.
    try {
      pigeon_instance.attachToCamera(cameraControl, cameraInfo)
    } catch (exception: Throwable) {
      Log.w(TAG, "WhiteBalanceManager.attachToCamera failed: ${exception.message}")
    }
    callback(Result.success(Unit))
  }

  /** Forwards an auto white balance reading to Dart on the main thread. */
  fun reportAutoWhiteBalanceChanged(
      instance: WhiteBalanceManager,
      temperature: Double,
      tint: Double,
  ) {
    pigeonRegistrar.runOnMainThread(
        object : ProxyApiRegistrar.FlutterMethodRunnable() {
          override fun run() {
            onAutoWhiteBalanceChanged(instance, temperature, tint) { result ->
              result.exceptionOrNull()?.let {
                Log.e(TAG, "WhiteBalanceManager.onAutoWhiteBalanceChanged failed: ${it.message}")
              }
            }
          }
        })
  }

  private fun completeWhenDone(
      future: ListenableFuture<Void?>,
      callback: (Result<Unit>) -> Unit,
  ) {
    Futures.addCallback(
        future,
        object : FutureCallback<Void?> {
          override fun onSuccess(result: Void?) {
            callback(Result.success(Unit))
          }

          override fun onFailure(t: Throwable) {
            if (t is CameraControl.OperationCanceledException) {
              // `Camera2CameraControl` cancels an in flight future as soon as newer options arrive,
              // which happens routinely: `setExposureMode`, `setVideoStabilizationMode` and
              // `attachToCamera` all update the same control, and at startup they overlap. The
              // white
              // balance options were still merged in, so this is not a failure to report.
              callback(Result.success(Unit))
              return
            }
            callback(Result.failure(t))
          }
        },
        ContextCompat.getMainExecutor(pigeonRegistrar.context),
    )
  }

  private companion object {
    const val TAG = "WhiteBalanceManager"
  }
}
