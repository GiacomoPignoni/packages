// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.util.Log;
import android.util.Range;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraEffect;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.SessionConfig;
import androidx.camera.core.UseCase;
import androidx.camera.core.UseCaseGroup;
import androidx.camera.core.ViewPort;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;
import com.google.common.util.concurrent.ListenableFuture;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutionException;
import kotlin.Result;
import kotlin.Unit;
import kotlin.jvm.functions.Function1;

/**
 * ProxyApi implementation for {@link ProcessCameraProvider}. This class may handle instantiating
 * native object instances that are attached to a Dart instance or handle method calls on the
 * associated native class or an instance of that class.
 */
class ProcessCameraProviderProxyApi extends PigeonApiProcessCameraProvider {
  private static final String TAG = "ProcessCameraProvider";

  ProcessCameraProviderProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  @Override
  public void getInstance(
      @NonNull Function1<? super Result<ProcessCameraProvider>, Unit> callback) {
    final ListenableFuture<ProcessCameraProvider> processCameraProviderFuture =
        ProcessCameraProvider.getInstance(getPigeonRegistrar().getContext());

    processCameraProviderFuture.addListener(
        () -> {
          try {
            // Camera provider is now guaranteed to be available.
            ResultCompat.success(processCameraProviderFuture.get(), callback);
          } catch (InterruptedException | ExecutionException e) {
            ResultCompat.failure(e, callback);
          }
        },
        ContextCompat.getMainExecutor(getPigeonRegistrar().getContext()));
  }

  @NonNull
  @Override
  public List<CameraInfo> getAvailableCameraInfos(ProcessCameraProvider pigeonInstance) {
    return pigeonInstance.getAvailableCameraInfos();
  }

  @NonNull
  @Override
  public Camera bindToLifecycle(
      @NonNull ProcessCameraProvider pigeonInstance,
      @NonNull CameraSelector cameraSelector,
      @NonNull List<? extends UseCase> useCases,
      @NonNull List<? extends CameraEffect> effects,
      @Nullable ViewPort viewPort) {
    final LifecycleOwner lifecycleOwner = getPigeonRegistrar().getLifecycleOwner();
    if (lifecycleOwner == null) {
      throw new IllegalStateException(
          "LifecycleOwner must be set to get ProcessCameraProvider instance.");
    }

    final Camera camera;
    try {
      if (effects.isEmpty() && viewPort == null) {
        camera =
            pigeonInstance.bindToLifecycle(
                lifecycleOwner, cameraSelector, useCases.toArray(new UseCase[0]));
      } else {
        // Effects and the view port can only be attached through a UseCaseGroup. CameraX stores
        // the effects on the camera adapter rather than on the group, so they apply to every bound
        // use case and the caller has to repeat them on each incremental bind - see the Dart-side
        // doc on `bindToLifecycle`. The view port is per-group and applies to the use cases in
        // this call.
        final UseCaseGroup.Builder builder = new UseCaseGroup.Builder();
        for (UseCase useCase : useCases) {
          builder.addUseCase(useCase);
        }
        for (CameraEffect effect : effects) {
          builder.addEffect(effect);
        }
        if (viewPort != null) {
          builder.setViewPort(viewPort);
        }
        camera = pigeonInstance.bindToLifecycle(lifecycleOwner, cameraSelector, builder.build());
      }
    } catch (RuntimeException e) {
      // A configuration this device will not accept is one of the two ways an uncompressed still
      // stream can fail, and the only one that says so out loud. Reported rather than handled: the
      // caller owns the use cases, so this bind still fails - but the next camera to open will
      // build itself a compressed `ImageCapture` and succeed. Rethrown unchanged.
      UncompressedCaptureSupport.onBindFailed(useCases, e);
      throw e;
    }

    // The quieter failure: the configuration was accepted, but at a smaller still resolution than
    // a JPEG stream would have been given. Checked here because this is the first point at which
    // what CameraX actually negotiated is knowable, and against the bound camera's own info rather
    // than the selector's, which can resolve to more than one.
    UncompressedCaptureSupport.onBound(useCases, camera.getCameraInfo());
    return camera;
  }

  @NonNull
  @Override
  public List<Range<?>> getSupportedFrameRateRanges(
      @NonNull ProcessCameraProvider pigeonInstance,
      @NonNull CameraSelector cameraSelector,
      @NonNull List<? extends UseCase> useCases,
      @NonNull List<? extends CameraEffect> effects,
      @Nullable ViewPort viewPort) {
    final CameraInfo cameraInfo = selectCameraInfo(pigeonInstance, cameraSelector);
    if (cameraInfo == null || useCases.isEmpty()) {
      return new ArrayList<>();
    }

    // Asked with the group that is about to be bound, because the stream configuration is what
    // decides the answer: the same camera that reaches 60fps with a 720p preview commonly tops out
    // at 30 once the streams are 1080p, and the effect contributes a surface of its own.
    final SessionConfig.Builder builder = new SessionConfig.Builder(new ArrayList<>(useCases));
    for (CameraEffect effect : effects) {
      builder.addEffect(effect);
    }
    if (viewPort != null) {
      builder.setViewPort(viewPort);
    }

    Set<Range<Integer>> ranges;
    try {
      ranges = cameraInfo.getSupportedFrameRateRanges(builder.build());
    } catch (RuntimeException e) {
      // The configuration-aware overload is a default interface method that not every backend
      // implements, and it rejects configurations it cannot resolve. Broadly caught because this
      // is a capability query on the way to opening a camera: falling back to the device-wide
      // answer is always safe, and failing the camera over it is not.
      Log.w(TAG, "Could not read the frame rate ranges for this configuration: " + e.getMessage());
      ranges = null;
    }
    if (ranges == null || ranges.isEmpty()) {
      // Device-wide rather than configuration-aware: coarser, but it still rules out ranges the
      // camera cannot produce at all, which is better than applying an unchecked one.
      ranges = cameraInfo.getSupportedFrameRateRanges();
    }
    return new ArrayList<Range<?>>(ranges);
  }

  /** The {@link CameraInfo} {@code cameraSelector} resolves to, or null if it matches nothing. */
  @Nullable
  private CameraInfo selectCameraInfo(
      @NonNull ProcessCameraProvider provider, @NonNull CameraSelector cameraSelector) {
    try {
      final List<CameraInfo> filtered =
          cameraSelector.filter(new ArrayList<>(provider.getAvailableCameraInfos()));
      return filtered.isEmpty() ? null : filtered.get(0);
    } catch (IllegalArgumentException e) {
      // `filter` throws when the selector's own filters reject every camera.
      return null;
    }
  }

  @Override
  public boolean isBound(ProcessCameraProvider pigeonInstance, @NonNull UseCase useCase) {
    return pigeonInstance.isBound(useCase);
  }

  @Override
  public void unbind(
      ProcessCameraProvider pigeonInstance, @NonNull List<? extends UseCase> useCases) {
    pigeonInstance.unbind(useCases.toArray(new UseCase[0]));
  }

  @Override
  public void unbindAll(ProcessCameraProvider pigeonInstance) {
    pigeonInstance.unbindAll();
  }
}
