// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../camera.dart';

/// Signature for a callback receiving the a camera image.
///
/// This is used by [CameraController.startImageStream].
// TODO(stuartmorgan): Fix this naming the next time there's a breaking change
// to this package.
// ignore: camel_case_types
typedef onLatestImageAvailable = void Function(CameraImage image);

/// Completes with a list of available cameras.
///
/// May throw a [CameraException].
Future<List<CameraDescription>> availableCameras() async {
  return CameraPlatform.instance.availableCameras();
}

/// The state of a [CameraController].
class CameraValue {
  /// Creates a new camera controller state.
  const CameraValue({
    required this.isInitialized,
    this.errorDescription,
    this.previewSize,
    required this.isRecordingVideo,
    required this.isTakingPicture,
    required this.isStreamingImages,
    required this._isRecordingPaused,
    required this.flashMode,
    required this.exposureMode,
    required this.focusMode,
    required this.exposurePointSupported,
    required this.focusPointSupported,
    required this.deviceOrientation,
    required this.description,
    this.lockedCaptureOrientation,
    this.recordingOrientation,
    this.isPreviewPaused = false,
    this.previewPauseOrientation,
    this.videoStabilizationMode = VideoStabilizationMode.off,
    this.captureScale = 1.0,
    this.captureCornerRadius = 0.0,
    this.whiteBalanceValues,
  });

  /// Creates a new camera controller state for an uninitialized controller.
  const CameraValue.uninitialized(CameraDescription description)
    : this(
        isInitialized: false,
        isRecordingVideo: false,
        isTakingPicture: false,
        isStreamingImages: false,
        isRecordingPaused: false,
        flashMode: FlashMode.auto,
        exposureMode: ExposureMode.auto,
        exposurePointSupported: false,
        focusMode: FocusMode.auto,
        focusPointSupported: false,
        deviceOrientation: DeviceOrientation.portraitUp,
        isPreviewPaused: false,
        description: description,
        videoStabilizationMode: VideoStabilizationMode.off,
        captureScale: 1.0,
        captureCornerRadius: 0.0,
      );

  /// True after [CameraController.initialize] has completed successfully.
  final bool isInitialized;

  /// True when a picture capture request has been sent but as not yet returned.
  final bool isTakingPicture;

  /// True when the camera is recording (not the same as previewing).
  final bool isRecordingVideo;

  /// True when images from the camera are being streamed.
  final bool isStreamingImages;

  final bool _isRecordingPaused;

  /// True when the preview widget has been paused manually.
  final bool isPreviewPaused;

  /// Set to the orientation the preview was paused in, if it is currently paused.
  final DeviceOrientation? previewPauseOrientation;

  /// True when camera [isRecordingVideo] and recording is paused.
  bool get isRecordingPaused => isRecordingVideo && _isRecordingPaused;

  /// Description of an error state.
  ///
  /// This is null while the controller is not in an error state.
  /// When [hasError] is true this contains the error description.
  final String? errorDescription;

  /// The size of the preview in pixels.
  ///
  /// Is `null` until [isInitialized] is `true`.
  final Size? previewSize;

  /// Convenience getter for `previewSize.width / previewSize.height`.
  ///
  /// Can only be called when [initialize] is done.
  double get aspectRatio => previewSize!.width / previewSize!.height;

  /// Whether the controller is in an error state.
  ///
  /// When true [errorDescription] describes the error.
  bool get hasError => errorDescription != null;

  /// The flash mode the camera is currently set to.
  final FlashMode flashMode;

  /// The exposure mode the camera is currently set to.
  final ExposureMode exposureMode;

  /// The focus mode the camera is currently set to.
  final FocusMode focusMode;

  /// The currently locked white balance values, or `null` when the camera is
  /// in automatic white balance. Supported on iOS, and on Android cameras
  /// that report [CameraController.supportsWhiteBalance].
  final WhiteBalanceValues? whiteBalanceValues;

  /// The white balance mode the camera is currently set to.
  ///
  /// Derived from [whiteBalanceValues]: [WhiteBalanceMode.auto] when
  /// [whiteBalanceValues] is `null`, [WhiteBalanceMode.locked] otherwise.
  WhiteBalanceMode get whiteBalanceMode =>
      whiteBalanceValues == null ? WhiteBalanceMode.auto : WhiteBalanceMode.locked;

  /// Whether setting the exposure point is supported.
  final bool exposurePointSupported;

  /// Whether setting the focus point is supported.
  final bool focusPointSupported;

  /// The current device UI orientation.
  final DeviceOrientation deviceOrientation;

  /// The currently locked capture orientation.
  final DeviceOrientation? lockedCaptureOrientation;

  /// Whether the capture orientation is currently locked.
  bool get isCaptureOrientationLocked => lockedCaptureOrientation != null;

  /// The orientation of the currently running video recording.
  final DeviceOrientation? recordingOrientation;

  /// The properties of the camera device controlled by this controller.
  final CameraDescription description;

  /// The current video stabilization mode.
  final VideoStabilizationMode videoStabilizationMode;

  /// The current capture scale. `1.0` means no extra crop; smaller values
  /// further narrow the captured area.
  final double captureScale;

  /// The corner radius of the [captureScale] preview rectangle.
  /// `0.0` means sharp corners; `1.0` is the maximum rounding.
  final double captureCornerRadius;

  /// Creates a modified copy of the object.
  ///
  /// Explicitly specified fields get the specified value, all other fields get
  /// the same value of the current object.
  CameraValue copyWith({
    bool? isInitialized,
    bool? isRecordingVideo,
    bool? isTakingPicture,
    bool? isStreamingImages,
    String? errorDescription,
    Size? previewSize,
    bool? isRecordingPaused,
    FlashMode? flashMode,
    ExposureMode? exposureMode,
    FocusMode? focusMode,
    bool? exposurePointSupported,
    bool? focusPointSupported,
    DeviceOrientation? deviceOrientation,
    Optional<DeviceOrientation>? lockedCaptureOrientation,
    Optional<DeviceOrientation>? recordingOrientation,
    bool? isPreviewPaused,
    CameraDescription? description,
    Optional<DeviceOrientation>? previewPauseOrientation,
    VideoStabilizationMode? videoStabilizationMode,
    double? captureScale,
    double? captureCornerRadius,
    Optional<WhiteBalanceValues>? whiteBalanceValues,
  }) {
    return CameraValue(
      isInitialized: isInitialized ?? this.isInitialized,
      errorDescription: errorDescription ?? this.errorDescription,
      previewSize: previewSize ?? this.previewSize,
      isRecordingVideo: isRecordingVideo ?? this.isRecordingVideo,
      isTakingPicture: isTakingPicture ?? this.isTakingPicture,
      isStreamingImages: isStreamingImages ?? this.isStreamingImages,
      isRecordingPaused: isRecordingPaused ?? _isRecordingPaused,
      flashMode: flashMode ?? this.flashMode,
      exposureMode: exposureMode ?? this.exposureMode,
      focusMode: focusMode ?? this.focusMode,
      exposurePointSupported: exposurePointSupported ?? this.exposurePointSupported,
      focusPointSupported: focusPointSupported ?? this.focusPointSupported,
      deviceOrientation: deviceOrientation ?? this.deviceOrientation,
      lockedCaptureOrientation: lockedCaptureOrientation == null
          ? this.lockedCaptureOrientation
          : lockedCaptureOrientation.orNull,
      recordingOrientation: recordingOrientation == null
          ? this.recordingOrientation
          : recordingOrientation.orNull,
      isPreviewPaused: isPreviewPaused ?? this.isPreviewPaused,
      description: description ?? this.description,
      previewPauseOrientation: previewPauseOrientation == null
          ? this.previewPauseOrientation
          : previewPauseOrientation.orNull,
      videoStabilizationMode: videoStabilizationMode ?? this.videoStabilizationMode,
      captureScale: captureScale ?? this.captureScale,
      captureCornerRadius: captureCornerRadius ?? this.captureCornerRadius,
      whiteBalanceValues: whiteBalanceValues == null
          ? this.whiteBalanceValues
          : whiteBalanceValues.orNull,
    );
  }

  @override
  String toString() {
    return '${objectRuntimeType(this, 'CameraValue')}('
        'isRecordingVideo: $isRecordingVideo, '
        'isInitialized: $isInitialized, '
        'errorDescription: $errorDescription, '
        'previewSize: $previewSize, '
        'isStreamingImages: $isStreamingImages, '
        'flashMode: $flashMode, '
        'exposureMode: $exposureMode, '
        'focusMode: $focusMode, '
        'exposurePointSupported: $exposurePointSupported, '
        'focusPointSupported: $focusPointSupported, '
        'deviceOrientation: $deviceOrientation, '
        'lockedCaptureOrientation: $lockedCaptureOrientation, '
        'recordingOrientation: $recordingOrientation, '
        'isPreviewPaused: $isPreviewPaused, '
        'previewPausedOrientation: $previewPauseOrientation, '
        'videoStabilizationMode: $videoStabilizationMode, '
        'captureScale: $captureScale, '
        'captureCornerRadius: $captureCornerRadius, '
        'whiteBalanceValues: $whiteBalanceValues, '
        'description: $description)';
  }
}

/// Controls a device camera.
///
/// Use [availableCameras] to get a list of available cameras.
///
/// Before using a [CameraController] a call to [initialize] must complete.
///
/// To show the camera preview on the screen use a [CameraPreview] widget.
class CameraController extends ValueNotifier<CameraValue> {
  /// Creates a new camera controller in an uninitialized state.
  ///
  /// - [resolutionPreset] affect the quality of video recording and image capture.
  /// - [enableAudio] controls audio presence in recorded video.
  ///
  /// Following parameters (if present) will overwrite [resolutionPreset] settings:
  /// - [fps] controls rate at which frames should be captured by the camera in frames per second.
  /// - [videoBitrate] controls the video encoding bit rate for recording.
  /// - [audioBitrate] controls the audio encoding bit rate for recording.
  ///
  /// - [aspectRatio] is the width/height ratio to center-crop the preview,
  ///   photos and video to; `null` means no crop. Equivalent to calling
  ///   [setAspectRatio], but applied while the camera is being built rather
  ///   than after it has started producing frames — which is the difference
  ///   between a preview that is the right shape from its first frame and one
  ///   that arrives at the camera's own shape and is corrected a moment later.
  ///   Prefer it whenever the ratio is known up front; a controller replaced to
  ///   change [resolutionPreset] is the common case, since a new controller
  ///   carries none of the old one's state.

  CameraController(
    CameraDescription description,
    ResolutionPreset resolutionPreset, {
    bool enableAudio = true,
    int? fps,
    int? videoBitrate,
    int? audioBitrate,
    double? aspectRatio,
    this.imageFormatGroup,
  }) : mediaSettings = MediaSettings(
         resolutionPreset: resolutionPreset,
         enableAudio: enableAudio,
         fps: fps,
         videoBitrate: videoBitrate,
         audioBitrate: audioBitrate,
         aspectRatio: aspectRatio,
       ),
       _aspectRatio = aspectRatio,
       _aspectRatioSet = aspectRatio != null,
       super(CameraValue.uninitialized(description));

  /// The properties of the camera device controlled by this controller.
  CameraDescription get description => value.description;

  /// The resolution this controller is targeting.
  ///
  /// This resolution preset is not guaranteed to be available on the device,
  /// if unavailable a lower resolution will be used.
  ///
  /// See also: [ResolutionPreset].
  ResolutionPreset get resolutionPreset => mediaSettings.resolutionPreset ?? ResolutionPreset.max;

  /// Whether to include audio when recording a video.
  bool get enableAudio => mediaSettings.enableAudio;

  /// The media settings this controller is targeting.
  ///
  /// This media settings are not guaranteed to be available on the device,
  /// if unavailable a [resolutionPreset] default values will be used.
  ///
  /// See also: [MediaSettings].
  final MediaSettings mediaSettings;

  /// The [ImageFormatGroup] describes the output of the raw image format.
  ///
  /// When null the imageFormat will fallback to the platforms default.
  final ImageFormatGroup? imageFormatGroup;

  /// The id of a camera that hasn't been initialized.
  @visibleForTesting
  static const int kUninitializedCameraId = -1;
  int _cameraId = kUninitializedCameraId;

  bool _isDisposed = false;
  StreamSubscription<CameraImageData>? _imageStreamSubscription;

  // Latest effects values applied via [setEffectsValues]. Cached so that
  // they can be re-applied to the native camera after a [setDescription]
  // switch, since each native camera instance starts with no effects.
  EffectsValues? _effectsValues;

  // Aspect ratio to crop to: the one this controller was constructed with,
  // then whatever [setAspectRatio] was last given. Cached so it can be applied
  // before the camera starts producing frames, and again after a
  // [setDescription] camera switch. `_aspectRatioSet` distinguishes "never
  // asked for" from a deliberate `null` (no crop).
  double? _aspectRatio;
  bool _aspectRatioSet;

  // Latest capture scale applied via [setCaptureScale]. Cached so it can be
  // re-applied after a [setDescription] camera switch.
  double? _captureScale;

  // Latest capture corner radius applied via [setCaptureCornerRadius]. Cached
  // so it can be re-applied after a [setDescription] camera switch.
  double? _captureCornerRadius;

  // Latest white balance values applied via [setWhiteBalance]. Cached so they
  // can be re-applied after a [setDescription] camera switch. `_whiteBalanceSet`
  // distinguishes "never called" (let the new camera start in its default
  // auto WB) from a deliberate user choice — including locking to a value
  // or explicitly switching back to auto via `setWhiteBalance(null)`.
  WhiteBalanceValues? _whiteBalanceValues;
  bool _whiteBalanceSet = false;

  StreamSubscription<CameraResolutionChangedEvent>? _resolutionChangedSubscription;

  // Most recent size the platform reported for the preview surface itself, or
  // null if it has not reported one for the current camera yet.
  //
  // This is the surface the texture is actually drawn into, so it accounts for
  // any crop the host applies — an aspect-ratio view port, for instance. The
  // size on [CameraInitializedEvent] is the camera's *uncropped* output, which
  // is only the same thing when nothing is cropping. Whenever both are
  // available this one wins; see where [value] is finalised in [initialize].
  Size? _reportedPreviewSize;

  // Auto-WB events from the platform are filtered by `cameraId`, but
  // `_cameraId` changes on every [setDescription]. Without rebinding, a
  // subscriber that listened before the switch would silently stop receiving
  // events from the new camera. We funnel the per-camera platform stream
  // through this controller-owned broadcast so the public
  // [autoWhiteBalanceValues] getter has a stable identity across switches —
  // subscribers don't need to re-listen — while [_initializeWithDescription]
  // swaps the upstream on every camera (re)create.
  final StreamController<({double temperature, double tint})> _autoWhiteBalanceStreamController =
      StreamController<({double temperature, double tint})>.broadcast();
  StreamSubscription<CameraAutoWhiteBalanceChangedEvent>? _autoWhiteBalanceSubscription;

  // A Future awaiting an attempt to initialize (e.g. after `initialize` was
  // just called). If the controller has not been initialized at least once,
  // this value is null.
  Future<void>? _initializeFuture;
  StreamSubscription<DeviceOrientationChangedEvent>? _deviceOrientationSubscription;

  /// Checks whether [CameraController.dispose] has completed successfully.
  ///
  /// This is a no-op when asserts are disabled.
  void debugCheckIsDisposed() {
    assert(_isDisposed);
  }

  /// The camera identifier with which the controller is associated.
  int get cameraId => _cameraId;

  /// Emits the temperature (Kelvin) and tint values selected by the camera's
  /// auto white balance system. Only emits while the camera is in
  /// [WhiteBalanceMode.auto]. Supported on iOS and Android; some Android
  /// cameras report nothing usable to derive a reading from and never emit.
  ///
  /// The stream identity is stable for the lifetime of the controller, even
  /// across [setDescription] camera switches; subscribers do not need to
  /// re-listen after a switch.
  Stream<({double temperature, double tint})> get autoWhiteBalanceValues =>
      _autoWhiteBalanceStreamController.stream;

  /// Initializes the camera on the device.
  ///
  /// Throws a [CameraException] if the initialization fails.
  Future<void> initialize() => _initializeWithDescription(description);

  /// Initializes the camera on the device with the specified description.
  ///
  /// Throws a [CameraException] if the initialization fails.
  Future<void> _initializeWithDescription(CameraDescription description) async {
    if (_isDisposed) {
      throw CameraException(
        'Disposed CameraController',
        'initialize was called on a disposed CameraController',
      );
    }

    final initializeCompleter = Completer<void>();
    _initializeFuture = initializeCompleter.future;

    try {
      final initializeCompleter = Completer<CameraInitializedEvent>();

      _deviceOrientationSubscription ??= CameraPlatform.instance
          .onDeviceOrientationChanged()
          .listen((DeviceOrientationChangedEvent event) {
            if (!_isDisposed) {
              value = value.copyWith(deviceOrientation: event.orientation);
            }
          });

      _cameraId = await CameraPlatform.instance.createCameraWithSettings(
        description,
        mediaSettings,
      );

      unawaited(
        CameraPlatform.instance.onCameraInitialized(_cameraId).first.then((
          CameraInitializedEvent event,
        ) {
          initializeCompleter.complete(event);
        }),
      );

      unawaited(
        CameraPlatform.instance.onCameraError(_cameraId).first.then((CameraErrorEvent event) {
          if (!_isDisposed) {
            value = value.copyWith(errorDescription: event.description);
          }
        }),
      );

      // Register the resolution-changed listener *before* `initializeCamera`
      // so we don't miss the first `previewSizeChanged` event the host may
      // emit when the renderer is built from the first sample buffer.
      await _resolutionChangedSubscription?.cancel();
      _reportedPreviewSize = null;
      _resolutionChangedSubscription = CameraPlatform.instance
          .onCameraResolutionChanged(_cameraId)
          .listen((CameraResolutionChangedEvent event) {
            final size = Size(event.captureWidth, event.captureHeight);
            _reportedPreviewSize = size;
            value = value.copyWith(previewSize: size);
          });

      // Rebind the auto-WB upstream to the new `_cameraId`. The platform
      // stream filters by camera id, so a subscription bound to the old id
      // would silently stop receiving events after a `setDescription` swap.
      await _autoWhiteBalanceSubscription?.cancel();
      _autoWhiteBalanceSubscription = CameraPlatform.instance
          .onAutoWhiteBalanceChanged(_cameraId)
          .listen((CameraAutoWhiteBalanceChangedEvent event) {
            if (!_autoWhiteBalanceStreamController.isClosed) {
              _autoWhiteBalanceStreamController.add((
                temperature: event.temperature,
                tint: event.tint,
              ));
            }
          });

      // Before `initializeCamera`, not after: these decide what the very first
      // frame looks like, and `initializeCamera` is what starts frames flowing.
      //
      // The aspect ratio is the one that shows. `createCamera` takes its crop
      // from `MediaSettings`, which carries none — the ratio lives here, set
      // through `setAspectRatio` — so a camera built after a `setDescription`
      // lens switch starts uncropped. Applying the ratio afterwards then makes
      // the host rebuild the preview a second time, and the frames in between
      // arrive at the camera's full shape while the preview is still laid out
      // for the old crop: a first frame that looks rotated and stretched before
      // it snaps into place. Setting it first means one build, correct at once.
      //
      // All four only configure the host's render pipeline, which exists from
      // `createCamera`. [setWhiteBalance] stays below because it drives the
      // camera's control, which does not exist until the use cases are bound.
      if (_effectsValues != null) {
        await CameraPlatform.instance.setEffectsValues(_cameraId, _effectsValues!);
      }

      // Skipped when the ratio already travelled in [mediaSettings], which
      // `createCamera` applies: the camera was built with it, and sending it
      // again would only ask the host to re-check a crop it already has.
      if (_aspectRatioSet && _aspectRatio != mediaSettings.aspectRatio) {
        await CameraPlatform.instance.setAspectRatio(_cameraId, _aspectRatio);
      }

      if (_captureScale != null) {
        await CameraPlatform.instance.setCaptureScale(_cameraId, _captureScale!);
      }

      if (_captureCornerRadius != null) {
        await CameraPlatform.instance.setCaptureCornerRadius(_cameraId, _captureCornerRadius!);
      }

      await CameraPlatform.instance.initializeCamera(
        _cameraId,
        imageFormatGroup: imageFormatGroup ?? ImageFormatGroup.unknown,
      );

      if (_whiteBalanceSet) {
        await CameraPlatform.instance.setWhiteBalance(_cameraId, _whiteBalanceValues);
      }

      final CameraInitializedEvent event = await initializeCompleter.future;

      // The controller may be disposed while awaiting initialization above.
      if (!_isDisposed) {
        value = value.copyWith(
          isInitialized: true,
          description: description,
          // A size the platform reported for the preview surface takes precedence
          // over the one on `CameraInitializedEvent`. The latter is the camera's
          // uncropped output, so overwriting with it here would undo a crop the
          // host had already told us about during `initializeCamera` — and leave
          // the preview laid out to one shape while the texture carries another,
          // until something else happened to make the host report again.
          previewSize: _reportedPreviewSize ?? Size(event.previewWidth, event.previewHeight),
          exposureMode: event.exposureMode,
          focusMode: event.focusMode,
          exposurePointSupported: event.exposurePointSupported,
          focusPointSupported: event.focusPointSupported,
        );
      }
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    } finally {
      initializeCompleter.complete();
    }
  }

  /// Prepare the capture session for video recording.
  ///
  /// Use of this method is optional, but it may be called for performance
  /// reasons on iOS.
  ///
  /// Preparing audio can cause a minor delay in the CameraPreview view on iOS.
  /// If video recording is intended, calling this early eliminates this delay
  /// that would otherwise be experienced when video recording is started.
  /// This operation is a no-op on Android and Web.
  ///
  /// Throws a [CameraException] if the prepare fails.
  Future<void> prepareForVideoRecording() async {
    await CameraPlatform.instance.prepareForVideoRecording();
  }

  /// Pauses the current camera preview
  Future<void> pausePreview() async {
    if (value.isPreviewPaused || !value.isInitialized || _isDisposed) {
      return;
    }
    try {
      await CameraPlatform.instance.pausePreview(_cameraId);
      value = value.copyWith(
        isPreviewPaused: true,
        previewPauseOrientation: Optional<DeviceOrientation>.of(
          value.lockedCaptureOrientation ?? value.deviceOrientation,
        ),
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Resumes the current camera preview
  Future<void> resumePreview() async {
    if (!value.isPreviewPaused) {
      return;
    }
    try {
      await CameraPlatform.instance.resumePreview(_cameraId);
      value = value.copyWith(
        isPreviewPaused: false,
        previewPauseOrientation: const Optional<DeviceOrientation>.absent(),
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Sets the description of the camera.
  ///
  /// On Android, you must start the recording with [startVideoRecording]
  /// with `enablePersistentRecording` set to `true`
  /// to avoid cancelling any active recording.
  ///
  /// Throws a [CameraException] if setting the description fails.
  Future<void> setDescription(CameraDescription description) async {
    if (value.isRecordingVideo) {
      await CameraPlatform.instance.setDescriptionWhileRecording(description);
      value = value.copyWith(description: description);
    } else {
      if (_initializeFuture != null) {
        await _initializeFuture;
        await CameraPlatform.instance.dispose(_cameraId);
      }

      await _initializeWithDescription(description);
    }
  }

  /// Captures an image and returns the file where it was saved.
  ///
  /// Throws a [CameraException] if the capture fails.
  Future<XFile> takePicture() async {
    _throwIfNotInitialized('takePicture');
    if (value.isTakingPicture) {
      throw CameraException(
        'Previous capture has not returned yet.',
        'takePicture was called before the previous capture returned.',
      );
    }
    value = value.copyWith(isTakingPicture: true);
    try {
      return await CameraPlatform.instance.takePicture(_cameraId);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    } finally {
      value = value.copyWith(isTakingPicture: false);
    }
  }

  /// Captures an image and returns two files for the same shutter event: the
  /// un-effected `original` and the `processed` photo with any platform
  /// effects applied (equivalent to [takePicture]).
  ///
  /// On platforms with no effects pipeline, both files contain identical
  /// bytes.
  ///
  /// Throws a [CameraException] if the capture fails.
  Future<(XFile original, XFile processed)> takePictureWithOriginal() async {
    _throwIfNotInitialized('takePictureWithOriginal');
    if (value.isTakingPicture) {
      throw CameraException(
        'Previous capture has not returned yet.',
        'takePictureWithOriginal was called before the previous capture '
            'returned.',
      );
    }
    value = value.copyWith(isTakingPicture: true);
    try {
      return await CameraPlatform.instance.takePictureWithOriginal(_cameraId);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    } finally {
      value = value.copyWith(isTakingPicture: false);
    }
  }

  /// Start streaming images from platform camera.
  ///
  /// Settings for capturing images on iOS and Android is set to always use the
  /// latest image available from the camera and will drop all other images.
  ///
  /// When running continuously with [CameraPreview] widget, this function runs
  /// best with [ResolutionPreset.low]. Running on [ResolutionPreset.high] can
  /// have significant frame rate drops for [CameraPreview] on lower end
  /// devices.
  ///
  /// Throws a [CameraException] if image streaming or video recording has
  /// already started.
  ///
  /// The `startImageStream` method is only available on platforms that
  /// report support for image streaming via [supportsImageStreaming].
  ///
  // TODO(bmparr): Add settings for resolution and fps.
  Future<void> startImageStream(onLatestImageAvailable onAvailable) async {
    assert(supportsImageStreaming());
    _throwIfNotInitialized('startImageStream');
    if (value.isRecordingVideo) {
      throw CameraException(
        'A video recording is already started.',
        'startImageStream was called while a video is being recorded.',
      );
    }
    if (value.isStreamingImages) {
      throw CameraException(
        'A camera has started streaming images.',
        'startImageStream was called while a camera was streaming images.',
      );
    }

    try {
      _imageStreamSubscription = CameraPlatform.instance.onStreamedFrameAvailable(_cameraId).listen(
        (CameraImageData imageData) {
          onAvailable(CameraImage.fromPlatformInterface(imageData));
        },
      );
      value = value.copyWith(isStreamingImages: true);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Stop streaming images from platform camera.
  ///
  /// Throws a [CameraException] if image streaming was not started or video
  /// recording was started.
  ///
  /// The `stopImageStream` method is only available on platforms that
  /// report support for image streaming via [supportsImageStreaming].
  Future<void> stopImageStream() async {
    assert(supportsImageStreaming());
    _throwIfNotInitialized('stopImageStream');
    if (!value.isStreamingImages) {
      throw CameraException(
        'No camera is streaming images',
        'stopImageStream was called when no camera is streaming images.',
      );
    }

    try {
      value = value.copyWith(isStreamingImages: false);
      await _imageStreamSubscription?.cancel();
      _imageStreamSubscription = null;
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Start a video recording.
  ///
  /// You may optionally pass an [onAvailable] callback to also have the
  /// video frames streamed to this callback.
  ///
  /// The video is returned as a [XFile] after calling [stopVideoRecording].
  /// Throws a [CameraException] if the capture fails.
  ///
  /// `enablePersistentRecording` parameter configures the recording to be a persistent recording.
  /// A persistent recording can only be stopped by explicitly calling [stopVideoRecording]
  /// and will ignore events that would normally cause recording to stop,
  /// such as lifecycle events or explicit calls to [setDescription] while recording is in progress.
  /// Currently a no-op on platforms other than Android.
  Future<void> startVideoRecording({
    onLatestImageAvailable? onAvailable,
    bool enablePersistentRecording = true,
  }) async {
    _throwIfNotInitialized('startVideoRecording');
    if (value.isRecordingVideo) {
      throw CameraException(
        'A video recording is already started.',
        'startVideoRecording was called when a recording is already started.',
      );
    }

    void Function(CameraImageData image)? streamCallback;
    if (onAvailable != null) {
      streamCallback = (CameraImageData imageData) {
        onAvailable(CameraImage.fromPlatformInterface(imageData));
      };
    }

    try {
      await CameraPlatform.instance.startVideoCapturing(
        VideoCaptureOptions(
          _cameraId,
          streamCallback: streamCallback,
          enablePersistentRecording: enablePersistentRecording,
        ),
      );
      value = value.copyWith(
        isRecordingVideo: true,
        isRecordingPaused: false,
        recordingOrientation: Optional<DeviceOrientation>.of(
          value.lockedCaptureOrientation ?? value.deviceOrientation,
        ),
        isStreamingImages: onAvailable != null,
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Stops the video recording and returns the file where it was saved.
  ///
  /// Throws a [CameraException] if the capture failed.
  Future<XFile> stopVideoRecording() async {
    _throwIfNotInitialized('stopVideoRecording');
    if (!value.isRecordingVideo) {
      throw CameraException(
        'No video is recording',
        'stopVideoRecording was called when no video is recording.',
      );
    }

    if (value.isStreamingImages) {
      await stopImageStream();
    }

    try {
      final XFile file = await CameraPlatform.instance.stopVideoRecording(_cameraId);
      value = value.copyWith(
        isRecordingVideo: false,
        recordingOrientation: const Optional<DeviceOrientation>.absent(),
      );
      return file;
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Pause video recording.
  ///
  /// This feature is only available on iOS and Android sdk 24+.
  Future<void> pauseVideoRecording() async {
    _throwIfNotInitialized('pauseVideoRecording');
    if (!value.isRecordingVideo) {
      throw CameraException(
        'No video is recording',
        'pauseVideoRecording was called when no video is recording.',
      );
    }
    try {
      await CameraPlatform.instance.pauseVideoRecording(_cameraId);
      value = value.copyWith(isRecordingPaused: true);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Resume video recording after pausing.
  ///
  /// This feature is only available on iOS and Android sdk 24+.
  Future<void> resumeVideoRecording() async {
    _throwIfNotInitialized('resumeVideoRecording');
    if (!value.isRecordingVideo) {
      throw CameraException(
        'No video is recording',
        'resumeVideoRecording was called when no video is recording.',
      );
    }
    try {
      await CameraPlatform.instance.resumeVideoRecording(_cameraId);
      value = value.copyWith(isRecordingPaused: false);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Returns a widget showing a live camera preview.
  Widget buildPreview() {
    _throwIfNotInitialized('buildPreview');
    try {
      return CameraPlatform.instance.buildPreview(_cameraId);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Gets the maximum supported zoom level for the selected camera.
  Future<double> getMaxZoomLevel() {
    _throwIfNotInitialized('getMaxZoomLevel');
    try {
      return CameraPlatform.instance.getMaxZoomLevel(_cameraId);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Gets the minimum supported zoom level for the selected camera.
  Future<double> getMinZoomLevel() {
    _throwIfNotInitialized('getMinZoomLevel');
    try {
      return CameraPlatform.instance.getMinZoomLevel(_cameraId);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Set the zoom level for the selected camera.
  ///
  /// The supplied [zoom] value should be between 1.0 and the maximum supported
  /// zoom level returned by the `getMaxZoomLevel`. Throws an `CameraException`
  /// when an illegal zoom level is suplied.
  Future<void> setZoomLevel(double zoom) {
    _throwIfNotInitialized('setZoomLevel');
    try {
      return CameraPlatform.instance.setZoomLevel(_cameraId, zoom);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Set the video stabilization mode for the selected camera.
  ///
  /// When [allowFallback] is true (default) the camera will be set to the best
  /// video stabilization mode up to, and including, [mode].
  ///
  /// When [allowFallback] is false and if [mode] is not one of the supported
  /// modes (see [getSupportedVideoStabilizationModes]), then it throws an
  /// [ArgumentError].
  ///
  /// This feature is only available if [getSupportedVideoStabilizationModes]
  /// returns at least one value other than [VideoStabilizationMode.off].
  Future<void> setVideoStabilizationMode(
    VideoStabilizationMode mode, {
    bool allowFallback = true,
  }) async {
    _throwIfNotInitialized('setVideoStabilizationMode');
    try {
      final VideoStabilizationMode? modeToSet = await _getVideoStabilizationModeToSet(
        mode,
        allowFallback,
      );

      // When _getVideoStabilizationModeToSet returns null
      // it means that the device doesn't support any
      // video stabilization mode and that doing nothing
      // is valid because allowFallback is true or [mode]
      // is [VideoStabilizationMode.off], so this results
      // in a no-op.
      if (modeToSet == null) {
        return;
      }
      await CameraPlatform.instance.setVideoStabilizationMode(_cameraId, modeToSet);
      value = value.copyWith(videoStabilizationMode: modeToSet);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  Future<VideoStabilizationMode?> _getVideoStabilizationModeToSet(
    VideoStabilizationMode requestedMode,
    bool allowFallback,
  ) async {
    final Iterable<VideoStabilizationMode> supportedModes = await CameraPlatform.instance
        .getSupportedVideoStabilizationModes(_cameraId);

    // If it can't fallback and the specific
    // requested mode isn't available, then...
    if (!allowFallback && !supportedModes.contains(requestedMode)) {
      // if the request is off, it is a no-op
      if (requestedMode == VideoStabilizationMode.off) {
        return null;
      }
      // otherwise, it throws.
      throw ArgumentError('Unavailable video stabilization mode.', 'mode');
    }

    VideoStabilizationMode? fallbackMode = requestedMode;
    while (fallbackMode != null && !supportedModes.contains(fallbackMode)) {
      fallbackMode = CameraPlatform.getFallbackVideoStabilizationMode(fallbackMode);
    }

    return fallbackMode;
  }

  /// Gets a list of video stabilization modes that are supported
  /// for the selected camera.
  ///
  /// [VideoStabilizationMode.off] will always be listed.
  Future<Iterable<VideoStabilizationMode>> getSupportedVideoStabilizationModes() async {
    _throwIfNotInitialized('getSupportedVideoStabilizationModes');
    try {
      final modes = <VideoStabilizationMode>{
        VideoStabilizationMode.off,
        ...await CameraPlatform.instance.getSupportedVideoStabilizationModes(_cameraId),
      };
      return modes;
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Sets the flash mode for taking pictures.
  Future<void> setFlashMode(FlashMode mode) async {
    try {
      await CameraPlatform.instance.setFlashMode(_cameraId, mode);
      value = value.copyWith(flashMode: mode);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Gets the [FlashMode]s that are supported for this camera.
  ///
  /// Currently only implemented on iOS; other platforms return an empty list.
  Future<Iterable<FlashMode>> getSupportedFlashModes() async {
    _throwIfNotInitialized('getSupportedFlashModes');
    try {
      return CameraPlatform.instance.getSupportedFlashModes(_cameraId);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Sets the exposure mode for taking pictures.
  Future<void> setExposureMode(ExposureMode mode) async {
    try {
      await CameraPlatform.instance.setExposureMode(_cameraId, mode);
      value = value.copyWith(exposureMode: mode);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Sets the exposure point for automatically determining the exposure value.
  ///
  /// Supplying a `null` value will reset the exposure point to it's default
  /// value.
  Future<void> setExposurePoint(Offset? point) async {
    if (point != null && (point.dx < 0 || point.dx > 1 || point.dy < 0 || point.dy > 1)) {
      throw ArgumentError('The values of point should be anywhere between (0,0) and (1,1).');
    }

    try {
      await CameraPlatform.instance.setExposurePoint(
        _cameraId,
        point == null ? null : Point<double>(point.dx, point.dy),
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Gets the minimum supported exposure offset for the selected camera in EV units.
  Future<double> getMinExposureOffset() async {
    _throwIfNotInitialized('getMinExposureOffset');
    try {
      return await CameraPlatform.instance.getMinExposureOffset(_cameraId);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Gets the maximum supported exposure offset for the selected camera in EV units.
  Future<double> getMaxExposureOffset() async {
    _throwIfNotInitialized('getMaxExposureOffset');
    try {
      return await CameraPlatform.instance.getMaxExposureOffset(_cameraId);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Gets the supported step size for exposure offset for the selected camera in EV units.
  ///
  /// Returns 0 when the camera supports using a free value without stepping.
  Future<double> getExposureOffsetStepSize() async {
    _throwIfNotInitialized('getExposureOffsetStepSize');
    try {
      return await CameraPlatform.instance.getExposureOffsetStepSize(_cameraId);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Sets the exposure offset for the selected camera.
  ///
  /// The supplied [offset] value should be in EV units. 1 EV unit represents a
  /// doubling in brightness. It should be between the minimum and maximum offsets
  /// obtained through `getMinExposureOffset` and `getMaxExposureOffset` respectively.
  /// Throws a `CameraException` when an illegal offset is supplied.
  ///
  /// When the supplied [offset] value does not align with the step size obtained
  /// through `getExposureStepSize`, it will automatically be rounded to the nearest step.
  ///
  /// Returns the (rounded) offset value that was set.
  Future<double> setExposureOffset(double offset) async {
    _throwIfNotInitialized('setExposureOffset');
    // Check if offset is in range
    final List<double> range = await Future.wait(<Future<double>>[
      getMinExposureOffset(),
      getMaxExposureOffset(),
    ]);
    if (offset < range[0] || offset > range[1]) {
      throw CameraException(
        'exposureOffsetOutOfBounds',
        'The provided exposure offset was outside the supported range for this device.',
      );
    }

    // Round to the closest step if needed
    final double stepSize = await getExposureOffsetStepSize();
    if (stepSize > 0) {
      final double inv = 1.0 / stepSize;
      double roundedOffset = (offset * inv).roundToDouble() / inv;
      if (roundedOffset > range[1]) {
        roundedOffset = (offset * inv).floorToDouble() / inv;
      } else if (roundedOffset < range[0]) {
        roundedOffset = (offset * inv).ceilToDouble() / inv;
      }
      offset = roundedOffset;
    }

    try {
      return await CameraPlatform.instance.setExposureOffset(_cameraId, offset);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Locks the capture orientation.
  ///
  /// If [orientation] is omitted, the current device orientation is used.
  Future<void> lockCaptureOrientation([DeviceOrientation? orientation]) async {
    try {
      await CameraPlatform.instance.lockCaptureOrientation(
        _cameraId,
        orientation ?? value.deviceOrientation,
      );
      value = value.copyWith(
        lockedCaptureOrientation: Optional<DeviceOrientation>.of(
          orientation ?? value.deviceOrientation,
        ),
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Sets the focus mode for taking pictures.
  Future<void> setFocusMode(FocusMode mode) async {
    try {
      await CameraPlatform.instance.setFocusMode(_cameraId, mode);
      value = value.copyWith(focusMode: mode);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Sets the white balance for the camera.
  ///
  /// Pass `null` to enable automatic white balance. Pass a
  /// [WhiteBalanceValues] to lock the white balance at the given temperature
  /// and tint. Supported on iOS, and on Android cameras that report
  /// [supportsWhiteBalance].
  ///
  /// The value is cached and re-applied automatically after a
  /// [setDescription] camera switch — but this re-application is
  /// **best-effort**. If the new sensor doesn't support the previously
  /// configured mode (e.g. switching to a lens whose hardware can't lock
  /// white balance), the failure is reported as a non-fatal platform error
  /// and the new camera starts in its default mode; the camera switch
  /// itself still succeeds.
  Future<void> setWhiteBalance(WhiteBalanceValues? values) async {
    _throwIfNotInitialized('setWhiteBalance');
    // `_whiteBalanceValues`/`_whiteBalanceSet` record what was asked for regardless of whether the
    // camera accepts it, so a later `setDescription` switch to hardware that does support it still
    // gets the request — see the fields' doc comment. `value.whiteBalanceValues`, in contrast, is
    // only updated once the request is confirmed, so it never claims a lock the camera rejected.
    _whiteBalanceValues = values;
    _whiteBalanceSet = true;
    await CameraPlatform.instance.setWhiteBalance(_cameraId, values);
    value = value.copyWith(whiteBalanceValues: Optional<WhiteBalanceValues>.fromNullable(values));
  }

  /// Whether this camera can lock its white balance to a chosen temperature and
  /// tint via [setWhiteBalance].
  ///
  /// Not every camera can: on Android in particular, a sensor may run its own
  /// auto white balance with no way to override it, and platforms that do not
  /// implement white balance at all report `false`. Hide or disable any white
  /// balance UI when this is `false` — [setWhiteBalance] would fail with a
  /// `setWhiteBalanceFailed` [CameraException].
  ///
  /// Answered per camera, so it must be asked again after a [setDescription]
  /// switch: the front and back lenses of one device can differ.
  Future<bool> supportsWhiteBalance() async {
    _throwIfNotInitialized('supportsWhiteBalance');
    try {
      return await CameraPlatform.instance.supportsWhiteBalance(_cameraId);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Unlocks the capture orientation.
  Future<void> unlockCaptureOrientation() async {
    try {
      await CameraPlatform.instance.unlockCaptureOrientation(_cameraId);
      value = value.copyWith(lockedCaptureOrientation: const Optional<DeviceOrientation>.absent());
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Sets the focus point for automatically determining the focus value.
  ///
  /// Supplying a `null` value will reset the focus point to it's default
  /// value.
  Future<void> setFocusPoint(Offset? point) async {
    if (point != null && (point.dx < 0 || point.dx > 1 || point.dy < 0 || point.dy > 1)) {
      throw ArgumentError('The values of point should be anywhere between (0,0) and (1,1).');
    }
    try {
      await CameraPlatform.instance.setFocusPoint(
        _cameraId,
        point == null ? null : Point<double>(point.dx, point.dy),
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Sets the JPEG compression quality for still image capture.
  ///
  /// This only applies to images captured in JPEG format.
  /// The [quality] must be between 1 (lowest) and 100 (highest).
  ///
  /// This is a best-effort setting: platforms that do not support controlling
  /// the JPEG quality ignore it rather than throwing. See
  /// https://github.com/flutter/flutter/issues/191790 for the current state of
  /// platform support.
  Future<void> setJpegImageQuality(int quality) async {
    if (quality < 1 || quality > 100) {
      throw ArgumentError.value(quality, 'quality', 'Must be between 1 and 100.');
    }
    try {
      await CameraPlatform.instance.setJpegImageQuality(_cameraId, quality);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Sets the values of the camera's effects.
  ///
  /// The values are cached and re-applied automatically after a
  /// [setDescription] camera switch, so callers do not need to push them
  /// again on every switch.
  Future<void> setEffectsValues(EffectsValues values) async {
    _effectsValues = values;
    await CameraPlatform.instance.setEffectsValues(_cameraId, values);
  }

  /// Sets the aspect ratio (width/height) applied (as a center-crop) to
  /// preview, photo, and video output. Pass `null` to disable cropping.
  ///
  /// The value is cached and re-applied automatically after a
  /// [setDescription] camera switch.
  Future<void> setAspectRatio(double? aspectRatio) async {
    _aspectRatio = aspectRatio;
    _aspectRatioSet = true;
    await CameraPlatform.instance.setAspectRatio(_cameraId, aspectRatio);
  }

  /// Sets the capture scale applied inside the aspect-ratio crop.
  ///
  /// `1.0` means no extra crop. Smaller values further narrow the captured
  /// area; the preview keeps the full aspect-ratio framing with the outside
  /// darkened, while saved photo and video files contain only the scaled
  /// rectangle. Values are clamped to the supported `[0.1, 1.0]` range
  /// before being applied — values below `0.1` would shrink the capture
  /// rectangle to a degenerate size.
  ///
  /// `scale` must be a finite (non-NaN, non-infinite) number; a
  /// non-finite value throws [ArgumentError].
  ///
  /// On iOS, calling this while a video is recording stashes the value; it
  /// takes effect on the next recording, since the AVAssetWriter is locked
  /// to the renderer's dimensions for the duration of a take and the scale
  /// cannot change mid-recording without corrupting the file. On Android the
  /// change applies immediately, including to a recording already in
  /// progress.
  ///
  /// The value is cached and re-applied automatically after a
  /// [setDescription] camera switch.
  Future<void> setCaptureScale(double scale) async {
    if (scale.isNaN || scale.isInfinite) {
      throw ArgumentError.value(scale, 'scale', 'scale must be a finite number');
    }
    final double clamped = scale.clamp(0.1, 1.0);
    await CameraPlatform.instance.setCaptureScale(_cameraId, clamped);
    _captureScale = clamped;
    value = value.copyWith(captureScale: clamped);
  }

  /// Sets the corner radius of the [CameraValue.captureScale] preview
  /// rectangle.
  ///
  /// [radius] must be in the range `[0.0, 1.0]`. `0.0` (default) produces
  /// sharp corners; larger values progressively round the corners of the
  /// darkened border visible in the preview. Saved photos and videos are
  /// unaffected.
  ///
  /// The value is cached and re-applied automatically after a
  /// [setDescription] camera switch.
  Future<void> setCaptureCornerRadius(double radius) async {
    if (radius.isNaN || radius.isInfinite) {
      throw ArgumentError.value(radius, 'radius', 'radius must be a finite number');
    }
    final double clamped = radius.clamp(0.0, 1.0);
    await CameraPlatform.instance.setCaptureCornerRadius(_cameraId, clamped);
    _captureCornerRadius = clamped;
    value = value.copyWith(captureCornerRadius: clamped);
  }

  /// Check whether the camera platform supports image streaming.
  bool supportsImageStreaming() => CameraPlatform.instance.supportsImageStreaming();

  /// Releases the resources of this camera.
  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    unawaited(_deviceOrientationSubscription?.cancel());
    unawaited(_resolutionChangedSubscription?.cancel());
    unawaited(_autoWhiteBalanceSubscription?.cancel());
    unawaited(_autoWhiteBalanceStreamController.close());
    _isDisposed = true;
    super.dispose();
    if (_initializeFuture != null) {
      await _initializeFuture;
      await CameraPlatform.instance.dispose(_cameraId);
    }
  }

  void _throwIfNotInitialized(String functionName) {
    if (!value.isInitialized) {
      throw CameraException(
        'Uninitialized CameraController',
        '$functionName() was called on an uninitialized CameraController.',
      );
    }
    if (_isDisposed) {
      throw CameraException(
        'Disposed CameraController',
        '$functionName() was called on a disposed CameraController.',
      );
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    // Prevent ValueListenableBuilder in CameraPreview widget from causing an
    // exception to be thrown by attempting to remove its own listener after
    // the controller has already been disposed.
    if (!_isDisposed) {
      super.removeListener(listener);
    }
  }
}

/// A value that might be absent.
///
/// Used to represent [DeviceOrientation]s that are optional but also able
/// to be cleared.
@immutable
class Optional<T> extends IterableBase<T> {
  /// Constructs an empty Optional.
  const Optional.absent() : _value = null;

  /// Constructs an Optional of the given [value].
  const Optional.of(T value) : _value = value;

  /// Constructs an Optional of the given [value].
  ///
  /// If [value] is null, returns [absent()].
  const Optional.fromNullable(T? value) : _value = value;

  final T? _value;

  /// True when this optional contains a value.
  bool get isPresent => _value != null;

  /// True when this optional contains no value.
  bool get isNotPresent => _value == null;

  /// Gets the Optional value.
  ///
  /// Throws [StateError] if [value] is null.
  T get value {
    if (_value == null) {
      throw StateError('value called on absent Optional.');
    }
    return _value;
  }

  /// Executes a function if the Optional value is present.
  void ifPresent(void Function(T value) ifPresent) {
    if (isPresent) {
      ifPresent(_value as T);
    }
  }

  /// Execution a function if the Optional value is absent.
  void ifAbsent(void Function() ifAbsent) {
    if (!isPresent) {
      ifAbsent();
    }
  }

  /// Gets the Optional value with a default.
  ///
  /// The default is returned if the Optional is [absent()].
  ///
  /// Throws [ArgumentError] if [defaultValue] is null.
  T or(T defaultValue) {
    return _value ?? defaultValue;
  }

  /// Gets the Optional value, or `null` if there is none.
  T? get orNull => _value;

  /// Transforms the Optional value.
  ///
  /// If the Optional is [absent()], returns [absent()] without applying the transformer.
  ///
  /// The transformer must not return `null`. If it does, an [ArgumentError] is thrown.
  Optional<S> transform<S>(S Function(T value) transformer) {
    return _value == null ? Optional<S>.absent() : Optional<S>.of(transformer(_value));
  }

  /// Transforms the Optional value.
  ///
  /// If the Optional is [absent()], returns [absent()] without applying the transformer.
  ///
  /// Returns [absent()] if the transformer returns `null`.
  Optional<S> transformNullable<S>(S? Function(T value) transformer) {
    return _value == null ? Optional<S>.absent() : Optional<S>.fromNullable(transformer(_value));
  }

  @override
  Iterator<T> get iterator => isPresent ? <T>[_value as T].iterator : Iterable<T>.empty().iterator;

  /// Delegates to the underlying [value] hashCode.
  @override
  int get hashCode => _value.hashCode;

  /// Delegates to the underlying [value] operator==.
  @override
  bool operator ==(Object o) => o is Optional<T> && o._value == _value;

  @override
  String toString() {
    return _value == null ? 'Optional { absent }' : 'Optional { value: $_value }';
  }
}
