// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.graphics.ImageFormat;
import android.hardware.camera2.CaptureResult;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.camera.camera2.interop.Camera2Interop;
import androidx.camera.camera2.interop.ExperimentalCamera2Interop;
import androidx.camera.core.ImageCapture;
import androidx.camera.core.ImageCaptureException;
import androidx.camera.core.ImageProxy;
import androidx.camera.core.resolutionselector.ResolutionSelector;
import java.io.File;
import java.io.IOException;
import kotlin.Result;
import kotlin.Unit;
import kotlin.jvm.functions.Function1;

/**
 * ProxyApi implementation for {@link ImageCapture}. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
class ImageCaptureProxyApi extends PigeonApiImageCapture {
  static final String TEMPORARY_FILE_NAME = "CAP";
  static final String JPG_FILE_TYPE = ".jpg";

  ImageCaptureProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  @NonNull
  @Override
  @OptIn(markerClass = ExperimentalCamera2Interop.class)
  public ImageCapture pigeon_defaultConstructor(
      @Nullable ResolutionSelector resolutionSelector,
      @Nullable Long targetRotation,
      @Nullable CameraXFlashMode flashMode,
      @Nullable Long jpegQuality) {
    final ImageCapture.Builder builder = new ImageCapture.Builder();
    if (targetRotation != null) {
      builder.setTargetRotation(targetRotation.intValue());
    }
    if (flashMode != null) {
      // This sets the requested flash mode, but may fail silently.
      switch (flashMode) {
        case AUTO:
          builder.setFlashMode(ImageCapture.FLASH_MODE_AUTO);
          break;
        case OFF:
          builder.setFlashMode(ImageCapture.FLASH_MODE_OFF);
          break;
        case ON:
          builder.setFlashMode(ImageCapture.FLASH_MODE_ON);
          break;
      }
    }
    if (resolutionSelector != null) {
      builder.setResolutionSelector(resolutionSelector);
    }
    if (jpegQuality != null) {
      builder.setJpegQuality(jpegQuality.intValue());
    }
    if (UncompressedCaptureSupport.isSupported(getPigeonRegistrar().getContext())) {
      // Skips the ISP's JPEG encode and the decode that used to undo it: the effects pipeline
      // wants pixels, and a JPEG in between is a lossy round trip that costs ~140ms of CPU on a
      // 12MP frame. `ImagePipeline` leaves a non-JPEG buffer format alone rather than converting
      // it, so the frame arrives as it was captured.
      //
      // Asked for per device rather than unconditionally, and withdrawn if this device turns out
      // not to cope — see UncompressedCaptureSupport, which also explains why "not coping" is not
      // always an error. Either way the frame is delivered to `takePictureWithEffects`, which
      // handles both formats: `StillCaptureProcessor` decodes if a JPEG arrives.
      builder.setBufferFormat(ImageFormat.YUV_420_888);
      // An uncompressed frame carries no Exif, so the exposure the photo was taken with has to be
      // read from the camera's own result for that frame. See CaptureResultCache.
      final CaptureResultCache resultCache = new CaptureResultCache();
      new Camera2Interop.Extender<>(builder)
          .setSessionCaptureCallback(resultCache.getCaptureCallback());
      final ImageCapture imageCapture = builder.build();
      CaptureResultCache.register(imageCapture, resultCache);
      UncompressedCaptureSupport.markUncompressed(imageCapture);
      return imageCapture;
    }
    return builder.build();
  }

  @Override
  public void setFlashMode(
      @NonNull ImageCapture pigeonInstance, @NonNull CameraXFlashMode flashMode) {
    int nativeFlashMode = -1;
    switch (flashMode) {
      case AUTO:
        nativeFlashMode = ImageCapture.FLASH_MODE_AUTO;
        break;
      case OFF:
        nativeFlashMode = ImageCapture.FLASH_MODE_OFF;
        break;
      case ON:
        nativeFlashMode = ImageCapture.FLASH_MODE_ON;
    }
    pigeonInstance.setFlashMode(nativeFlashMode);
  }

  @Override
  public void takePicture(
      @NonNull ImageCapture pigeonInstance,
      @NonNull SystemServicesManager systemServicesManager,
      @NonNull Function1<? super Result<String>, Unit> callback) {
    final File outputDir = getPigeonRegistrar().getContext().getCacheDir();
    File temporaryCaptureFile;
    try {
      temporaryCaptureFile = File.createTempFile(TEMPORARY_FILE_NAME, JPG_FILE_TYPE, outputDir);
    } catch (IOException | SecurityException e) {
      ResultCompat.failure(e, callback);
      return;
    }

    final ImageCapture.OutputFileOptions outputFileOptions =
        createImageCaptureOutputFileOptions(temporaryCaptureFile);
    final ImageCapture.OnImageSavedCallback onImageSavedCallback =
        createOnImageSavedCallback(temporaryCaptureFile, systemServicesManager, callback);

    pigeonInstance.takePicture(
        outputFileOptions, getPigeonRegistrar().getCaptureExecutor(), onImageSavedCallback);
  }

  @Override
  public void takePictureWithEffects(
      @NonNull ImageCapture pigeonInstance,
      @NonNull SystemServicesManager systemServicesManager,
      @NonNull CameraEffectsManager effectsManager,
      boolean includeOriginal,
      @NonNull Function1<? super Result<CapturedPicturePaths>, Unit> callback) {
    // Captured in memory rather than straight to a file: `takePictureWithOriginal` has to produce
    // both an un-effected original and a processed photo from the *same* shutter event, which a
    // file-backed capture cannot give.
    pigeonInstance.takePicture(
        getPigeonRegistrar().getCaptureExecutor(),
        new ImageCapture.OnImageCapturedCallback() {
          @Override
          public void onCaptureSuccess(@NonNull ImageProxy image) {
            // An uncompressed capture carries no Exif of its own, so the exposure it was taken
            // with is looked up from the camera's result for that frame.
            final CaptureResultCache resultCache = CaptureResultCache.of(pigeonInstance);
            final CaptureResult captureResult =
                resultCache == null
                    ? null
                    : resultCache.resultFor(image.getImageInfo().getTimestamp());
            try {
              final CapturedPicturePaths paths =
                  StillCaptureProcessor.process(
                      image,
                      effectsManager,
                      includeOriginal,
                      getPigeonRegistrar().getContext().getCacheDir(),
                      captureResult);
              replyOnMainThread(() -> ResultCompat.success(paths, callback));
            } catch (Throwable t) {
              // Catches Throwable, not just Exception: decoding/rendering a full-resolution
              // capture can throw OutOfMemoryError, and the Dart Future must still be completed
              // rather than left hanging forever.
              systemServicesManager.onCameraError(
                  "Failed to process the captured image: " + t.getMessage());
              replyOnMainThread(() -> ResultCompat.failure(t, callback));
            } finally {
              image.close();
            }
          }

          @Override
          public void onError(@NonNull ImageCaptureException exception) {
            systemServicesManager.onCameraError(
                getImageCaptureExceptionDescription(exception.getImageCaptureError()));
            replyOnMainThread(() -> ResultCompat.failure(exception, callback));
          }
        });
  }

  /**
   * Answers the pending Dart call from the main thread.
   *
   * <p>Unlike {@link #takePicture}, which hands back a plain path string, this method's result is a
   * {@link CapturedPicturePaths} proxy: returning one registers it with the instance manager, which
   * sends a message over the binary messenger, and Flutter rejects those from any thread but the
   * main one. The capture callbacks above run on the executor {@code takePicture} was handed, so
   * only the reply hops — the decode, render and JPEG encode stay off the main thread.
   */
  private void replyOnMainThread(@NonNull Runnable reply) {
    getPigeonRegistrar()
        .runOnMainThread(
            new ProxyApiRegistrar.FlutterMethodRunnable() {
              @Override
              public void run() {
                reply.run();
              }
            });
  }

  @Override
  public void setTargetRotation(ImageCapture pigeonInstance, long rotation) {
    pigeonInstance.setTargetRotation((int) rotation);
  }

  @Nullable
  @Override
  public ResolutionSelector resolutionSelector(@NonNull ImageCapture pigeonInstance) {
    return pigeonInstance.getResolutionSelector();
  }

  ImageCapture.OutputFileOptions createImageCaptureOutputFileOptions(@NonNull File file) {
    return new ImageCapture.OutputFileOptions.Builder(file).build();
  }

  @NonNull
  ImageCapture.OnImageSavedCallback createOnImageSavedCallback(
      @NonNull File file,
      @NonNull SystemServicesManager systemServicesManager,
      @NonNull Function1<? super Result<String>, Unit> callback) {
    return new ImageCapture.OnImageSavedCallback() {
      @Override
      public void onImageSaved(@NonNull ImageCapture.OutputFileResults outputFileResults) {
        ResultCompat.success(file.getAbsolutePath(), callback);
      }

      @Override
      public void onError(@NonNull ImageCaptureException exception) {
        systemServicesManager.onCameraError(
            getImageCaptureExceptionDescription(exception.getImageCaptureError()));
        ResultCompat.failure(exception, callback);
      }
    };
  }

  /**
   * Returns an error description for each {@link ImageCaptureException} error code.
   *
   * <p>See
   * https://developer.android.com/reference/androidx/camera/core/ImageCaptureException#getImageCaptureError()
   * for details on each error type.
   */
  String getImageCaptureExceptionDescription(int imageCaptureErrorCode) {
    switch (imageCaptureErrorCode) {
      case ImageCapture.ERROR_FILE_IO:
        return "An error occurred while attempting to save the captured image to a file.";
      case ImageCapture.ERROR_CAPTURE_FAILED:
        return "The camera framework failed to fulfill the image capture request.";
      case ImageCapture.ERROR_CAMERA_CLOSED:
        return "Image capture failed due to the camera being closed.";
      case ImageCapture.ERROR_INVALID_CAMERA:
        return "The ImageCapture use case was bound to an invalid camera by the Flutter camera"
            + " plugin. If you see this error, please file an issue if you cannot find one"
            + " that already exists: https://github.com/flutter/flutter/issues/.";
      default:
        return "An unknown error has occurred while attempting to take a picture. Check the logs"
            + " for more details.";
    }
  }
}
