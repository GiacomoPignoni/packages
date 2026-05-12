// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import CoreMotion
import Flutter
import os

// MARK: - Shader pipeline lifecycle
//
// `VideoFrameRenderer` is the Metal pass that applies effects (LUT, grain,
// vignette), aspect-ratio center-crop, and `captureScale` darkening. It is
// owned exclusively by `DefaultCamera` and accessed on `captureSessionQueue`.
//
// Build & rebuild
//   - Built lazily on the first sample buffer once the source dimensions and
//     pixel format are known. Also pre-built from `setUpVideoRecording` and
//     `captureToFile` when those run before the first frame, so the
//     AVAssetWriter / photo settings can be sized for the renderer's output.
//   - Rebuilt whenever the source format changes (`videoFormat` setter,
//     `setDescriptionWhileRecording`) or the desired output dimensions
//     change (`setAspectRatio`). Rebuilds are blocked while recording: the
//     AVAssetWriter is locked to the renderer's output dimensions, so the
//     request is stashed and applied on `stopVideoRecording`.
//
// Texture hand-off
//   - LUT and grain textures decode asynchronously from disk. Across a
//     rebuild, the outgoing renderer is parked in `previousVideoFrameRenderer`
//     so the new instance can adopt its already-decoded textures synchronously
//     in `buildRendererIfPossible` and avoid a one-frame un-filtered preview.
//
// `previewSize` convention
//   - Always reported sensor-landscape (longer axis as width). The Flutter
//     `CameraPreview` widget inverts this in portrait. See
//     `landscapePreviewSize` for the single source of truth.

/// Aspect-ratio change requested while recording, deferred until
/// `stopVideoRecording`. `.none` means no pending change; `.set(value)`
/// carries the deferred ratio (where `value == nil` means "clear the crop").
/// A separate case is needed because `nil` is itself a valid aspect-ratio
/// value, so plain `Double?` cannot distinguish "no change" from "clear".
private enum PendingAspectRatio {
  case none
  case set(Double?)
}

final class DefaultCamera: NSObject, Camera {
  var dartAPI: CameraEventApi?
  var onFrameAvailable: (() -> Void)?

  var videoFormat: FourCharCode = kCVPixelFormatType_32BGRA {
    didSet {
      captureVideoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: videoFormat
      ]
      // The setter is only invoked from `CameraPlugin.initialize`, which
      // runs before any sample buffer has arrived, so in practice the
      // renderer is always nil here. The explicit reset is defensive in case
      // a future caller invokes the setter after frames have started flowing
      // — `submitRender` would otherwise keep a renderer wired for the old
      // pixel format. The timer stop is part of the same insurance: an
      // in-flight photo delegate strongly retains the renderer, so dropping
      // it without stopping the grain timer would leave the timer firing
      // until that capture completes. Renderer access is otherwise confined
      // to the capture session queue, which is also where this setter runs.
      videoFrameRenderer?.stopGrainAnimation()
      videoFrameRenderer = nil
      shaderSourceUnsupported = false
    }
  }

  private(set) var isPreviewPaused = false

  var minimumExposureOffset: CGFloat { CGFloat(captureDevice.minExposureTargetBias) }
  var maximumExposureOffset: CGFloat { CGFloat(captureDevice.maxExposureTargetBias) }
  var minimumAvailableZoomFactor: CGFloat { captureDevice.minAvailableVideoZoomFactor }
  var maximumAvailableZoomFactor: CGFloat { captureDevice.maxAvailableVideoZoomFactor }

  /// The flash modes supported by the current capture device, derived from
  /// `AVCapturePhotoOutput.supportedFlashModes`. AVFoundation only reports
  /// `.off`/`.auto`/`.on` here, so `torch` is never included even when the
  /// device has a torch.
  var supportedFlashModes: [PlatformFlashMode] {
    capturePhotoOutput.supportedFlashModes.map { getPlatformFlashMode(for: $0) }
  }

  /// The queue on which `latestPixelBuffer` property is accessed.
  /// To avoid unnecessary contention, do not access `latestPixelBuffer` on the `captureSessionQueue`.
  private let pixelBufferSynchronizationQueue = DispatchQueue(
    label: "io.flutter.camera.pixelBufferSynchronizationQueue")

  /// The queue on which captured photos (not videos) are written to disk.
  /// Videos are written to disk by `videoAdaptor` on an internal queue managed by AVFoundation.
  private let photoIOQueue = DispatchQueue(label: "io.flutter.camera.photoIOQueue")

  /// All DefaultCamera's state access and capture session related operations should be run on this queue.
  private let captureSessionQueue: DispatchQueue

  private let mediaSettings: PlatformMediaSettings
  private var framesPerSecond: Double?
  private let mediaSettingsAVWrapper: FLTCamMediaSettingsAVWrapper

  let videoCaptureSession: CaptureSession
  let audioCaptureSession: CaptureSession

  /// A wrapper for AVCaptureDevice creation to allow for dependency injection in tests.
  private let videoCaptureDeviceFactory: VideoCaptureDeviceFactory
  private let audioCaptureDeviceFactory: AudioCaptureDeviceFactory
  private let captureDeviceInputFactory: CaptureDeviceInputFactory
  private let assetWriterFactory: AssetWriterFactory
  private let inputPixelBufferAdaptorFactory: InputPixelBufferAdaptorFactory

  /// A wrapper for CMVideoFormatDescriptionGetDimensions.
  /// Allows for alternate implementations in tests.
  private let videoDimensionsConverter: VideoDimensionsConverter

  private let deviceOrientationProvider: DeviceOrientationProvider
  private let motionManager = CMMotionManager()

  private(set) var captureDevice: CaptureDevice
  // Setter exposed for tests.
  var captureVideoOutput: CaptureVideoDataOutput
  // Setter exposed for tests.
  var capturePhotoOutput: CapturePhotoOutput
  private var captureVideoInput: CaptureInput

  private var videoWriter: AssetWriter?
  private var videoWriterInput: AssetWriterInput?
  private var audioWriterInput: AssetWriterInput?
  private var assetWriterPixelBufferAdaptor: AssetWriterInputPixelBufferAdaptor?
  private var videoAdaptor: AssetWriterInputPixelBufferAdaptor?
  private var videoFrameRenderer: VideoFrameRenderer?
  /// Retains the previous renderer across an aspect-ratio rebuild so the
  /// new renderer can synchronously adopt its already-decoded LUT / grain
  /// Metal textures via `adoptTextures(from:)`. Without this hand-off the
  /// preview flashes un-filtered for a few frames while the async
  /// `loadLutTexture` / `loadGrainTexture` callbacks decode the files again
  /// on the new renderer. Cleared inside `buildRendererIfPossible` once the
  /// transfer is complete.
  private var previousVideoFrameRenderer: VideoFrameRenderer?
  /// Latched once the source pixel format has been examined and rejected by
  /// the shader pipeline. Stops re-checking and re-logging on every frame.
  private var shaderSourceUnsupported = false
  /// Latest effects values, retained so they are re-applied whenever the
  /// renderer is recreated (camera switch, aspect-ratio change, pixel-format
  /// change, etc.). Symmetric with `captureScale`: a plain field that survives
  /// every rebuild, not a one-shot pending slot.
  private var currentEffectsValues: PlatformEffectsValues?
  /// Active aspect ratio (width/height) for the shader pipeline. Determines
  /// the renderer's output dimensions; updated via `setAspectRatio`. `nil`
  /// means no center-crop is applied.
  private var aspectRatio: Double? = nil
  /// Inner-rect "capture scale" (0.1–1.0). Narrows the captured area inside
  /// the aspect-ratio crop; the preview shows the full crop with the area
  /// outside this scaled rect dimmed, while photo and video files contain
  /// only the scaled rect.
  private var captureScale: Float = 1.0
  /// Corner radius of the captureScale preview rectangle, in the same
  /// [-1,1] d-space as the scaled rect. 0 = square corners.
  private var captureCornerRadius: Float = 0.0
  /// `setCaptureScale` calls received while recording. The AVAssetWriter is
  /// locked to the renderer's dimensions for the duration of the take, so we
  /// stash the latest value and apply it once recording stops. Nil when no
  /// pending change.
  private var pendingCaptureScale: Float?
  /// Deferred `setAspectRatio` request received while recording. See
  /// `PendingAspectRatio` at file scope.
  private var pendingAspectRatio: PendingAspectRatio = .none

  /// A dictionary to retain all in-progress SavePhotoDelegates. The key of the dictionary is the
  /// AVCapturePhotoSettings's uniqueID for each photo capture operation, and the value is the
  /// SavePhotoDelegate that handles the result of each photo capture operation. Note that photo
  /// capture operations may overlap, so FLTCam has to keep track of multiple delegates in progress,
  /// instead of just a single delegate reference.
  private(set) var inProgressSavePhotoDelegates = [Int64: SavePhotoDelegate]()

  /// Parallel to `inProgressSavePhotoDelegates`, for the dual-output
  /// `takePictureWithOriginal` path.
  private(set) var inProgressSavePhotoWithOriginalDelegates =
    [Int64: SavePhotoWithOriginalDelegate]()

  private var imageStreamHandler: ImageStreamHandler?

  private var previewSize: CGSize?
  /// Set to true by `reportInitializationState` once the `initialized` event
  /// has been dispatched to Dart. `previewSizeChanged` must never be sent
  /// before `initialized`, so `updatePreviewSize` is a no-op until this flag
  /// is set.
  private var isInitialized = false
  var deviceOrientation: UIDeviceOrientation {
    didSet {
      guard deviceOrientation != oldValue else { return }
      updateOrientation()
    }
  }

  /// Tracks the latest pixel buffer sent from AVFoundation's sample buffer delegate callback.
  /// Used to deliver the latest pixel buffer to the flutter engine via the `copyPixelBuffer` API.
  private var latestPixelBuffer: CVPixelBuffer?

  private var videoRecordingPath: String?
  private(set) var isRecording = false
  private var isRecordingPaused = false
  private var isFirstVideoSample = false
  private var isAudioSetup = false
  /// Time of the end of the last sample.
  private var lastSampleEndTime = CMTime.invalid
  /// Whether the recording is disconnected.
  private var isRecordingDisconnected = false
  /// Represents sum of all pauses/interruptions during recording.
  private var recordingTimeOffset = CMTime.invalid
  /// Output to use for adjusting of recording time offset.
  private var outputForOffsetAdjusting: AVCaptureOutput?
  /// Time of the last appended video sample.
  private var lastAppendedVideoSampleTime = CMTime.invalid

  /// True when images from the camera are being streamed.
  private(set) var isStreamingImages = false

  /// Number of frames currently pending processing.
  private var streamingPendingFramesCount = 0

  /// Maximum number of frames pending processing.
  /// To limit memory consumption, limit the number of frames pending processing.
  /// After some testing, 4 was determined to be the best maximum value.
  /// https://github.com/flutter/plugins/pull/4520#discussion_r766335637
  private var maxStreamingPendingFramesCount = 4

  private var fileFormat = PlatformImageFileFormat.jpeg
  private var lockedCaptureOrientation = UIDeviceOrientation.unknown
  private var exposureMode = PlatformExposureMode.auto
  private var focusMode = PlatformFocusMode.auto
  private var isWhiteBalanceLocked = false
  /// Latest locked white-balance values requested via `setWhiteBalance`, kept
  /// so they can be re-applied to a new `AVCaptureDevice` after
  /// `setDescriptionWhileRecording`. `nil` when the user is in auto mode or
  /// has never locked WB.
  private var currentWhiteBalanceValues: PlatformWhiteBalanceValues?
  private var flashMode: PlatformFlashMode

  /// KVO token for `AVCaptureDevice.deviceWhiteBalanceGains` while the
  /// camera is in auto white balance. Nil when not observing. Always bound
  /// to the *current* `captureDevice`; rebound on device swaps.
  private var whiteBalanceObservation: NSKeyValueObservation?
  /// Earliest `Date` at which the next `autoWhiteBalanceChanged` event may
  /// be dispatched to Dart. KVO fires at ~30–60 Hz, so this gate is checked
  /// on the *calling* thread before hopping `captureSessionQueue`.
  ///
  /// **Intentionally read without a lock on the early-out path.** `Date` is
  /// 16 bytes and a torn read across threads is possible — that is OK: the
  /// post-hop check inside `captureSessionQueue` is the source of truth, and
  /// at worst a torn read lets a single extra block reach the queue where
  /// the downstream guard discards it. Do **not** add a lock here; it would
  /// defeat the cheap calling-thread fast path that keeps the serial capture
  /// queue free of throw-away work contending with the sample-buffer
  /// callback.
  private var nextAutoWhiteBalanceEmission: Date = .distantPast
  /// Minimum interval between `autoWhiteBalanceChanged` events.
  private static let autoWhiteBalanceMinInterval: TimeInterval = 0.1

  /// `os_log` subsystem for hot-path diagnostics that would flood the
  /// system log if emitted on every frame. `NSLog` is synchronous, takes a
  /// global lock, and is documented as unsuitable for realtime code paths;
  /// `os_log` writes through a per-process ring buffer instead.
  private static let recordingLog = OSLog(
    subsystem: "io.flutter.camera_avfoundation", category: "recording")
  /// Earliest time at which the next recording-failure log may be emitted.
  /// Bounds the cost of a stuck writer (e.g. disk full) where every video
  /// sample would otherwise format and log four hex/integer fields.
  ///
  /// Queue-confined to `captureSessionQueue` (the only writer is
  /// `logRecordingFailure`, called from the sample-buffer callback). No lock
  /// is needed precisely because of that confinement — do not add one and
  /// do not relax the confinement.
  private var nextRecordingFailureLog: Date = .distantPast
  /// Minimum interval between recording-failure logs (drop-or-append-fail).
  private static let recordingFailureLogMinInterval: TimeInterval = 1.0

  private static func pigeonErrorFromNSError(_ error: NSError) -> PigeonError {
    return PigeonError(
      code: "Error \(error.code)",
      message: error.localizedDescription,
      details: error.domain)
  }

  /// Returns a `CGSize` in the camera plugin's sensor-landscape
  /// `previewSize` convention: the longer axis is reported as `width`. The
  /// existing `CameraPreview` widget then inverts this in portrait device
  /// orientation to size its `AspectRatio` box correctly. Without this
  /// normalization, an aspect-ratio-cropped buffer (e.g. 810×1080) would be
  /// reported with height > width and the widget's inversion math would lay
  /// out the box in the wrong orientation.
  private static func landscapePreviewSize(width: Int, height: Int) -> CGSize {
    let longer = max(width, height)
    let shorter = min(width, height)
    return CGSize(width: CGFloat(longer), height: CGFloat(shorter))
  }

  /// Cached device-screen shorter side in *native pixels*. Used to size the
  /// renderer's preview pool: on-screen preview is sampled by Flutter into a
  /// FlutterView that never exceeds the screen, so rendering the shader at a
  /// larger size is wasted GPU work — and on heavy effects (49-tap blur,
  /// mist) shader cost is dominated by output fragment count.
  ///
  /// First access reads `UIScreen.main.nativeBounds`. UIScreen geometric
  /// properties are supposed to be read from the main thread; if we're not
  /// on it we hop with `sync`. Result is cached for the process lifetime —
  /// screen geometry doesn't change on iOS (split-screen on iPad changes
  /// the *window*, not the screen).
  private static let _screenShorterSidePixelsLock = NSLock()
  private static var _screenShorterSidePixelsCache: Int?
  static func screenShorterSidePixels() -> Int {
    // Lock is held across the (possibly blocking) main-thread hop so two
    // racing callers cannot both compute the value and both write the
    // cache. UIScreen access only touches `main`, never this lock, so the
    // `sync` hop cannot deadlock on it.
    _screenShorterSidePixelsLock.lock()
    defer { _screenShorterSidePixelsLock.unlock() }
    if let cached = _screenShorterSidePixelsCache {
      return cached
    }

    let compute: () -> Int = {
      let bounds = UIScreen.main.nativeBounds
      let shorter = min(Int(bounds.width), Int(bounds.height))
      // Fallback for headless / very-early-init scenarios. 1280 ≈ shorter
      // side of mid-range iPhones; keeps preview rendering bounded but
      // doesn't downscale aggressively.
      return shorter > 0 ? shorter : 1280
    }
    let value = Thread.isMainThread ? compute() : DispatchQueue.main.sync(execute: compute)
    _screenShorterSidePixelsCache = value
    return value
  }

  private static func createConnection(
    captureDevice: CaptureDevice,
    videoFormat: FourCharCode,
    captureDeviceInputFactory: CaptureDeviceInputFactory
  ) throws -> (CaptureInput, CaptureVideoDataOutput, AVCaptureConnection) {
    // Setup video capture input.
    let captureVideoInput = try captureDeviceInputFactory.deviceInput(with: captureDevice)

    // Setup video capture output.
    let captureVideoOutput = AVCaptureVideoDataOutput()
    captureVideoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: videoFormat
    ]
    captureVideoOutput.alwaysDiscardsLateVideoFrames = true

    // Setup video capture connection.
    let connection = AVCaptureConnection(
      inputPorts: captureVideoInput.ports,
      output: captureVideoOutput.avOutput)

    if captureDevice.position == .front {
      connection.isVideoMirrored = true
    }

    return (captureVideoInput, captureVideoOutput, connection)
  }

  init(configuration: CameraConfiguration) throws {
    captureSessionQueue = configuration.captureSessionQueue
    mediaSettings = configuration.mediaSettings
    mediaSettingsAVWrapper = configuration.mediaSettingsWrapper
    videoCaptureSession = configuration.videoCaptureSession
    audioCaptureSession = configuration.audioCaptureSession
    videoCaptureDeviceFactory = configuration.videoCaptureDeviceFactory
    audioCaptureDeviceFactory = configuration.audioCaptureDeviceFactory
    captureDeviceInputFactory = configuration.captureDeviceInputFactory
    assetWriterFactory = configuration.assetWriterFactory
    inputPixelBufferAdaptorFactory = configuration.inputPixelBufferAdaptorFactory
    videoDimensionsConverter = configuration.videoDimensionsConverter
    deviceOrientationProvider = configuration.deviceOrientationProvider
    aspectRatio = configuration.aspectRatio

    // Compile the Metal pipeline ahead of the first frame so the
    // sample-buffer callback doesn't pay for it.
    VideoFrameRenderer.warmUp()

    captureDevice = videoCaptureDeviceFactory(configuration.initialCameraName)
    flashMode = captureDevice.hasFlash ? .auto : .off

    capturePhotoOutput = AVCapturePhotoOutput()
    capturePhotoOutput.isHighResolutionCaptureEnabled = true

    videoCaptureSession.automaticallyConfiguresApplicationAudioSession = false
    audioCaptureSession.automaticallyConfiguresApplicationAudioSession = false

    deviceOrientation = configuration.orientation

    let connection: AVCaptureConnection
    (captureVideoInput, captureVideoOutput, connection) = try DefaultCamera.createConnection(
      captureDevice: captureDevice,
      videoFormat: videoFormat,
      captureDeviceInputFactory: configuration.captureDeviceInputFactory)

    super.init()

    captureVideoOutput.setSampleBufferDelegate(self, queue: captureSessionQueue)

    videoCaptureSession.addInputWithNoConnections(captureVideoInput)
    videoCaptureSession.addOutputWithNoConnections(captureVideoOutput.avOutput)
    videoCaptureSession.addConnection(connection)

    // Pinned for the life of the session. This connection feeds both the preview texture and the
    // recorder; re-orienting it transposes the buffer dimensions mid-stream, which rebuilds the
    // render pipeline on every turn. Pinned, the preview is a fixed window onto the scene — the
    // phone and the image turn together, so nothing on screen moves. Device rotation rides on the
    // photo's EXIF tag (`updateOrientation`) and the video track transform (`setupWriter`) instead.
    //
    // Must follow `addConnection`: `isVideoOrientationSupported` is false while detached, so
    // pinning any earlier silently does nothing.
    if connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    }

    videoCaptureSession.addOutput(capturePhotoOutput.avOutput)

    // Keep the camera alive while the app shares the foreground with another
    // app on iPad (Split View / Slide Over / Stage Manager). Without this,
    // iOS interrupts the session with
    // `videoDeviceNotAvailableWithMultipleForegroundApps`, freezing the
    // preview and failing capture with AVErrorSessionNotRunning (-11803).
    // Supported only on iOS 16+ and on capable hardware; a no-op otherwise.
    // Must be set inside a configuration block, after the camera input and
    // outputs have been attached.
    if videoCaptureSession.multitaskingCameraAccessSupported {
      videoCaptureSession.beginConfiguration()
      videoCaptureSession.multitaskingCameraAccessEnabled = true
      videoCaptureSession.commitConfiguration()
    }

    motionManager.startAccelerometerUpdates()

    if configuration.mediaSettings.framesPerSecond != nil {
      // The frame rate can be changed only on a locked for configuration device.
      try mediaSettingsAVWrapper.lockDevice(captureDevice)
      defer { mediaSettingsAVWrapper.unlockDevice(captureDevice) }

      mediaSettingsAVWrapper.beginConfiguration(for: videoCaptureSession)
      defer { mediaSettingsAVWrapper.commitConfiguration(for: videoCaptureSession) }

      try setCaptureSessionPreset(mediaSettings.resolutionPreset)

      (captureDevice.flutterActiveFormat, framesPerSecond) = FormatUtils.findBestFormat(
        for: captureDevice,
        mediaSettings: mediaSettings,
        videoDimensionsConverter: videoDimensionsConverter)

      if let framesPerSecond = framesPerSecond {
        // Set frame rate with 1/10 precision allowing non-integral values.
        let fpsNominator = floor(framesPerSecond * 10.0)
        let duration = CMTimeMake(value: 10, timescale: Int32(fpsNominator))

        mediaSettingsAVWrapper.setMinFrameDuration(duration, on: captureDevice)
        mediaSettingsAVWrapper.setMaxFrameDuration(duration, on: captureDevice)
      }
    } else {
      // If the frame rate is not important fall to a less restrictive
      // behavior (no configuration locking).
      try setCaptureSessionPreset(mediaSettings.resolutionPreset)
    }

    updateOrientation()

    // Handle video and audio interruptions and errors. Interruption can happen for example by
    // an incoming call during video recording. Error can happen for example when recording starts
    // during an incoming call.
    // https://github.com/flutter/flutter/issues/151253
    for session in [videoCaptureSession, audioCaptureSession] {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(captureSessionWasInterrupted),
        name: AVCaptureSession.wasInterruptedNotification,
        object: session)

      NotificationCenter.default.addObserver(
        self,
        selector: #selector(captureSessionRuntimeError),
        name: AVCaptureSession.runtimeErrorNotification,
        object: session)
    }
  }

  @objc private func captureSessionWasInterrupted(notification: NSNotification) {
    isRecordingDisconnected = true
  }

  @objc private func captureSessionRuntimeError(notification: NSNotification) {
    reportErrorMessage(
      "\(String(describing: notification.userInfo?[AVCaptureSessionErrorKey] as? Error))")
  }

  // Possible values for presets are hard-coded in FLT interface having
  // corresponding AVCaptureSessionPreset counterparts.
  // If _resolutionPreset is not supported by camera there is
  // fallback to lower resolution presets.
  // If none can be selected there is error condition.
  private func setCaptureSessionPreset(
    _ resolutionPreset: PlatformResolutionPreset
  ) throws {
    switch resolutionPreset {
    case .photo:
      // `AVCaptureSession.Preset.photo` configures the sensor for the
      // largest still-image dimensions it supports, at the cost of a reduced
      // video stream (~1440p on most iPhones). Use it as-is when supported;
      // otherwise fall through to the `.max` device-format path so callers
      // still get the best stills resolution available.
      if videoCaptureSession.canSetSessionPreset(.photo) {
        videoCaptureSession.sessionPreset = .photo
        break
      }
      fallthrough
    case .max:
      if let bestFormat = highestResolutionFormat(forCaptureDevice: captureDevice) {
        videoCaptureSession.sessionPreset = .inputPriority
        do {
          try captureDevice.lockForConfiguration()
          // Set the best device format found and finish the device configuration.
          captureDevice.flutterActiveFormat = bestFormat
          captureDevice.unlockForConfiguration()
          break
        }
      }
      fallthrough
    case .ultraHigh:
      if videoCaptureSession.canSetSessionPreset(.hd4K3840x2160) {
        videoCaptureSession.sessionPreset = .hd4K3840x2160
        break
      }
      if videoCaptureSession.canSetSessionPreset(.high) {
        videoCaptureSession.sessionPreset = .high
        break
      }
      fallthrough
    case .veryHigh:
      if videoCaptureSession.canSetSessionPreset(.hd1920x1080) {
        videoCaptureSession.sessionPreset = .hd1920x1080
        break
      }
      fallthrough
    case .high:
      if videoCaptureSession.canSetSessionPreset(.hd1280x720) {
        videoCaptureSession.sessionPreset = .hd1280x720
        break
      }
      fallthrough
    case .medium:
      if videoCaptureSession.canSetSessionPreset(.vga640x480) {
        videoCaptureSession.sessionPreset = .vga640x480
        break
      }
      fallthrough
    case .low:
      if videoCaptureSession.canSetSessionPreset(.cif352x288) {
        videoCaptureSession.sessionPreset = .cif352x288
        break
      }
      fallthrough
    default:
      if videoCaptureSession.canSetSessionPreset(.low) {
        videoCaptureSession.sessionPreset = .low
      } else {
        throw NSError(
          domain: NSCocoaErrorDomain,
          code: URLError.unknown.rawValue,
          userInfo: [
            NSLocalizedDescriptionKey: "No capture session available for current capture session."
          ])
      }
    }

    let size = videoDimensionsConverter(captureDevice.flutterActiveFormat)
    let sourceWidth = Int(size.width)
    let sourceHeight = Int(size.height)
    if aspectRatio != nil {
      let effectiveRatio = effectiveAspectRatio(
        forSourceWidth: sourceWidth, sourceHeight: sourceHeight)
      let crop = VideoFrameRenderer.croppedDimensions(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        targetRatio: effectiveRatio)
      previewSize = DefaultCamera.landscapePreviewSize(
        width: crop.width, height: crop.height)
    } else {
      previewSize = DefaultCamera.landscapePreviewSize(
        width: sourceWidth, height: sourceHeight)
    }
    audioCaptureSession.sessionPreset = videoCaptureSession.sessionPreset
  }

  /// Finds the highest available non-square resolution in terms of pixel count for the given device.
  /// Preferred are formats with the same subtype as current activeFormat.
  private func highestResolutionFormat(forCaptureDevice captureDevice: CaptureDevice)
    -> CaptureDeviceFormat?
  {
    let preferredSubType = CMFormatDescriptionGetMediaSubType(
      captureDevice.flutterActiveFormat.formatDescription)
    var bestFormat: CaptureDeviceFormat? = nil
    var maxPixelCount: UInt = 0
    var isBestSubTypePreferred = false

    // These formats are compressed and lossy, and unsupported by the Flutter Engine.
    let unsupportedSubTypes: [FourCharCode] = [
      1_651_798_066  // Hex for 'btp2', or kCVPixelFormatType_96VersatileBayerPacked12
    ]

    for format in captureDevice.flutterFormats {
      let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)

      // Skip formats that will crash the Flutter Engine
      if unsupportedSubTypes.contains(subType) {
        continue
      }

      let resolution = videoDimensionsConverter(format)
      let height = UInt(resolution.height)
      let width = UInt(resolution.width)

      // Guard against 1:1 resolutions provided by the iPhone 17 centre stage sensor.
      if height == width {
        continue
      }

      let pixelCount = height * width
      let isSubTypePreferred = subType == preferredSubType

      if pixelCount > maxPixelCount
        || (pixelCount == maxPixelCount && isSubTypePreferred && !isBestSubTypePreferred)
      {
        bestFormat = format
        maxPixelCount = pixelCount
        isBestSubTypePreferred = isSubTypePreferred
      }
    }
    return bestFormat
  }

  func setUpCaptureSessionForAudioIfNeeded() {
    // Don't setup audio twice or we will lose the audio.
    guard mediaSettings.enableAudio && !isAudioSetup else { return }

    let audioDevice = audioCaptureDeviceFactory()
    do {
      // Create a device input with the device and add it to the session.
      // Setup the audio input.
      let audioInput = try captureDeviceInputFactory.deviceInput(with: audioDevice)

      // Setup the audio output.
      let audioOutput = AVCaptureAudioDataOutput()

      let block = {
        // Set up options implicit to AVAudioSessionCategoryPlayback to avoid conflicts with other
        // plugins like video_player.
        DefaultCamera.upgradeAudioSessionCategory(
          requestedCategory: .playAndRecord,
          options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay]
        )
      }

      if !Thread.isMainThread {
        DispatchQueue.main.sync(execute: block)
      } else {
        block()
      }

      if audioCaptureSession.canAddInput(audioInput) {
        audioCaptureSession.addInput(audioInput)

        if audioCaptureSession.canAddOutput(audioOutput) {
          audioCaptureSession.addOutput(audioOutput)
          audioOutput.setSampleBufferDelegate(self, queue: captureSessionQueue)
          isAudioSetup = true
        } else {
          reportErrorMessage("Unable to add Audio input/output to session capture")
          isAudioSetup = false
        }
      }
    } catch let error as NSError {
      reportErrorMessage(error.description)
    }
  }

  // This function, although slightly modified, is also in video_player_avfoundation (in ObjC).
  // Both need to do the same thing and run on the same thread (for example main thread).
  // Configure application wide audio session manually to prevent overwriting flag
  // MixWithOthers by capture session.
  // Only change category if it is considered an upgrade which means it can only enable
  // ability to play in silent mode or ability to record audio but never disables it,
  // that could affect other plugins which depend on this global state. Only change
  // category or options if there is change to prevent unnecessary lags and silence.
  private static func upgradeAudioSessionCategory(
    requestedCategory: AVAudioSession.Category,
    options: AVAudioSession.CategoryOptions
  ) {
    let playCategories: Set<AVAudioSession.Category> = [.playback, .playAndRecord]
    let recordCategories: Set<AVAudioSession.Category> = [.record, .playAndRecord]
    let requiredCategories: Set<AVAudioSession.Category> = [
      requestedCategory, AVAudioSession.sharedInstance().category,
    ]

    let requiresPlay = !requiredCategories.isDisjoint(with: playCategories)
    let requiresRecord = !requiredCategories.isDisjoint(with: recordCategories)

    var finalCategory = requestedCategory
    if requiresPlay && requiresRecord {
      finalCategory = .playAndRecord
    } else if requiresPlay {
      finalCategory = .playback
    } else if requiresRecord {
      finalCategory = .record
    }

    let finalOptions = AVAudioSession.sharedInstance().categoryOptions.union(options)

    if finalCategory == AVAudioSession.sharedInstance().category
      && finalOptions == AVAudioSession.sharedInstance().categoryOptions
    {
      return
    }

    try? AVAudioSession.sharedInstance().setCategory(finalCategory, options: finalOptions)
  }

  func reportInitializationState() {
    // Get all the state on the current thread, not the main thread.
    let state = PlatformCameraState(
      previewSize: PlatformSize(
        // previewSize is set during init, so it will never be nil.
        width: previewSize!.width,
        height: previewSize!.height
      ),
      exposureMode: exposureMode,
      focusMode: focusMode,
      exposurePointSupported: captureDevice.isExposurePointOfInterestSupported,
      focusPointSupported: captureDevice.isFocusPointOfInterestSupported
    )

    // Mark initialized before dispatching so any previewSizeChanged event
    // queued on the main thread (from the first sample buffer arriving while
    // this is in flight) fires after initialized, not before.
    isInitialized = true
    ensureToRunOnMainQueue { [weak self] in
      self?.dartAPI?.initialized(initialState: state) { _ in
        // Ignore any errors, as this is just an event broadcast.
      }
    }
    // Camera initializes in auto white balance; begin observing gains so
    // Dart can read the hardware-selected temperature/tint.
    if !isWhiteBalanceLocked {
      startObservingAutoWhiteBalance()
    }
  }

  func receivedImageStreamData() {
    streamingPendingFramesCount -= 1
  }

  func start() {
    videoCaptureSession.startRunning()
    audioCaptureSession.startRunning()
  }

  func stop() {
    videoCaptureSession.stopRunning()
    audioCaptureSession.stopRunning()
  }

  func startVideoRecording(
    completion: @escaping (Result<Void, any Error>) -> Void,
    messengerForStreaming messenger: FlutterBinaryMessenger?
  ) {
    guard !isRecording else {
      completion(
        .failure(
          PigeonError(
            code: "Error",
            message: "Video is already recording",
            details: nil)))
      return
    }

    if let messenger = messenger {
      startImageStream(with: messenger) { [weak self] error in
        self?.setUpVideoRecording(completion: completion)
      }
      return
    }

    setUpVideoRecording(completion: completion)
  }

  /// Main logic to setup the video recording.
  private func setUpVideoRecording(completion: @escaping (Result<Void, any Error>) -> Void) {
    let videoRecordingPath: String
    do {
      videoRecordingPath = try getTemporaryFilePath(
        withExtension: "mp4",
        subfolder: "videos",
        prefix: "REC_")
      self.videoRecordingPath = videoRecordingPath
    } catch let error as NSError {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error)))
      return
    }

    guard setupWriter(forPath: videoRecordingPath) else {
      completion(
        .failure(
          PigeonError(
            code: "IOError",
            message: "Setup Writer Failed",
            details: nil)))
      return
    }

    // startWriting should not be called in didOutputSampleBuffer where it can cause state
    // in which isRecording is true but videoWriter.status is .unknown
    // in stopVideoRecording if it is called after startVideoRecording but before
    // didOutputSampleBuffer had chance to call startWriting and lag at start of video
    // https://github.com/flutter/flutter/issues/132016
    // https://github.com/flutter/flutter/issues/151319
    guard let videoWriter = videoWriter, videoWriter.startWriting() else {
      completion(
        .failure(
          PigeonError(
            code: "IOError",
            message: "AVAssetWriter failed to start writing",
            details: videoWriter?.error?.localizedDescription)))
      return
    }
    isFirstVideoSample = true
    isRecording = true
    isRecordingPaused = false
    isRecordingDisconnected = false
    recordingTimeOffset = CMTime.zero
    outputForOffsetAdjusting = captureVideoOutput.avOutput
    lastAppendedVideoSampleTime = CMTime.negativeInfinity
    completion(.success(()))
  }

  private func setupWriter(forPath path: String) -> Bool {
    setUpCaptureSessionForAudioIfNeeded()

    // Single source of truth for source dimensions. The active-format
    // converter is called from multiple branches below; binding once avoids
    // both redundant calls and any chance of the value drifting between
    // reads.
    let sourceSize = videoDimensionsConverter(captureDevice.flutterActiveFormat)

    // Pre-build the renderer if needed so the AVAssetWriter is configured for
    // the renderer's output dimensions, not the source dimensions. Without
    // this, recording started before the first sample buffer would attach an
    // adaptor sized for the source — then the renderer would lazily build on
    // the first frame and feed the adaptor differently-sized buffers, which
    // either get rejected or silently corrupt the file.
    if videoFrameRenderer == nil, !shaderSourceUnsupported {
      buildRendererIfPossible(
        sourceWidth: Int(sourceSize.width),
        sourceHeight: Int(sourceSize.height),
        sourcePixelFormat: videoFormat)
    }

    let videoWriter: AssetWriter

    do {
      videoWriter = try assetWriterFactory(URL(fileURLWithPath: path), .mp4)
      self.videoWriter = videoWriter
    } catch let error as NSError {
      reportErrorMessage(error.description)
      return false
    }

    var videoSettings = mediaSettingsAVWrapper.recommendedVideoSettingsForAssetWriter(
      withFileType:
        AVFileType.mp4,
      for: captureVideoOutput
    )

    if videoSettings == nil {
      os_log(
        "DefaultCamera: recommendedVideoSettingsForAssetWriter returned nil — building minimal H.264 settings.",
        log: DefaultCamera.recordingLog, type: .info)
    }

    // Snapshot the recording-output dims into a local *once* so all four
    // settings (videoSettings + adaptor attrs) see the same values. The
    // accessors read live uniforms; reading them four times would let a
    // concurrent `setCaptureScale` (now blocked during recording, but cheap
    // insurance) tear the configuration.
    let recordingDims: (width: Int, height: Int)?
    if let renderer = videoFrameRenderer {
      recordingDims = (renderer.recordingOutputWidth, renderer.recordingOutputHeight)
    } else {
      recordingDims = nil
    }

    let codec = preferredVideoCodec

    // If the system declined to recommend settings (can happen before the
    // session has produced its first sample buffer), synthesize a minimal
    // settings dict ourselves. With nil settings the AssetWriterInput goes
    // into passthrough mode and silently rejects every appended pixel
    // buffer — the resulting MP4 has no video track and is reported as a
    // 0×0 video. We also need *some* dims; use the renderer's recording
    // dims if available, else the source dims from the active format.
    if videoSettings == nil {
      let fallbackDims = recordingDims ?? (Int(sourceSize.width), Int(sourceSize.height))
      videoSettings = [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: fallbackDims.width,
        AVVideoHeightKey: fallbackDims.height,
      ]
    } else {
      // Override AVFoundation's recommendation so the video codec matches
      // the photo codec selected in captureToFile.
      videoSettings?[AVVideoCodecKey] = codec
    }

    if mediaSettings.videoBitrate != nil || framesPerSecond != nil {
      var compressionProperties: [String: Any] = [:]

      if let videoBitrate = mediaSettings.videoBitrate {
        compressionProperties[AVVideoAverageBitRateKey] = Int(videoBitrate)
      }

      if let framesPerSecond = framesPerSecond {
        compressionProperties[AVVideoExpectedSourceFrameRateKey] = framesPerSecond
      }

      videoSettings?[AVVideoCompressionPropertiesKey] = compressionProperties
    }

    // When the renderer is active we feed the encoder buffers from
    // `renderForRecording` (aspect-cropped at full output dimensions, no
    // darkening — capture scale is applied internally and the result is
    // Lanczos-upscaled back to full size so AVAssetWriter sees consistent
    // dimensions regardless of captureScale). Override the encoder's target
    // dimensions to match the renderer's output. Otherwise AVAssetWriter
    // scales the buffer back to the recommended sensor size on encode and
    // the saved file ends up with the wrong dimensions.
    if let dims = recordingDims {
      videoSettings?[AVVideoWidthKey] = dims.width
      videoSettings?[AVVideoHeightKey] = dims.height
    }

    let videoWriterInput = mediaSettingsAVWrapper.assetWriterVideoInput(
      withOutputSettings: videoSettings)
    self.videoWriterInput = videoWriterInput

    // Encoded frames are always phone-upright, so how the phone was held at the start of the take
    // rides along as a track transform — frozen for the whole recording.
    videoWriterInput.avInput.transform = DefaultCamera.videoTransform(
      forDeviceOrientation: lockedCaptureOrientation != .unknown
        ? lockedCaptureOrientation : deviceOrientation)

    var sourcePixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: videoFormat
    ]
    // When the shader is active we feed the adaptor BGRA buffers from our
    // Metal recording pool. Tell the adaptor the exact dimensions and
    // request an IOSurface-backed pool so it doesn't have to copy/convert
    // each frame — critical at 4K/60.
    if let dims = recordingDims {
      sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] =
        kCVPixelFormatType_32BGRA
      sourcePixelBufferAttributes[kCVPixelBufferWidthKey as String] = dims.width
      sourcePixelBufferAttributes[kCVPixelBufferHeightKey as String] = dims.height
      sourcePixelBufferAttributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
      sourcePixelBufferAttributes[kCVPixelBufferMetalCompatibilityKey as String] = true
    }

    videoAdaptor = inputPixelBufferAdaptorFactory(videoWriterInput, sourcePixelBufferAttributes)

    videoWriterInput.expectsMediaDataInRealTime = true

    // Add the audio input
    if mediaSettings.enableAudio {
      var audioChannelLayout = AudioChannelLayout()
      audioChannelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono

      let audioChannelLayoutData = withUnsafeBytes(of: &audioChannelLayout) { Data($0) }

      var audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100.0,
        AVNumberOfChannelsKey: 1,
        AVChannelLayoutKey: audioChannelLayoutData,
      ]

      if let audioBitrate = mediaSettings.audioBitrate {
        audioSettings[AVEncoderBitRateKey] = Int(audioBitrate)
      }

      let newAudioWriterInput = mediaSettingsAVWrapper.assetWriterAudioInput(
        withOutputSettings: audioSettings)
      newAudioWriterInput.expectsMediaDataInRealTime = true
      mediaSettingsAVWrapper.addInput(newAudioWriterInput, to: videoWriter)
      self.audioWriterInput = newAudioWriterInput
    }

    if flashMode == .torch {
      try? captureDevice.lockForConfiguration()
      captureDevice.torchMode = .on
      captureDevice.unlockForConfiguration()
    }

    mediaSettingsAVWrapper.addInput(videoWriterInput, to: videoWriter)

    captureVideoOutput.setSampleBufferDelegate(self, queue: captureSessionQueue)

    return true
  }

  func pauseVideoRecording() {
    isRecordingPaused = true
    isRecordingDisconnected = true
  }

  func resumeVideoRecording() {
    isRecordingPaused = false
  }

  func stopVideoRecording(completion: @escaping (Result<String, any Error>) -> Void) {
    guard isRecording else {
      let error = NSError(
        domain: NSCocoaErrorDomain,
        code: URLError.resourceUnavailable.rawValue,
        userInfo: [NSLocalizedDescriptionKey: "Video is not recording!"]
      )
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error)))
      return
    }

    isRecording = false
    // Order matters: when both are pending, the aspect-ratio path drops the
    // renderer, making any uniform/pool work performed by the scale path
    // moot. Apply aspect first; the scale path then either operates on the
    // (newly null) renderer — its `?.` chains no-op — or on the live one if
    // no aspect change was pending. `captureScale` is read as a field by
    // `buildRendererIfPossible` on the next rebuild, so the value still
    // sticks either way.
    //
    // No explicit reset of `shaderSourceUnsupported` here: the only way the
    // latch can be stale post-recording is if the source format changed,
    // and every source-format change point already resets it (the
    // `videoFormat` setter, `setDescriptionWhileRecording`,
    // `applyPendingAspectRatioIfNeeded`, and `maintainRenderer`'s
    // not-recording branch). Clearing it here would just force the next
    // sample buffer to re-run `canHandle` and re-latch when the format is
    // genuinely unsupported.
    applyPendingAspectRatioIfNeeded()
    applyPendingCaptureScaleIfNeeded()

    // When `isRecording` is true `startWriting` was already called so `videoWriter.status`
    // is always either `.writing` or `.failed` and `finishWriting` does not throw exceptions so
    // there is no need to check `videoWriter.status`
    //
    // The writer and path are captured here because a new recording can start
    // before `finishWriting` invokes its handler — by then `videoWriter` /
    // `videoRecordingPath` already describe the *new* take, and the teardown
    // below must neither touch the new graph nor report the new path.
    let finishingWriter = videoWriter
    let finishedRecordingPath = videoRecordingPath
    finishingWriter?.finishWriting { [weak self] in
      guard let strongSelf = self else { return }
      // Hop back to `captureSessionQueue`: the writer fields and the renderer
      // are owned by that queue, while `finishWriting` invokes this handler
      // on an arbitrary internal queue.
      strongSelf.captureSessionQueue.async { [weak self] in
        guard let strongSelf = self else { return }

        // The writer graph and the warm recording pools are only needed while
        // a take is active; at 4K they pin >100 MB of IOSurfaces. Release them
        // between recordings — the next `setupWriter` / first recording frame
        // recreates them. The parked previous renderer (pending aspect-ratio
        // rebuild) holds pools of its own until the hand-off frame arrives,
        // so it is invalidated too.
        if strongSelf.videoWriter === finishingWriter {
          strongSelf.videoWriter = nil
          strongSelf.videoWriterInput = nil
          strongSelf.audioWriterInput = nil
          strongSelf.videoAdaptor = nil
          strongSelf.videoRecordingPath = nil
          strongSelf.videoFrameRenderer?.invalidateRecordingPool()
          strongSelf.previousVideoFrameRenderer?.invalidateRecordingPool()
        }

        if finishingWriter?.status == .completed {
          strongSelf.updateOrientation()
          completion(.success(finishedRecordingPath!))
        } else {
          completion(
            .failure(
              PigeonError(
                code: "IOError",
                message: "AVAssetWriter could not finish writing!",
                details: nil)))
        }
      }
    }
  }

  func captureToFile(completion: @escaping (Result<String, any Error>) -> Void) {
    let prep = prepareCapture()

    let path: String
    do {
      path = try getTemporaryFilePath(
        withExtension: prep.fileExtension,
        subfolder: "pictures",
        prefix: "CAP_")
    } catch let error as NSError {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error)))
      return
    }

    let settings = prep.settings
    let savePhotoDelegate = SavePhotoDelegate(
      path: path,
      ioQueue: photoIOQueue,
      photoProcessor: makePhotoProcessor(renderer: prep.renderer, isHEIF: prep.isHEIF),
      completionHandler: { [weak self] path, error in
        guard let strongSelf = self else { return }

        strongSelf.captureSessionQueue.async { [weak self] in
          self?.inProgressSavePhotoDelegates.removeValue(forKey: settings.uniqueID)
        }

        if let error = error {
          completion(.failure(DefaultCamera.pigeonErrorFromNSError(error as NSError)))
        } else {
          assert(path != nil, "Path must not be nil if no error.")
          completion(.success(path!))
        }
      }
    )

    assert(
      DispatchQueue.getSpecific(key: captureSessionQueueSpecificKey)
        == captureSessionQueueSpecificValue,
      "save photo delegate references must be updated on the capture session queue")
    inProgressSavePhotoDelegates[settings.uniqueID] = savePhotoDelegate
    capturePhotoOutput.capturePhoto(with: settings, delegate: savePhotoDelegate)
  }

  /// Shared first-half of `captureToFile` and `captureToFilesWithOriginal`:
  /// lazily builds the renderer for this capture, picks the codec, and
  /// constructs the `AVCapturePhotoSettings`. The two paths diverge after
  /// this in temp-path generation and delegate construction.
  private func prepareCapture() -> (
    settings: AVCapturePhotoSettings,
    renderer: VideoFrameRenderer?,
    isHEIF: Bool,
    fileExtension: String
  ) {
    // Eagerly build the renderer if it hasn't been created yet (e.g. photo
    // requested before the first preview sample buffer arrived, or right
    // after `setAspectRatio` dropped the old renderer). Without this the
    // photo path silently skips all effects for that one capture.
    if videoFrameRenderer == nil, !shaderSourceUnsupported {
      let size = videoDimensionsConverter(captureDevice.flutterActiveFormat)
      buildRendererIfPossible(
        sourceWidth: Int(size.width),
        sourceHeight: Int(size.height),
        sourcePixelFormat: videoFormat)
    }

    let renderer = videoFrameRenderer
    let isHEIF = preferredVideoCodec == .hevc
    let settings = makePhotoSettings(useShaderPath: renderer != nil, isHEIF: isHEIF)
    let fileExtension = isHEIF ? "heif" : "jpg"
    return (settings, renderer, isHEIF, fileExtension)
  }

  /// Builds the `AVCapturePhotoSettings` for one capture. On the shader path
  /// we request raw BGRA so the renderer can re-encode from VRAM; if BGRA is
  /// not advertised we fall back to compressed delivery and the photo
  /// processor will decode via CGImage.
  private func makePhotoSettings(useShaderPath: Bool, isHEIF: Bool) -> AVCapturePhotoSettings {
    let settings: AVCapturePhotoSettings
    if useShaderPath,
      capturePhotoOutput.avOutput.availablePhotoPixelFormatTypes
        .contains(kCVPixelFormatType_32BGRA)
    {
      settings = AVCapturePhotoSettings(format: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ])
    } else {
      if useShaderPath {
        NSLog(
          "DefaultCamera: BGRA pixel format not available — using compressed delivery for shader path"
        )
      }
      settings =
        isHEIF
        ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        : AVCapturePhotoSettings()
    }

    // Must be applied *after* the format branch above: each
    // `AVCapturePhotoSettings(format:)` returns a fresh instance with the
    // flag reset to its default (false).
    //
    // `isHighResolutionPhotoEnabled` is deprecated in iOS 16 in favor of
    // `maxPhotoDimensions`. Migrating requires also configuring
    // `capturePhotoOutput.maxPhotoDimensions` at init; tracked as a follow-up.
    if mediaSettings.resolutionPreset == .max {
      settings.isHighResolutionPhotoEnabled = true
    }

    if flashMode != .torch {
      settings.flashMode = getAVCaptureFlashMode(for: flashMode)
    }
    settings.photoQualityPrioritization = .speed
    disableComputationalFusion(on: settings)
    return settings
  }

  /// Sibling of `captureToFile` that produces two files for the same shutter
  /// event: the un-effected original (with the configured `captureScale` crop
  /// preserved) and the shader-processed version. Both writes complete before
  /// the completion fires; if either fails, the partial success is rolled back
  /// inside `SavePhotoWithOriginalDelegate` so no orphan file is left behind.
  ///
  /// When the renderer is inactive the two files contain byte-identical raw
  /// photo data (there is no effect to apply, but the API contract — always
  /// return two paths — is preserved).
  func captureToFilesWithOriginal(
    completion: @escaping (
      Result<(originalPath: String, processedPath: String), any Error>
    ) -> Void
  ) {
    let prep = prepareCapture()

    let originalPath: String
    let processedPath: String
    do {
      originalPath = try getTemporaryFilePath(
        withExtension: prep.fileExtension,
        subfolder: "pictures",
        prefix: "CAP_ORIG_")
      processedPath = try getTemporaryFilePath(
        withExtension: prep.fileExtension,
        subfolder: "pictures",
        prefix: "CAP_PROC_")
    } catch let error as NSError {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error)))
      return
    }

    let settings = prep.settings
    let savePhotoDelegate = SavePhotoWithOriginalDelegate(
      originalPath: originalPath,
      processedPath: processedPath,
      ioQueue: photoIOQueue,
      originalProcessor: makeOriginalPhotoProcessor(renderer: prep.renderer, isHEIF: prep.isHEIF),
      processedProcessor: makePhotoProcessor(renderer: prep.renderer, isHEIF: prep.isHEIF),
      completionHandler: { [weak self] result in
        guard let strongSelf = self else { return }

        strongSelf.captureSessionQueue.async { [weak self] in
          self?.inProgressSavePhotoWithOriginalDelegates.removeValue(
            forKey: settings.uniqueID)
        }

        switch result {
        case .success(let paths):
          completion(.success(paths))
        case .failure(let error):
          completion(.failure(DefaultCamera.pigeonErrorFromNSError(error as NSError)))
        }
      }
    )

    assert(
      DispatchQueue.getSpecific(key: captureSessionQueueSpecificKey)
        == captureSessionQueueSpecificValue,
      "save photo delegate references must be updated on the capture session queue")
    inProgressSavePhotoWithOriginalDelegates[settings.uniqueID] = savePhotoDelegate
    capturePhotoOutput.capturePhoto(with: settings, delegate: savePhotoDelegate)
  }

  /// Photo processor closure for the **original** side of
  /// `captureToFilesWithOriginal`. Preserves the `captureScale` crop via the
  /// renderer's Core Image path, but never invokes `CameraShader.metal`. With
  /// no renderer falls back to the raw `fileDataRepresentation()`.
  ///
  /// On the BGRA pixel-buffer path we must always go through
  /// `renderOriginalImageData` — `fileDataRepresentation()` returns nil when
  /// the photo was requested in a raw pixel format. The compressed-delivery
  /// fallback can still short-circuit via `fileDataRepresentation()` when no
  /// crop/resample is configured.
  private func makeOriginalPhotoProcessor(
    renderer: VideoFrameRenderer?, isHEIF: Bool
  ) -> (AVCapturePhoto) -> Data? {
    guard let renderer = renderer else {
      return { photo in photo.fileDataRepresentation() }
    }
    let utType: CFString = isHEIF ? "public.heic" as CFString : "public.jpeg" as CFString
    return { photo in
      if let pixelBuffer = photo.pixelBuffer {
        return renderer.renderOriginalImageData(
          sourceBuffer: pixelBuffer,
          destinationUTType: utType,
          metadata: photo.metadata as CFDictionary)
      }
      // Compressed-delivery fallback — BGRA was unavailable when settings
      // were built, so the photo arrived as JPEG/HEIF. Logged so a silent
      // regression on the BGRA fast path stays observable.
      if let cgImage = photo.cgImageRepresentation() {
        if !renderer.photoOriginalRequiresProcessing(
          sourceWidth: cgImage.width, sourceHeight: cgImage.height),
          let fileData = photo.fileDataRepresentation()
        {
          return fileData
        }
        NSLog(
          "DefaultCamera: original photo arrived without pixelBuffer — falling back to CPU CGImage path."
        )
        return renderer.renderOriginalImageData(
          cgImage: cgImage,
          destinationUTType: utType,
          metadata: photo.metadata as CFDictionary)
      }
      return nil
    }
  }

  /// Photo processor closure for `SavePhotoDelegate`. With no renderer, falls
  /// back to the raw `fileDataRepresentation()`. With a renderer, encodes via
  /// Metal/CIContext from the raw pixel buffer, or via CGImage if compressed
  /// delivery was forced.
  private func makePhotoProcessor(
    renderer: VideoFrameRenderer?, isHEIF: Bool
  ) -> (AVCapturePhoto) -> Data? {
    guard let renderer = renderer else {
      return { photo in photo.fileDataRepresentation() }
    }
    let utType: CFString = isHEIF ? "public.heic" as CFString : "public.jpeg" as CFString
    return { photo in
      if let pixelBuffer = photo.pixelBuffer {
        return renderer.renderImageData(
          sourceBuffer: pixelBuffer,
          destinationUTType: utType,
          metadata: photo.metadata as CFDictionary)
      }
      // Compressed-delivery fallback: indicates BGRA was unavailable when
      // settings were built. Logged so a silent regression is observable.
      if let cgImage = photo.cgImageRepresentation() {
        NSLog(
          "DefaultCamera: photo arrived without pixelBuffer — falling back to CPU CGImage path."
        )
        return renderer.renderImageData(
          cgImage: cgImage,
          destinationUTType: utType,
          metadata: photo.metadata as CFDictionary)
      }
      return nil
    }
  }

  /// Disables Apple's multi-frame fusion paths so a future change to device
  /// discovery (e.g. adding a virtual multi-camera) cannot silently re-enable
  /// computational stacking.
  private func disableComputationalFusion(on settings: AVCapturePhotoSettings) {
    if capturePhotoOutput.avOutput.isVirtualDeviceFusionSupported {
      settings.isAutoVirtualDeviceFusionEnabled = false
    }
    if capturePhotoOutput.avOutput.isDualCameraFusionSupported {
      settings.isAutoDualCameraFusionEnabled = false
    }
  }

  private func getTemporaryFilePath(
    withExtension ext: String,
    subfolder: String,
    prefix: String
  ) throws -> String {
    let temporaryDirectory = FileManager.default.temporaryDirectory

    let fileDirectory = temporaryDirectory.appendingPathComponent("camera").appendingPathComponent(
      subfolder)
    let fileName = prefix + UUID().uuidString
    let file = fileDirectory.appendingPathComponent(fileName).appendingPathExtension(ext).path

    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: fileDirectory.path) {
      try fileManager.createDirectory(
        at: fileDirectory,
        withIntermediateDirectories: true,
        attributes: nil)
    }

    return file
  }

  private func updateOrientation() {
    guard !isRecording else { return }

    let orientation =
      (lockedCaptureOrientation != .unknown)
      ? lockedCaptureOrientation
      : deviceOrientation

    // Photo output only — the video connection is pinned to portrait at session setup, and a
    // recording takes its rotation from the asset writer's track transform instead.
    updateOrientation(orientation, forCaptureOutput: capturePhotoOutput)
  }

  /// Track rotation bringing a portrait-pinned capture upright for a device held at `orientation`.
  /// Applied to the writer input rather than the pixels, as iOS does for its own recordings.
  ///
  /// The landscape signs are calibrated against the device, not derived: `UIDeviceOrientation`
  /// names the side the home button ends up on, which runs opposite to the direction the device
  /// turned. Flipping either one alone lands 180° out — upside down rather than merely mirrored.
  private static func videoTransform(forDeviceOrientation orientation: UIDeviceOrientation)
    -> CGAffineTransform
  {
    switch orientation {
    case .landscapeLeft:
      return CGAffineTransform(rotationAngle: -.pi / 2)
    case .landscapeRight:
      return CGAffineTransform(rotationAngle: .pi / 2)
    case .portraitUpsideDown:
      return CGAffineTransform(rotationAngle: .pi)
    default:
      return .identity
    }
  }

  private func updateOrientation(
    _ orientation: UIDeviceOrientation, forCaptureOutput captureOutput: CaptureOutput
  ) {
    if let connection = captureOutput.connection(with: .video),
      connection.isVideoOrientationSupported
    {
      connection.videoOrientation = videoOrientation(forDeviceOrientation: orientation)
    }
  }

  private func videoOrientation(forDeviceOrientation deviceOrientation: UIDeviceOrientation)
    -> AVCaptureVideoOrientation
  {
    switch deviceOrientation {
    case .portrait:
      return .portrait
    case .landscapeLeft:
      return .landscapeRight
    case .landscapeRight:
      return .landscapeLeft
    case .portraitUpsideDown:
      return .portraitUpsideDown
    default:
      return .portrait
    }
  }

  func lockCaptureOrientation(_ pigeonOrientation: PlatformDeviceOrientation) {
    let orientation = getUIDeviceOrientation(for: pigeonOrientation)
    if lockedCaptureOrientation != orientation {
      lockedCaptureOrientation = orientation
      updateOrientation()
    }
  }

  func unlockCaptureOrientation() {
    lockedCaptureOrientation = .unknown
    updateOrientation()
  }

  func setImageFileFormat(_ fileFormat: PlatformImageFileFormat) {
    self.fileFormat = fileFormat
  }

  /// Codec that the photo and video encoders should agree on. HEVC when the
  /// user selected HEIF and the device's photo output can produce HEVC,
  /// otherwise H.264 — the only other AVAssetWriter video codec we configure.
  private var preferredVideoCodec: AVVideoCodecType {
    (fileFormat == .heif && capturePhotoOutput.availablePhotoCodecTypes.contains(.hevc))
      ? .hevc : .h264
  }

  /// Pins the queue contract for state mutated here and read on the
  /// sample-buffer callback (also on `captureSessionQueue`). The Pigeon API
  /// shims in `CameraPlugin` hop onto this queue before invoking each
  /// setter, so the renderer-adjacent fields (`aspectRatio`,
  /// `currentEffectsValues`, `pendingAspectRatio`, `pendingCaptureScale`,
  /// `captureScale`, `captureCornerRadius`) are written and read on a single
  /// serial queue. Asserting here so a future caller that bypasses the
  /// CameraPlugin dispatch produces a torn-read crash in DEBUG instead of
  /// silently feeding bad values into the realtime video path.
  private func assertOnCaptureSessionQueue() {
    assert(
      DispatchQueue.getSpecific(key: captureSessionQueueSpecificKey)
        == captureSessionQueueSpecificValue,
      "Must be called on captureSessionQueue — renderer state would race with the sample-buffer callback otherwise."
    )
  }

  func setEffectsValues(_ values: PlatformEffectsValues) {
    assertOnCaptureSessionQueue()
    let previousPath = currentEffectsValues?.grainNoisePath
    let previousLutPath = currentEffectsValues?.lutFilePath
    currentEffectsValues = values

    // Finiteness and range are enforced at the Dart `EffectsValues`
    // constructor, so per-field guards here would only mask bugs in callers
    // that bypass the Dart layer.
    videoFrameRenderer?.updateUniforms { $0.apply(values) }
    videoFrameRenderer?.updateGrainSize(Float(values.grainSize))

    // Only touch the grain texture when the path actually changes, avoiding
    // redundant background loads on every setEffectsValues call.
    let newPath = values.grainNoisePath
    if newPath != previousPath {
      if let path = newPath {
        videoFrameRenderer?.loadGrainTexture(path: path)
      } else {
        videoFrameRenderer?.clearGrainTexture()
      }
    }

    // Same change-detection contract as grain: only (re)load when the path
    // actually changes, and free the GPU texture when it goes back to nil.
    let newLutPath = values.lutFilePath
    if newLutPath != previousLutPath {
      if let path = newLutPath {
        videoFrameRenderer?.loadLutTexture(path: path)
      } else {
        videoFrameRenderer?.clearLutTexture()
      }
    }
  }

  /// Re-orients `aspectRatio` to match the orientation of an incoming source
  /// buffer of `sw × sh` pixels. The user-facing `aspectRatio` describes the
  /// *shape* of the desired rectangle (`< 1` portrait, `> 1` landscape) in
  /// the user's intended orientation; when the buffer arrives rotated to a
  /// different orientation (e.g. landscape device with a portrait ratio),
  /// we invert it so the crop produces a buffer in the same orientation as
  /// the device — i.e. rotation-follows-device. Returns `nil` (no crop) when
  /// the user passed `nil`, non-finite, or non-positive. Square ratios
  /// (`== 1`) pass through unchanged.
  private func effectiveAspectRatio(forSourceWidth sw: Int, sourceHeight sh: Int) -> Double? {
    guard let r = aspectRatio, r > 0, r.isFinite else { return aspectRatio }
    guard sw > 0, sh > 0 else { return r }
    let sourceIsLandscape = sw > sh
    let ratioIsLandscape = r > 1
    if sourceIsLandscape == ratioIsLandscape || r == 1.0 {
      return r
    }
    return 1.0 / r
  }

  /// Sensor-landscape interpretation of the user's `aspectRatio`. Photo
  /// sample buffers always arrive in sensor (landscape) orientation
  /// regardless of device rotation — the EXIF orientation tag carries the
  /// rotation hint applied at display time. So the sensor-space crop ratio
  /// is always the landscape form of the user's shape (`>= 1`), and EXIF
  /// brings the displayed result back to the requested orientation
  /// (portrait or landscape) according to the device's orientation at
  /// capture time. Returns `nil` for the no-crop case.
  private func sensorSpaceAspectRatio() -> Double? {
    guard let r = aspectRatio, r > 0, r.isFinite else { return aspectRatio }
    return r >= 1.0 ? r : 1.0 / r
  }

  /// Builds the Metal renderer for the given source dimensions / pixel format.
  /// Idempotent — does nothing if the renderer is already alive or the source
  /// has been latched as unsupported. Called from the sample-buffer callback
  /// (where we know the real source from the buffer) and from
  /// `setUpVideoRecording` (where we have to size the AVAssetWriter *before*
  /// the first sample buffer arrives, so we use the active format's
  /// dimensions and the camera's current `videoFormat`).
  private func buildRendererIfPossible(
    sourceWidth: Int, sourceHeight: Int, sourcePixelFormat: OSType
  ) {
    guard videoFrameRenderer == nil, !shaderSourceUnsupported else { return }
    guard sourceWidth > 0, sourceHeight > 0 else { return }
    guard VideoFrameRenderer.canHandle(pixelFormat: sourcePixelFormat) else {
      NSLog(
        "DefaultCamera: shader disabled — unsupported source pixel format \(String(format: "0x%08X", sourcePixelFormat))"
      )
      shaderSourceUnsupported = true
      return
    }

    // Re-orient the user-supplied aspect ratio to the current buffer's
    // orientation. `aspectRatio` describes the *shape* of the desired
    // rectangle (portrait if < 1, landscape if > 1); the device-orientation
    // adaptation happens here so that on a rotation the crop produces a
    // buffer whose pixel dimensions match the on-screen rectangle the user
    // expects (rotation-follows-device). Without this, applying e.g. 0.8 to
    // a landscape source (sw > sh) yields a portrait-pixel texture that
    // `landscapePreviewSize` mis-normalises, and Flutter's `AspectRatio`
    // then stretches the preview to fill a landscape box.
    //
    // During recording the renderer is not rebuilt (AVAssetWriter is locked
    // to the renderer's output dimensions), so the orientation that was
    // active at recording start is baked in for the duration of the take.
    let effectiveAspectRatio = effectiveAspectRatio(
      forSourceWidth: sourceWidth, sourceHeight: sourceHeight)
    let crop = VideoFrameRenderer.croppedDimensions(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      targetRatio: effectiveAspectRatio)
    // Sensor-space ratio handed to the renderer for the photo path. Photo
    // sample buffers always arrive in sensor (landscape) orientation
    // regardless of device rotation; EXIF carries the rotation hint. So the
    // photo crop is computed in sensor-landscape space and a viewer rotates
    // the result back to match the device orientation at capture time.
    let sensorAspectRatio = sensorSpaceAspectRatio()
    // Cap the preview-path output at the device's screen-shorter-side in
    // physical pixels. Recording / photo paths still render at the full
    // `crop.width × crop.height`, so this is purely a preview-cost reduction.
    // Rationale: the on-screen preview is sampled by Flutter into a
    // FlutterView that never exceeds the screen, so anything larger is
    // wasted shader work — and heavy effects (49-tap blur, mist) are
    // dominated by output fragment count.
    let previewCap = DefaultCamera.screenShorterSidePixels()
    NSLog(
      "DefaultCamera: shader pipeline starting at \(sourceWidth)x\(sourceHeight) → \(crop.width)x\(crop.height) (aspect=\(String(describing: aspectRatio)) effective=\(String(describing: effectiveAspectRatio)) sensor=\(String(describing: sensorAspectRatio))) format=\(String(format: "0x%08X", sourcePixelFormat)) previewCap=\(previewCap)"
    )
    let renderer = VideoFrameRenderer(
      width: crop.width, height: crop.height, targetRatio: sensorAspectRatio,
      sourceWidth: sourceWidth, sourceHeight: sourceHeight,
      sourcePixelFormat: sourcePixelFormat,
      previewMaxShorterSide: previewCap)
    videoFrameRenderer = renderer
    // Hand the already-decoded LUT / grain textures from the previous renderer
    // (if any) over to the new one before any frame is rendered, so the
    // preview keeps applying them without a one-frame flash while the async
    // re-load completes. Drop the reference unconditionally so a failed
    // rebuild (e.g. Metal init returns nil, source format latched as
    // unsupported) cannot leak the old renderer's textures and pools
    // indefinitely.
    let previous = previousVideoFrameRenderer
    previousVideoFrameRenderer = nil
    if let renderer = renderer {
      if let previous = previous {
        renderer.adoptTextures(from: previous)
      }
      renderer.updateUniforms {
        $0.uvScale = crop.uvScale
        $0.captureScale = captureScale
        $0.captureCornerRadius = captureCornerRadius
        if let values = currentEffectsValues {
          $0.apply(values)
        }
      }
      // Re-apply grain pixel size and trigger texture load on the new renderer.
      // The path is always re-loaded here because this is a brand-new renderer
      // instance and it does not have a texture yet, even if the path hasn't
      // changed since the last build.
      if let values = currentEffectsValues {
        renderer.updateGrainSize(Float(values.grainSize))
        if let path = values.grainNoisePath {
          renderer.loadGrainTexture(path: path)
        }
        if let lutPath = values.lutFilePath {
          renderer.loadLutTexture(path: lutPath)
        }
      }
      updatePreviewSize(
        width: CGFloat(renderer.outputWidth),
        height: CGFloat(renderer.outputHeight))
    } else {
      shaderSourceUnsupported = true
    }
  }

  /// Parks the live renderer in `previousVideoFrameRenderer` so the next
  /// `buildRendererIfPossible` can adopt its LUT / grain textures, and drops
  /// `videoFrameRenderer` so the next sample buffer triggers that rebuild.
  /// The parked instance never renders again, so its 24-fps grain timer is
  /// stopped here — it would otherwise keep firing until the hand-off frame
  /// arrives, which may be never if the session is stopped.
  private func parkRendererForRebuild() {
    previousVideoFrameRenderer = videoFrameRenderer
    previousVideoFrameRenderer?.stopGrainAnimation()
    videoFrameRenderer = nil
    shaderSourceUnsupported = false
  }

  func setAspectRatio(_ aspectRatio: Double?) {
    assertOnCaptureSessionQueue()
    if isRecording {
      // Aspect changes rebuild the renderer (new output dimensions), which
      // would invalidate the AVAssetWriter's pixel-buffer adaptor. Stash the
      // requested ratio and apply it once recording stops.
      //
      // Always stash, even when the requested value matches `self.aspectRatio`:
      // a previous in-recording call may have stashed a *different* value, and
      // the user's most recent request must win on stop. If the desired value
      // happens to match the currently-applied one, store `.set` with that
      // value — `applyPendingAspectRatioIfNeeded` will no-op the rebuild.
      pendingAspectRatio = .set(aspectRatio)
      return
    }
    guard self.aspectRatio != aspectRatio else { return }
    self.aspectRatio = aspectRatio
    // Drop the renderer so the next sample buffer rebuilds it at the new
    // output dimensions. Cheap because MetalSetup is cached. Stash the old
    // renderer so the rebuilt one can adopt its LUT / grain textures and
    // avoid a one-frame un-filtered preview while async re-loads complete.
    parkRendererForRebuild()
  }

  func setCaptureScale(_ scale: Double) {
    assertOnCaptureSessionQueue()
    // The Dart side (CameraController.setCaptureScale) validates finiteness
    // and clamps to the supported [0.1, 1.0] range, so we trust the input
    // here. Keep a single defensive `isFinite` check so a misbehaving
    // alternative client cannot poison the shader with NaN.
    guard scale.isFinite else { return }
    let scaleValue = Float(scale)
    // Recording output dimensions no longer change with captureScale (the
    // renderer Lanczos-upscales internally so AVAssetWriter sees a constant
    // size). But changing scale mid-recording would still force the scaled
    // intermediate pool to be rebuilt at new dimensions, racing against
    // `renderForRecording` and risking torn frames. Stash the value and
    // apply on stop so the pool swap happens in a quiescent window.
    if isRecording {
      pendingCaptureScale = scaleValue
      return
    }
    guard scaleValue != captureScale else { return }
    captureScale = scaleValue
    videoFrameRenderer?.updateUniforms { $0.captureScale = scaleValue }
    videoFrameRenderer?.invalidateRecordingPool()
  }

  /// Applies a `captureScale` change that was deferred during a recording.
  /// Called from `stopVideoRecording` once `isRecording` is back to false.
  private func applyPendingCaptureScaleIfNeeded() {
    guard let pending = pendingCaptureScale else { return }
    pendingCaptureScale = nil
    guard pending != captureScale else { return }
    captureScale = pending
    videoFrameRenderer?.updateUniforms { $0.captureScale = pending }
    videoFrameRenderer?.invalidateRecordingPool()
  }

  func setCaptureCornerRadius(_ radius: Double) {
    assertOnCaptureSessionQueue()
    // Clamp to [0, 1] — 0 = square corners, 1 = maximal rounding.
    guard radius.isFinite else { return }
    let r = Float(max(0.0, min(1.0, radius)))
    guard r != captureCornerRadius else { return }
    captureCornerRadius = r
    // captureCornerRadius only affects preview passes (darkenOutside > 0);
    // recording passes always have insideScaled = true regardless, so no
    // deferral during recording is needed.
    videoFrameRenderer?.updateUniforms { $0.captureCornerRadius = r }
  }

  /// Applies an `aspectRatio` change that was deferred during a recording.
  /// Called from `stopVideoRecording` once `isRecording` is back to false.
  /// Rebuilds the renderer so the new ratio takes effect on the next frame.
  private func applyPendingAspectRatioIfNeeded() {
    guard case .set(let pending) = pendingAspectRatio else { return }
    pendingAspectRatio = .none
    guard pending != aspectRatio else { return }
    aspectRatio = pending
    // Same texture hand-off as `setAspectRatio` — keep the LUT / grain
    // visible across the rebuild that happens on the next sample buffer.
    parkRendererForRebuild()
  }

  /// Updates `previewSize` and notifies Dart. Called whenever the renderer's
  /// output dimensions change (initial setup or aspect ratio change).
  /// Normalizes to the sensor-landscape convention (longer axis = width) so
  /// the existing `CameraPreview` widget's portrait inversion math sizes
  /// the `AspectRatio` box correctly.
  ///
  /// Must be called on `captureSessionQueue` — the same queue all other
  /// `previewSize` reads/writes use, so the assignment is race-free.
  private func updatePreviewSize(width: CGFloat, height: CGFloat) {
    let newSize = DefaultCamera.landscapePreviewSize(
      width: Int(width), height: Int(height))
    guard newSize != previewSize else { return }
    previewSize = newSize
    // Only broadcast after the camera has been reported as initialized.
    // `buildRendererIfPossible` may fire on the first sample buffer before
    // `reportInitializationState` has dispatched `initialized` to Dart, and
    // a `previewSizeChanged` arriving before `initialized` confuses the
    // Flutter layer.
    guard isInitialized else { return }
    let platformSize = PlatformSize(
      width: Double(newSize.width), height: Double(newSize.height))
    ensureToRunOnMainQueue { [weak self] in
      self?.dartAPI?.previewSizeChanged(size: platformSize) { _ in
        // Best-effort broadcast.
      }
    }
  }

  /// Ensures the renderer is in sync with `newBuffer`'s actual dimensions and
  /// pixel format. Called once per video sample buffer before any rendering.
  ///
  /// Three states:
  ///   - No renderer yet (and not latched as unsupported): try to build one.
  ///   - Renderer alive and matches the source: no-op.
  ///   - Renderer alive but source dims/format changed: rebuild if not
  ///     recording (AVAssetWriter would reject a dimension change), or
  ///     update the renderer's source-tracking fields in place while
  ///     recording.
  ///
  /// Must be called on `captureSessionQueue`.
  private func maintainRenderer(for newBuffer: CVPixelBuffer) {
    if videoFrameRenderer == nil, !shaderSourceUnsupported {
      let format = CVPixelBufferGetPixelFormatType(newBuffer)
      let bufferWidth = CVPixelBufferGetWidth(newBuffer)
      let bufferHeight = CVPixelBufferGetHeight(newBuffer)
      buildRendererIfPossible(
        sourceWidth: bufferWidth,
        sourceHeight: bufferHeight,
        sourcePixelFormat: format)
      return
    }
    guard let renderer = videoFrameRenderer else { return }

    let format = CVPixelBufferGetPixelFormatType(newBuffer)
    let bufferWidth = CVPixelBufferGetWidth(newBuffer)
    let bufferHeight = CVPixelBufferGetHeight(newBuffer)
    let dimsChanged =
      renderer.sourceWidth != bufferWidth || renderer.sourceHeight != bufferHeight
    let formatChanged = renderer.sourcePixelFormat != format
    guard dimsChanged || formatChanged else { return }

    if !isRecording {
      // Park and rebuild: source dimensions or pixel format changed while not
      // recording. The rebuild recomputes uvScale and resets
      // sourcePixelFormat so the correct fragment pipeline is selected going
      // forward, and `parkRendererForRebuild` resets shaderSourceUnsupported
      // in case the old sensor had an unsupported format that blocked the
      // pipeline. Parking (rather than a bare `= nil`) matters twice over:
      // an in-flight photo delegate strongly retains the old renderer via its
      // processor closure, so its 24-fps grain timer must be stopped or it
      // would keep firing until that capture completes; and the immediate
      // rebuild below can then adopt the old renderer's decoded LUT / grain
      // textures instead of flashing un-filtered while they re-decode.
      parkRendererForRebuild()
      buildRendererIfPossible(
        sourceWidth: bufferWidth,
        sourceHeight: bufferHeight,
        sourcePixelFormat: format)
      return
    }

    // Recording: keep the renderer (AVAssetWriter is locked to its output
    // dimensions). If dims changed, recompute uvScale for the new source
    // size. submitRender already selects the correct fragment pipeline
    // per-frame from the buffer's actual format, so the encoded output is
    // correct regardless of formatChanged — we only update the tracked field
    // so `renderer.sourcePixelFormat` stays consistent with the live source.
    if dimsChanged {
      renderer.updateSourceDimensions(width: bufferWidth, height: bufferHeight)
    }
    if formatChanged {
      renderer.updateSourcePixelFormat(format)
    }
  }

  /// Returns the buffer to publish to the Flutter preview texture, or nil to
  /// drop this frame. Renders via the renderer's pool when one is active so
  /// Flutter's retention of CVPixelBuffers cannot starve AVCapture's internal
  /// pool — except when `canBypassPreview` confirms the shader would be a
  /// no-op, in which case we publish the source directly and skip the GPU
  /// pass entirely (vanilla path with no effects / crop configured).
  private func renderForPreview(_ newBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    guard let renderer = videoFrameRenderer else { return newBuffer }
    if renderer.canBypassPreview(
      sourcePixelFormat: CVPixelBufferGetPixelFormatType(newBuffer),
      sourceWidth: CVPixelBufferGetWidth(newBuffer),
      sourceHeight: CVPixelBufferGetHeight(newBuffer))
    {
      return newBuffer
    }
    return renderer.render(newBuffer, blocking: false)
  }

  /// Returns a recording-pool buffer for this sample if the renderer is
  /// active and the AVAssetWriter is in `.writing`, otherwise nil.
  ///
  /// Blocks on the recording semaphore so we never drop a frame from the
  /// MP4 (vs. preview, which drops). Gated on `.writing` so we don't waste
  /// GPU work and a recording-pool slot on frames that arrive between
  /// `isRecording` flipping true and the AVAssetWriter actually accepting
  /// buffers (the window between `startWriting()` returning and the writer's
  /// state machine transitioning to `.writing`).
  ///
  /// A nil return when the renderer is active is later interpreted in the
  /// recording path as a frame drop (see the `recordingVideoBuffer == nil`
  /// log site below) — we MUST NOT fall back to `newBuffer` because the
  /// adaptor was configured for the renderer's output dimensions.
  private func renderForRecordingIfNeeded(_ newBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    guard isRecording,
      videoWriter?.status == .writing,
      let renderer = videoFrameRenderer
    else {
      return nil
    }
    return renderer.renderForRecording(newBuffer)
  }

  func setExposureMode(_ mode: PlatformExposureMode) {
    exposureMode = mode
    applyExposureMode()
  }

  private func applyExposureMode() {
    try? captureDevice.lockForConfiguration()
    switch exposureMode {
    case .locked:
      // AVCaptureExposureMode.autoExpose automatically adjusts the exposure one time, and then locks exposure for the device
      captureDevice.exposureMode = .autoExpose
    case .auto:
      if captureDevice.isExposureModeSupported(.continuousAutoExposure) {
        captureDevice.exposureMode = .continuousAutoExposure
      } else {
        captureDevice.exposureMode = .autoExpose
      }
    @unknown default:
      assertionFailure("Unknown exposure mode")
    }
    captureDevice.unlockForConfiguration()
  }

  func setExposureOffset(_ offset: Double) {
    try? captureDevice.lockForConfiguration()
    captureDevice.setExposureTargetBias(Float(offset), completionHandler: nil)
    captureDevice.unlockForConfiguration()
  }

  func setExposurePoint(
    _ point: PlatformPoint?, withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    guard captureDevice.isExposurePointOfInterestSupported else {
      completion(
        .failure(
          PigeonError(
            code: "setExposurePointFailed",
            message: "Device does not have exposure point capabilities",
            details: nil)))
      return
    }

    try? captureDevice.lockForConfiguration()
    // A nil point resets to the center.
    let exposurePoint = cgPoint(for: point ?? PlatformPoint(x: 0.5, y: 0.5))
    captureDevice.exposurePointOfInterest = exposurePoint
    captureDevice.unlockForConfiguration()
    // Retrigger auto exposure
    applyExposureMode()
    completion(.success(()))
  }

  func setFocusMode(_ mode: PlatformFocusMode) {
    focusMode = mode
    applyFocusMode()
  }

  func setFocusPoint(
    _ point: PlatformPoint?, completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    guard captureDevice.isFocusPointOfInterestSupported else {
      completion(
        .failure(
          PigeonError(
            code: "setFocusPointFailed",
            message: "Device does not have focus point capabilities",
            details: nil)))
      return
    }

    try? captureDevice.lockForConfiguration()
    // A nil point resets to the center.
    captureDevice.focusPointOfInterest = cgPoint(for: point ?? PlatformPoint(x: 0.5, y: 0.5))

    captureDevice.unlockForConfiguration()
    // Retrigger auto focus
    applyFocusMode()
    completion(.success(()))
  }

  private func applyFocusMode() {
    applyFocusMode(focusMode, onDevice: captureDevice)
  }

  private func applyFocusMode(
    _ focusMode: PlatformFocusMode, onDevice captureDevice: CaptureDevice
  ) {
    try? captureDevice.lockForConfiguration()
    switch focusMode {
    case .locked:
      // AVCaptureFocusMode.autoFocus automatically adjusts the focus one time, and then locks focus
      if captureDevice.isFocusModeSupported(.autoFocus) {
        captureDevice.focusMode = .autoFocus
      }
    case .auto:
      if captureDevice.isFocusModeSupported(.continuousAutoFocus) {
        captureDevice.focusMode = .continuousAutoFocus
      } else if captureDevice.isFocusModeSupported(.autoFocus) {
        captureDevice.focusMode = .autoFocus
      }
    @unknown default:
      assertionFailure("Unknown focus mode")
    }
    captureDevice.unlockForConfiguration()
  }

  func setWhiteBalance(
    _ values: PlatformWhiteBalanceValues?,
    withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    assertOnCaptureSessionQueue()
    do {
      try applyWhiteBalance(values)
      currentWhiteBalanceValues = values
      completion(.success(()))
    } catch let error as PigeonError {
      completion(.failure(error))
    } catch let error as NSError {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error)))
    }
  }

  func isWhiteBalanceSupported() -> Bool {
    // The mode `applyWhiteBalance` needs for a lock; auto is mandatory on every
    // capture device, so it is the locked mode that decides whether the control
    // can be offered at all.
    return captureDevice.isWhiteBalanceModeSupported(.locked)
  }

  /// Applies a white-balance configuration to the *current* `captureDevice`.
  /// Pass `nil` to enter continuous auto white balance, or a value to lock
  /// the gains at the requested temperature/tint.
  ///
  /// Throws `PigeonError` when the requested mode is unsupported, or a raw
  /// `NSError` when `lockForConfiguration` fails.
  ///
  /// Updates `isWhiteBalanceLocked` and the KVO observation as a side effect,
  /// but does **not** touch `currentWhiteBalanceValues` — callers decide
  /// whether to remember the requested values (the Pigeon entry point does;
  /// the device-switch re-apply does not, since it's just re-asserting the
  /// already-stored value).
  private func applyWhiteBalance(_ values: PlatformWhiteBalanceValues?) throws {
    if let values = values {
      guard captureDevice.isWhiteBalanceModeSupported(.locked) else {
        throw PigeonError(
          code: "setWhiteBalanceFailed",
          message: "Device does not support manual white balance",
          details: nil)
      }
      let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
        temperature: Float(values.temperature), tint: Float(values.tint))
      var gains = captureDevice.deviceWhiteBalanceGains(for: tempAndTint)
      let maxGain = captureDevice.maxWhiteBalanceGain
      gains.redGain = min(max(gains.redGain, 1.0), maxGain)
      gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
      gains.blueGain = min(max(gains.blueGain, 1.0), maxGain)
      // `lockForConfiguration` can throw; do the mutation inside a
      // `defer`-guarded scope so an unlock failure path doesn't leave the
      // device half-configured. Software bookkeeping (the locked flag and
      // KVO observation) only flips *after* the device successfully
      // transitions, so an early throw can't desync them from reality.
      try captureDevice.lockForConfiguration()
      defer { captureDevice.unlockForConfiguration() }
      captureDevice.setWhiteBalanceModeLocked(
        withDeviceWhiteBalanceGains: gains, completionHandler: nil)
      // Stop observation *before* flipping the flag so any in-flight KVO
      // callback already enqueued on captureSessionQueue sees the new state
      // and bails (the closure checks both observation != nil and
      // isWhiteBalanceLocked).
      stopObservingAutoWhiteBalance()
      isWhiteBalanceLocked = true
    } else {
      guard captureDevice.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else {
        throw PigeonError(
          code: "setWhiteBalanceFailed",
          message: "Device does not support auto white balance",
          details: nil)
      }
      try captureDevice.lockForConfiguration()
      defer { captureDevice.unlockForConfiguration() }
      captureDevice.whiteBalanceMode = .continuousAutoWhiteBalance
      // Same ordering as the locked branch: the device transition above must
      // succeed before we flip the cached state and (re)start observing.
      isWhiteBalanceLocked = false
      startObservingAutoWhiteBalance()
    }
  }

  /// Starts observing `deviceWhiteBalanceGains` on the underlying
  /// AVCaptureDevice. While in auto white balance, dispatches the converted
  /// temperature/tint to Dart at most every
  /// `autoWhiteBalanceMinInterval` seconds. No-op if already observing.
  private func startObservingAutoWhiteBalance() {
    guard whiteBalanceObservation == nil else { return }
    let avDevice = captureDevice.avDevice
    // KVO can fire at ~30–60 Hz on whatever thread AVFoundation mutates the
    // observed property from. Throttle on the calling thread so most fires
    // exit cheaply without enqueueing throw-away work onto
    // `captureSessionQueue` (which owns the realtime sample-buffer callback).
    // Only hop the queue when an emission is actually due. The post-hop
    // checks remain the source of truth: a torn read of
    // `nextAutoWhiteBalanceEmission` can at worst let one extra block reach
    // the queue, which the downstream checks will discard.
    whiteBalanceObservation = avDevice.observe(
      \.deviceWhiteBalanceGains, options: [.new]
    ) { [weak self] device, _ in
      guard let self = self else { return }
      guard self.whiteBalanceObservation != nil,
        !self.isWhiteBalanceLocked
      else { return }
      let now = Date()
      guard now >= self.nextAutoWhiteBalanceEmission else { return }
      let gains = device.deviceWhiteBalanceGains
      let maxGain = device.maxWhiteBalanceGain
      // Gains must be in [1, maxWhiteBalanceGain]; out-of-range values occur
      // transiently during startup and cause temperatureAndTintValues to throw.
      guard gains.redGain >= 1.0, gains.redGain <= maxGain,
        gains.greenGain >= 1.0, gains.greenGain <= maxGain,
        gains.blueGain >= 1.0, gains.blueGain <= maxGain
      else { return }
      let values = device.temperatureAndTintValues(for: gains)
      // Skip non-finite values (can occur transiently right after the
      // device starts).
      guard values.temperature.isFinite, values.tint.isFinite else { return }
      let temperature = Double(values.temperature)
      let tint = Double(values.tint)
      self.captureSessionQueue.async { [weak self] in
        guard let self = self else { return }
        // Re-check the observation is still active and bound to this device.
        // If it has been torn down (camera switch, lock) we must not emit.
        // Re-check the throttle gate as the source of truth (the calling-thread
        // check above is an optimistic early-out).
        guard self.whiteBalanceObservation != nil,
          !self.isWhiteBalanceLocked,
          now >= self.nextAutoWhiteBalanceEmission
        else { return }
        self.nextAutoWhiteBalanceEmission = now.addingTimeInterval(
          DefaultCamera.autoWhiteBalanceMinInterval)
        ensureToRunOnMainQueue { [weak self] in
          self?.dartAPI?.autoWhiteBalanceChanged(
            temperature: temperature, tint: tint
          ) { _ in
            // Best-effort broadcast.
          }
        }
      }
    }
  }

  /// Stops the auto white balance observation, if active.
  private func stopObservingAutoWhiteBalance() {
    whiteBalanceObservation?.invalidate()
    whiteBalanceObservation = nil
    nextAutoWhiteBalanceEmission = .distantPast
  }

  /// Maps a point normalised in preview space to the capture device's sensor space. A fixed 90° ccw
  /// rotation, not one that tracks the device: the preview is pinned to portrait, so its coordinate
  /// space no longer turns with the phone.
  private func cgPoint(for point: PlatformPoint) -> CGPoint {
    return CGPoint(x: point.y, y: 1 - point.x)
  }

  func setZoomLevel(
    _ zoom: CGFloat, withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    if zoom < captureDevice.minAvailableVideoZoomFactor
      || zoom > captureDevice.maxAvailableVideoZoomFactor
    {
      completion(
        .failure(
          PigeonError(
            code: "ZOOM_ERROR",
            message:
              "Zoom level out of bounds (zoom level should be between \(captureDevice.minAvailableVideoZoomFactor) and \(captureDevice.maxAvailableVideoZoomFactor).",
            details: nil)))
      return
    }

    do {
      try captureDevice.lockForConfiguration()
    } catch let error as NSError {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error)))
      return
    }

    captureDevice.videoZoomFactor = zoom
    captureDevice.unlockForConfiguration()
    completion(.success(()))
  }

  func setVideoStabilizationMode(
    _ mode: PlatformVideoStabilizationMode,
    withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    let stabilizationMode = getAvCaptureVideoStabilizationMode(mode)

    guard captureDevice.isVideoStabilizationModeSupported(stabilizationMode) else {
      completion(
        .failure(
          PigeonError(
            code: "VIDEO_STABILIZATION_ERROR",
            message: "Unavailable video stabilization mode.",
            details: [
              "requested_mode": stabilizationMode.rawValue
            ]
          ))
      )
      return
    }
    if let connection = captureVideoOutput.connection(with: .video) {
      connection.preferredVideoStabilizationMode = stabilizationMode
    }
    completion(.success(()))
  }

  func isVideoStabilizationModeSupported(_ mode: PlatformVideoStabilizationMode) -> Bool {
    let stabilizationMode = getAvCaptureVideoStabilizationMode(mode)
    return captureDevice.isVideoStabilizationModeSupported(stabilizationMode)
  }

  func setFlashMode(
    _ mode: PlatformFlashMode,
    withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    switch mode {
    case .torch:
      guard captureDevice.hasTorch else {
        completion(
          .failure(
            PigeonError(
              code: "setFlashModeFailed",
              message: "Device does not support torch mode",
              details: nil))
        )
        return
      }
      guard captureDevice.isTorchAvailable else {
        completion(
          .failure(
            PigeonError(
              code: "setFlashModeFailed",
              message: "Torch mode is currently not available",
              details: nil)))
        return
      }
      if captureDevice.torchMode != .on {
        try? captureDevice.lockForConfiguration()
        captureDevice.torchMode = .on
        captureDevice.unlockForConfiguration()
      }
    case .off, .auto, .always:
      guard captureDevice.hasFlash else {
        completion(
          .failure(
            PigeonError(
              code: "setFlashModeFailed",
              message: "Device does not have flash capabilities",
              details: nil)))
        return
      }
      let avFlashMode = getAVCaptureFlashMode(for: mode)
      guard capturePhotoOutput.supportedFlashModes.contains(avFlashMode)
      else {
        completion(
          .failure(
            PigeonError(
              code: "setFlashModeFailed",
              message: "Device does not support this specific flash mode",
              details: nil)))
        return
      }
      if captureDevice.torchMode != .off {
        try? captureDevice.lockForConfiguration()
        captureDevice.torchMode = .off
        captureDevice.unlockForConfiguration()
      }
    @unknown default:
      assertionFailure("Unknown flash mode")
    }

    flashMode = mode
    completion(.success(()))
  }

  func pausePreview() {
    isPreviewPaused = true
  }

  func resumePreview() {
    isPreviewPaused = false
  }

  func setDescriptionWhileRecording(
    _ cameraName: String, withCompletion completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    guard isRecording else {
      completion(
        .failure(
          PigeonError(
            code: "setDescriptionWhileRecordingFailed",
            message: "Device was not recording",
            details: nil)))
      return
    }

    // The KVO observation is bound to the *current* `captureDevice`. Tear
    // it down before the swap so no stale callback fires for the outgoing
    // device. `isWhiteBalanceLocked` and `currentWhiteBalanceValues` are
    // preserved across the swap so the new device can be re-locked below.
    stopObservingAutoWhiteBalance()

    captureDevice = videoCaptureDeviceFactory(cameraName)

    let oldConnection = captureVideoOutput.connection(with: .video)

    // Stop video capture from the old output.
    captureVideoOutput.setSampleBufferDelegate(nil, queue: nil)

    // Remove the old video capture connections.
    videoCaptureSession.beginConfiguration()
    videoCaptureSession.removeInput(captureVideoInput)
    videoCaptureSession.removeOutput(captureVideoOutput.avOutput)

    let newConnection: AVCaptureConnection

    do {
      (captureVideoInput, captureVideoOutput, newConnection) = try DefaultCamera.createConnection(
        captureDevice: captureDevice,
        videoFormat: videoFormat,
        captureDeviceInputFactory: captureDeviceInputFactory)

      captureVideoOutput.setSampleBufferDelegate(self, queue: captureSessionQueue)
    } catch {
      // Balance the `beginConfiguration()` above — leaving the session in a
      // begun-configuration state would stall every later configuration
      // change (session preset, orientation, the next device switch).
      videoCaptureSession.commitConfiguration()
      completion(
        .failure(
          PigeonError(
            code: "VideoError",
            message: "Unable to create video connection",
            details: nil)))
      return
    }

    // Keep the same orientation the old connections had.
    if let oldConnection = oldConnection, newConnection.isVideoOrientationSupported {
      newConnection.videoOrientation = oldConnection.videoOrientation
    }

    // Add the new connections to the session. Each failure branch must
    // `return` (a fall-through would call `completion` a second time with
    // success and keep mutating the half-broken session) and must commit the
    // configuration first so the `beginConfiguration()` above stays balanced.
    if !videoCaptureSession.canAddInput(captureVideoInput) {
      videoCaptureSession.commitConfiguration()
      completion(
        .failure(
          PigeonError(
            code: "VideoError",
            message: "Unable to switch video input",
            details: nil)))
      return
    }
    videoCaptureSession.addInputWithNoConnections(captureVideoInput)

    if !videoCaptureSession.canAddOutput(captureVideoOutput.avOutput) {
      videoCaptureSession.commitConfiguration()
      completion(
        .failure(
          PigeonError(
            code: "VideoError",
            message: "Unable to switch video output",
            details: nil)))
      return
    }
    videoCaptureSession.addOutputWithNoConnections(captureVideoOutput.avOutput)

    if !videoCaptureSession.canAddConnection(newConnection) {
      videoCaptureSession.commitConfiguration()
      completion(
        .failure(
          PigeonError(
            code: "VideoError",
            message: "Unable to switch video connection",
            details: nil)))
      return
    }
    videoCaptureSession.addConnection(newConnection)
    videoCaptureSession.commitConfiguration()

    // The new sensor may report different dimensions/format. If we're not
    // recording, park the renderer so the next frame rebuilds it at the new
    // size. Parking (rather than a bare `= nil`) stops the grain timer — an
    // in-flight photo delegate strongly retains the old renderer via its
    // processor closure, so the timer would otherwise keep firing until that
    // capture completes — and lets the rebuild adopt the old renderer's
    // decoded LUT / grain textures (they are file-derived, not
    // sensor-derived) instead of flashing un-filtered while they re-decode.
    // While recording we have to keep the existing renderer because the
    // videoAdaptor is locked to its output dimensions — the next sample
    // buffer will detect the source-size change and call
    // `updateSourceDimensions` on the renderer to recompute the vertex-stage
    // `uvScale` so the new source's center-crop still matches the renderer's
    // (locked) output ratio.
    //
    // Always reset shaderSourceUnsupported (parking also does this, but the
    // recording branch needs it too): the old sensor may have latched it
    // with an unsupported format, but the new sensor might be fine. The next
    // sample buffer will re-set the flag if the new format is also
    // unsupported.
    shaderSourceUnsupported = false
    if !isRecording {
      parkRendererForRebuild()
    }

    // Re-apply the white-balance state to the new device. If WB was locked,
    // re-lock at the same temperature/tint. Otherwise rebind the auto-WB KVO
    // observation to the new device so Dart keeps receiving updates.
    //
    // The new sensor may not support the same WB capabilities as the old
    // one. If `applyWhiteBalance` fails we report it as a non-fatal error
    // and leave the new device in its default mode — the camera-switch
    // itself succeeded, which is what `completion` reports.
    do {
      try applyWhiteBalance(isWhiteBalanceLocked ? currentWhiteBalanceValues : nil)
    } catch let error as PigeonError {
      reportErrorMessage(
        "setDescriptionWhileRecording: could not restore white balance: \(error.message ?? error.code)"
      )
    } catch let error as NSError {
      reportErrorMessage(
        "setDescriptionWhileRecording: could not restore white balance: \(error.localizedDescription)"
      )
    }

    completion(.success(()))
  }

  func startImageStream(
    with messenger: any FlutterBinaryMessenger,
    completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    startImageStream(
      with: messenger,
      imageStreamHandler: DefaultImageStreamHandler(captureSessionQueue: captureSessionQueue),
      completion: completion
    )
  }

  func startImageStream(
    with messenger: FlutterBinaryMessenger,
    imageStreamHandler: ImageStreamHandler,
    completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    if isStreamingImages {
      reportErrorMessage("Images from camera are already streaming!")
      completion(.success(()))
      return
    }

    ensureToRunOnMainQueue { [weak self] in
      guard let self else {
        completion(.success(()))
        return
      }
      ImageDataStreamStreamHandler.register(with: messenger, streamHandler: imageStreamHandler)
      self.imageStreamHandler = imageStreamHandler
      self.captureSessionQueue.async { [weak self] in
        if let self {
          self.isStreamingImages = true
          self.streamingPendingFramesCount = 0
        }
        completion(.success(()))
      }
    }
  }

  func stopImageStream() {
    if isStreamingImages {
      isStreamingImages = false
      imageStreamHandler = nil
    } else {
      reportErrorMessage("Images from camera are not streaming!")
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    // Buffer destined for the AVAssetWriter — at the renderer's full output
    // dimensions, with no preview darkening. Distinct from the preview
    // buffer because preview shows the dark border, recording must not.
    var recordingVideoBuffer: CVPixelBuffer?

    if output == captureVideoOutput.avOutput,
      let newBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    {
      maintainRenderer(for: newBuffer)
      // Submit order matters: preview is non-blocking and recording blocks
      // on its semaphore. Submitting preview first lets the GPU start on
      // the preview pass while the CPU is still preparing the recording
      // submission. Publishing the preview buffer to Flutter happens last
      // so a recording stall doesn't delay it any further than the GPU
      // pipeline does already.
      let previewBuffer = renderForPreview(newBuffer)
      recordingVideoBuffer = renderForRecordingIfNeeded(newBuffer)

      if let displayBuffer = previewBuffer {
        pixelBufferSynchronizationQueue.sync {
          latestPixelBuffer = displayBuffer
        }
        onFrameAvailable?()
      }
    }

    guard CMSampleBufferDataIsReady(sampleBuffer) else {
      reportErrorMessage("sample buffer is not ready. Skipping sample")
      return
    }

    handleSampleBufferStreaming(sampleBuffer)

    if isRecording && !isRecordingPaused && videoCaptureSession.isRunning
      && audioCaptureSession.isRunning
    {
      if videoWriter?.status == .failed, let error = videoWriter?.error {
        reportErrorMessage("\(error)")
        return
      }

      // do not append sample buffer when readyForMoreMediaData is NO to avoid crash
      // https://github.com/flutter/flutter/issues/132073
      if output == captureVideoOutput.avOutput {
        if !(videoWriterInput?.isReadyForMoreMediaData ?? false) {
          return
        }
      } else {
        // ignore audio samples until the first video sample arrives to avoid black frames
        // https://github.com/flutter/flutter/issues/57831
        if isFirstVideoSample || !(audioWriterInput?.isReadyForMoreMediaData ?? false) {
          return
        }
        outputForOffsetAdjusting = output
      }

      let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

      if isFirstVideoSample {
        videoWriter?.startSession(atSourceTime: sampleTime)
        // fix sample times not being numeric when pause/resume happens before first sample buffer
        // arrives
        // https://github.com/flutter/flutter/issues/132014
        isRecordingDisconnected = false
        isFirstVideoSample = false
      }

      var currentSampleEndTime = sampleTime
      let duration = CMSampleBufferGetDuration(sampleBuffer)
      if CMTIME_IS_NUMERIC(duration) {
        currentSampleEndTime = CMTimeAdd(currentSampleEndTime, duration)
      }

      // Use a single time offset for both video and audio to avoid desync.
      // https://github.com/flutter/flutter/issues/149978
      if isRecordingDisconnected {
        if output == outputForOffsetAdjusting {
          let offset = CMTimeSubtract(currentSampleEndTime, lastSampleEndTime)
          recordingTimeOffset = CMTimeAdd(recordingTimeOffset, offset)
          lastSampleEndTime = currentSampleEndTime
          isRecordingDisconnected = false
        }
        return
      }

      if output == outputForOffsetAdjusting {
        lastSampleEndTime = currentSampleEndTime
      }

      if output == captureVideoOutput.avOutput {
        // When the shader is active the videoAdaptor was configured for the
        // recording-pool dimensions. If the GPU pass produced no buffer we
        // MUST NOT fall back to the source — its size won't match the
        // adaptor and the append will corrupt the recording. Drop instead.
        let nextBuffer: CVPixelBuffer?
        if videoFrameRenderer != nil {
          nextBuffer = recordingVideoBuffer
          if recordingVideoBuffer == nil {
            logRecordingFailure(
              "recordingVideoBuffer nil — dropping recording frame (renderer in flight or pool exhausted)"
            )
          }
        } else {
          nextBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        }
        guard let nextBuffer = nextBuffer else {
          return
        }
        let nextSampleTime = CMTimeSubtract(sampleTime, recordingTimeOffset)
        if nextSampleTime > lastAppendedVideoSampleTime {
          let appended = videoAdaptor?.append(nextBuffer, withPresentationTime: nextSampleTime) ?? false
          if !appended {
            // The @autoclosure defers context construction until the rate
            // limit will actually emit — a stuck writer fails every frame
            // and eagerly building the message would defeat the throttle.
            logRecordingFailure(
              "videoAdaptor.append FAILED — buffer=\(CVPixelBufferGetWidth(nextBuffer))x\(CVPixelBufferGetHeight(nextBuffer)) fmt=\(String(format: "0x%08X", CVPixelBufferGetPixelFormatType(nextBuffer))) writerStatus=\(videoWriter?.status.rawValue ?? -1) writerError=\(videoWriter?.error?.localizedDescription ?? "nil")"
            )
          }
          lastAppendedVideoSampleTime = nextSampleTime
        }
      } else {
        if recordingTimeOffset.value != 0 {
          if let adjustedSampleBuffer = copySampleBufferWithAdjustedTime(
            sampleBuffer,
            by: recordingTimeOffset)
          {
            newAudioSample(adjustedSampleBuffer)
          }
        } else {
          newAudioSample(sampleBuffer)
        }
      }
    }
  }

  private func handleSampleBufferStreaming(_ sampleBuffer: CMSampleBuffer) {
    guard isStreamingImages,
      let eventSink = imageStreamHandler?.eventSink,
      streamingPendingFramesCount < maxStreamingPendingFramesCount
    else {
      return
    }

    // Non-pixel buffer samples, such as audio samples, are ignored for streaming.
    // Image streaming always uses the source buffer — the rendered buffer may
    // still be GPU-in-flight and must not be accessed CPU-side.
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    streamingPendingFramesCount += 1

    // Must lock base address before accessing the pixel data
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)

    let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
    let imageHeight = CVPixelBufferGetHeight(pixelBuffer)

    var planes: [PlatformCameraImagePlane] = []

    let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
    let planeCount = isPlanar ? CVPixelBufferGetPlaneCount(pixelBuffer) : 1

    for i in 0..<planeCount {
      let planeAddress: UnsafeMutableRawPointer?
      let bytesPerRow: Int
      let height: Int
      let width: Int

      if isPlanar {
        planeAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, i)
        bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, i)
        height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i)
        width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i)
      } else {
        planeAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        width = CVPixelBufferGetWidth(pixelBuffer)
      }

      let length = bytesPerRow * height
      let bytes = Data(bytes: planeAddress!, count: length)

      let planeBuffer = PlatformCameraImagePlane(
        bytes: FlutterStandardTypedData(bytes: bytes),
        bytesPerRow: Int64(bytesPerRow),
        width: Int64(width),
        height: Int64(height)
      )
      planes.append(planeBuffer)
    }

    // Lock the base address before accessing pixel data, and unlock it afterwards.
    // Done accessing the `pixelBuffer` at this point.
    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

    let imageBuffer = PlatformCameraImageData(
      formatCode: Int64(videoFormat),
      width: Int64(imageWidth),
      height: Int64(imageHeight),
      planes: planes,
      lensAperture: Double(captureDevice.lensAperture),
      sensorExposureTimeNanoseconds: Int64(captureDevice.exposureDuration.seconds * 1_000_000_000),
      sensorSensitivity: Double(captureDevice.iso)
    )

    DispatchQueue.main.async {
      eventSink.success(imageBuffer)
    }
  }

  private func copySampleBufferWithAdjustedTime(_ sample: CMSampleBuffer, by offset: CMTime)
    -> CMSampleBuffer?
  {
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(
      sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)

    let timingInfo = UnsafeMutablePointer<CMSampleTimingInfo>.allocate(capacity: Int(count))
    defer { timingInfo.deallocate() }

    CMSampleBufferGetSampleTimingInfoArray(
      sample, entryCount: count, arrayToFill: timingInfo, entriesNeededOut: &count)

    for i in 0..<count {
      timingInfo[Int(i)].decodeTimeStamp = CMTimeSubtract(
        timingInfo[Int(i)].decodeTimeStamp, offset)
      timingInfo[Int(i)].presentationTimeStamp = CMTimeSubtract(
        timingInfo[Int(i)].presentationTimeStamp, offset)
    }

    var adjustedSampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(
      allocator: nil,
      sampleBuffer: sample,
      sampleTimingEntryCount: count,
      sampleTimingArray: timingInfo,
      sampleBufferOut: &adjustedSampleBuffer)

    return adjustedSampleBuffer
  }

  private func newAudioSample(_ sampleBuffer: CMSampleBuffer) {
    guard videoWriter?.status == .writing else {
      if videoWriter?.status == .failed, let error = videoWriter?.error {
        reportErrorMessage("\(error)")
      }
      return
    }
    if !(audioWriterInput?.append(sampleBuffer) ?? false) {
      reportErrorMessage("Unable to write to audio input")
    }
  }

  func close() {
    stop()
    for input in videoCaptureSession.inputs {
      videoCaptureSession.removeInput(input)
    }
    for output in videoCaptureSession.outputs {
      videoCaptureSession.removeOutput(output)
    }
    for input in audioCaptureSession.inputs {
      audioCaptureSession.removeInput(input)
    }
    for output in audioCaptureSession.outputs {
      audioCaptureSession.removeOutput(output)
    }
    // Drop the renderers and any cached pixel buffer eagerly so the recording
    // pool (up to ~240 MB at 4K), warm preview pool, CIContext, and Metal
    // texture cache are released now rather than at ARC's discretion. The
    // grain timer is stopped explicitly because an in-flight photo delegate
    // can keep the live renderer alive past this point; the parked previous
    // renderer's timer was already stopped when it was parked.
    stopObservingAutoWhiteBalance()
    videoFrameRenderer?.stopGrainAnimation()
    videoFrameRenderer = nil
    previousVideoFrameRenderer = nil
    shaderSourceUnsupported = false
    pixelBufferSynchronizationQueue.sync {
      latestPixelBuffer = nil
    }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard !isPreviewPaused else { return nil }
    var pixelBuffer: CVPixelBuffer?
    pixelBufferSynchronizationQueue.sync {
      pixelBuffer = latestPixelBuffer
      latestPixelBuffer = nil
    }

    if let buffer = pixelBuffer {
      return Unmanaged.passRetained(buffer)
    } else {
      return nil
    }
  }

  /// Rate-limited variant of `os_log` for the recording hot path. Must be
  /// called on `captureSessionQueue` (the only thread that writes
  /// `nextRecordingFailureLog`); the sample-buffer callback satisfies that.
  /// The `@autoclosure` defers context-string construction until the gate
  /// allows an emission — important because a stuck writer fires every frame.
  private func logRecordingFailure(_ message: @autoclosure () -> String) {
    let now = Date()
    guard now >= nextRecordingFailureLog else { return }
    nextRecordingFailureLog = now.addingTimeInterval(
      DefaultCamera.recordingFailureLogMinInterval)
    os_log("%{public}@", log: DefaultCamera.recordingLog, type: .error, message())
  }

  /// Reports the given error message to the Dart side of the plugin.
  ///
  /// Can be called from any thread.
  private func reportErrorMessage(_ errorMessage: String) {
    ensureToRunOnMainQueue { [weak self] in
      self?.dartAPI?.error(message: errorMessage) { _ in
        // Ignore any errors, as this is just an event broadcast.
      }
    }
  }

  deinit {
    motionManager.stopAccelerometerUpdates()
    whiteBalanceObservation?.invalidate()
  }
}
