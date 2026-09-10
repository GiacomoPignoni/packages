// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraMetadata;
import android.util.SizeF;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.camera2.interop.ExperimentalCamera2Interop;
import androidx.camera.core.CameraInfo;

/**
 * ProxyApi implementation for {@link Camera2CameraInfo}. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
@OptIn(markerClass = ExperimentalCamera2Interop.class)
class Camera2CameraInfoProxyApi extends PigeonApiCamera2CameraInfo {
  Camera2CameraInfoProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @NonNull
  @Override
  public Camera2CameraInfo from(@NonNull CameraInfo cameraInfo) {
    return Camera2CameraInfo.from(cameraInfo);
  }

  @NonNull
  @Override
  public String getCameraId(Camera2CameraInfo pigeonInstance) {
    return pigeonInstance.getCameraId();
  }

  @Nullable
  @Override
  public Object getCameraCharacteristic(
      Camera2CameraInfo pigeonInstance, @NonNull CameraCharacteristics.Key<?> key) {
    final Object result = pigeonInstance.getCameraCharacteristic(key);
    if (result == null) {
      return null;
    }

    if (CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL.equals(key)) {
      switch ((Integer) result) {
        case CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_3:
          return InfoSupportedHardwareLevel.LEVEL3;
        case CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL:
          return InfoSupportedHardwareLevel.EXTERNAL;
        case CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_FULL:
          return InfoSupportedHardwareLevel.FULL;
        case CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY:
          return InfoSupportedHardwareLevel.LEGACY;
        case CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED:
          return InfoSupportedHardwareLevel.LIMITED;
        default:
          // Fall through to return result.
          break;
      }
    }
    return result;
  }

  /**
   * The 35mm-equivalent focal length in millimetres, or null when the device does not report both
   * characteristics it is derived from.
   *
   * <p>Uses the diagonal of a 35mm frame (sqrt(36^2 + 24^2) ~= 43.2666mm) over the diagonal of this
   * sensor to get the crop factor, which is the same reference AVFoundation's diagonal
   * field-of-view calculation resolves to. Computed here rather than in Dart because {@code SizeF}
   * and {@code float[]} have no Pigeon representation.
   */
  @Nullable
  @Override
  public Double getEquivalentFocalLength(Camera2CameraInfo pigeonInstance) {
    return equivalentFocalLength(pigeonInstance);
  }

  /**
   * The 35mm-equivalent focal length of the camera {@code cameraInfo} describes, in millimetres, or
   * null when it does not report both characteristics that is derived from.
   *
   * <p>Static so that a camera which cannot be handed to Dart as a {@link Camera2CameraInfo} of its
   * own — a physical camera inside a logical one, which supports characteristics and little else —
   * can still be measured. See {@code CameraInfoProxyApi.getPhysicalCameraFocalLengths}.
   */
  @Nullable
  static Double equivalentFocalLength(@NonNull Camera2CameraInfo pigeonInstance) {
    final float[] focalLengths =
        pigeonInstance.getCameraCharacteristic(
            CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS);
    final SizeF sensorSize =
        pigeonInstance.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE);
    if (focalLengths == null || focalLengths.length == 0 || sensorSize == null) {
      return null;
    }

    final double sensorDiagonal =
        Math.hypot((double) sensorSize.getWidth(), (double) sensorSize.getHeight());
    if (!(sensorDiagonal > 0d) || !(focalLengths[0] > 0f)) {
      return null;
    }
    // The first entry is the lens's native focal length; a zoom lens would list more, but every
    // camera CameraX exposes as a separate CameraInfo is a fixed lens.
    return focalLengths[0] * (FULL_FRAME_DIAGONAL_MM / sensorDiagonal);
  }

  /** Diagonal of a 35mm frame in millimetres, matching the constant AVFoundation resolves to. */
  private static final double FULL_FRAME_DIAGONAL_MM = 43.2666d;
}
