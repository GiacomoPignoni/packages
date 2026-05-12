// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:math' show Point;

import 'package:async/async.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart' show Uint8List, debugPrint;
import 'package:flutter/services.dart' show DeviceOrientation, PlatformException;
import 'package:flutter/widgets.dart' show Texture, Widget, visibleForTesting;
import 'package:stream_transform/stream_transform.dart';
import 'camerax_library.dart';
import 'surface_texture_rotated_preview.dart';

/// The Android implementation of [CameraPlatform] that uses the CameraX library.
class AndroidCameraCameraX extends CameraPlatform {
  /// Constructs an [AndroidCameraCameraX].
  AndroidCameraCameraX();

  /// Registers this class as the default instance of [CameraPlatform].
  static void registerWith() {
    CameraPlatform.instance = AndroidCameraCameraX();
  }

  /// The [ProcessCameraProvider] instance used to access camera functionality.
  @visibleForTesting
  ProcessCameraProvider? processCameraProvider;

  /// The [Camera] instance returned by the [processCameraProvider] when a [UseCase] is
  /// bound to the lifecycle of the camera it manages.
  @visibleForTesting
  Camera? camera;

  /// The [CameraInfo] instance that corresponds to the [camera] instance.
  @visibleForTesting
  CameraInfo? cameraInfo;

  /// The [CameraControl] instance that corresponds to the [camera] instance.
  late CameraControl cameraControl;

  /// The [LiveData] of the [CameraState] that represents the state of the
  /// [camera] instance.
  LiveData<CameraState>? liveCameraState;

  /// The [Preview] instance that can be configured to present a live camera preview.
  @visibleForTesting
  Preview? preview;

  /// The [VideoCapture] instance that can be instantiated and configured to
  /// handle video recording
  @visibleForTesting
  VideoCapture? videoCapture;

  /// The [Recorder] instance handling the current creating a new [PendingRecording].
  @visibleForTesting
  Recorder? recorder;

  /// The [PendingRecording] instance used to create an active [Recording].
  @visibleForTesting
  PendingRecording? pendingRecording;

  /// The [Recording] instance representing the current recording.
  @visibleForTesting
  Recording? recording;

  /// The path at which the video file will be saved for the current [Recording].
  @visibleForTesting
  String? videoOutputPath;

  /// Handles access to system resources.
  late final SystemServicesManager systemServicesManager = SystemServicesManager(
    onCameraError: (_, String errorDescription) {
      cameraErrorStreamController.add(errorDescription);
    },
  );

  /// Renders the camera frames through the OpenGL effects pipeline.
  ///
  /// Created by the first [createCameraWithSettings] and then reused by every
  /// camera afterwards; [dispose] detaches its outputs but does not release it.
  /// Null only before the first camera has ever been created, which is what
  /// keeps [setEffectsValues] and friends from standing up a GL context for a
  /// plugin that has not been asked for a camera yet.
  ///
  /// It has to be shared, not per camera. CameraX keeps a `CameraUseCaseAdapter`
  /// per camera id and stores the effects bound to it there; unbinding removes
  /// the use cases but never the effects. A manager released along with its
  /// camera therefore leaves every adapter it was ever bound to holding an
  /// effect whose GL context is gone, and the next bind that picks one up gets
  /// a processor that drops every frame — the preview freezes after a frame or
  /// two, and only starts again when something rebinds with a live effect.
  @visibleForTesting
  CameraEffectsManager? effectsManager;

  /// The [CameraEffect] owned by [effectsManager].
  ///
  /// Cached because it has to be passed to *every* [ProcessCameraProvider.bindToLifecycle]
  /// call: CameraX stores effects on the camera adapter, so a later bind that
  /// omitted them would clear the ones an earlier bind set.
  @visibleForTesting
  CameraEffect? cameraEffect;

  List<CameraEffect> get _cameraEffects =>
      cameraEffect == null ? const <CameraEffect>[] : <CameraEffect>[cameraEffect!];

  /// The center-crop aspect ratio currently in force, or null for no crop.
  double? _aspectRatio;

  /// The [ViewPort] [_aspectRatio] asks for, rebuilt by [_updateViewPort].
  ///
  /// Every bind passes it. A `ViewPort` belongs to the `UseCaseGroup` handed to
  /// [ProcessCameraProvider.bindToLifecycle], so CameraX only reads it there —
  /// which is also why changing the crop of a running camera means re-binding.
  ///
  /// This, rather than a crop inside the shader, is what gives the recorded
  /// video the requested shape: CameraX sizes the preview surface *and* the
  /// encoder's input surface to the view port, so nothing has to be resampled
  /// into a surface of a different shape afterwards.
  ViewPort? _viewPort;

  /// A [setAspectRatio] call deferred until the current recording stops.
  ///
  /// A type of its own because `null` is itself a valid ratio, so a plain
  /// `double?` cannot tell "nothing pending" from "pending: clear the crop".
  /// `DefaultCamera.pendingAspectRatio` defers for the same reason.
  _PendingAspectRatio? _pendingAspectRatio;

  /// Denominator used to turn the aspect ratio into the `Rational` a [ViewPort]
  /// takes.
  static const int _viewPortRatioDenominator = 1000;

  /// Counts [setExposureOffset] calls, so a cancelled one can be attributed.
  ///
  /// CameraX cancels a pending `setExposureCompensationIndex` as soon as a newer
  /// one is submitted, and reports that with the same `OperationCanceledException`
  /// it uses for a camera that closed underneath the request. Comparing the count
  /// a call was issued at against the latest one tells a superseded request — a
  /// slider drag makes a stream of them — apart from a genuine failure.
  int _exposureOffsetRequests = 0;

  /// Manages the white balance of the camera and reports what auto white
  /// balance settles on.
  late final WhiteBalanceManager whiteBalanceManager = WhiteBalanceManager(
    onAutoWhiteBalanceChanged: (_, double temperature, double tint) {
      cameraEventStreamController.add(
        CameraAutoWhiteBalanceChangedEvent(_flutterSurfaceTextureId, temperature, tint),
      );
    },
  );

  /// Handles retrieving media orientation for a device.
  late final DeviceOrientationManager deviceOrientationManager = DeviceOrientationManager(
    onDeviceOrientationChanged: (_, String orientation) {
      final DeviceOrientation deviceOrientation = _deserializeDeviceOrientation(orientation);
      deviceOrientationChangedStreamController.add(
        DeviceOrientationChangedEvent(deviceOrientation),
      );
    },
  );

  /// Stream that emits an event when the corresponding video recording is finalized.
  static final StreamController<VideoRecordEvent> videoRecordingEventStreamController =
      StreamController<VideoRecordEvent>.broadcast();

  /// Stream that emits the errors caused by camera usage on the native side.
  static final StreamController<String> cameraErrorStreamController =
      StreamController<String>.broadcast();

  /// Stream that emits the device orientation whenever it is changed.
  ///
  /// Values may start being added to the stream once
  /// `startListeningForDeviceOrientationChange(...)` is called.
  static final StreamController<DeviceOrientationChangedEvent>
  deviceOrientationChangedStreamController =
      StreamController<DeviceOrientationChangedEvent>.broadcast();

  /// Stream queue to pick up finalized viceo recording events in
  /// [stopVideoRecording].
  final StreamQueue<VideoRecordEvent> videoRecordingEventStreamQueue =
      StreamQueue<VideoRecordEvent>(videoRecordingEventStreamController.stream);

  late final VideoRecordEventListener _videoRecordingEventListener = VideoRecordEventListener(
    onEvent: (_, VideoRecordEvent event) {
      videoRecordingEventStreamController.add(event);
    },
  );

  /// Whether or not [preview] has been bound to the lifecycle of the camera by
  /// [createCamera].
  @visibleForTesting
  bool previewInitiallyBound = false;

  bool _previewIsPaused = false;

  /// The prefix used to create the filename for video recording files.
  @visibleForTesting
  final String videoPrefix = 'REC';

  /// The [ImageCapture] instance that can be configured to capture a still image.
  @visibleForTesting
  ImageCapture? imageCapture;

  /// The flash mode currently configured for [imageCapture].
  CameraXFlashMode? _currentFlashMode;

  /// Whether or not torch flash mode has been enabled for the [camera].
  @visibleForTesting
  bool torchEnabled = false;

  /// The [ImageAnalysis] instance that can be configured to analyze individual
  /// frames.
  ImageAnalysis? imageAnalysis;

  /// The [CameraSelector] used to configure the [processCameraProvider] to use
  /// the desired camera.
  @visibleForTesting
  CameraSelector? cameraSelector;

  /// The controller we need to broadcast the different camera events.
  ///
  /// It is a `broadcast` because multiple controllers will connect to
  /// different stream views of this Controller.
  /// This is only exposed for test purposes. It shouldn't be used by clients of
  /// the plugin as it may break or change at any time.
  @visibleForTesting
  final StreamController<CameraEvent> cameraEventStreamController =
      StreamController<CameraEvent>.broadcast();

  /// The stream of camera events for the camera with ID cameraId.
  Stream<CameraEvent> _cameraEvents(int cameraId) =>
      cameraEventStreamController.stream.where((CameraEvent event) => event.cameraId == cameraId);

  /// The controller we need to stream image data.
  @visibleForTesting
  StreamController<CameraImageData>? cameraImageDataStreamController;

  /// Constant representing the multi-plane Android YUV 420 image format used by ImageProxy.
  ///
  /// See https://developer.android.com/reference/android/graphics/ImageFormat#YUV_420_888.
  static const int imageProxyFormatYuv420_888 = 35;

  /// Constant representing the NV21 image format used by ImageProxy.
  ///
  /// See https://developer.android.com/reference/android/graphics/ImageFormat#NV21.
  static const int imageProxyFormatNv21 = 17;

  /// Constant representing the compressed JPEG image format used by ImageProxy.
  ///
  /// See https://developer.android.com/reference/android/graphics/ImageFormat#JPEG.
  static const int imageProxyFormatJpeg = 256;

  /// Constant representing the YUV 420 image format used for configuring ImageAnalysis.
  ///
  /// See https://developer.android.com/reference/androidx/camera/core/ImageAnalysis#OUTPUT_IMAGE_FORMAT_YUV_420_888()
  static const int imageAnalysisOutputImageFormatYuv420_888 = 1;

  /// Constant representing the NV21 image format used for configuring ImageAnalysis.
  ///
  /// See https://developer.android.com/reference/androidx/camera/core/ImageAnalysis#OUTPUT_IMAGE_FORMAT_NV21().
  static const int imageAnalysisOutputImageFormatNv21 = 3;

  /// Error code indicating a [ZoomState] was requested, but one has not been
  /// set for the camera in use.
  static const String zoomStateNotSetErrorCode = 'zoomStateNotSet';

  /// Whether or not the capture orientation is locked.
  ///
  /// Indicates a new target rotation should not be set as it has been locked by
  /// [lockCaptureOrientation].
  @visibleForTesting
  bool captureOrientationLocked = false;

  /// Whether or not the default rotation for [UseCase]s needs to be set
  /// manually because the capture orientation was previously locked.
  ///
  /// Currently, CameraX provides no way to unset target rotations for
  /// [UseCase]s, so once they are set and unset, this plugin must start setting
  /// the default orientation manually.
  ///
  /// See https://developer.android.com/reference/androidx/camera/core/ImageCapture#setTargetRotation(int)
  /// for an example on how setting target rotations for [UseCase]s works.
  bool shouldSetDefaultRotation = false;

  /// Error code indicating that an exposure offset value failed to be set.
  static const String setExposureOffsetFailedErrorCode = 'setExposureOffsetFailed';

  /// The currently set [FocusMeteringAction] used to enable auto-focus and
  /// auto-exposure.
  @visibleForTesting
  FocusMeteringAction? currentFocusMeteringAction;

  /// Current focus mode set via [setFocusMode].
  ///
  /// CameraX defaults to auto focus mode.
  FocusMode _currentFocusMode = FocusMode.auto;

  /// Current exposure mode set via [setExposureMode].
  ///
  /// CameraX defaults to auto exposure mode.
  ExposureMode _currentExposureMode = ExposureMode.auto;

  /// Whether or not a default focus point of the entire sensor area was focused
  /// and locked.
  ///
  /// This should only be true if [setExposureMode] was called to set
  /// [FocusMode.locked] and no previous focus point was set via
  /// [setFocusPoint].
  bool _defaultFocusPointLocked = false;

  /// Error code indicating that exposure compensation is not supported by
  /// CameraX for the device.
  static const String exposureCompensationNotSupported = 'exposureCompensationNotSupported';

  /// Whether or not the created camera is front facing.
  @visibleForTesting
  late bool cameraIsFrontFacing;

  /// The camera sensor orientation.
  ///
  /// This can change if the camera being used changes. Also, it is independent
  /// of the device orientation or user interface orientation.
  @visibleForTesting
  late double sensorOrientationDegrees;

  /// The initial orientation of the device when the camera is created.
  late DeviceOrientation _initialDeviceOrientation;

  /// The initial rotation of the Android default display when the camera is created.
  ///
  /// This is expressed in terms of one of the [Surface] rotation constant.
  late int _initialDefaultDisplayRotation;

  /// Whether or not audio should be enabled for recording video if permission is
  /// granted.
  @visibleForTesting
  late bool enableRecordingAudio;

  /// A map to associate a [CameraInfo] with its camera name.
  final Map<String, CameraInfo> _savedCameras = <String, CameraInfo>{};

  /// The preset resolution selector for the camera.
  ResolutionSelector? _presetResolutionSelector;

  /// The resolution selector for [imageAnalysis].
  ///
  /// Capped below the preset's, so image streaming never contributes a
  /// record-size stream to the session. See [_getResolutionSelectorFromPreset].
  ResolutionSelector? _analysisResolutionSelector;

  /// Whether [_recoverLostPreviewOutput] is already re-binding the preview.
  bool _recoveringPreviewOutput = false;

  /// The target FPS range the camera's [UseCase]s were built with, after
  /// [_resolveTargetFpsRange] checked it against what the camera can actually
  /// deliver, or null to leave the rate to CameraX.
  CameraIntegerRange? _targetFpsRange;

  /// The ID of the surface texture that the camera preview is drawn to.
  late int _flutterSurfaceTextureId;

  /// The configured format of outputted images from image streaming.
  int? _imageAnalysisOutputImageFormat;

  /// Returns list of all available cameras and their descriptions.
  @override
  Future<List<CameraDescription>> availableCameras() async {
    setUpGenerics();

    final cameraDescriptions = <CameraDescription>[];

    processCameraProvider ??= await ProcessCameraProvider.getInstance();
    final List<CameraInfo> cameraInfos = (await processCameraProvider!.getAvailableCameraInfos())
        .cast();

    CameraLensDirection? cameraLensDirection;
    int? cameraSensorOrientation;
    String? cameraName;

    for (final cameraInfo in cameraInfos) {
      final LensFacing lensFacing = cameraInfo.lensFacing;
      switch (lensFacing) {
        case LensFacing.front:
          cameraLensDirection = CameraLensDirection.front;
        case LensFacing.back:
          cameraLensDirection = CameraLensDirection.back;
        case LensFacing.external:
          cameraLensDirection = CameraLensDirection.external;
        case LensFacing.unknown:
          // Skip this CameraInfo as its lens direction is unknown
          continue;
      }

      cameraSensorOrientation = cameraInfo.sensorRotationDegrees;
      cameraName = await Camera2CameraInfo.from(cameraInfo: cameraInfo).getCameraId();

      _savedCameras[cameraName] = cameraInfo;

      cameraDescriptions.add(
        CameraDescription(
          name: cameraName,
          lensDirection: cameraLensDirection,
          sensorOrientation: cameraSensorOrientation,
          equivalentFocalLength: await Camera2CameraInfo.from(
            cameraInfo: cameraInfo,
          ).getEquivalentFocalLength(),
        ),
      );
    }

    return cameraDescriptions;
  }

  /// Creates an uninitialized camera instance with default settings and returns the camera ID.
  ///
  /// See [createCameraWithSettings]
  @override
  Future<int> createCamera(
    CameraDescription description,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) => createCameraWithSettings(
    description,
    MediaSettings(resolutionPreset: resolutionPreset, enableAudio: enableAudio),
  );

  /// Creates an uninitialized camera instance and returns the camera ID.
  ///
  /// In the CameraX library, cameras are accessed by combining [UseCase]s
  /// to an instance of a [ProcessCameraProvider]. Thus, to create an
  /// uninitialized camera instance, this method retrieves a
  /// [ProcessCameraProvider] instance.
  ///
  /// The specified `mediaSettings.resolutionPreset` is the target resolution
  /// that CameraX will attempt to select for the [UseCase]s constructed in this
  /// method ([preview], [imageCapture], [imageAnalysis], [videoCapture]). If
  /// unavailable, a fallback behavior of targeting the next highest resolution
  /// will be attempted. See https://developer.android.com/media/camera/camerax/configuration#specify-resolution.
  ///
  /// To return the camera ID, which is equivalent to the ID of the surface texture
  /// that a camera preview can be drawn to, a [Preview] instance is configured
  /// and bound to the [ProcessCameraProvider] instance.
  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings? mediaSettings,
  ) async {
    enableRecordingAudio = mediaSettings?.enableAudio ?? false;
    final CameraPermissionsError? error = await systemServicesManager.requestCameraPermissions(
      enableRecordingAudio,
    );

    if (error != null) {
      throw CameraException(error.errorCode, error.description);
    }
    // Choose CameraInfo to create CameraSelector by name associated with desired camera.
    final CameraInfo? chosenCameraInfo = _savedCameras[cameraDescription.name];

    // Save CameraSelector that matches cameraDescription.
    final LensFacing cameraSelectorLensDirection = _getCameraSelectorLensDirection(
      cameraDescription.lensDirection,
    );
    cameraIsFrontFacing = cameraSelectorLensDirection == LensFacing.front;
    cameraSelector = CameraSelector(cameraInfoForFilter: chosenCameraInfo);
    // Start listening for device orientation changes preceding camera creation.
    unawaited(deviceOrientationManager.startListeningForDeviceOrientationChange());
    // Determine ResolutionSelector and QualitySelector based on
    // resolutionPreset for camera UseCases.
    _presetResolutionSelector = _getResolutionSelectorFromPreset(mediaSettings?.resolutionPreset);
    _analysisResolutionSelector = _getResolutionSelectorFromPreset(
      mediaSettings?.resolutionPreset,
      maxBoundSize: _imageAnalysisMaxBoundSize,
    );

    final QualitySelector? presetQualitySelector = _getQualitySelectorFromPreset(
      mediaSettings?.resolutionPreset,
    );

    // Retrieve a fresh ProcessCameraProvider instance.
    processCameraProvider ??= await ProcessCameraProvider.getInstance();
    // Awaited, not fired and forgotten: this runs when a camera is created
    // without a preceding `dispose`, and the pipeline released just below is the
    // one those still-bound use cases are feeding. Building the next camera
    // while the previous one is mid-detach is how surfaces end up outliving the
    // context that renders into them.
    await processCameraProvider!.unbindAll();

    // The white balance manager belongs to the plugin rather than to any one
    // camera, so the lock requested for a previous one is still on it. Clearing
    // it here stops `_updateCameraInfoAndLiveCameraState` re-applying that lock
    // to the camera being built, which would leave the hardware locked while
    // the Dart-side controller reported auto.
    await whiteBalanceManager.reset();

    // Set up the effects pipeline before the use cases, so the `CameraEffect` it
    // owns is available for the first `bindToLifecycle`.
    //
    // A ratio the settings do not name leaves the current one alone rather than
    // clearing it. This object outlives the cameras it builds — every other
    // thing the render pipeline is configured with survives into the next one,
    // because [effectsManager] and its uniforms are deliberately reused — and a
    // crop that did not was the odd one out. Clearing it meant a camera rebuilt
    // to change the resolution preset came up at the sensor's own shape and was
    // corrected a frame or two later, once the caller had re-applied the ratio
    // to a camera that was already running. `setAspectRatio(null)` still clears
    // it; only silence is taken to mean "unchanged".
    _aspectRatio = mediaSettings?.aspectRatio ?? _aspectRatio;
    _pendingAspectRatio = null;
    _updateViewPort();
    // Built once and reused by every camera afterwards; see [effectsManager] for
    // why it must not be rebuilt per camera. The previous camera's `dispose`
    // detached its outputs, so what is left to do is point it at this camera's
    // crop.
    final CameraEffectsManager manager =
        effectsManager ??
        CameraEffectsManager(
          aspectRatio: _aspectRatio,
          onPreviewSizeChanged: (CameraEffectsManager manager, int width, int height) {
            cameraEventStreamController.add(
              CameraResolutionChangedEvent(
                _flutterSurfaceTextureId,
                width.toDouble(),
                height.toDouble(),
              ),
            );
          },
          onPreviewOutputLost: (CameraEffectsManager manager) {
            unawaited(_recoverLostPreviewOutput());
          },
        );
    effectsManager = manager;
    // A no-op on a freshly built one, which took the ratio in its constructor.
    await manager.setAspectRatio(_aspectRatio);
    cameraEffect = await manager.getCameraEffect();

    // Configure ImageCapture instance. Built before the preview because
    // `_resolveTargetFpsRange` needs the whole group to ask about, and this one
    // carries no frame rate of its own.
    imageCapture = await _createImageCapture();

    // A frame rate reaches the camera as a raw `CONTROL_AE_TARGET_FPS_RANGE`
    // capture-request option, which CameraX never sees and therefore never
    // validates against the streams it went on to configure. Forcing one the
    // configuration cannot satisfy leaves a session that configures, reports
    // itself active, and never delivers a frame. So it is checked here, against
    // the group that is about to be bound, before any use case is built with it.
    _targetFpsRange = await _resolveTargetFpsRange(mediaSettings?.fps);

    // Configure Preview instance.
    preview = Preview(
      resolutionSelector: _presetResolutionSelector,
      targetFpsRange: _targetFpsRange,
      whiteBalanceManager: whiteBalanceManager,
    );
    _flutterSurfaceTextureId = await preview!.setSurfaceProvider(systemServicesManager);

    // Configure VideoCapture and Recorder instances.
    recorder = Recorder(
      qualitySelector: presetQualitySelector,
      targetVideoEncodingBitRate: mediaSettings?.videoBitrate,
    );
    videoCapture = VideoCapture.withOutput(videoOutput: recorder!, targetFpsRange: _targetFpsRange);

    // Retrieve info required for correcting the rotation of the camera preview.
    //
    // `Preview.surfaceProducerHandlesCropAndRotation` is deliberately not
    // consulted. It reports whether Flutter's surface producer would apply a
    // buffer transform of its own, which mattered when CameraX wrote into that
    // surface directly. The shader writes real pixels into it instead, leaving
    // nothing for either kind of producer to transform, so both now display the
    // same frame and the preview needs the same correction either way.
    sensorOrientationDegrees = cameraDescription.sensorOrientation.toDouble();
    _initialDeviceOrientation = _deserializeDeviceOrientation(
      await deviceOrientationManager.getUiOrientation(),
    );
    _initialDefaultDisplayRotation = await deviceOrientationManager.getDefaultDisplayRotation();

    // Must precede the first `bindToLifecycle`: the effect's output orientation
    // is fixed when CameraX builds the preview pipeline, and a later change to
    // the target rotation does not rebuild it.
    await preview!.setTargetRotation(_previewTargetRotation);

    return _flutterSurfaceTextureId;
  }

  /// Initializes the camera with ID [cameraId] on the device.
  ///
  /// Specifically, this method:
  ///  * Configures the [ImageAnalysis] instance according to the specified
  ///   [imageFormatGroup]
  ///  * Binds the configured [Preview], [ImageCapture], and [ImageAnalysis]
  ///    instances to the [ProcessCameraProvider] instance.
  ///  * Retrieves information about the camera and sends a [CameraInitializedEvent].
  ///
  /// [imageFormatGroup] is used to specify the image format used for image
  /// streaming, but CameraX currently only supports YUV_420_888 (the CameraX default),
  /// NV21, and RGBA (not supported by Flutter).
  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    // If preview has not been created, then no camera has been created, which signals that
    // createCamera was not called before initializeCamera.
    if (preview == null) {
      throw CameraException(
        'cameraNotFound',
        "Camera not found. Please call the 'create' method before calling 'initialize'",
      );
    }
    // Configure ImageAnalysis instance.
    // Defaults to YUV_420_888 image format.
    _imageAnalysisOutputImageFormat = _imageAnalysisOutputFormatFromImageFormatGroup(
      imageFormatGroup,
    );
    imageAnalysis = ImageAnalysis(
      resolutionSelector: _analysisResolutionSelector,
      targetFpsRange: _targetFpsRange,
      outputImageFormat: _imageAnalysisOutputImageFormat,
    );

    // Bind configured UseCases to ProcessCameraProvider instance & mark Preview
    // instance as bound but not paused. Video capture is bound at first use
    // instead of here.
    camera = await _bindWithFallback(<UseCase>[preview!, imageCapture!, imageAnalysis!]);
    await _updateCameraInfoAndLiveCameraState(_flutterSurfaceTextureId);
    previewInitiallyBound = true;
    _previewIsPaused = false;

    // Configure CameraInitializedEvent to send as representation of a
    // configured camera:

    // Retrieve preview resolution.
    final ResolutionInfo previewResolutionInfo = (await preview!.getResolutionInfo())!;

    // Mark auto-focus, auto-exposure and setting points for focus & exposure
    // as available operations as CameraX does its best across devices to
    // support these by default.
    const ExposureMode exposureMode = ExposureMode.auto;
    const FocusMode focusMode = FocusMode.auto;
    const exposurePointSupported = true;
    const focusPointSupported = true;

    cameraEventStreamController.add(
      CameraInitializedEvent(
        cameraId,
        previewResolutionInfo.resolution.width.toDouble(),
        previewResolutionInfo.resolution.height.toDouble(),
        exposureMode,
        exposurePointSupported,
        focusMode,
        focusPointSupported,
      ),
    );

    // The event above carries `Preview.getResolutionInfo()`, which is the camera's *uncropped*
    // resolution — the view port crop only shows up in the surface the effect is handed. The
    // effects manager reports that surface's size on its own schedule, so it is asked again here
    // to guarantee it lands after the event that would otherwise overwrite it.
    await effectsManager?.notifyPreviewSize();
  }

  /// Releases the resources of the accessed camera with ID [cameraId].
  @override
  Future<void> dispose(int cameraId) async {
    // Teardown order is the reverse of construction, and it matters more than it
    // looks. Releasing the surface provider hands Flutter's texture back to the
    // engine, which closes the `ImageReader` behind it. Anything still writing
    // into that surface afterwards leaves the engine's raster thread reading
    // images that have already been closed — and the engine answers that with a
    // failed `CHECK` in `platform_view_android_jni_impl.cc`, which aborts the
    // process. It is not an exception any Dart or Java code here could catch.
    //
    // Two things write into it, and both have to be stopped first: the camera,
    // via the use cases, and the shader pipeline, which holds an EGL window
    // surface created from that same `Surface` and swaps a buffer into it on
    // every frame. Awaiting each step keeps the sequence deterministic.
    await liveCameraState?.removeObservers();
    await processCameraProvider?.unbindAll();
    await imageAnalysis?.clearAnalyzer();
    await deviceOrientationManager.stopListeningForDeviceOrientationChange();
    // Detached, not released: the pipeline is reused by the next camera, and
    // releasing it here is what leaves CameraX's cached adapters holding a dead
    // effect. See [effectsManager]. This still has to happen after the use cases
    // are unbound and before the surface provider goes, because it is what stops
    // the shader drawing into Flutter's surface.
    await effectsManager?.detachOutputs();
    // Last: nothing is producing into the surface any more.
    await preview?.releaseSurfaceProvider();
  }

  /// The camera with ID [cameraId] has been initialized.
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) {
    return _cameraEvents(cameraId).whereType<CameraInitializedEvent>();
  }

  /// The resolution of camera with ID [cameraId] has changed.
  ///
  /// Carries the size of the surface the effects pipeline draws into, which is
  /// the camera's output *after* any [setAspectRatio] view port crop — unlike
  /// the size on [CameraInitializedEvent], which is the uncropped output.
  @override
  Stream<CameraResolutionChangedEvent> onCameraResolutionChanged(int cameraId) {
    return _cameraEvents(cameraId).whereType<CameraResolutionChangedEvent>();
  }

  /// The camera with ID [cameraId] has started to close.
  @override
  Stream<CameraClosingEvent> onCameraClosing(int cameraId) {
    return _cameraEvents(cameraId).whereType<CameraClosingEvent>();
  }

  /// The camera with ID [cameraId] experienced an error.
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) {
    return StreamGroup.mergeBroadcast<CameraErrorEvent>(<Stream<CameraErrorEvent>>[
      cameraErrorStreamController.stream.map<CameraErrorEvent>((String errorDescription) {
        return CameraErrorEvent(cameraId, errorDescription);
      }),
      _cameraEvents(cameraId).whereType<CameraErrorEvent>(),
    ]);
  }

  /// The camera with ID [cameraId] finished recording a video.
  @override
  Stream<VideoRecordedEvent> onVideoRecordedEvent(int cameraId) {
    return _cameraEvents(cameraId).whereType<VideoRecordedEvent>();
  }

  /// The temperature and tint the camera's auto white balance has settled on.
  ///
  /// Only settled readings are reported: frames where the camera is still
  /// converging on a white balance are skipped, so the values here are the ones
  /// actually shown on screen.
  ///
  /// Devices that do not report `COLOR_CORRECTION_GAINS` in their capture
  /// results never emit; see [WhiteBalanceManager].
  @override
  Stream<CameraAutoWhiteBalanceChangedEvent> onAutoWhiteBalanceChanged(int cameraId) {
    return _cameraEvents(cameraId).whereType<CameraAutoWhiteBalanceChangedEvent>();
  }

  /// Locks the capture orientation of camera with ID [cameraId].
  @override
  Future<void> lockCaptureOrientation(int cameraId, DeviceOrientation orientation) async {
    // Flag that (1) default rotation for UseCases will need to be set manually
    // if orientation is ever unlocked and (2) the capture orientation is locked
    // and should not be changed until unlocked.
    shouldSetDefaultRotation = true;
    captureOrientationLocked = true;

    // Get target rotation based on locked orientation.
    final int targetLockedRotation = _getRotationConstantFromDeviceOrientation(orientation);

    // Update UseCases to use target device orientation.
    await imageCapture!.setTargetRotation(targetLockedRotation);
    await imageAnalysis!.setTargetRotation(targetLockedRotation);
    await videoCapture!.setTargetRotation(targetLockedRotation);
  }

  /// Unlocks the capture orientation of camera with ID [cameraId].
  @override
  Future<void> unlockCaptureOrientation(int cameraId) async {
    // Flag that default rotation should be set for UseCases as needed.
    captureOrientationLocked = false;
  }

  /// Sets the exposure point for automatically determining the exposure values for
  /// camera with ID [cameraId].
  ///
  /// Supplying `null` for the [point] argument will result in resetting to the
  /// original exposure point value.
  ///
  /// Supplied non-null point must be mapped to the entire un-altered preview
  /// surface for the exposure point to be applied accurately.
  @override
  Future<void> setExposurePoint(int cameraId, Point<double>? point) async {
    // We lock the new focus and metering action if focus mode has been locked
    // to ensure that the current focus point remains locked. Any exposure mode
    // setting will not be impacted by this lock (setting an exposure mode
    // is implemented with Camera2 interop that will override settings to
    // achieve the expected exposure mode as needed).
    await _startFocusAndMeteringForPoint(
      point: point,
      meteringMode: MeteringMode.ae,
      disableAutoCancel: _currentFocusMode == FocusMode.locked,
    );
  }

  /// Gets the minimum supported exposure offset for the camera with ID [cameraId] in EV units.
  @override
  Future<double> getMinExposureOffset(int cameraId) async {
    final ExposureState exposureState = cameraInfo!.exposureState;
    return exposureState.exposureCompensationRange.lower * exposureState.exposureCompensationStep;
  }

  /// Gets the maximum supported exposure offset for the camera with ID [cameraId] in EV units.
  @override
  Future<double> getMaxExposureOffset(int cameraId) async {
    final ExposureState exposureState = cameraInfo!.exposureState;
    return exposureState.exposureCompensationRange.upper * exposureState.exposureCompensationStep;
  }

  /// Sets the focus mode for taking pictures with camera with ID [cameraId]
  ///
  /// Setting [FocusMode.locked] will lock the current focus point if one exists
  /// or the center of entire sensor area if not, and will stay locked until
  /// either:
  ///   * Another focus point is set via [setFocusPoint] (which will then become
  ///     the locked focus point), or
  ///   * Locked focus mode is unset by setting [FocusMode.auto].
  @override
  Future<void> setFocusMode(int cameraId, FocusMode mode) async {
    if (_currentFocusMode == mode) {
      // Desired focus mode is already set.
      return;
    }

    MeteringPoint? autoFocusPoint;
    bool? disableAutoCancel;
    switch (mode) {
      case FocusMode.auto:
        // Determine auto-focus point to restore, if any. We do not restore
        // default auto-focus point if set previously to lock focus.
        final MeteringPoint? unLockedFocusPoint = _defaultFocusPointLocked
            ? null
            : currentFocusMeteringAction!.meteringPointsAf.first;
        _defaultFocusPointLocked = false;
        autoFocusPoint = unLockedFocusPoint;
        disableAutoCancel = false;
      case FocusMode.locked:
        MeteringPoint? lockedFocusPoint;

        // Determine if there is an auto-focus point set currently to lock.
        if (currentFocusMeteringAction != null) {
          final List<MeteringPoint> possibleCurrentAfPoints =
              currentFocusMeteringAction!.meteringPointsAf;
          lockedFocusPoint = possibleCurrentAfPoints.isEmpty ? null : possibleCurrentAfPoints.first;
        }

        // If there isn't, lock center of entire sensor area by default.
        if (lockedFocusPoint == null) {
          final meteringPointFactory = DisplayOrientedMeteringPointFactory(
            cameraInfo: cameraInfo!,
            width: 1,
            height: 1,
          );
          lockedFocusPoint = await meteringPointFactory.createPointWithSize(0.5, 0.5, 1);
          _defaultFocusPointLocked = true;
        }

        autoFocusPoint = lockedFocusPoint;
        disableAutoCancel = true;
    }
    // Start appropriate focus and metering action.
    final bool focusAndMeteringWasSuccessful = await _startFocusAndMeteringFor(
      meteringPoint: autoFocusPoint,
      meteringMode: MeteringMode.af,
      disableAutoCancel: disableAutoCancel,
    );

    if (!focusAndMeteringWasSuccessful) {
      // Do not update current focus mode.
      return;
    }

    // Update current focus mode.
    _currentFocusMode = mode;

    // If focus mode was just locked and exposure mode is not, set auto exposure
    // mode to ensure that disabling auto-cancel does not interfere with
    // automatic exposure metering.
    if (_currentExposureMode == ExposureMode.auto && _currentFocusMode == FocusMode.locked) {
      await setExposureMode(cameraId, _currentExposureMode);
    }
  }

  /// Gets the supported step size for exposure offset for the camera with ID [cameraId] in EV units.
  ///
  /// Returns -1 if exposure compensation is not supported for the device.
  @override
  Future<double> getExposureOffsetStepSize(int cameraId) async {
    final ExposureState exposureState = cameraInfo!.exposureState;
    final double exposureOffsetStepSize = exposureState.exposureCompensationStep;
    if (exposureOffsetStepSize == 0) {
      // CameraX returns a step size of 0 if exposure compensation is not
      // supported for the device.
      return -1;
    }
    return exposureOffsetStepSize;
  }

  /// Sets the exposure offset for the camera with ID [cameraId].
  ///
  /// The supplied [offset] value should be in EV units. 1 EV unit represents a
  /// doubling in brightness. It should be between the minimum and maximum offsets
  /// obtained through `getMinExposureOffset` and `getMaxExposureOffset` respectively.
  /// Throws a `CameraException` when trying to set exposure offset on a device
  /// that doesn't support exposure compensationan or if setting the offset fails,
  /// like in the case that an illegal offset is supplied.
  ///
  /// When the supplied [offset] value does not align with the step size obtained
  /// through `getExposureStepSize`, it will automatically be rounded to the nearest step.
  ///
  /// Returns the (rounded) offset value that was set.
  @override
  Future<double> setExposureOffset(int cameraId, double offset) async {
    final double exposureOffsetStepSize = cameraInfo!.exposureState.exposureCompensationStep;
    if (exposureOffsetStepSize == 0) {
      throw CameraException(
        exposureCompensationNotSupported,
        'Exposure compensation not supported',
      );
    }

    // (Exposure compensation index) * (exposure offset step size) =
    // (exposure offset).
    final int roundedExposureCompensationIndex = (offset / exposureOffsetStepSize).round();
    final int request = ++_exposureOffsetRequests;
    // Captured to tell a rebind from a real rejection below;
    // `_updateCameraInfoAndLiveCameraState` swaps this for a new instance every
    // time the use cases are rebound.
    final CameraControl requestedOn = cameraControl;

    try {
      final int? newIndex = await requestedOn.setExposureCompensationIndex(
        roundedExposureCompensationIndex,
      );

      if (newIndex == null) {
        if (request != _exposureOffsetRequests) {
          // Superseded by a later call rather than rejected: CameraX cancels a
          // pending index whenever a newer one is submitted, which a slider drag
          // does on every frame. The newer call reports the outcome, so raising
          // here would only bury the caller in errors it cannot act on.
          return roundedExposureCompensationIndex * exposureOffsetStepSize;
        }
        if (!identical(requestedOn, cameraControl)) {
          // The camera this was asked of has been rebound underneath it — a lens
          // switch, an aspect ratio change, or binding video capture at the start
          // of a recording. CameraX reports that with the same cancellation it
          // uses for a rejected request, but it is this plugin's own doing rather
          // than something the caller got wrong, and callers commonly set the
          // exposure offset alongside the very calls that rebind. Raising here
          // turns an ordinary camera switch into a fatal initialization error.
          return roundedExposureCompensationIndex * exposureOffsetStepSize;
        }
        cameraErrorStreamController.add(
          'Setting exposure compensation index was canceled due to the camera being closed or a new request being submitted.',
        );
        throw CameraException(
          setExposureOffsetFailedErrorCode,
          'Setting exposure compensation index was canceled due to the camera being closed or a new request being submitted.',
        );
      }

      // Back to EV: the platform interface, this method's own contract and
      // `AVFoundationCamera.setExposureOffset` all deal in exposure offsets,
      // while CameraX counts in steps of `exposureCompensationStep`.
      return newIndex * exposureOffsetStepSize;
    } on PlatformException catch (e) {
      cameraErrorStreamController.add(
        e.message ?? 'Setting the camera exposure compensation index failed.',
      );
      // Surfacing error to plugin layer to maintain consistency of
      // setExposureOffset implementation across platform implementations.

      throw CameraException(
        setExposureOffsetFailedErrorCode,
        e.message ?? 'Setting the camera exposure compensation index failed.',
      );
    }
  }

  /// Sets the focus point for automatically determining the focus values for the
  /// camera with ID [cameraId].
  ///
  /// Supplying `null` for the [point] argument will result in resetting to the
  /// original focus point value.
  ///
  /// Supplied non-null point must be mapped to the entire un-altered preview
  /// surface for the focus point to be applied accurately.
  @override
  Future<void> setFocusPoint(int cameraId, Point<double>? point) async {
    // We lock the new focus and metering action if focus mode has been locked
    // to ensure that the current focus point remains locked. Any exposure mode
    // setting will not be impacted by this lock (setting an exposure mode
    // is implemented with Camera2 interop that will override settings to
    // achieve the expected exposure mode as needed).
    await _startFocusAndMeteringForPoint(
      point: point,
      meteringMode: MeteringMode.af,
      disableAutoCancel: _currentFocusMode == FocusMode.locked,
    );
  }

  /// Sets the white balance for the camera with ID [cameraId].
  ///
  /// Passing `null` returns the camera to automatic white balance; passing
  /// [WhiteBalanceValues] locks it at that temperature and tint.
  ///
  /// CameraX has no white balance control, so this goes through Camera2
  /// interop. The gains come from the sensor's own colour calibration when the
  /// camera publishes one, which is the counterpart of the per-device
  /// calibration AVFoundation uses. Cameras that publish none fall back to an
  /// approximation derived from the Planckian locus — see
  /// `WhiteBalanceConverter` — where a given temperature can land slightly
  /// differently than it does on iOS.
  ///
  /// The lock survives rebinding the camera; see
  /// [_updateCameraInfoAndLiveCameraState].
  @override
  Future<void> setWhiteBalance(int cameraId, WhiteBalanceValues? values) async {
    final CameraInfo? info = cameraInfo;
    if (info == null) {
      throw CameraException(
        'setWhiteBalanceFailed',
        'Camera not found. Please call the "create" method before setting the white balance.',
      );
    }
    try {
      await whiteBalanceManager.setWhiteBalance(
        Camera2CameraControl.from(cameraControl: cameraControl),
        Camera2CameraInfo.from(cameraInfo: info),
        values?.temperature,
        values?.tint,
      );
    } on PlatformException catch (e) {
      throw CameraException('setWhiteBalanceFailed', e.message);
    }
  }

  /// Whether the camera with ID [cameraId] can have its white balance locked to
  /// a chosen temperature and tint via [setWhiteBalance].
  ///
  /// Android hardware support is genuinely uneven: a camera has to allow its
  /// auto white balance algorithm to be switched off *and* honour the colour
  /// correction keys for a temperature to mean anything. See
  /// `WhiteBalanceManager.isWhiteBalanceSupported` for what is checked.
  ///
  /// Only [setWhiteBalance] itself reports whether a particular lock was
  /// accepted; a `true` here says the camera advertises the capability, not
  /// that any given temperature will be reproduced exactly.
  @override
  Future<bool> supportsWhiteBalance(int cameraId) async {
    final CameraInfo? info = cameraInfo;
    if (info == null) {
      throw CameraException(
        'whiteBalanceSupportUnknown',
        'Camera not found. Please call the "create" method before querying white balance support.',
      );
    }
    return whiteBalanceManager.isWhiteBalanceSupported(Camera2CameraInfo.from(cameraInfo: info));
  }

  /// Sets the exposure mode for taking pictures with the camera with ID [cameraId].
  ///
  /// Setting [ExposureMode.locked] will lock current exposure point until it
  /// is unset by setting [ExposureMode.auto].
  @override
  Future<void> setExposureMode(int cameraId, ExposureMode mode) async {
    final camera2Control = Camera2CameraControl.from(cameraControl: cameraControl);
    final lockExposureMode = mode == ExposureMode.locked;

    final captureRequestOptions = CaptureRequestOptions(
      options: <CaptureRequestKey, Object?>{CaptureRequest.controlAELock: lockExposureMode},
    );

    try {
      await camera2Control.addCaptureRequestOptions(captureRequestOptions);
    } on PlatformException catch (e) {
      cameraErrorStreamController.add(
        e.message ??
            'The camera was unable to set new capture request options due to new options being unavailable or the camera being closed.',
      );
    }

    _currentExposureMode = mode;
  }

  /// Gets the maximum supported zoom level for the camera with ID [cameraId].
  @override
  Future<double> getMaxZoomLevel(int cameraId) async {
    final LiveData<ZoomState> liveZoomState = await cameraInfo!.getZoomState();
    final ZoomState? zoomState = await liveZoomState.getValue();

    if (zoomState == null) {
      throw CameraException(
        zoomStateNotSetErrorCode,
        'No explicit ZoomState has been set on the LiveData instance for the camera in use.',
      );
    }
    return zoomState.maxZoomRatio;
  }

  /// Gets the minimum supported zoom level for the camera with ID [cameraId].
  @override
  Future<double> getMinZoomLevel(int cameraId) async {
    final LiveData<ZoomState> liveZoomState = await cameraInfo!.getZoomState();
    final ZoomState? zoomState = await liveZoomState.getValue();

    if (zoomState == null) {
      throw CameraException(
        zoomStateNotSetErrorCode,
        'No explicit ZoomState has been set on the LiveData instance for the camera in use.',
      );
    }
    return zoomState.minZoomRatio;
  }

  /// Set the zoom level for the camera with ID [cameraId].
  ///
  /// The supplied [zoom] value should be between the minimum and the maximum
  /// supported zoom level returned by [getMinZoomLevel] and [getMaxZoomLevel].
  /// Throws a `CameraException` when an illegal zoom level is supplied.
  @override
  Future<void> setZoomLevel(int cameraId, double zoom) async {
    try {
      await cameraControl.setZoomRatio(zoom);
    } on PlatformException catch (e) {
      cameraErrorStreamController.add(
        e.message ??
            'Zoom ratio was unable to be set. If ratio was not out of range, newer value may have been set; otherwise, the camera may be closed.',
      );
    }
  }

  @override
  Future<Iterable<VideoStabilizationMode>> getSupportedVideoStabilizationModes(int cameraId) async {
    return (await _getSupportedVideoStabilizationModeMap(cameraId)).keys;
  }

  /// Throws a [ArgumentError] when an unsupported [mode] is
  /// supplied.
  @override
  Future<void> setVideoStabilizationMode(int cameraId, VideoStabilizationMode mode) async {
    final Map<VideoStabilizationMode, int> availableModes =
        await _getSupportedVideoStabilizationModeMap(cameraId);

    final int? controlMode = availableModes[mode];
    if (controlMode == null) {
      throw ArgumentError('Unavailable video stabilization mode.', 'mode');
    }

    final captureRequestOptions = CaptureRequestOptions(
      options: <CaptureRequestKey, Object?>{
        CaptureRequest.controlVideoStabilizationMode: controlMode,
      },
    );

    final camera2Control = Camera2CameraControl.from(cameraControl: cameraControl);
    await camera2Control.addCaptureRequestOptions(captureRequestOptions);
  }

  /// Gets a map of video stabilization control modes that are supported for the
  /// selected camera, indexed by the respective [VideoStabilizationMode].
  Future<Map<VideoStabilizationMode, int>> _getSupportedVideoStabilizationModeMap(
    int cameraId,
  ) async {
    if (cameraInfo == null) {
      return <VideoStabilizationMode, int>{};
    }

    final camera2CameraInfo = Camera2CameraInfo.from(cameraInfo: cameraInfo!);

    final List<int> controlModes =
        await camera2CameraInfo.getCameraCharacteristic(
              CameraCharacteristics.controlAvailableVideoStabilizationModes,
            )
            as List<int>? ??
        const <int>[];

    final modes = <VideoStabilizationMode, int>{
      for (final int controlMode in controlModes)
        // https://developer.android.com/reference/android/hardware/camera2/CameraMetadata#CONTROL_VIDEO_STABILIZATION_MODE_OFF
        if (controlMode == 0)
          VideoStabilizationMode.off: 0
        // https://developer.android.com/reference/android/hardware/camera2/CameraMetadata#CONTROL_VIDEO_STABILIZATION_MODE_ON
        else if (controlMode == 1)
          VideoStabilizationMode.level1: 1,
    };

    return modes;
  }

  /// The ui orientation changed.
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() {
    return deviceOrientationChangedStreamController.stream;
  }

  /// Pause the active preview on the current frame for the camera with ID [cameraId].
  @override
  Future<void> pausePreview(int cameraId) async {
    _previewIsPaused = true;
    await _unbindUseCaseFromLifecycle(preview!);
  }

  /// Sets the active camera while recording.
  ///
  /// To avoid cancelling any active recording when this method is called,
  /// you must start the recording with [startVideoCapturing]
  /// with `enablePersistentRecording` set to `true`.
  @override
  Future<void> setDescriptionWhileRecording(CameraDescription description) async {
    if (recording == null) {
      cameraErrorStreamController.add('Camera description not set. No active video recording.');
      return;
    }
    final CameraInfo? chosenCameraInfo = _savedCameras[description.name];

    // Save CameraSelector that matches cameraDescription.
    final LensFacing cameraSelectorLensDirection = _getCameraSelectorLensDirection(
      description.lensDirection,
    );
    cameraIsFrontFacing = cameraSelectorLensDirection == LensFacing.front;
    cameraSelector = CameraSelector(cameraInfoForFilter: chosenCameraInfo);

    // Retrieve info required for correcting the rotation of the camera preview.
    // Both of these feed the target rotation below, so they have to be updated
    // before the rebind that rebuilds the preview's effect pipeline.
    sensorOrientationDegrees = description.sensorOrientation.toDouble();
    await preview!.setTargetRotation(_previewTargetRotation);

    // Unbind all use cases and rebind to new CameraSelector
    final useCases = <UseCase>[videoCapture!];
    if (!_previewIsPaused) {
      useCases.add(preview!);
    }
    if (imageCapture != null && await processCameraProvider!.isBound(imageCapture!)) {
      useCases.add(imageCapture!);
    }
    if (imageAnalysis != null && await processCameraProvider!.isBound(imageAnalysis!)) {
      useCases.add(imageAnalysis!);
    }
    await processCameraProvider?.unbindAll();
    camera = await _bindWithFallback(useCases);

    await _updateCameraInfoAndLiveCameraState(_flutterSurfaceTextureId);
  }

  /// Resume the paused preview for the camera with ID [cameraId].
  @override
  Future<void> resumePreview(int cameraId) async {
    _previewIsPaused = false;
    await _bindUseCaseToLifecycle(preview!, cameraId);
  }

  /// Returns a widget showing a live camera preview for the camera with ID [cameraId].
  ///
  /// [createCamera] must be called before attempting to build this preview, and
  /// [cameraId] can be retrieved from that call.
  @override
  Widget buildPreview(int cameraId) {
    if (!previewInitiallyBound) {
      // No camera has been created, and thus, the preview UseCase has not been
      // bound to the camera lifecycle, restricting this preview from being
      // built.
      throw CameraException(
        'cameraNotFound',
        "Camera not found. Please call the 'create' method before calling 'buildPreview'",
      );
    }

    final Stream<DeviceOrientation> deviceOrientationStream = onDeviceOrientationChanged().map(
      (DeviceOrientationChangedEvent e) => e.orientation,
    );
    final Widget preview = Texture(textureId: cameraId);

    return SurfaceTextureRotatedPreview(
      _initialDeviceOrientation,
      _initialDefaultDisplayRotation,
      deviceOrientationStream,
      deviceOrientationManager,
      child: preview,
    );
  }

  /// Captures an image using the camera with ID [cameraId] and returns the file where it was saved.
  @override
  Future<XFile> takePicture(int cameraId) async {
    final CapturedPicturePaths paths = await _capture(cameraId, includeOriginal: false);
    return XFile(paths.processedPath);
  }

  @override
  Future<(XFile original, XFile processed)> takePictureWithOriginal(int cameraId) async {
    final CapturedPicturePaths paths = await _capture(cameraId, includeOriginal: true);
    // `includeOriginal: true` guarantees the native side wrote both files.
    return (XFile(paths.originalPath!), XFile(paths.processedPath));
  }

  /// Prepares [imageCapture] and takes one photo through the effects pipeline.
  Future<CapturedPicturePaths> _capture(int cameraId, {required bool includeOriginal}) async {
    await _bindUseCaseToLifecycle(imageCapture!, cameraId);
    // Set flash mode.
    if (_currentFlashMode != null) {
      await imageCapture!.setFlashMode(_currentFlashMode!);
    } else if (torchEnabled) {
      // Ensure any previously set flash modes are unset when torch mode has
      // been enabled.
      await imageCapture!.setFlashMode(CameraXFlashMode.off);
    }

    // Set target rotation to the current default CameraX rotation if
    // the capture orientation is not locked.
    if (!captureOrientationLocked) {
      await imageCapture!.setTargetRotation(
        await deviceOrientationManager.getDefaultDisplayRotation(),
      );
    }

    return imageCapture!.takePictureWithEffects(
      systemServicesManager,
      effectsManager!,
      includeOriginal,
    );
  }

  /// Applies visual effect parameters to the shader pipeline.
  @override
  Future<void> setEffectsValues(int cameraId, EffectsValues values) async {
    await effectsManager?.setEffectsValues(
      PlatformEffectsValues(
        vignetteIntensity: values.vignetteIntensity,
        grainNoisePath: values.grainNoisePath,
        grainOpacity: values.grainOpacity,
        grainSize: values.grainSize,
        grainBehavior: switch (values.grainBehavior) {
          GrainBehavior.overlay => PlatformGrainBehavior.overlay,
          GrainBehavior.darkOnly => PlatformGrainBehavior.darkOnly,
        },
        lutFilePath: values.lutFilePath,
        lutIntensity: values.lutIntensity,
        resolution: values.resolution,
        colorShift: values.colorShift,
        mist: values.mist,
        prism: values.prism,
        cheapFisheye: values.cheapFisheye,
        bloom: values.bloom,
        diffusion: values.diffusion,
      ),
    );
  }

  /// Sets the center-crop aspect ratio (width/height) applied to preview,
  /// photo and video, or `null` to disable cropping.
  @override
  Future<void> setAspectRatio(int cameraId, double? aspectRatio) async {
    if (recording != null) {
      // Applying it re-binds, which tears down the encoder's input surface and
      // would abort the recording. `DefaultCamera` defers the same way; this is
      // applied when the recording stops.
      _pendingAspectRatio = _PendingAspectRatio(aspectRatio);
      return;
    }
    await _applyAspectRatio(aspectRatio);
  }

  /// Applies [aspectRatio], and reports whether that re-bound the preview.
  Future<bool> _applyAspectRatio(double? aspectRatio) async {
    if (_aspectRatio == aspectRatio) {
      return false;
    }
    _aspectRatio = aspectRatio;
    // The still-capture path crops the decoded frame itself rather than reading
    // the view port, so it has to be told separately.
    await effectsManager?.setAspectRatio(aspectRatio);
    if (effectsManager == null) {
      // Null only before the very first camera, so there is nothing to re-bind —
      // and building a view port now would leave an orphan native object behind.
      // `createCameraWithSettings` derives one from `_aspectRatio` when it makes
      // the camera. After a `dispose` the manager is still around, and
      // `_rebindPreview` is the one that notices nothing is bound.
      return false;
    }
    _updateViewPort();
    return _rebindPreview();
  }

  /// Rebuilds [_viewPort] from [_aspectRatio].
  void _updateViewPort() {
    final double? ratio = _aspectRatio;
    if (ratio == null || ratio <= 0 || !ratio.isFinite) {
      _viewPort = null;
      return;
    }
    // The ratio is expressed in the display's natural orientation:
    // `ViewPort.rotation` tells CameraX which frame it is in, and CameraX maps
    // it into sensor coordinates — inverting it for a sensor mounted at 90 or
    // 270 degrees, the same re-orientation `DefaultCamera.effectiveAspectRatio`
    // does by hand on iOS.
    //
    // `Rational` needs whole numbers. A thousandth is finer than any sensor or
    // encoder resolves, and CameraX reduces the fraction itself, so 0.75 lands
    // back on exactly 3:4.
    _viewPort = ViewPort(
      aspectRatioWidth: (ratio * _viewPortRatioDenominator).round(),
      aspectRatioHeight: _viewPortRatioDenominator,
      rotation: Surface.rotation0,
    );
  }

  /// Re-binds [preview] so the current [_viewPort] takes effect.
  ///
  /// A view port reaches a use case only through a bind, and it is read when
  /// that use case builds its pipeline — so changing the crop on a running
  /// camera, or restoring one a rebuilt pipeline came back without, means
  /// detaching and re-attaching something. Only the preview is cycled: binding a
  /// group sets the view port on the camera's use case adapter, which recomputes
  /// the crop rect of *every* bound use case, so the ones that are left alone
  /// still pick it up.
  ///
  /// Deliberately not [ProcessCameraProvider.unbindAll]: with no use case left
  /// attached CameraX closes the camera device, which cancels every in-flight
  /// [CameraControl] request with "the camera being closed or a new request
  /// being submitted". Callers routinely change the aspect ratio alongside an
  /// exposure or zoom call — the example app does both in one `Future.wait` —
  /// and those would fail. Leaving the other use cases attached holds the device
  /// open across the swap.
  ///
  /// [videoCapture] is not cycled because it is only ever bound while a
  /// recording is in flight, and [setAspectRatio] defers until that stops.
  ///
  /// Returns whether it ran; it does not when nothing is bound to rebuild, in
  /// which case the next bind — from `resumePreview` or
  /// [_bindUseCaseToLifecycle] — picks the current configuration up anyway.
  Future<bool> _rebindPreview() async {
    final ProcessCameraProvider? provider = processCameraProvider;
    final Preview? previewUseCase = preview;
    if (provider == null ||
        cameraSelector == null ||
        previewUseCase == null ||
        _previewIsPaused ||
        !previewInitiallyBound ||
        !await provider.isBound(previewUseCase)) {
      return false;
    }

    await provider.unbind(<UseCase>[previewUseCase]);
    // Binding the preview alone is enough: CameraX unions it with the use cases
    // that are still attached, so image capture and image analysis stay bound
    // and the effect still finds a preview-targeted use case to attach to.
    camera = await provider.bindToLifecycle(
      cameraSelector!,
      <UseCase>[previewUseCase],
      _cameraEffects,
      _viewPort,
    );
    await _updateCameraInfoAndLiveCameraState(_flutterSurfaceTextureId);
    return true;
  }

  /// Re-binds [preview] after the effects pipeline lost the surface it was
  /// drawing into, so CameraX hands it a new one.
  ///
  /// Without this the camera goes on running and the shader goes on receiving
  /// frames it has nowhere to put: a preview stuck on its last good frame, with
  /// no error anywhere to explain it. A surface is abandoned by its consumer
  /// often enough for this to matter — a lens switch and a backgrounded app both
  /// do it — and CameraX only builds a new preview pipeline, and so only hands
  /// out a new surface, when the use case is re-bound.
  ///
  /// Guarded rather than debounced: a rebind that itself fails to produce a
  /// usable surface would otherwise report the loss again and spin.
  Future<void> _recoverLostPreviewOutput() async {
    if (_recoveringPreviewOutput) {
      return;
    }
    _recoveringPreviewOutput = true;
    try {
      final bool rebound = await _rebindPreview();
      if (!rebound) {
        // Nothing was bound, so nothing was lost that a bind will not fix.
        return;
      }
    } on PlatformException catch (e) {
      cameraErrorStreamController.add(
        'The camera preview lost its surface and could not be restored: ${e.message}',
      );
    } finally {
      _recoveringPreviewOutput = false;
    }
  }

  /// Applies an aspect ratio change that [setAspectRatio] deferred because a
  /// recording was in flight, and reports whether that re-bound the preview.
  Future<bool> _applyPendingAspectRatio() async {
    final _PendingAspectRatio? pending = _pendingAspectRatio;
    if (pending == null) {
      return false;
    }
    _pendingAspectRatio = null;
    return _applyAspectRatio(pending.value);
  }

  /// Sets the capture scale applied inside the aspect-ratio crop.
  @override
  Future<void> setCaptureScale(int cameraId, double scale) async {
    await effectsManager?.setCaptureScale(scale);
  }

  /// Sets the corner radius of the capture-scale rectangle drawn in the
  /// preview.
  @override
  Future<void> setCaptureCornerRadius(int cameraId, double radius) async {
    await effectsManager?.setCaptureCornerRadius(radius);
  }

  /// Gets the [FlashMode]s supported by the camera with ID [cameraId].
  ///
  /// CameraX exposes no per-mode capability query, only whether the camera has
  /// a flash unit at all; a camera that has one supports every mode.
  @override
  Future<Iterable<FlashMode>> getSupportedFlashModes(int cameraId) async {
    final CameraInfo? info = cameraInfo;
    if (info == null || !await info.hasFlashUnit()) {
      return const <FlashMode>[FlashMode.off];
    }
    return const <FlashMode>[FlashMode.off, FlashMode.auto, FlashMode.always, FlashMode.torch];
  }

  /// Sets the flash mode for the camera with ID [cameraId].
  ///
  /// When the [FlashMode.torch] is enabled, any previously set [FlashMode] with
  /// this method will be disabled, just as with any other [FlashMode]; while
  /// this is not default native Android behavior as defined by the CameraX API,
  /// this behavior is compliant with the plugin platform interface.
  ///
  /// This method combines the notion of setting the flash mode of the
  /// [imageCapture] UseCase and enabling the camera torch, as described
  /// by https://developer.android.com/reference/androidx/camera/core/ImageCapture
  /// and https://developer.android.com/reference/androidx/camera/core/CameraControl#enableTorch(boolean),
  /// respectively.
  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {
    // Turn off torch mode if it is enabled and not being redundantly set.
    if (mode != FlashMode.torch && torchEnabled) {
      await _enableTorchMode(false);
      torchEnabled = false;
    }

    switch (mode) {
      case FlashMode.off:
        _currentFlashMode = CameraXFlashMode.off;
      case FlashMode.auto:
        _currentFlashMode = CameraXFlashMode.auto;
      case FlashMode.always:
        _currentFlashMode = CameraXFlashMode.on;
      case FlashMode.torch:
        _currentFlashMode = null;
        if (torchEnabled) {
          // Torch mode enabled already.
          return;
        }

        await _enableTorchMode(true);
        torchEnabled = true;
    }
  }

  /// Prepare the capture session for video recording.
  ///
  /// This optimization is not used on Android, so this implementation is a
  /// no-op.
  @override
  Future<void> prepareForVideoRecording() {
    return Future<void>.value();
  }

  /// Configures and starts a video recording with the camera with ID [cameraId].
  /// Returns silently without doing anything if there is currently an active
  /// recording.
  ///
  /// Note that the preset resolution is used to configure the recording, but
  /// 240p ([ResolutionPreset.low]) is unsupported and will fallback to
  /// configure the recording as the next highest available quality.
  ///
  /// This method is deprecated in favour of [startVideoCapturing].
  @override
  Future<void> startVideoRecording(int cameraId, {Duration? maxVideoDuration}) async {
    // Ignore maxVideoDuration, as it is unimplemented and deprecated.
    return startVideoCapturing(VideoCaptureOptions(cameraId));
  }

  /// Starts a video recording and/or streaming session.
  ///
  /// Please see [VideoCaptureOptions] for documentation on the
  /// configuration options. Currently streamOptions are unsupported due to
  /// limitations of the platform interface.
  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    if (recording != null) {
      // There is currently an active recording, so do not start a new one.
      return;
    }
    final dynamic Function(CameraImageData)? streamCallback = options.streamCallback;
    if (streamCallback == null) {
      // For potential performance improvements, unbind imageAnalysis if not in use.
      // See https://developer.android.com/media/camera/camerax/architecture#combine-use-cases
      // for details.
      await _unbindUseCaseFromLifecycle(imageAnalysis!);
    }

    await _bindUseCaseToLifecycle(videoCapture!, options.cameraId);

    // Set target rotation to default CameraX rotation only if capture
    // orientation not locked.
    if (!captureOrientationLocked && shouldSetDefaultRotation) {
      await videoCapture!.setTargetRotation(
        await deviceOrientationManager.getDefaultDisplayRotation(),
      );
    }

    videoOutputPath = await systemServicesManager.getTempFilePath(videoPrefix, '.mp4');
    pendingRecording = await recorder!.prepareRecording(videoOutputPath!);

    if (options.enablePersistentRecording) {
      pendingRecording = await pendingRecording?.asPersistentRecording();
    }

    // Enable/disable recording audio as requested. If enabling audio is requested
    // and permission was not granted when the camera was created, then recording
    // audio will be disabled to respect the denied permission.
    pendingRecording = await pendingRecording!.withAudioEnabled(
      /* initialMuted */
      !enableRecordingAudio,
    );

    recording = await pendingRecording!.start(_videoRecordingEventListener);

    if (streamCallback != null) {
      onStreamedFrameAvailable(options.cameraId).listen(streamCallback);
    }

    // Wait for video recording to start.
    VideoRecordEvent event = await videoRecordingEventStreamQueue.next;
    while (event is! VideoRecordEventStart) {
      event = await videoRecordingEventStreamQueue.next;
    }
  }

  /// Stops the video recording and returns the file where it was saved.
  /// Throws a CameraException if the recording is currently null, or if the
  /// videoOutputPath is null.
  ///
  /// If the videoOutputPath is null the recording objects are cleaned up
  /// so starting a new recording is possible.
  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    if (recording == null) {
      throw CameraException(
        'videoRecordingFailed',
        'Attempting to stop a '
            'video recording while no recording is in progress.',
      );
    }

    /// Stop the active recording and wait for the video recording to be finalized.
    await recording!.close();
    VideoRecordEvent event = await videoRecordingEventStreamQueue.next;
    while (event is! VideoRecordEventFinalize) {
      event = await videoRecordingEventStreamQueue.next;
    }
    recording = null;
    pendingRecording = null;

    if (videoOutputPath == null) {
      // Handle any errors with finalizing video recording.
      throw CameraException(
        'INVALID_PATH',
        'The platform did not return a path '
            'while reporting success. The platform should always '
            'return a valid path or report an error.',
      );
    }

    await _unbindUseCaseFromLifecycle(videoCapture!);
    // Safe now that the encoder is gone: an aspect ratio change re-binds.
    final bool reboundForAspectRatio = await _applyPendingAspectRatio();
    if (!reboundForAspectRatio) {
      // Unbinding the encoder takes `StreamSharing` apart, and the preview
      // pipeline CameraX builds to replace it comes back with no crop at all —
      // its `SurfaceProcessorNode` is built from a crop rect covering the whole
      // frame, where the same node before the recording carried the view port's.
      // A view port reaches a use case only through a bind, and stopping a
      // recording is otherwise the one transition here that rebuilds the preview
      // without performing one. That is also why starting another recording puts
      // the crop back: that path binds.
      await _rebindPreview();
    }
    final videoFile = XFile(videoOutputPath!);
    cameraEventStreamController.add(VideoRecordedEvent(cameraId, videoFile, /* duration */ null));
    return videoFile;
  }

  /// Pause the current video recording of the camera with ID [cameraId] if it is not null.
  @override
  Future<void> pauseVideoRecording(int cameraId) async {
    if (recording != null) {
      await recording!.pause();
    }
  }

  /// Resume the current video recording of the camera with ID [cameraId] if it is not null.
  @override
  Future<void> resumeVideoRecording(int cameraId) async {
    if (recording != null) {
      await recording!.resume();
    }
  }

  @override
  bool supportsImageStreaming() => true;

  /// A new streamed frame is available from the camera with ID [cameraId].
  ///
  /// Listening to this stream will start streaming, and canceling will stop.
  /// To temporarily stop receiving frames, cancel, then listen again later.
  /// Pausing/resuming is not supported, as pausing the stream would cause
  /// very high memory usage, and will throw an exception due to the
  /// implementation using a broadcast [StreamController], which does not
  /// support those operations.
  ///
  /// If the camera was initialized with [ImageFormatGroup.nv21], then the
  /// streamed images will still have format [ImageFormatGroup.yuv420], but
  /// their image data will be formatted in NV21.
  ///
  /// [options] are not used.
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) {
    cameraImageDataStreamController = StreamController<CameraImageData>(
      onListen: () async => _configureImageAnalysis(cameraId),
      onCancel: _onFrameStreamCancel,
    );
    return cameraImageDataStreamController!.stream;
  }

  // Methods for binding UseCases to the lifecycle of the camera controlled
  // by a ProcessCameraProvider instance:

  /// Binds [useCase] to the camera lifecycle controlled by the
  /// [processCameraProvider] if not already bound.
  ///
  /// [cameraId] used to build [CameraEvent]s should you wish to filter
  /// these based on a reference to a cameraId received from calling
  /// [createCamera].
  Future<void> _bindUseCaseToLifecycle(UseCase useCase, int cameraId) async {
    final bool useCaseIsBound = await processCameraProvider!.isBound(useCase);
    final bool useCaseIsPausedPreview = useCase is Preview && _previewIsPaused;

    if (useCaseIsBound || useCaseIsPausedPreview) {
      // Only bind if useCase is not already bound or preview is intentionally
      // paused.
      return;
    }

    // Rebind the preview alongside the incoming use case rather than the use case alone.
    // CameraX matches effects against the use cases in the group it is given, so binding
    // e.g. `imageCapture` on its own would find nothing for a preview-targeted effect,
    // log "Unused effects", and drop the effect from the camera.
    final useCases = <UseCase>[
      if (preview != null && !_previewIsPaused && preview != useCase) preview!,
      useCase,
    ];
    camera = await _bindWithFallback(useCases);

    await _updateCameraInfoAndLiveCameraState(cameraId);
  }

  /// Builds the [ImageCapture] this camera takes photos with.
  ///
  /// Its buffer format is not decided here: the native side picks an
  /// uncompressed one where the device claims to offer it, so a rebuilt
  /// instance is the way to pick that decision up again after it changes.
  Future<ImageCapture> _createImageCapture() async => ImageCapture(
    resolutionSelector: _presetResolutionSelector,
    /* use CameraX default target rotation */ targetRotation: await deviceOrientationManager
        .getDefaultDisplayRotation(),
  );

  /// Binds [useCases] with the current effects and view port, rebuilding
  /// [imageCapture] and retrying once if the camera refuses the configuration.
  ///
  /// Stills are captured uncompressed wherever the device claims to offer it
  /// (see `UncompressedCaptureSupport` on the native side), and a `YUV_420_888`
  /// still stream next to the analysis stream's own is one uncompressed stream
  /// more than camera2's guaranteed combinations promise. Which devices that
  /// catches out cannot be read from their characteristics up front: CameraX
  /// only says so by throwing `IllegalArgumentException: No supported surface
  /// combination` out of the bind — which, on the first camera an app opens, is
  /// a camera that never opens at all.
  ///
  /// That same throw is what makes the native side withdraw the format for the
  /// rest of the process, so the [ImageCapture] built here is a JPEG one and the
  /// group binds. Retried on any failure rather than on that message alone: the
  /// alternative is matching CameraX's exception text, and the cost of a wrong
  /// guess is one extra bind attempt on a camera that was failing anyway.
  Future<Camera> _bindWithFallback(List<UseCase> useCases) async {
    try {
      return await processCameraProvider!.bindToLifecycle(
        cameraSelector!,
        useCases,
        _cameraEffects,
        _viewPort,
      );
    } on PlatformException catch (e) {
      final ImageCapture? refused = imageCapture;
      if (refused == null || !useCases.contains(refused)) {
        rethrow;
      }
      debugPrint('Rebuilding the still capture use case after a failed bind: ${e.message}');
      // A no-op after a bind that threw, which attaches nothing. It matters when
      // the refused use case was left attached by an *earlier* bind: the
      // replacement would then be a stream on top of it rather than instead of
      // it, and the retry would fail for the same reason as the attempt.
      await processCameraProvider!.unbind(<UseCase>[refused]);
      final ImageCapture replacement = await _createImageCapture();
      imageCapture = replacement;
      return processCameraProvider!.bindToLifecycle(
        cameraSelector!,
        useCases
            .map((UseCase useCase) => identical(useCase, refused) ? replacement : useCase)
            .toList(),
        _cameraEffects,
        _viewPort,
      );
    }
  }

  /// Configures the [imageAnalysis] instance for image streaming.
  Future<void> _configureImageAnalysis(int cameraId) async {
    await _bindUseCaseToLifecycle(imageAnalysis!, cameraId);

    // Set target rotation to default CameraX rotation only if capture
    // orientation not locked.
    if (!captureOrientationLocked && shouldSetDefaultRotation) {
      await imageAnalysis!.setTargetRotation(
        await deviceOrientationManager.getDefaultDisplayRotation(),
      );
    }

    // Create and set Analyzer that can read image data for image streaming.
    final weakThis = WeakReference<AndroidCameraCameraX>(this);
    Future<void> analyze(ImageProxy imageProxy) async {
      final List<PlaneProxy> planes = await imageProxy.getPlanes();
      final cameraImagePlanes = <CameraImagePlane>[];

      // Determine image planes.
      if (_imageAnalysisOutputImageFormat == imageAnalysisOutputImageFormatNv21) {
        // Convert three generically YUV_420_888 formatted image planes into one singular
        // NV21 formatted image plane if NV21 was requested for image streaming. The conversion
        // should be null safe.
        final Uint8List bytes = await ImageProxyUtils.getNv21Buffer(
          imageProxy.width,
          imageProxy.height,
          planes,
        );

        cameraImagePlanes.add(
          CameraImagePlane(
            bytes: bytes,
            bytesPerRow: imageProxy.width,
            // NV21 has 1.5 bytes per pixel (Y plane has width * height; VU plane has width * height / 2),
            // but this is rounded up because an int is expected. camera_android reports the same.
            bytesPerPixel: 1,
          ),
        );
      } else {
        for (final plane in planes) {
          cameraImagePlanes.add(
            CameraImagePlane(
              bytes: plane.buffer,
              bytesPerRow: plane.rowStride,
              bytesPerPixel: plane.pixelStride,
            ),
          );
        }
      }

      // Determine image format.
      CameraImageFormat? cameraImageFormat;

      if (_imageAnalysisOutputImageFormat == imageAnalysisOutputImageFormatNv21) {
        // Manually override ImageFormat to NV21 if set for image streaming as CameraX
        // still reports YUV_420_888 if the underlying format is NV21.
        cameraImageFormat = const CameraImageFormat(
          ImageFormatGroup.nv21,
          raw: imageProxyFormatNv21,
        );
      } else {
        final int imageRawFormat = imageProxy.format;
        cameraImageFormat = CameraImageFormat(
          _imageFormatGroupFromPlatformData(imageRawFormat),
          raw: imageRawFormat,
        );
      }

      // Send out CameraImageData.
      final cameraImageData = CameraImageData(
        format: cameraImageFormat,
        planes: cameraImagePlanes,
        height: imageProxy.height,
        width: imageProxy.width,
      );

      weakThis.target!.cameraImageDataStreamController!.add(cameraImageData);
      await imageProxy.close();
    }

    await imageAnalysis!.setAnalyzer(Analyzer(analyze: (_, ImageProxy image) => analyze(image)));
  }

  /// Unbinds [useCase] from camera lifecycle controlled by the
  /// [processCameraProvider] if not already unbound.
  Future<void> _unbindUseCaseFromLifecycle(UseCase useCase) async {
    final bool useCaseIsBound = await processCameraProvider!.isBound(useCase);
    if (!useCaseIsBound) {
      return;
    }

    await processCameraProvider!.unbind(<UseCase>[useCase]);
  }

  // Methods for configuring image streaming:

  /// The [onCancel] callback for the stream controller used for image
  /// streaming.
  ///
  /// Removes the previously set analyzer on the [imageAnalysis] instance, since
  /// image information should no longer be streamed.
  FutureOr<void> _onFrameStreamCancel() async {
    await imageAnalysis!.clearAnalyzer();
  }

  /// Converts [ImageFormatGroup]s to Android ImageAnalysis output format constants.
  ///
  /// See https://developer.android.com/reference/androidx/camera/core/ImageAnalysis.
  int? _imageAnalysisOutputFormatFromImageFormatGroup(dynamic format) {
    switch (format) {
      case ImageFormatGroup.yuv420:
        return imageAnalysisOutputImageFormatYuv420_888;
      case ImageFormatGroup.nv21:
        return imageAnalysisOutputImageFormatNv21;
    }

    return null;
  }

  /// Converts from Android ImageFormat constants to [ImageFormatGroup]s.
  ///
  /// See https://developer.android.com/reference/android/graphics/ImageFormat.
  ImageFormatGroup _imageFormatGroupFromPlatformData(dynamic data) {
    switch (data) {
      case imageProxyFormatYuv420_888: // android.graphics.ImageFormat.YUV_420_888
        return ImageFormatGroup.yuv420;
      case imageProxyFormatNv21: // android.graphics.ImageFormat.NV21
        return ImageFormatGroup.nv21;
      case imageProxyFormatJpeg: // android.graphics.ImageFormat.JPEG
        return ImageFormatGroup.jpeg;
    }

    return ImageFormatGroup.unknown;
  }

  // Methods concerning camera state:

  /// Updates [cameraInfo] and [cameraControl] to the information corresponding
  /// to [camera] and adds observers to the [LiveData] of the [CameraState] of
  /// the current [camera], saved as [liveCameraState].
  ///
  /// If a previous [liveCameraState] was stored, existing observers are
  /// removed, as well.
  Future<void> _updateCameraInfoAndLiveCameraState(int cameraId) async {
    cameraInfo = (await camera!.getCameraInfo()) as CameraInfo;
    cameraControl = camera!.cameraControl;

    // Camera2 capture request options live on the `Camera` instance, which
    // `bindToLifecycle` replaces, so a white balance lock has to be re-sent
    // every time the camera is rebound. The manager holds the requested value
    // and does nothing when the white balance has never been set.
    await whiteBalanceManager.attachToCamera(
      Camera2CameraControl.from(cameraControl: cameraControl),
      Camera2CameraInfo.from(cameraInfo: cameraInfo!),
    );

    await liveCameraState?.removeObservers();
    liveCameraState = await cameraInfo!.getCameraState();
    await liveCameraState!.observe(_createCameraClosingObserver(cameraId));
  }

  /// Creates [Observer] of the [CameraState] that will:
  ///
  ///  * Send a [CameraClosingEvent] if the [CameraState] indicates that the
  ///    camera has begun to close.
  ///  * Send a [CameraErrorEvent] if the [CameraState] indicates that the
  ///    camera is in error state.
  Observer<CameraState> _createCameraClosingObserver(int cameraId) {
    final weakThis = WeakReference<AndroidCameraCameraX>(this);

    // Callback method used to implement the behavior described above:
    void onChanged(CameraState state) {
      if (state.type == CameraStateType.closing) {
        weakThis.target!.cameraEventStreamController.add(CameraClosingEvent(cameraId));
      }
      if (state.error != null) {
        late final String errorDescription;
        switch (state.error!.code) {
          case CameraStateErrorCode.cameraInUse:
            errorDescription =
                'The camera was already in use, possibly by a higher-priority camera client.';
          case CameraStateErrorCode.maxCamerasInUse:
            errorDescription =
                'The limit number of open cameras has been reached, and more cameras cannot be opened until other instances are closed.';
          case CameraStateErrorCode.otherRecoverableError:
            errorDescription =
                'The camera device has encountered a recoverable error. CameraX will attempt to recover from the error.';
          case CameraStateErrorCode.streamConfig:
            errorDescription = 'Configuring the camera has failed.';
          case CameraStateErrorCode.cameraDisabled:
            errorDescription =
                'The camera device could not be opened due to a device policy. Thia may be caused by a client from a background process attempting to open the camera.';
          case CameraStateErrorCode.cameraFatalError:
            errorDescription =
                'The camera was closed due to a fatal error. This may require the Android device be shut down and restarted to restore camera function or may indicate a persistent camera hardware problem.';
          case CameraStateErrorCode.doNotDisturbModeEnabled:
            errorDescription =
                'The camera could not be opened because "Do Not Disturb" mode is enabled. Please disable this mode, and try opening the camera again.';
          case CameraStateErrorCode.unknown:
            errorDescription = 'There was an unspecified issue with the current camera state.';
        }
        weakThis.target!.cameraEventStreamController.add(
          CameraErrorEvent(cameraId, errorDescription),
        );
      }
    }

    return Observer<CameraState>(onChanged: (_, CameraState value) => onChanged(value));
  }

  // Methods for mapping Flutter camera constants to CameraX constants:

  /// Returns [CameraSelector] lens direction that maps to specified
  /// [CameraLensDirection].
  LensFacing _getCameraSelectorLensDirection(CameraLensDirection lensDirection) {
    switch (lensDirection) {
      case CameraLensDirection.front:
        return LensFacing.front;
      case CameraLensDirection.back:
        return LensFacing.back;
      case CameraLensDirection.external:
        return LensFacing.external;
    }
  }

  /// Returns [Surface] constant for counter-clockwise degrees of rotation from
  /// [DeviceOrientation.portraitUp] required to reach the specified
  /// [DeviceOrientation].
  int _getRotationConstantFromDeviceOrientation(DeviceOrientation orientation) {
    switch (orientation) {
      case DeviceOrientation.portraitUp:
        return Surface.rotation0;
      case DeviceOrientation.landscapeLeft:
        return Surface.rotation90;
      case DeviceOrientation.portraitDown:
        return Surface.rotation180;
      case DeviceOrientation.landscapeRight:
        return Surface.rotation270;
    }
  }

  /// The [Surface] rotation constant to give [preview] so that the effect
  /// pipeline hands Flutter an upright buffer.
  ///
  /// [Surface.rotation0] — the display's natural orientation — and never
  /// anything else, which is what makes the render path the single owner of
  /// sensor orientation and front-camera mirroring.
  ///
  /// Binding a [CameraEffect] puts the preview stream behind a CameraX
  /// `SurfaceProcessorNode`. That node sizes its output
  /// `getRotatedSize(cropRect, relativeRotation)` and gives the processor a
  /// transform with `relativeRotation` and the node's mirroring already folded
  /// in, where `relativeRotation` is the sensor orientation measured against
  /// this target rotation. Asking for the natural orientation therefore makes
  /// `relativeRotation` the full sensor orientation, and the frame the shader
  /// writes is upright in that orientation — mirrored too, for a front-facing
  /// preview, since the node mirrors what it hands a `PREVIEW` output.
  ///
  /// Everything downstream then has one job left, whichever camera is open and
  /// whichever way its sensor is mounted: turn the frame by however far the
  /// display has been rotated. That is all
  /// [SurfaceTextureRotatedPreview] does.
  ///
  /// Cancelling the sensor orientation here instead — leaving `relativeRotation`
  /// zero so the frame arrives in raw sensor orientation for the preview widget
  /// to correct — is the other way to arrange this, and is what this plugin did
  /// before the effect pipeline existed. It cannot be made to work once CameraX
  /// supplies the mirroring: the widget then has to undo a rotation *through* a
  /// mirror, which reverses its sense, and the correction stops being
  /// expressible as a quarter-turn count that is right for both cameras.
  int get _previewTargetRotation => Surface.rotation0;

  /// The frame rate range to build this camera's [UseCase]s with, given the
  /// application asked for [requestedFps], or null to leave the rate to CameraX.
  ///
  /// A frame rate is applied through Camera2 interop, as a
  /// `CONTROL_AE_TARGET_FPS_RANGE` capture-request option written straight into
  /// the repeating request. CameraX does not see it, so it plays no part in how
  /// CameraX resolves the stream configuration, and nothing checks the two
  /// against each other. A camera that reaches 60fps with a 720p preview
  /// commonly tops out at 30 once the streams are 1080p, and an effect adds a
  /// surface of its own on top; ask that camera for a fixed 60 anyway and the
  /// session configures, reports itself active, and never delivers a frame.
  ///
  /// So the camera is asked what the configuration about to be bound can
  /// actually do. The probe use cases stand in for the real ones, which do not
  /// exist yet: only the resolution selectors matter to the answer, and the
  /// frame rate deliberately does not — it is invisible to CameraX either way,
  /// which is what makes the probe faithful.
  Future<CameraIntegerRange?> _resolveTargetFpsRange(int? requestedFps) async {
    if (requestedFps == null || requestedFps <= 0) {
      return null;
    }

    final List<CameraIntegerRange> supported;
    try {
      supported = await processCameraProvider!.getSupportedFrameRateRanges(
        cameraSelector!,
        <UseCase>[
          Preview(resolutionSelector: _presetResolutionSelector),
          imageCapture!,
          ImageAnalysis(resolutionSelector: _analysisResolutionSelector),
        ],
        _cameraEffects,
        _viewPort,
      );
    } on PlatformException catch (e) {
      // Applying an unchecked range is the failure this method exists to
      // prevent, so a query that cannot answer means no range at all.
      debugPrint('Could not read the supported frame rate ranges: ${e.message}');
      return null;
    }

    final CameraIntegerRange? selected = _selectFrameRateRange(requestedFps, supported);
    if (selected == null) {
      debugPrint(
        'The camera reports no frame rate range for this configuration; '
        'leaving the frame rate to CameraX instead of forcing ${requestedFps}fps.',
      );
    } else if (selected.upper != requestedFps || selected.lower != requestedFps) {
      debugPrint(
        'The camera cannot hold ${requestedFps}fps with this configuration; '
        'using [${selected.lower}, ${selected.upper}] instead.',
      );
    }
    return selected;
  }

  /// Picks the range out of [supported] that best serves [requestedFps].
  ///
  /// Prefers the fixed `[requestedFps, requestedFps]` the caller is really
  /// asking for, then the fastest range that does not overshoot it, and only
  /// then the slowest range there is. Overshooting is the one thing never
  /// chosen: a range whose lower bound is above the request is a camera being
  /// pushed past what was asked for.
  static CameraIntegerRange? _selectFrameRateRange(
    int requestedFps,
    List<CameraIntegerRange> supported,
  ) {
    if (supported.isEmpty) {
      return null;
    }

    CameraIntegerRange? best;
    for (final range in supported) {
      if (range.lower == requestedFps && range.upper == requestedFps) {
        return range;
      }
      if (range.upper > requestedFps) {
        continue;
      }
      // Among the ranges that fit, the fastest; among equally fast ones, the
      // one that is fixed rather than free to drop.
      if (best == null ||
          range.upper > best.upper ||
          (range.upper == best.upper && range.lower > best.lower)) {
        best = range;
      }
    }
    if (best != null) {
      return best;
    }

    // Everything the camera offers is faster than the request. Take the slowest
    // of them, which is the closest thing to what was asked for.
    return supported.reduce(
      (CameraIntegerRange a, CameraIntegerRange b) => b.upper < a.upper ? b : a,
    );
  }

  /// The largest size [imageAnalysis] is configured for, whatever the preset.
  ///
  /// CameraX's own guidance is to keep image analysis at or below preview size,
  /// and the cost of ignoring it is not just throughput. At 1080p the analysis
  /// stream counts as a record-size one, and a preview, an analysis and a
  /// capture stream all at record size is not a combination the camera is
  /// required to support — with the effect's own surface on top of them. The
  /// stream that hands frames to Dart gains nothing from the extra pixels, so it
  /// is the one that gives way.
  ///
  /// Plain numbers rather than a [CameraSize]: that is a proxy object with a
  /// native counterpart, and one held in a `static` would outlive every camera
  /// and every instance manager that ever attached it.
  static const ({int width, int height}) _imageAnalysisMaxBoundSize = (width: 1280, height: 720);

  /// Returns the [ResolutionSelector] that maps to the specified resolution
  /// preset for camera [UseCase]s.
  ///
  /// If the specified [preset] is unavailable, the camera will fall back to the
  /// closest lower resolution available.
  ///
  /// [maxBoundSize] caps the size the preset asks for, for use cases that should
  /// not follow it all the way up; see [_imageAnalysisMaxBoundSize].
  ResolutionSelector? _getResolutionSelectorFromPreset(
    ResolutionPreset? preset, {
    ({int width, int height})? maxBoundSize,
  }) {
    const ResolutionStrategyFallbackRule fallbackRule =
        ResolutionStrategyFallbackRule.closestLowerThenHigher;

    ({int width, int height}) boundSize;
    AspectRatio? aspectRatio;
    ResolutionStrategy? resolutionStrategy;
    switch (preset) {
      case ResolutionPreset.low:
        boundSize = (width: 320, height: 240);
        aspectRatio = AspectRatio.ratio4To3;
      case ResolutionPreset.medium:
        boundSize = (width: 720, height: 480);
      case ResolutionPreset.high:
        boundSize = (width: 1280, height: 720);
        aspectRatio = AspectRatio.ratio16To9;
      case ResolutionPreset.veryHigh:
        boundSize = (width: 1920, height: 1080);
        aspectRatio = AspectRatio.ratio16To9;
      case ResolutionPreset.ultraHigh:
        boundSize = (width: 3840, height: 2160);
        aspectRatio = AspectRatio.ratio16To9;
      case ResolutionPreset.max:
      case ResolutionPreset.photo:
        // `ResolutionPreset.photo` is an iOS-specific concept
        // (`AVCaptureSession.Preset.photo`); on Android there is no direct
        // analogue, so we treat it the same as `max` — highest available.
        if (maxBoundSize == null) {
          // Automatically set strategy to choose highest available.
          resolutionStrategy = ResolutionStrategy.highestAvailableStrategy;
          return ResolutionSelector(resolutionStrategy: resolutionStrategy);
        }
        // A capped use case cannot follow "highest available" anywhere, so it
        // is pinned to its cap instead.
        boundSize = maxBoundSize;
      case null:
        // If no preset is specified, default to CameraX's default behavior
        // for each UseCase. A cap is not applied either: CameraX's own default
        // for image analysis is already well below one.
        return null;
    }

    if (maxBoundSize != null &&
        boundSize.width * boundSize.height > maxBoundSize.width * maxBoundSize.height) {
      boundSize = maxBoundSize;
    }

    resolutionStrategy = ResolutionStrategy(
      boundSize: CameraSize(width: boundSize.width, height: boundSize.height),
      fallbackRule: fallbackRule,
    );
    final AspectRatioStrategy? aspectRatioStrategy = aspectRatio == null
        ? null
        : AspectRatioStrategy(
            preferredAspectRatio: aspectRatio,
            fallbackRule: AspectRatioStrategyFallbackRule.auto,
          );
    // Deliberately no `ResolutionFilter`: one built from the bound size pins the
    // choice to exactly that size, which overrides `fallbackRule` and leaves
    // CameraX no room to pick a size the rest of the configuration — the other
    // streams, the effect's surface, the requested frame rate — can live with.
    // The strategy already expresses the preference; the fallback rule is what
    // makes it a preference rather than a demand.
    return ResolutionSelector(
      resolutionStrategy: resolutionStrategy,
      aspectRatioStrategy: aspectRatioStrategy,
    );
  }

  /// Returns the [QualitySelector] that maps to the specified resolution
  /// preset for the camera used only for video capture.
  ///
  /// If the specified [preset] is unavailable, the camera will fall back to the
  /// closest lower resolution available.
  QualitySelector? _getQualitySelectorFromPreset(ResolutionPreset? preset) {
    VideoQuality? videoQuality;
    switch (preset) {
      case ResolutionPreset.low:
      // 240p is not supported by CameraX.
      case ResolutionPreset.medium:
        videoQuality = VideoQuality.SD;
      case ResolutionPreset.high:
        videoQuality = VideoQuality.HD;
      case ResolutionPreset.veryHigh:
        videoQuality = VideoQuality.FHD;
      case ResolutionPreset.ultraHigh:
        videoQuality = VideoQuality.UHD;
      case ResolutionPreset.max:
      case ResolutionPreset.photo:
        // `ResolutionPreset.photo` is an iOS-specific concept; on Android
        // we record at the highest video quality available, matching `max`.
        videoQuality = VideoQuality.highest;
      case null:
        // If no preset is specified, default to CameraX's default behavior
        // for each UseCase.
        return null;
    }

    // We will choose the next highest video quality if the one desired
    // is unavailable.
    final fallbackStrategy = FallbackStrategy.lowerQualityOrHigherThan(quality: videoQuality);

    return QualitySelector.from(quality: videoQuality, fallbackStrategy: fallbackStrategy);
  }

  // Methods for configuring auto-focus and auto-exposure:

  Future<bool> _startFocusAndMeteringForPoint({
    required Point<double>? point,
    required MeteringMode meteringMode,
    bool disableAutoCancel = false,
  }) async {
    MeteringPoint? meteringPoint;
    if (point != null) {
      if (point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) {
        throw CameraException(
          'pointInvalid',
          'The coordinates of a metering point for an auto-focus or auto-exposure action must be within (0,0) and (1,1), but a point with coordinates (${point.x}, ${point.y}) was provided for metering mode $meteringMode.',
        );
      }

      final meteringPointFactory = DisplayOrientedMeteringPointFactory(
        width: 1.0,
        height: 1.0,
        cameraInfo: cameraInfo!,
      );
      meteringPoint = await meteringPointFactory.createPoint(point.x, point.y);
    }
    return _startFocusAndMeteringFor(
      meteringPoint: meteringPoint,
      meteringMode: meteringMode,
      disableAutoCancel: disableAutoCancel,
    );
  }

  /// Starts a focus and metering action and returns whether or not it was
  /// successful.
  ///
  /// This method will modify and start the current action's [MeteringPoint]s
  /// overriden with the [meteringPoint] provided for the specified
  /// [meteringMode] type only, with all other metering points of other modes
  /// left untouched. If no current action exists, only the specified
  /// [meteringPoint] will be set. Thus, the focus and metering action started
  /// will only contain at most the one most recently set metering point for
  /// each metering mode: AF, AE, AWB.
  ///
  /// Thus, if [meteringPoint] is non-null, this action includes:
  ///   * metering points and their modes previously added to
  ///     [currentFocusMeteringAction] that do not share a metering mode with
  ///     [meteringPoint] (if [currentFocusMeteringAction] is non-null) and
  ///   * [meteringPoint] with the specified [meteringMode].
  /// If [meteringPoint] is null and [currentFocusMeteringAction] is non-null,
  /// this action includes only metering points and their modes previously added
  /// to [currentFocusMeteringAction] that do not share a metering mode with
  /// [meteringPoint]. If [meteringPoint] and [currentFocusMeteringAction] are
  /// null, then focus and metering will be canceled.
  Future<bool> _startFocusAndMeteringFor({
    required MeteringPoint? meteringPoint,
    required MeteringMode meteringMode,
    bool disableAutoCancel = false,
  }) async {
    if (meteringPoint == null) {
      // Try to clear any metering point from previous action with the specified
      // meteringMode.
      if (currentFocusMeteringAction == null) {
        // Attempting to clear a metering point from a previous action, but no
        // such action exists.
        return false;
      }

      final Iterable<(MeteringPoint, MeteringMode)> originalMeteringPoints = _combineMeteringPoints(
        currentFocusMeteringAction!,
      );

      // Remove metering point with specified meteringMode from current focus
      // and metering action, as only one focus or exposure point may be set
      // at once in this plugin.
      final List<(MeteringPoint, MeteringMode)> newMeteringPointInfos = originalMeteringPoints
          .where(
            ((MeteringPoint, MeteringMode) meteringPointInfo) =>
                // meteringPointInfo may technically include points without a
                // mode specified, but this logic is safe because this plugin
                // only uses points that explicitly have mode
                // FocusMeteringAction.flagAe or FocusMeteringAction.flagAf.
                meteringPointInfo.$2 != meteringMode,
          )
          .toList();

      if (newMeteringPointInfos.isEmpty) {
        // If no other metering points were specified, cancel any previously
        // started focus and metering actions.
        await cameraControl.cancelFocusAndMetering();
        currentFocusMeteringAction = null;
        return true;
      }
      // Create builder to potentially add more MeteringPoints to.
      final actionBuilder = FocusMeteringActionBuilder.withMode(
        point: newMeteringPointInfos.first.$1,
        mode: newMeteringPointInfos.first.$2,
      );
      if (disableAutoCancel) {
        unawaited(actionBuilder.disableAutoCancel());
      }

      // Add any additional metering points in order as specified by input lists.
      newMeteringPointInfos.skip(1).forEach(((MeteringPoint point, MeteringMode) info) {
        actionBuilder.addPointWithMode(info.$1, info.$2);
      });
      currentFocusMeteringAction = await actionBuilder.build();
    } else {
      // Add new metering point with specified meteringMode, which may involve
      // replacing a metering point with the same specified meteringMode from
      // the current focus and metering action.
      var newMeteringPointInfos = <(MeteringPoint, MeteringMode)>[];

      if (currentFocusMeteringAction != null) {
        final Iterable<(MeteringPoint, MeteringMode)> originalMeteringPoints =
            _combineMeteringPoints(currentFocusMeteringAction!);

        newMeteringPointInfos = originalMeteringPoints
            .where(
              ((MeteringPoint, MeteringMode) meteringPointInfo) =>
                  // meteringPointInfo may technically include points without a
                  // mode specified, but this logic is safe because this plugin
                  // only uses points that explicitly have mode
                  // FocusMeteringAction.flagAe or FocusMeteringAction.flagAf.
                  meteringPointInfo.$2 != meteringMode,
            )
            .toList();
      }

      newMeteringPointInfos.add((meteringPoint, meteringMode));

      final actionBuilder = FocusMeteringActionBuilder.withMode(
        point: newMeteringPointInfos.first.$1,
        mode: newMeteringPointInfos.first.$2,
      );

      if (disableAutoCancel) {
        unawaited(actionBuilder.disableAutoCancel());
      }

      newMeteringPointInfos.skip(1).forEach(((MeteringPoint point, MeteringMode mode) info) {
        actionBuilder.addPointWithMode(info.$1, info.$2);
      });
      currentFocusMeteringAction = await actionBuilder.build();
    }

    try {
      final FocusMeteringResult? result = await cameraControl.startFocusAndMetering(
        currentFocusMeteringAction!,
      );

      if (result == null) {
        cameraErrorStreamController.add(
          'Starting focus and metering was canceled due to the camera being closed or a new request being submitted.',
        );
      }

      return result?.isFocusSuccessful ?? false;
    } on PlatformException catch (e) {
      cameraErrorStreamController.add(e.message ?? 'Starting focus and metering failed.');
      // Surfacing error to differentiate an operation cancellation from an
      // illegal argument exception at a plugin layer.
      rethrow;
    }
  }

  // Combines the metering points and metering modes of a `FocusMeteringAction`
  // into a single list.
  Iterable<(MeteringPoint, MeteringMode)> _combineMeteringPoints(
    FocusMeteringAction focusMeteringAction,
  ) {
    Iterable<(MeteringPoint, MeteringMode)> toMeteringPointRecords(
      Iterable<MeteringPoint> points,
      MeteringMode mode,
    ) {
      return points.map((MeteringPoint point) => (point, mode));
    }

    return <(MeteringPoint, MeteringMode)>[
      ...toMeteringPointRecords(focusMeteringAction.meteringPointsAf, MeteringMode.af),
      ...toMeteringPointRecords(focusMeteringAction.meteringPointsAe, MeteringMode.ae),
      ...toMeteringPointRecords(focusMeteringAction.meteringPointsAwb, MeteringMode.awb),
    ];
  }

  Future<void> _enableTorchMode(bool value) async {
    try {
      await cameraControl.enableTorch(value);
    } on PlatformException catch (e) {
      cameraErrorStreamController.add(e.message ?? 'The camera was unable to change torch modes.');
    }
  }

  static DeviceOrientation _deserializeDeviceOrientation(String orientation) {
    switch (orientation) {
      case 'LANDSCAPE_LEFT':
        return DeviceOrientation.landscapeLeft;
      case 'LANDSCAPE_RIGHT':
        return DeviceOrientation.landscapeRight;
      case 'PORTRAIT_DOWN':
        return DeviceOrientation.portraitDown;
      case 'PORTRAIT_UP':
        return DeviceOrientation.portraitUp;
      default:
        throw ArgumentError('"$orientation" is not a valid DeviceOrientation value');
    }
  }
}

/// A [AndroidCameraCameraX.setAspectRatio] call deferred until the current
/// recording stops.
///
/// A class rather than a bare `double?` because `null` is a valid ratio meaning
/// "no crop", so it cannot double as "nothing deferred".
class _PendingAspectRatio {
  const _PendingAspectRatio(this.value);

  /// The requested ratio (width/height), or null to clear the crop.
  final double? value;
}
