// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import CoreMotion
import Flutter

/// A class that manages camera's state and performs camera operations.
protocol Camera: FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate
{
  /// The API instance used to communicate with the Dart side of the plugin.
  /// Once initially set, this should only ever be accessed on the main thread.
  var dartAPI: CameraEventApi? { get set }

  var onFrameAvailable: (() -> Void)? { get set }

  /// Format used for video and image streaming.
  var videoFormat: FourCharCode { get set }

  var isPreviewPaused: Bool { get }
  var isStreamingImages: Bool { get }

  var deviceOrientation: UIDeviceOrientation { get set }

  var minimumAvailableZoomFactor: CGFloat { get }
  var maximumAvailableZoomFactor: CGFloat { get }
  var minimumExposureOffset: CGFloat { get }
  var maximumExposureOffset: CGFloat { get }

  /// The flash modes supported by the current capture device.
  var supportedFlashModes: [PlatformFlashMode] { get }

  func setUpCaptureSessionForAudioIfNeeded()

  /// Informs the Dart side of the plugin of the current camera state and capabilities.
  func reportInitializationState()

  /// Acknowledges the receipt of one image stream frame.
  ///
  /// This should be called each time a frame is received. Failing to call it may
  /// cause later frames to be dropped instead of streamed.
  func receivedImageStreamData()

  func start()
  func stop()

  /// Starts recording a video with an optional streaming messenger.
  /// If the messenger is non-nil then it will be called for each
  /// captured frame, allowing streaming concurrently with recording.
  ///
  /// @param messenger Nullable messenger for capturing each frame.
  func startVideoRecording(
    completion: @escaping (Result<Void, any Error>) -> Void,
    messengerForStreaming: FlutterBinaryMessenger?
  )
  func pauseVideoRecording()
  func resumeVideoRecording()
  func stopVideoRecording(completion: @escaping (Result<String, any Error>) -> Void)

  func captureToFile(completion: @escaping (Result<String, any Error>) -> Void)

  /// Captures one shutter event and writes two files: the un-effected
  /// original (with the configured `captureScale` crop preserved) and the
  /// shader-processed photo.
  func captureToFilesWithOriginal(
    completion: @escaping (
      Result<(originalPath: String, processedPath: String), any Error>
    ) -> Void
  )

  func lockCaptureOrientation(_ orientation: PlatformDeviceOrientation)
  func unlockCaptureOrientation()

  func setImageFileFormat(_ fileFormat: PlatformImageFileFormat)

  /// Applies visual effect parameters to the active Metal shader pipeline.
  /// No-op when no shader pipeline is active.
  func setEffectsValues(_ values: PlatformEffectsValues)

  /// Sets the center-crop aspect ratio (width/height) applied to preview,
  /// photo, and video. Pass `nil` to disable cropping. No-op when no shader
  /// pipeline is active.
  func setAspectRatio(_ aspectRatio: Double?)

  /// Sets the capture scale (0.1–1.0) applied inside the aspect-ratio crop.
  /// No-op when no shader pipeline is active.
  func setCaptureScale(_ scale: Double)

  /// Sets the corner radius of the captureScale rectangle in the preview.
  /// The radius is in the range [0.0, 1.0], where 0.0 means square corners
  /// and positive values round the corners of the darkened border. Only
  /// affects the preview; saved photos and videos are unaffected.
  /// No-op when no shader pipeline is active.
  func setCaptureCornerRadius(_ radius: Double)

  func setExposureMode(_ mode: PlatformExposureMode)
  func setExposureOffset(_ offset: Double)

  /// Sets the exposure point, in a (0,1) coordinate system.
  ///
  /// If @c point is nil, the exposure point will reset to the center.
  func setExposurePoint(
    _ point: PlatformPoint?,
    withCompletion: @escaping (Result<Void, any Error>) -> Void
  )

  /// Sets FocusMode on the current AVCaptureDevice.
  ///
  /// If the @c focusMode is set to FocusModeAuto the AVCaptureDevice is configured to use
  /// AVCaptureFocusModeContinuousModeAutoFocus when supported, otherwise it is set to
  /// AVCaptureFocusModeAutoFocus. If neither AVCaptureFocusModeContinuousModeAutoFocus nor
  /// AVCaptureFocusModeAutoFocus are supported focus mode will not be set.
  /// If @c focusMode is set to FocusModeLocked the AVCaptureDevice is configured to use
  /// AVCaptureFocusModeAutoFocus. If AVCaptureFocusModeAutoFocus is not supported focus mode will not
  /// be set.
  ///
  /// @param mode The focus mode that should be applied.
  func setFocusMode(_ mode: PlatformFocusMode)

  /// Sets the focus point, in a (0,1) coordinate system.
  ///
  /// If @c point is nil, the focus point will reset to the center.
  func setFocusPoint(
    _ point: PlatformPoint?,
    completion: @escaping (Result<Void, any Error>) -> Void
  )

  /// Sets the white balance for the current AVCaptureDevice.
  ///
  /// If `values` is `nil`, switches to continuous auto white balance.
  /// Otherwise, locks the white balance to the given temperature and tint.
  /// Calls completion with an error if the required mode is not supported.
  func setWhiteBalance(
    _ values: PlatformWhiteBalanceValues?,
    withCompletion: @escaping (Result<Void, any Error>) -> Void
  )

  /// Whether the current AVCaptureDevice can have its white balance locked to a
  /// given temperature and tint.
  func isWhiteBalanceSupported() -> Bool

  func setZoomLevel(_ zoom: CGFloat, withCompletion: @escaping (Result<Void, any Error>) -> Void)

  func setVideoStabilizationMode(
    _ mode: PlatformVideoStabilizationMode,
    withCompletion: @escaping (Result<Void, any Error>) -> Void)

  func isVideoStabilizationModeSupported(_ mode: PlatformVideoStabilizationMode) -> Bool

  func setFlashMode(
    _ mode: PlatformFlashMode,
    withCompletion: @escaping (Result<Void, any Error>) -> Void
  )

  func pausePreview()
  func resumePreview()

  func setDescriptionWhileRecording(
    _ cameraName: String,
    withCompletion: @escaping (Result<Void, any Error>) -> Void
  )

  func startImageStream(
    with: FlutterBinaryMessenger, completion: @escaping (Result<Void, any Error>) -> Void)
  func stopImageStream()

  // Override to make `AVCaptureVideoDataOutputSampleBufferDelegate`/
  // `AVCaptureAudioDataOutputSampleBufferDelegate` method non optional
  override func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  )

  func close()
}
