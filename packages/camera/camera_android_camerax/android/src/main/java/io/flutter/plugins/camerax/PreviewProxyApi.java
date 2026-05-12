// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.hardware.camera2.CaptureRequest;
import android.util.Range;
import android.view.Surface;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.camera.camera2.interop.Camera2Interop;
import androidx.camera.camera2.interop.ExperimentalCamera2Interop;
import androidx.camera.core.Preview;
import androidx.camera.core.ResolutionInfo;
import androidx.camera.core.SurfaceRequest;
import androidx.camera.core.resolutionselector.ResolutionSelector;
import io.flutter.view.TextureRegistry;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * ProxyApi implementation for {@link Preview}. This class may handle instantiating native object
 * instances that are attached to a Dart instance or handle method calls on the associated native
 * class or an instance of that class.
 */
class PreviewProxyApi extends PigeonApiPreview {
  // Stores the SurfaceProducer when it is used as a SurfaceProvider for a Preview.
  private final Map<Preview, TextureRegistry.SurfaceProducer> surfaceProducers = new HashMap<>();

  /**
   * Runs the completion callback CameraX invokes when it is finished with a provided surface.
   *
   * <p>One for the whole proxy api rather than one per {@link SurfaceRequest}. CameraX asks for a
   * new surface every time it rebuilds the preview pipeline, which a lens switch, an aspect ratio
   * change and a recording starting all do, so a thread created per request is a thread leaked per
   * rebind. The callbacks it runs are short and independent, so they are content to share one.
   */
  private final ExecutorService surfaceReleaseExecutor =
      Executors.newSingleThreadExecutor(
          runnable -> {
            final Thread thread = new Thread(runnable, "CameraXPreviewSurfaceRelease");
            thread.setDaemon(true);
            return thread;
          });

  PreviewProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  // Range<?> is defined as Range<Integer> in pigeon.
  @SuppressWarnings("unchecked")
  @OptIn(markerClass = ExperimentalCamera2Interop.class)
  @NonNull
  @Override
  public Preview pigeon_defaultConstructor(
      @Nullable ResolutionSelector resolutionSelector,
      @Nullable Long targetRotation,
      @Nullable Range<?> targetFpsRange,
      @Nullable WhiteBalanceManager whiteBalanceManager) {
    final Preview.Builder builder = new Preview.Builder();
    if (targetRotation != null) {
      builder.setTargetRotation(targetRotation.intValue());
    }
    if (resolutionSelector != null) {
      builder.setResolutionSelector(resolutionSelector);
    }

    if (targetFpsRange != null || whiteBalanceManager != null) {
      Camera2Interop.Extender<Preview> extender = new Camera2Interop.Extender<>(builder);
      if (targetFpsRange != null) {
        extender.setCaptureRequestOption(
            CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, (Range<Integer>) targetFpsRange);
      }
      if (whiteBalanceManager != null) {
        // The capture results are the only place the auto white balance gains are reported, and
        // this is the only hook Camera2 interop offers for reading them.
        extender.setSessionCaptureCallback(whiteBalanceManager.getCaptureCallback());
      }
    }

    return builder.build();
  }

  @Override
  public long setSurfaceProvider(
      @NonNull Preview pigeonInstance, @NonNull SystemServicesManager systemServicesManager) {
    final TextureRegistry.SurfaceProducer surfaceProducer =
        getPigeonRegistrar().getTextureRegistry().createSurfaceProducer();
    final Preview.SurfaceProvider surfaceProvider =
        createSurfaceProvider(surfaceProducer, systemServicesManager);

    pigeonInstance.setSurfaceProvider(surfaceProvider);
    surfaceProducers.put(pigeonInstance, surfaceProducer);

    return surfaceProducer.id();
  }

  /**
   * Releases the Flutter surface producer backing this preview, if it has one.
   *
   * <p>Deliberately a no-op when there is nothing to release, rather than the {@code
   * IllegalStateException} this used to throw. {@code dispose} is the last thing to run on a camera
   * that may already have failed halfway through being created, or that is being disposed a second
   * time, and in both cases the producer is legitimately absent. Throwing from the final step of a
   * teardown turns a benign double-release into an exception that aborts the rest of {@code
   * CameraController.dispose}, which is how one failed camera switch cascades into a broken plugin.
   */
  @Override
  public void releaseSurfaceProvider(@NonNull Preview pigeonInstance) {
    final TextureRegistry.SurfaceProducer surfaceProducer = surfaceProducers.remove(pigeonInstance);
    if (surfaceProducer != null) {
      surfaceProducer.release();
    }
  }

  /**
   * Stops {@link #surfaceReleaseExecutor}'s thread.
   *
   * <p>{@code shutdown}, not {@code shutdownNow}: a queued callback still has a {@code Surface} to
   * release, and dropping it would leak the buffers behind it.
   */
  void releaseSurfaceReleaseExecutor() {
    surfaceReleaseExecutor.shutdown();
  }

  @Override
  public boolean surfaceProducerHandlesCropAndRotation(@NonNull Preview pigeonInstance) {
    final TextureRegistry.SurfaceProducer surfaceProducer = surfaceProducers.get(pigeonInstance);
    if (surfaceProducer != null) {
      return surfaceProducer.handlesCropAndRotation();
    }
    throw new IllegalStateException(
        "surfaceProducerHandlesCropAndRotation() cannot be called if the flutterSurfaceProducer for"
            + " the camera preview has not yet been initialized.");
  }

  @Nullable
  @Override
  public ResolutionInfo getResolutionInfo(Preview pigeonInstance) {
    return pigeonInstance.getResolutionInfo();
  }

  @Override
  public void setTargetRotation(Preview pigeonInstance, long rotation) {
    pigeonInstance.setTargetRotation((int) rotation);
  }

  @NonNull
  Preview.SurfaceProvider createSurfaceProvider(
      @NonNull TextureRegistry.SurfaceProducer surfaceProducer,
      @NonNull SystemServicesManager systemServicesManager) {
    return request -> {
      // Set callback for surfaceProducer to invalidate Surfaces that it produces when they
      // get destroyed.
      surfaceProducer.setCallback(
          new TextureRegistry.SurfaceProducer.Callback() {
            @Override
            public void onSurfaceAvailable() {
              // Do nothing. The Preview.SurfaceProvider will handle this whenever a new
              // Surface is needed.
            }

            @Override
            public void onSurfaceCleanup() {
              // Invalidate the SurfaceRequest so that CameraX knows to to make a new request
              // for a surface.
              request.invalidate();
            }
          });

      // Provide surface.
      surfaceProducer.setSize(
          request.getResolution().getWidth(), request.getResolution().getHeight());
      Surface flutterSurface = surfaceProducer.getForcedNewSurface();
      request.provideSurface(
          flutterSurface,
          surfaceReleaseExecutor,
          (result) -> {
            // See
            // https://developer.android.com/reference/androidx/camera/core/SurfaceRequest.Result
            // for documentation.
            // Always attempt a release.
            flutterSurface.release();
            int resultCode = result.getResultCode();
            switch (resultCode) {
              case SurfaceRequest.Result.RESULT_REQUEST_CANCELLED:
              case SurfaceRequest.Result.RESULT_WILL_NOT_PROVIDE_SURFACE:
              case SurfaceRequest.Result.RESULT_SURFACE_ALREADY_PROVIDED:
              case SurfaceRequest.Result.RESULT_SURFACE_USED_SUCCESSFULLY:
                // Only need to release, do nothing.
                break;
              case SurfaceRequest.Result.RESULT_INVALID_SURFACE: // Intentional fall through.
              default:
                systemServicesManager.onCameraError(getProvideSurfaceErrorDescription(resultCode));
            }
          });
    };
  }

  /**
   * Returns an error description for each {@link SurfaceRequest.Result} that represents an error
   * with providing a surface.
   */
  String getProvideSurfaceErrorDescription(int resultCode) {
    if (resultCode == SurfaceRequest.Result.RESULT_INVALID_SURFACE) {
      return resultCode + ": Provided surface could not be used by the camera.";
    }
    return resultCode + ": Attempt to provide a surface resulted with unrecognizable code.";
  }

  @Nullable
  @Override
  public ResolutionSelector resolutionSelector(@NonNull Preview pigeonInstance) {
    return pigeonInstance.getResolutionSelector();
  }
}
