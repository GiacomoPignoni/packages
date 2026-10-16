// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.content.Context;
import android.util.Log;
import android.view.Display;
import android.view.OrientationEventListener;
import android.view.Surface;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.VisibleForTesting;
import io.flutter.embedding.engine.systemchannels.PlatformChannel;
import io.flutter.embedding.engine.systemchannels.PlatformChannel.DeviceOrientation;
import java.util.Objects;

/**
 * Support class to help to determine the media orientation based on the orientation of the device.
 */
public class DeviceOrientationManager {
  private final DeviceOrientationManagerProxyApi api;
  private PlatformChannel.DeviceOrientation lastOrientation;
  private int displayRotation = Surface.ROTATION_0;

  @VisibleForTesting @Nullable protected OrientationEventListener orientationEventListener;

  DeviceOrientationManager(DeviceOrientationManagerProxyApi api) {
    this.api = api;
  }

  @NonNull
  Context getContext() {
    return api.getPigeonRegistrar().getContext();
  }

  /**
   * Starts listening to the device's sensors for device orientation updates.
   *
   * <p>When orientation information is updated, the callback method of the {@link
   * DeviceOrientationManagerProxyApi} is called with the new orientation.
   */
  public void start() {
    stop();

    // Read once, as the Dart side does when the camera is created: the UI is pinned, so the display
    // does not turn while the camera is open.
    displayRotation = getDefaultRotation();

    // Listen for changes in device orientation at the default rate that is suitable for monitoring
    // typical screen orientation changes.
    orientationEventListener = createOrientationEventListener();
    orientationEventListener.enable();
  }

  @VisibleForTesting
  @NonNull
  /**
   * Creates an {@link OrientationEventListener} that passes every sensor reading to {@link
   * #handleSensorOrientationChange}, which reports the device orientation whenever it snaps to a
   * new quarter turn.
   */
  protected OrientationEventListener createOrientationEventListener() {
    return new OrientationEventListener(getContext()) {
      @Override
      public void onOrientationChanged(int degrees) {
        handleSensorOrientationChange(degrees);
      }
    };
  }

  /** Stops listening for orientation updates. */
  public void stop() {
    if (orientationEventListener == null) {
      return;
    }
    lastOrientation = null;

    orientationEventListener.disable();
    orientationEventListener = null;
  }

  /**
   * Reports how the device is held relative to the UI, read from the sensor rather than the UI so
   * it keeps working under the system rotation lock and with the activity pinned to portrait.
   */
  @VisibleForTesting
  void handleSensorOrientationChange(int degrees) {
    PlatformChannel.DeviceOrientation orientation =
        orientationFromDegrees(degrees, displayRotation);
    if (orientation == null) {
      return;
    }
    handleOrientationChange(this, orientation, lastOrientation, api);
    lastOrientation = orientation;
  }

  /**
   * Snaps an {@link OrientationEventListener} angle to a quarter turn relative to the UI. The angle
   * is measured from the device's natural orientation, so {@code displayRotation} is added: where
   * that is landscape, the portrait UI already sits a quarter turn from it.
   *
   * <p>Null while the device lies flat or sits within 15 degrees of a diagonal, so the orientation
   * only flips once the device is turned past 60 degrees.
   */
  @VisibleForTesting
  @Nullable
  static PlatformChannel.DeviceOrientation orientationFromDegrees(
      int degrees, int displayRotation) {
    if (degrees == OrientationEventListener.ORIENTATION_UNKNOWN) {
      return null;
    }
    int uiDegrees = (degrees + 90 * displayRotation) % 360;
    int quarterTurns = Math.round(uiDegrees / 90f);
    if (Math.abs(uiDegrees - quarterTurns * 90) > 30) {
      return null;
    }
    switch (quarterTurns % 4) {
      case 1:
        return PlatformChannel.DeviceOrientation.LANDSCAPE_RIGHT;
      case 2:
        return PlatformChannel.DeviceOrientation.PORTRAIT_DOWN;
      case 3:
        return PlatformChannel.DeviceOrientation.LANDSCAPE_LEFT;
      default:
        return PlatformChannel.DeviceOrientation.PORTRAIT_UP;
    }
  }

  /**
   * Handles orientation changes coming from the device's sensors.
   *
   * <p>This method is visible for testing purposes only and should never be used outside this
   * class.
   */
  @VisibleForTesting
  static void handleOrientationChange(
      DeviceOrientationManager manager,
      DeviceOrientation newOrientation,
      DeviceOrientation previousOrientation,
      DeviceOrientationManagerProxyApi api) {
    if (!newOrientation.equals(previousOrientation)) {
      api.getPigeonRegistrar()
          .runOnMainThread(
              new ProxyApiRegistrar.FlutterMethodRunnable() {
                @Override
                public void run() {
                  api.onDeviceOrientationChanged(
                      manager,
                      newOrientation.toString(),
                      ResultCompat.asCompatCallback(
                          result -> {
                            if (result.isFailure()) {
                              onFailure(
                                  "DeviceOrientationManager.onDeviceOrientationChanged",
                                  Objects.requireNonNull(result.exceptionOrNull()));
                            }
                            return null;
                          }));
                }
              });
    }
  }

  /**
   * Gets default capture rotation for CameraX {@code UseCase}s.
   *
   * <p>See
   * https://developer.android.com/reference/androidx/camera/core/ImageCapture#setTargetRotation(int),
   * for instance.
   *
   * @return The rotation of the screen from its "natural" orientation; one of {@code
   *     Surface.ROTATION_0}, {@code Surface.ROTATION_90}, {@code Surface.ROTATION_180}, {@code
   *     Surface.ROTATION_270}
   */
  int getDefaultRotation() {
    Display display = getDisplay();

    if (display == null) {
      // The Activity is not available (null or destroyed), which can happen briefly
      // during configuration changes or due to race conditions. Returning ROTATION_0 ensures safe
      // fallback and prevents crashes until a valid Activity is attached again.
      Log.w(
          "DeviceOrientationManager",
          "Cannot get display: Activity may be null (destroyed or not yet attached) due to a race"
              + " condition.");
      return Surface.ROTATION_0;
    }

    return display.getRotation();
  }

  /**
   * Gets an instance of the Android {@link android.view.Display}.
   *
   * <p>This method is visible for testing purposes only and should never be used outside this
   * class.
   *
   * @return An instance of the Android {@link android.view.Display}.
   */
  @VisibleForTesting
  @Nullable
  Display getDisplay() {
    return api.getPigeonRegistrar().getDisplay();
  }
}
