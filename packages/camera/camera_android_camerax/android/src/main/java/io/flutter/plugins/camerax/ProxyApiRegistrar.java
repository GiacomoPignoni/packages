// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.app.Activity;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Display;
import android.view.WindowManager;
import androidx.annotation.ChecksSdkIntAtLeast;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.lifecycle.LifecycleOwner;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.view.TextureRegistry;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class ProxyApiRegistrar extends CameraXLibraryPigeonProxyApiRegistrar {
  @NonNull
  private final CameraPermissionsManager cameraPermissionsManager = new CameraPermissionsManager();

  @NonNull private final TextureRegistry textureRegistry;

  @NonNull private Context context;

  @Nullable private CameraPermissionsManager.PermissionsRegistry permissionsRegistry;

  /**
   * Handles errors received from calling a method from host->Dart.
   *
   * <p>If a call to Dart fails, users should call `onFailure`.
   */
  public abstract static class FlutterMethodRunnable implements Runnable {
    void onFailure(@NonNull String methodName, @NonNull Throwable throwable) {
      final String errorMessage;
      if (throwable instanceof CameraXError) {
        final CameraXError cameraXError = (CameraXError) throwable;
        errorMessage =
            cameraXError.getCode()
                + ": Error returned from calling "
                + methodName
                + ": "
                + cameraXError.getMessage()
                + " Details: "
                + cameraXError.getDetails();
      } else {
        errorMessage =
            throwable.getClass().getSimpleName()
                + ": Error returned from calling "
                + methodName
                + ": "
                + throwable.getMessage();
      }
      Log.e("ProxyApiRegistrar", errorMessage);
    }
  }

  // PreviewProxyApi maintains a state to track SurfaceProducers provided by the Flutter engine.
  @Nullable private PreviewProxyApi previewProxyApi;

  public ProxyApiRegistrar(
      @NonNull BinaryMessenger binaryMessenger,
      @NonNull Context context,
      @NonNull TextureRegistry textureRegistry) {
    super(binaryMessenger);
    this.context = context;
    this.textureRegistry = textureRegistry;
  }

  // Interface for an injectable SDK version checker.
  @ChecksSdkIntAtLeast(parameter = 0)
  boolean sdkIsAtLeast(int version) {
    return Build.VERSION.SDK_INT >= version;
  }

  // Added to be overridden for tests. The test implementation calls `callback` immediately, instead
  // of waiting for the main thread to run it.
  void runOnMainThread(@NonNull FlutterMethodRunnable runnable) {
    if (context instanceof Activity) {
      ((Activity) context).runOnUiThread(runnable);
    } else {
      new Handler(Looper.getMainLooper()).post(runnable);
    }
  }

  @NonNull
  public Context getContext() {
    return context;
  }

  @Nullable
  public Activity getActivity() {
    if (context instanceof Activity) {
      return (Activity) context;
    }

    return null;
  }

  public void setContext(@NonNull Context context) {
    this.context = context;
  }

  @Nullable
  public LifecycleOwner getLifecycleOwner() {
    if (context instanceof LifecycleOwner) {
      return (LifecycleOwner) context;
    } else if (context instanceof Activity) {
      return new ProxyLifecycleProvider((Activity) context);
    }

    return null;
  }

  @NonNull
  public CameraPermissionsManager getCameraPermissionsManager() {
    return cameraPermissionsManager;
  }

  void setPermissionsRegistry(
      @Nullable CameraPermissionsManager.PermissionsRegistry permissionsRegistry) {
    this.permissionsRegistry = permissionsRegistry;
  }

  @Nullable
  CameraPermissionsManager.PermissionsRegistry getPermissionsRegistry() {
    return permissionsRegistry;
  }

  @NonNull
  TextureRegistry getTextureRegistry() {
    return textureRegistry;
  }

  /**
   * The executor {@link ImageCaptureProxyApi} hands to {@code ImageCapture.takePicture}.
   *
   * <p>One shared thread rather than one per shutter press. A {@code
   * Executors.newSingleThreadExecutor()} per capture is only reclaimed when its finalizer runs, so
   * a burst of photos leaves a pile of live threads behind, each pinning the decoded bitmap its
   * callback was working on. A single thread also serialises the captures, which is what we want:
   * they all funnel into the one render thread anyway.
   *
   * <p>Lives on the registrar because the ProxyApi objects do not: {@code getPigeonApiImageCapture}
   * builds a fresh one per call, so a field there would be shared with nothing.
   *
   * <p>Runs at display priority. Everything the effects path does to a capture — the JPEG decode,
   * the re-encode — is CPU-bound work on a 12MP frame, and at the default priority the scheduler is
   * free to park it on a little core while the preview keeps the big ones busy. That showed up as
   * the same capture taking 143ms to encode on one run and 283ms on the next.
   */
  @NonNull
  private final ExecutorService captureExecutor =
      Executors.newSingleThreadExecutor(
          runnable -> {
            final Thread thread =
                new Thread(
                    () -> {
                      // Set from the thread itself: `setThreadPriority` with no tid argument
                      // applies to the caller.
                      android.os.Process.setThreadPriority(
                          android.os.Process.THREAD_PRIORITY_DISPLAY);
                      runnable.run();
                    },
                    "CameraXImageCapture");
            // The process must not be held open by a capture that never completes.
            thread.setDaemon(true);
            return thread;
          });

  @NonNull
  ExecutorService getCaptureExecutor() {
    return captureExecutor;
  }

  /**
   * Stops the threads the plugin's executors hold.
   *
   * <p>Called from {@link CameraAndroidCameraxPlugin#onDetachedFromEngine} rather than from an
   * override of the generated {@code tearDown}, which is final.
   *
   * <p>{@code shutdown}, not {@code shutdownNow}: a capture already in flight has a Dart callback
   * waiting on it and files half written to the cache directory, so it is left to finish.
   */
  void releaseExecutors() {
    captureExecutor.shutdown();
    if (previewProxyApi != null) {
      previewProxyApi.releaseSurfaceReleaseExecutor();
    }
  }

  long getDefaultClearFinalizedWeakReferencesInterval() {
    return 3000;
  }

  @SuppressWarnings(
      "deprecation") // getSystemService was the way of getting the default display prior to API 30
  @Nullable
  Display getDisplay() {
    Activity activity = getActivity();
    if (activity == null || activity.isDestroyed()) {
      return null;
    }

    if (sdkIsAtLeast(Build.VERSION_CODES.R)) {
      return activity.getDisplay();
    } else {
      return ((WindowManager) activity.getSystemService(Context.WINDOW_SERVICE))
          .getDefaultDisplay();
    }
  }

  @NonNull
  @Override
  public PigeonApiCameraSize getPigeonApiCameraSize() {
    return new CameraSizeProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiResolutionInfo getPigeonApiResolutionInfo() {
    return new ResolutionInfoProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCameraIntegerRange getPigeonApiCameraIntegerRange() {
    return new CameraIntegerRangeProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiMeteringPoint getPigeonApiMeteringPoint() {
    return new MeteringPointProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiObserver getPigeonApiObserver() {
    return new ObserverProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCameraInfo getPigeonApiCameraInfo() {
    return new CameraInfoProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCameraSelector getPigeonApiCameraSelector() {
    return new CameraSelectorProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiProcessCameraProvider getPigeonApiProcessCameraProvider() {
    return new ProcessCameraProviderProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCamera getPigeonApiCamera() {
    return new CameraProxyApi(this);
  }

  @NonNull
  @Override
  public SystemServicesManagerProxyApi getPigeonApiSystemServicesManager() {
    return new SystemServicesManagerProxyApi(this);
  }

  @NonNull
  @Override
  public DeviceOrientationManagerProxyApi getPigeonApiDeviceOrientationManager() {
    return new DeviceOrientationManagerProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiPreview getPigeonApiPreview() {
    if (previewProxyApi == null) {
      previewProxyApi = new PreviewProxyApi(this);
    }
    return previewProxyApi;
  }

  @NonNull
  @Override
  public PigeonApiVideoCapture getPigeonApiVideoCapture() {
    return new VideoCaptureProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiRecorder getPigeonApiRecorder() {
    return new RecorderProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiVideoRecordEventListener getPigeonApiVideoRecordEventListener() {
    return new VideoRecordEventListenerProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiPendingRecording getPigeonApiPendingRecording() {
    return new PendingRecordingProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiRecording getPigeonApiRecording() {
    return new RecordingProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiImageCapture getPigeonApiImageCapture() {
    return new ImageCaptureProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiResolutionStrategy getPigeonApiResolutionStrategy() {
    return new ResolutionStrategyProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiResolutionSelector getPigeonApiResolutionSelector() {
    return new ResolutionSelectorProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiAspectRatioStrategy getPigeonApiAspectRatioStrategy() {
    return new AspectRatioStrategyProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCameraState getPigeonApiCameraState() {
    return new CameraStateProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiExposureState getPigeonApiExposureState() {
    return new ExposureStateProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiZoomState getPigeonApiZoomState() {
    return new ZoomStateProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiImageAnalysis getPigeonApiImageAnalysis() {
    return new ImageAnalysisProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiAnalyzer getPigeonApiAnalyzer() {
    return new AnalyzerProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCameraStateStateError getPigeonApiCameraStateStateError() {
    return new CameraStateStateErrorProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiLiveData getPigeonApiLiveData() {
    return new LiveDataProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiImageProxy getPigeonApiImageProxy() {
    return new ImageProxyProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiPlaneProxy getPigeonApiPlaneProxy() {
    return new PlaneProxyProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiQualitySelector getPigeonApiQualitySelector() {
    return new QualitySelectorProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiFallbackStrategy getPigeonApiFallbackStrategy() {
    return new FallbackStrategyProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCameraControl getPigeonApiCameraControl() {
    return new CameraControlProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiFocusMeteringActionBuilder getPigeonApiFocusMeteringActionBuilder() {
    return new FocusMeteringActionBuilderProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiFocusMeteringAction getPigeonApiFocusMeteringAction() {
    return new FocusMeteringActionProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiFocusMeteringResult getPigeonApiFocusMeteringResult() {
    return new FocusMeteringResultProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCaptureRequest getPigeonApiCaptureRequest() {
    return new CaptureRequestProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCaptureRequestOptions getPigeonApiCaptureRequestOptions() {
    return new CaptureRequestOptionsProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCamera2CameraControl getPigeonApiCamera2CameraControl() {
    return new Camera2CameraControlProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiResolutionFilter getPigeonApiResolutionFilter() {
    return new ResolutionFilterProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCameraCharacteristics getPigeonApiCameraCharacteristics() {
    return new CameraCharacteristicsProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCamera2CameraInfo getPigeonApiCamera2CameraInfo() {
    return new Camera2CameraInfoProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiMeteringPointFactory getPigeonApiMeteringPointFactory() {
    return new MeteringPointFactoryProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiDisplayOrientedMeteringPointFactory
      getPigeonApiDisplayOrientedMeteringPointFactory() {
    return new DisplayOrientedMeteringPointFactoryProxyApi(this);
  }

  @NonNull
  @Override
  public CameraPermissionsErrorProxyApi getPigeonApiCameraPermissionsError() {
    return new CameraPermissionsErrorProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiImageProxyUtils getPigeonApiImageProxyUtils() {
    return new ImageProxyUtilsProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiPlatformEffectsValues getPigeonApiPlatformEffectsValues() {
    return new EffectsValuesProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCapturedPicturePaths getPigeonApiCapturedPicturePaths() {
    return new CapturedPicturePathsProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiCameraEffectsManager getPigeonApiCameraEffectsManager() {
    return new CameraEffectsManagerProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiViewPort getPigeonApiViewPort() {
    return new ViewPortProxyApi(this);
  }

  @NonNull
  @Override
  public PigeonApiWhiteBalanceManager getPigeonApiWhiteBalanceManager() {
    return new WhiteBalanceManagerProxyApi(this);
  }
}
