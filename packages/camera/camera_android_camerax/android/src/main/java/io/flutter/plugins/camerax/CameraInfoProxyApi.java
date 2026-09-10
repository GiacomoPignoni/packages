// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.util.Log;
import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.camera2.interop.ExperimentalCamera2Interop;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.ExperimentalLensFacing;
import androidx.camera.core.ExposureState;
import java.util.ArrayList;
import java.util.List;

/**
 * ProxyApi implementation for {@link CameraInfo}. This class may handle instantiating native object
 * instances that are attached to a Dart instance or handle method calls on the associated native
 * class or an instance of that class.
 */
class CameraInfoProxyApi extends PigeonApiCameraInfo {
  private static final String TAG = "CameraInfo";

  CameraInfoProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @Override
  public long sensorRotationDegrees(CameraInfo pigeonInstance) {
    return pigeonInstance.getSensorRotationDegrees();
  }

  @Override
  @OptIn(markerClass = ExperimentalLensFacing.class)
  public LensFacing lensFacing(CameraInfo pigeonInstance) {
    int lensFacing = pigeonInstance.getLensFacing();
    switch (lensFacing) {
      case CameraSelector.LENS_FACING_FRONT:
        return LensFacing.FRONT;
      case CameraSelector.LENS_FACING_BACK:
        return LensFacing.BACK;
      case CameraSelector.LENS_FACING_EXTERNAL:
        return LensFacing.EXTERNAL;
      default:
        return LensFacing.UNKNOWN;
    }
  }

  @NonNull
  @Override
  public ExposureState exposureState(CameraInfo pigeonInstance) {
    return pigeonInstance.getExposureState();
  }

  @NonNull
  @Override
  public LiveDataProxyApi.LiveDataWrapper getCameraState(CameraInfo pigeonInstance) {
    return new LiveDataProxyApi.LiveDataWrapper(
        pigeonInstance.getCameraState(), LiveDataSupportedType.CAMERA_STATE);
  }

  @NonNull
  @Override
  public LiveDataProxyApi.LiveDataWrapper getZoomState(CameraInfo pigeonInstance) {
    return new LiveDataProxyApi.LiveDataWrapper(
        pigeonInstance.getZoomState(), LiveDataSupportedType.ZOOM_STATE);
  }

  @Override
  public boolean hasFlashUnit(CameraInfo pigeonInstance) {
    return pigeonInstance.hasFlashUnit();
  }

  @NonNull
  @Override
  @OptIn(markerClass = ExperimentalCamera2Interop.class)
  public List<Double> getPhysicalCameraFocalLengths(CameraInfo pigeonInstance) {
    final List<Double> focalLengths = new ArrayList<>();
    for (CameraInfo physicalCameraInfo : pigeonInstance.getPhysicalCameraInfos()) {
      try {
        final Double focalLength =
            Camera2CameraInfoProxyApi.equivalentFocalLength(
                Camera2CameraInfo.from(physicalCameraInfo));
        if (focalLength != null) {
          focalLengths.add(focalLength);
        }
      } catch (RuntimeException exception) {
        // A physical camera supports a narrow slice of what a camera does, and which slice varies
        // by device. One that will not say how long its lens is is one this cannot describe; the
        // others are still worth reporting.
        Log.w(TAG, "Could not read the focal length of a physical camera: " + exception);
      }
    }
    return focalLengths;
  }
}
