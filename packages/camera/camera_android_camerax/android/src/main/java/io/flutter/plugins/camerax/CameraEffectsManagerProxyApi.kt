// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.util.Log
import androidx.camera.core.CameraEffect

/**
 * ProxyApi implementation for [CameraEffectsManager]. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
class CameraEffectsManagerProxyApi(override val pigeonRegistrar: ProxyApiRegistrar) :
    PigeonApiCameraEffectsManager(pigeonRegistrar) {
  override fun pigeon_defaultConstructor(aspectRatio: Double?): CameraEffectsManager =
      CameraEffectsManager(this, aspectRatio)

  override fun getCameraEffect(pigeon_instance: CameraEffectsManager): CameraEffect =
      pigeon_instance.getCameraEffect()

  override fun setEffectsValues(
      pigeon_instance: CameraEffectsManager,
      values: PlatformEffectsValues
  ) {
    pigeon_instance.setEffectsValues(values)
  }

  override fun setAspectRatio(pigeon_instance: CameraEffectsManager, aspectRatio: Double?) {
    pigeon_instance.setAspectRatio(aspectRatio)
  }

  override fun setCaptureScale(pigeon_instance: CameraEffectsManager, scale: Double) {
    pigeon_instance.setCaptureScale(scale)
  }

  override fun setCaptureCornerRadius(pigeon_instance: CameraEffectsManager, radius: Double) {
    pigeon_instance.setCaptureCornerRadius(radius)
  }

  override fun notifyPreviewSize(pigeon_instance: CameraEffectsManager) {
    pigeon_instance.notifyPreviewSize()
  }

  override fun detachOutputs(pigeon_instance: CameraEffectsManager) {
    pigeon_instance.detachOutputs()
  }

  override fun release(pigeon_instance: CameraEffectsManager) {
    pigeon_instance.release()
  }

  /** Forwards a preview size change to Dart on the main thread. */
  fun reportPreviewSizeChanged(instance: CameraEffectsManager, width: Int, height: Int) {
    pigeonRegistrar.runOnMainThread(
        object : ProxyApiRegistrar.FlutterMethodRunnable() {
          override fun run() {
            onPreviewSizeChanged(instance, width.toLong(), height.toLong()) { result ->
              result.exceptionOrNull()?.let {
                Log.e(TAG, "CameraEffectsManager.onPreviewSizeChanged failed: ${it.message}")
              }
            }
          }
        })
  }

  /** Forwards a lost preview output to Dart on the main thread. */
  fun reportPreviewOutputLost(instance: CameraEffectsManager) {
    pigeonRegistrar.runOnMainThread(
        object : ProxyApiRegistrar.FlutterMethodRunnable() {
          override fun run() {
            onPreviewOutputLost(instance) { result ->
              result.exceptionOrNull()?.let {
                Log.e(TAG, "CameraEffectsManager.onPreviewOutputLost failed: ${it.message}")
              }
            }
          }
        })
  }

  private companion object {
    const val TAG = "CameraEffectsManager"
  }
}
