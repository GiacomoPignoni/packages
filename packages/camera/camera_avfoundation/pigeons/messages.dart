// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    swiftOut: 'ios/camera_avfoundation/Sources/camera_avfoundation/Messages.swift',
    copyrightHeader: 'pigeons/copyright.txt',
  ),
)
// Pigeon version of GrainBehavior.
enum PlatformGrainBehavior {
  overlay,
  darkOnly,
}

// Pigeon version of CameraLensDirection.
enum PlatformCameraLensDirection {
  /// Front facing camera (a user looking at the screen is seen by the camera).
  front,

  /// Back facing camera (a user looking at the screen is not seen by the camera).
  back,

  /// External camera which may not be mounted to the device.
  external,
}

// Pigeon version of CameraLensDirection.
enum PlatformCameraLensType {
  /// A built-in wide-angle camera device type.
  wide,

  /// A built-in camera device type with a longer focal length than a wide-angle camera.
  telephoto,

  /// A built-in camera device type with a shorter focal length than a wide-angle camera.
  ultraWide,

  /// Unknown camera device type.
  unknown,
}

// Pigeon version of DeviceOrientation.
enum PlatformDeviceOrientation { portraitUp, landscapeLeft, portraitDown, landscapeRight }

// Pigeon version of ExposureMode.
enum PlatformExposureMode { auto, locked }

// Pigeon version of FlashMode.
enum PlatformFlashMode { off, auto, always, torch }

// Pigeon version of FocusMode.
enum PlatformFocusMode { auto, locked }

/// Pigeon version of ImageFileFormat.
enum PlatformImageFileFormat { jpeg, heif }

// Pigeon version of the subset of ImageFormatGroup supported on iOS.
enum PlatformImageFormatGroup { bgra8888, yuv420 }

// Pigeon version of ResolutionPreset.
enum PlatformResolutionPreset {
  low,
  medium,
  high,
  veryHigh,
  ultraHigh,
  max,
  /// Maps to `AVCaptureSession.Preset.photo` — full-sensor stills at the
  /// cost of a reduced video stream. See `ResolutionPreset.photo`.
  photo,
}

enum PlatformVideoStabilizationMode { off, standard, cinematic, cinematicExtended }

// Pigeon version of CameraDescription.
class PlatformCameraDescription {
  PlatformCameraDescription({
    required this.name,
    required this.lensDirection,
    required this.lensType,
    this.equivalentFocalLength,
  });

  /// The name of the camera device.
  final String name;

  /// The direction the camera is facing.
  final PlatformCameraLensDirection lensDirection;

  /// The type of the camera lens.
  final PlatformCameraLensType lensType;

  /// The approximate 35mm-equivalent focal length of the lens, in millimetres.
  ///
  /// Only populated on iOS (AVFoundation). Null on other platforms.
  final double? equivalentFocalLength;
}

// Pigeon version of the data needed for a CameraInitializedEvent.
class PlatformCameraState {
  PlatformCameraState({
    required this.previewSize,
    required this.exposureMode,
    required this.focusMode,
    required this.exposurePointSupported,
    required this.focusPointSupported,
  });

  /// The size of the preview, in pixels.
  final PlatformSize previewSize;

  /// The default exposure mode
  final PlatformExposureMode exposureMode;

  /// The default focus mode
  final PlatformFocusMode focusMode;

  /// Whether setting exposure points is supported.
  final bool exposurePointSupported;

  /// Whether setting focus points is supported.
  final bool focusPointSupported;
}

// Pigeon version of the data needed for a CameraImageData.
class PlatformCameraImageData {
  PlatformCameraImageData({
    required this.formatCode,
    required this.width,
    required this.height,
    required this.planes,
    required this.lensAperture,
    required this.sensorExposureTimeNanoseconds,
    required this.sensorSensitivity,
  });

  /// The FourCharCode of the image format.
  final int formatCode;

  final int width;
  final int height;
  final List<PlatformCameraImagePlane> planes;
  final double lensAperture;
  final int sensorExposureTimeNanoseconds;
  final double sensorSensitivity;
}

// Pigeon version of the data needed for a CameraImagePlane.
class PlatformCameraImagePlane {
  const PlatformCameraImagePlane({
    required this.bytes,
    required this.bytesPerRow,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int bytesPerRow;
  final int width;
  final int height;
}

// Pigeon version of to MediaSettings.
class PlatformMediaSettings {
  PlatformMediaSettings({
    required this.resolutionPreset,
    required this.framesPerSecond,
    required this.videoBitrate,
    required this.audioBitrate,
    required this.enableAudio,
    required this.aspectRatio,
  });

  final PlatformResolutionPreset resolutionPreset;
  final int? framesPerSecond;
  final int? videoBitrate;
  final int? audioBitrate;
  final bool enableAudio;

  /// Aspect ratio (width/height) that center-crops preview, photo, and video
  /// output. `null` means no crop. Only takes effect when the shader pipeline
  /// is enabled.
  final double? aspectRatio;
}

// Pigeon equivalent of CGPoint.
class PlatformPoint {
  PlatformPoint({required this.x, required this.y});

  final double x;
  final double y;
}

// Pigeon equivalent of CGSize.
class PlatformSize {
  PlatformSize({required this.width, required this.height});

  final double width;
  final double height;
}

// Visual effect parameters forwarded to the Metal shader pipeline.
class PlatformEffectsValues {
  PlatformEffectsValues({
    required this.vignetteIntensity,
    this.grainNoisePath,
    required this.grainOpacity,
    required this.grainSize,
    required this.grainBehavior,
    this.lutFilePath,
    required this.lutIntensity,
    required this.resolution,
    required this.colorShift,
    required this.mist,
    required this.prism,
    required this.cheapFisheye,
    required this.bloom,
    required this.diffusion,
  });

  /// Radial darkening toward the frame edges (0.0 = off, 1.0 = full vignette).
  final double vignetteIntensity;

  /// Absolute file path to the grain/noise source image.
  /// Null disables the grain effect.
  final String? grainNoisePath;

  /// Opacity of the grain overlay (0.0 = off, 1.0 = fully applied).
  final double grainOpacity;

  /// Resolution-independent grain tile size (>= 0.0).
  /// 1.0 = grain image spans the full frame; smaller values tile more finely; bigger values tile more coarsely.
  final double grainSize;

  /// Controls where grain is visible across the tonal range.
  final PlatformGrainBehavior grainBehavior;

  /// Absolute file path to a 3D LUT color-grade image: a 512×512 PNG storing
  /// a 64×64×64 cube as an 8×8 row-major grid of 64×64 tiles (tile index =
  /// blue slice; within a tile x = red, y = green top-to-bottom).
  /// Null disables the LUT color filter.
  final String? lutFilePath;

  /// Intensity of the LUT color filter (0.0 = no effect, 1.0 = full LUT).
  /// Ignored when [lutFilePath] is null.
  final double lutIntensity;

  /// Simulates a low-resolution sensor (0.0 = off, 1.0 = full strength).
  /// Adds a soft Gaussian blur and desaturation.
  final double resolution;

  /// Chromatic aberration strength (0.0 = off, 1.0 = full strength).
  final double colorShift;

  /// Dreamy mist / Orton-style soft glow (0.0 = off, 1.0 = full strength).
  final double mist;

  /// Radial chromatic motion blur (0.0 = off, 1.0 = full strength).
  final double prism;

  /// Cheap clip-on fisheye lens simulation (true = on).
  final bool cheapFisheye;

  /// Highlight bloom / light-bleed glow (0.0 = off, 1.0 = full strength).
  final double bloom;

  /// Diffusion / soft-focus filter (0.0 = off, 1.0 = full strength).
  /// Mixes the frame toward a wide Gaussian blur of itself.
  final double diffusion;
}

/// Paths to the two photo files produced by [CameraApi.takePictureWithOriginal].
class PlatformCapturedPicturePaths {
  PlatformCapturedPicturePaths({
    required this.originalPath,
    required this.processedPath,
  });

  /// File path of the un-effected original. The configured `captureScale` crop
  /// and resampling is preserved, but the custom Metal shader is not applied.
  final String originalPath;

  /// File path of the shader-processed photo (equivalent to
  /// [CameraApi.takePicture]).
  final String processedPath;
}

/// Pigeon version of WhiteBalanceValues.
class PlatformWhiteBalanceValues {
  PlatformWhiteBalanceValues({required this.temperature, required this.tint});

  /// The color temperature in Kelvin.
  final double temperature;

  /// The tint offset, where `0` is neutral.
  final double tint;
}

@HostApi()
abstract class CameraApi {
  /// Returns the list of available cameras.
  @async
  @ObjCSelector('availableCamerasWithCompletion')
  List<PlatformCameraDescription> getAvailableCameras();

  /// Create a new camera with the given settings, and returns its ID.
  /// Every preview frame, recorded video frame, and captured photo is
  /// rendered through the bundled Metal shader pipeline; when no effects or
  /// crop are applied the pipeline is a pass-through.
  @async
  @ObjCSelector('createCameraWithName:settings:')
  int create(String cameraName, PlatformMediaSettings settings);

  /// Initializes the camera with the given ID.
  @async
  @ObjCSelector('initializeCamera:withImageFormat:')
  void initialize(int cameraId, PlatformImageFormatGroup imageFormat);

  /// Begins streaming frames from the camera.
  @async
  void startImageStream();

  /// Stops streaming frames from the camera.
  @async
  void stopImageStream();

  /// Called by the Dart side of the plugin when it has received the last image
  /// frame sent.
  ///
  /// This is used to throttle sending frames across the channel.
  @async
  void receivedImageStreamData();

  /// Indicates that the given camera is no longer being used on the Dart side,
  /// and any associated resources can be cleaned up.
  @async
  @ObjCSelector('disposeCamera:')
  void dispose(int cameraId);

  /// Locks the camera capture to the current device orientation.
  @async
  @ObjCSelector('lockCaptureOrientation:')
  void lockCaptureOrientation(PlatformDeviceOrientation orientation);

  /// Unlocks camera capture orientation, allowing it to automatically adapt to
  /// device orientation.
  @async
  void unlockCaptureOrientation();

  /// Takes a picture with the current settings, and returns the path to the
  /// resulting file.
  @async
  String takePicture();

  /// Takes a picture and saves it twice: the un-effected original (with the
  /// configured `captureScale` crop preserved) and the shader-processed
  /// version. Returns the paths to both files.
  @async
  PlatformCapturedPicturePaths takePictureWithOriginal();

  /// Does any preprocessing necessary before beginning to record video.
  @async
  void prepareForVideoRecording();

  /// Begins recording video, optionally enabling streaming to Dart at the same
  /// time.
  @async
  @ObjCSelector('startVideoRecordingWithStreaming:')
  void startVideoRecording(bool enableStream);

  /// Stops recording video, and results the path to the resulting file.
  @async
  String stopVideoRecording();

  /// Pauses video recording.
  @async
  void pauseVideoRecording();

  /// Resumes a previously paused video recording.
  @async
  void resumeVideoRecording();

  /// Switches the camera to the given flash mode.
  @async
  @ObjCSelector('setFlashMode:')
  void setFlashMode(PlatformFlashMode mode);

  /// Returns the flash modes supported by the camera.
  @async
  @ObjCSelector('supportedFlashModes')
  List<PlatformFlashMode> getSupportedFlashModes();

  /// Switches the camera to the given exposure mode.
  @async
  @ObjCSelector('setExposureMode:')
  void setExposureMode(PlatformExposureMode mode);

  /// Anchors auto-exposure to the given point in (0,1) coordinate space.
  ///
  /// A null value resets to the default exposure point.
  @async
  @ObjCSelector('setExposurePoint:')
  void setExposurePoint(PlatformPoint? point);

  /// Returns the minimum exposure offset supported by the camera.
  @async
  @ObjCSelector('getMinimumExposureOffset')
  double getMinExposureOffset();

  /// Returns the maximum exposure offset supported by the camera.
  @async
  @ObjCSelector('getMaximumExposureOffset')
  double getMaxExposureOffset();

  /// Sets the exposure offset manually to the given value.
  @async
  @ObjCSelector('setExposureOffset:')
  void setExposureOffset(double offset);

  /// Switches the camera to the given focus mode.
  @async
  @ObjCSelector('setFocusMode:')
  void setFocusMode(PlatformFocusMode mode);

  /// Anchors auto-focus to the given point in (0,1) coordinate space.
  ///
  /// A null value resets to the default focus point.
  @async
  @ObjCSelector('setFocusPoint:')
  void setFocusPoint(PlatformPoint? point);

  /// Sets the white balance for the camera.
  ///
  /// Null enables automatic white balance; a non-null value locks the white
  /// balance to the given temperature and tint.
  @async
  @ObjCSelector('setWhiteBalance:')
  void setWhiteBalance(PlatformWhiteBalanceValues? values);

  /// Gets whether the camera can lock its white balance to a given temperature
  /// and tint.
  @async
  @ObjCSelector('isWhiteBalanceSupported')
  bool isWhiteBalanceSupported();

  /// Returns the minimum zoom level supported by the camera.
  @async
  @ObjCSelector('getMinimumZoomLevel')
  double getMinZoomLevel();

  /// Returns the maximum zoom level supported by the camera.
  @async
  @ObjCSelector('getMaximumZoomLevel')
  double getMaxZoomLevel();

  /// Sets the zoom factor.
  @async
  @ObjCSelector('setZoomLevel:')
  void setZoomLevel(double zoom);

  /// Sets the video stabilization mode.
  @async
  @ObjCSelector('setVideoStabilizationMode:')
  void setVideoStabilizationMode(PlatformVideoStabilizationMode mode);

  /// Gets if the given video stabilization mode is supported.
  @async
  @ObjCSelector('isVideoStabilizationModeSupported:')
  bool isVideoStabilizationModeSupported(PlatformVideoStabilizationMode mode);

  /// Pauses streaming of preview frames.
  @async
  void pausePreview();

  /// Resumes a previously paused preview stream.
  @async
  void resumePreview();

  /// Changes the camera used while recording video.
  ///
  /// This should only be called while video recording is active.
  @async
  void updateDescriptionWhileRecording(String cameraName);

  /// Sets the file format used for taking pictures.
  @async
  @ObjCSelector('setImageFileFormat:')
  void setImageFileFormat(PlatformImageFileFormat format);

  /// Applies visual effect parameters to the Metal shader pipeline.
  /// Has no effect when no shader pipeline is active.
  @async
  @ObjCSelector('setEffectsValues:')
  void setEffectsValues(PlatformEffectsValues values);

  /// Sets the center-crop aspect ratio (width/height) applied to preview,
  /// photo, and video. Pass `null` to disable cropping. Has no effect when
  /// no shader pipeline is active.
  @async
  @ObjCSelector('setAspectRatio:')
  void setAspectRatio(double? aspectRatio);

  /// Sets the capture scale (0.1–1.0) applied inside the aspect-ratio crop.
  /// 1.0 means no extra crop. Values below 1.0 narrow the captured area;
  /// the preview shows the full aspect-ratio crop with the area outside the
  /// scaled rectangle darkened, while photo and video files contain only
  /// the scaled rectangle.
  @async
  @ObjCSelector('setCaptureScale:')
  void setCaptureScale(double scale);

  /// Sets the corner radius of the captureScale rectangle in the preview.
  /// The radius is in the range [0.0, 1.0], where 0.0 means square corners
  /// and positive values round the corners of the darkened border.
  /// Only affects the preview; saved photos and videos are unaffected.
  @async
  @ObjCSelector('setCaptureCornerRadius:')
  void setCaptureCornerRadius(double radius);
}

@EventChannelApi()
abstract class CameraImageStreamEventApi {
  PlatformCameraImageData imageDataStream();
}

/// Handler for native callbacks that are not tied to a specific camera ID.
@FlutterApi()
abstract class CameraGlobalEventApi {
  /// Called when the device's physical orientation changes.
  void deviceOrientationChanged(PlatformDeviceOrientation orientation);
}

/// Handler for native callbacks that are tied to a specific camera ID.
///
/// This is intended to be initialized with the camera ID as a suffix.
@FlutterApi()
abstract class CameraEventApi {
  /// Called when the camera is inialitized for use.
  @ObjCSelector('initializedWithState:')
  void initialized(PlatformCameraState initialState);

  /// Called when an error occurs in the camera.
  ///
  /// This should be used for errors that occur outside of the context of
  /// handling a specific HostApi call, such as during streaming.
  @ObjCSelector('reportError:')
  void error(String message);

  /// Called when the preview size changes (e.g., after an aspect ratio change).
  @ObjCSelector('previewSizeChanged:')
  void previewSizeChanged(PlatformSize size);

  /// Called while the camera is in auto white balance mode with the
  /// temperature (Kelvin) and tint values currently selected by the
  /// hardware. iOS only.
  @ObjCSelector('autoWhiteBalanceChangedWithTemperature:tint:')
  void autoWhiteBalanceChanged(double temperature, double tint);
}
