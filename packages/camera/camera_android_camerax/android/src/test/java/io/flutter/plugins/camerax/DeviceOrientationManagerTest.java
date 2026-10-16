// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doNothing;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.spy;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.app.Activity;
import android.content.Context;
import android.util.FakeActivity;
import android.view.Display;
import android.view.OrientationEventListener;
import android.view.Surface;
import android.view.WindowManager;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import io.flutter.embedding.engine.systemchannels.PlatformChannel.DeviceOrientation;
import org.junit.Before;
import org.junit.Test;

public class DeviceOrientationManagerTest {
  private Activity mockActivity;
  private Display mockDisplay;

  private DeviceOrientationManagerProxyApi mockApi;
  private DeviceOrientationManager deviceOrientationManager;

  @Before
  public void before() {
    mockActivity = mock(Activity.class);
    mockDisplay = mock(Display.class);

    mockApi = mock(DeviceOrientationManagerProxyApi.class);

    final TestProxyApiRegistrar proxyApiRegistrar =
        new TestProxyApiRegistrar() {
          @NonNull
          @Override
          public Context getContext() {
            return mockActivity;
          }

          @Nullable
          @Override
          Display getDisplay() {
            return mockDisplay;
          }
        };

    when(mockApi.getPigeonRegistrar()).thenReturn(proxyApiRegistrar);

    deviceOrientationManager = new DeviceOrientationManager(mockApi);
  }

  @Test
  public void start_createsExpectedOrientationEventListener() {
    DeviceOrientationManager deviceOrientationManagerSpy = spy(deviceOrientationManager);

    doNothing().when(deviceOrientationManagerSpy).handleSensorOrientationChange(90);

    deviceOrientationManagerSpy.start();
    deviceOrientationManagerSpy.orientationEventListener.onOrientationChanged(90);

    verify(deviceOrientationManagerSpy).handleSensorOrientationChange(90);
  }

  @Test
  public void orientationFromDegrees_snapsToTheNearestQuarterTurn() {
    assertEquals(
        DeviceOrientation.PORTRAIT_UP,
        DeviceOrientationManager.orientationFromDegrees(0, Surface.ROTATION_0));
    assertEquals(
        DeviceOrientation.PORTRAIT_UP,
        DeviceOrientationManager.orientationFromDegrees(350, Surface.ROTATION_0));
    assertEquals(
        DeviceOrientation.LANDSCAPE_RIGHT,
        DeviceOrientationManager.orientationFromDegrees(90, Surface.ROTATION_0));
    assertEquals(
        DeviceOrientation.PORTRAIT_DOWN,
        DeviceOrientationManager.orientationFromDegrees(180, Surface.ROTATION_0));
    assertEquals(
        DeviceOrientation.LANDSCAPE_LEFT,
        DeviceOrientationManager.orientationFromDegrees(270, Surface.ROTATION_0));
  }

  @Test
  public void orientationFromDegrees_isRelativeToTheDisplayRotation() {
    // A landscape-natural device held upright for a portrait UI drawn at ROTATION_90.
    assertEquals(
        DeviceOrientation.PORTRAIT_UP,
        DeviceOrientationManager.orientationFromDegrees(270, Surface.ROTATION_90));
    assertEquals(
        DeviceOrientation.LANDSCAPE_RIGHT,
        DeviceOrientationManager.orientationFromDegrees(0, Surface.ROTATION_90));
  }

  @Test
  public void orientationFromDegrees_isNullWhenFlatOrNearADiagonal() {
    assertNull(
        DeviceOrientationManager.orientationFromDegrees(
            OrientationEventListener.ORIENTATION_UNKNOWN, Surface.ROTATION_0));
    assertNull(DeviceOrientationManager.orientationFromDegrees(45, Surface.ROTATION_0));
  }

  @Test
  public void handleSensorOrientationChange_usesTheDisplayRotationReadOnStart() {
    when(mockDisplay.getRotation()).thenReturn(Surface.ROTATION_90);

    deviceOrientationManager.start();
    deviceOrientationManager.handleSensorOrientationChange(270);

    verify(mockApi)
        .onDeviceOrientationChanged(
            eq(deviceOrientationManager), eq(DeviceOrientation.PORTRAIT_UP.toString()), any());
  }

  @Test
  public void start_enablesOrientationEventListener() {
    DeviceOrientationManager deviceOrientationManagerSpy = spy(deviceOrientationManager);
    OrientationEventListener mockOrientationEventListener = mock(OrientationEventListener.class);

    when(deviceOrientationManagerSpy.createOrientationEventListener())
        .thenReturn(mockOrientationEventListener);

    deviceOrientationManagerSpy.start();

    verify(mockOrientationEventListener).enable();
  }

  @Test
  public void stop_disablesOrientationListener() {
    OrientationEventListener mockOrientationEventListener = mock(OrientationEventListener.class);
    deviceOrientationManager.orientationEventListener = mockOrientationEventListener;

    deviceOrientationManager.stop();

    verify(mockOrientationEventListener).disable();
    assertNull(deviceOrientationManager.orientationEventListener);
  }

  @Test
  public void handleOrientationChange_shouldSendMessageWhenOrientationIsUpdated() {
    DeviceOrientation previousOrientation = DeviceOrientation.PORTRAIT_UP;
    DeviceOrientation newOrientation = DeviceOrientation.LANDSCAPE_LEFT;

    DeviceOrientationManager.handleOrientationChange(
        deviceOrientationManager, newOrientation, previousOrientation, mockApi);

    verify(mockApi, times(1))
        .onDeviceOrientationChanged(
            eq(deviceOrientationManager), eq(newOrientation.toString()), any());
  }

  @Test
  public void handleOrientationChange_shouldNotSendMessageWhenOrientationIsNotUpdated() {
    DeviceOrientation previousOrientation = DeviceOrientation.PORTRAIT_UP;
    DeviceOrientation newOrientation = DeviceOrientation.PORTRAIT_UP;

    DeviceOrientationManager.handleOrientationChange(
        deviceOrientationManager, newOrientation, previousOrientation, mockApi);

    verify(mockApi, never()).onDeviceOrientationChanged(any(), any(), any());
  }

  @Test
  public void getDefaultRotation_returnsExpectedValue() {
    final int expectedRotation = 90;
    when(mockDisplay.getRotation()).thenReturn(expectedRotation);

    final int defaultRotation = deviceOrientationManager.getDefaultRotation();

    assertEquals(defaultRotation, expectedRotation);
  }

  @Test
  public void getDisplayTest() {
    Display display = deviceOrientationManager.getDisplay();

    assertEquals(mockDisplay, display);
  }

  @Test
  public void getDisplay_shouldReturnNull_whenActivityDestroyed() {
    final DeviceOrientationManager deviceOrientationManager = createManager(true, false);
    assertNull(deviceOrientationManager.getDisplay());
    assertEquals(deviceOrientationManager.getDefaultRotation(), Surface.ROTATION_0);
  }

  @SuppressWarnings("deprecation")
  private DeviceOrientationManager createManager(boolean destroyed, boolean finishing) {
    FakeActivity activity = new FakeActivity();
    activity.setDestroyed(destroyed);
    activity.setFinishing(finishing);

    WindowManager windowManager = mock(WindowManager.class);
    when(windowManager.getDefaultDisplay()).thenReturn(mock(Display.class));
    activity.setWindowManager(windowManager);

    TestProxyApiRegistrar proxy =
        new TestProxyApiRegistrar() {
          @NonNull
          @Override
          public Context getContext() {
            return activity;
          }

          @Nullable
          @Override
          public Activity getActivity() {
            return activity;
          }
        };
    when(mockApi.getPigeonRegistrar()).thenReturn(proxy);

    return new DeviceOrientationManager(mockApi);
  }
}
