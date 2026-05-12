// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import CoreMotion
import Flutter

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
      // pixel format. Renderer access is otherwise confined to the capture
      // session queue, which is also where this setter runs.
      videoFrameRenderer = nil
      shaderSourceUnsupported = false
    }
  }

  private(set) var isPreviewPaused = false

  var minimumExposureOffset: CGFloat { CGFloat(captureDevice.minExposureTargetBias) }
  var maximumExposureOffset: CGFloat { CGFloat(captureDevice.maxExposureTargetBias) }
  var minimumAvailableZoomFactor: CGFloat { captureDevice.minAvailableVideoZoomFactor }
  var maximumAvailableZoomFactor: CGFloat { captureDevice.maxAvailableVideoZoomFactor }

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
  /// `setCaptureScale` calls received while recording. The AVAssetWriter is
  /// locked to the renderer's dimensions for the duration of the take, so we
  /// stash the latest value and apply it once recording stops. Nil when no
  /// pending change.
  private var pendingCaptureScale: Float?
  /// `setAspectRatio` calls received while recording. Aspect changes require
  /// rebuilding the renderer (new output dimensions), which cannot happen
  /// while the AVAssetWriter is live. The latest requested ratio is stashed
  /// here and applied (renderer rebuilt) once recording stops.
  ///
  /// `.none` means no pending change; `.set(value)` carries the deferred
  /// ratio (where `value == nil` means "clear the crop"). A separate case is
  /// needed because `nil` is itself a valid aspect-ratio value.
  private enum PendingAspectRatio {
    case none
    case set(Double?)
  }
  private var pendingAspectRatio: PendingAspectRatio = .none

  /// A dictionary to retain all in-progress SavePhotoDelegates. The key of the dictionary is the
  /// AVCapturePhotoSettings's uniqueID for each photo capture operation, and the value is the
  /// SavePhotoDelegate that handles the result of each photo capture operation. Note that photo
  /// capture operations may overlap, so FLTCam has to keep track of multiple delegates in progress,
  /// instead of just a single delegate reference.
  private(set) var inProgressSavePhotoDelegates = [Int64: SavePhotoDelegate]()

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
  /// Timestamp of the last `autoWhiteBalanceChanged` event dispatched to
  /// Dart, used to throttle KVO emissions to ~10/s.
  private var lastAutoWhiteBalanceEmission: Date?
  /// Minimum interval between `autoWhiteBalanceChanged` events.
  private static let autoWhiteBalanceMinInterval: TimeInterval = 0.1

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

    videoCaptureSession.addOutput(capturePhotoOutput.avOutput)

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
    if let aspectRatio = aspectRatio {
      let crop = VideoFrameRenderer.croppedDimensions(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        targetRatio: aspectRatio)
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

    // Pre-build the renderer if needed so the AVAssetWriter is configured for
    // the renderer's output dimensions, not the source dimensions. Without
    // this, recording started before the first sample buffer would attach an
    // adaptor sized for the source — then the renderer would lazily build on
    // the first frame and feed the adaptor differently-sized buffers, which
    // either get rejected or silently corrupt the file.
    if videoFrameRenderer == nil, !shaderSourceUnsupported {
      let size = videoDimensionsConverter(captureDevice.flutterActiveFormat)
      buildRendererIfPossible(
        sourceWidth: Int(size.width),
        sourceHeight: Int(size.height),
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
      NSLog(
        "DefaultCamera: recommendedVideoSettingsForAssetWriter returned nil — building minimal H.264 settings."
      )
    }

    // Snapshot the recording-output dims into a local *once* so all four
    // settings (videoSettings + adaptor attrs) see the same values. The
    // accessors read live uniforms; reading them four times would let a
    // concurrent `setCaptureScale` (now blocked during recording, but cheap
    // insurance) tear the configuration.
    let recordingDims: (width: Int, height: Int)? = videoFrameRenderer.map {
      ($0.recordingOutputWidth, $0.recordingOutputHeight)
    }

    // If the system declined to recommend settings (can happen before the
    // session has produced its first sample buffer), synthesize a minimal
    // settings dict ourselves. With nil settings the AssetWriterInput goes
    // into passthrough mode and silently rejects every appended pixel
    // buffer — the resulting MP4 has no video track and is reported as a
    // 0×0 video. We also need *some* dims; use the renderer's recording
    // dims if available, else the source dims from the active format.
    if videoSettings == nil {
      let fallbackDims: (width: Int, height: Int)
      if let dims = recordingDims {
        fallbackDims = dims
      } else {
        let size = videoDimensionsConverter(captureDevice.flutterActiveFormat)
        fallbackDims = (Int(size.width), Int(size.height))
      }
      // Use HEVC for the fallback codec when the user has selected HEIF as
      // their image format AND the device supports it, matching the codec
      // choice made for photos in captureToFile. Otherwise fall back to H264.
      let isHEVCCapable =
        fileFormat == .heif
        && capturePhotoOutput.availablePhotoCodecTypes.contains(.hevc)
      let fallbackCodec: AVVideoCodecType = isHEVCCapable ? .hevc : .h264
      videoSettings = [
        AVVideoCodecKey: fallbackCodec,
        AVVideoWidthKey: fallbackDims.width,
        AVVideoHeightKey: fallbackDims.height,
      ]
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
    // `renderForRecording` (aspect-cropped + capture-scaled, no darkening),
    // so override the encoder's target dimensions to match. Otherwise
    // AVAssetWriter scales the buffer back to the recommended sensor size on
    // encode and the saved file ends up with the wrong dimensions.
    // Also enforce the user-selected codec: if fileFormat is .heif and HEVC
    // is available, use hevc; otherwise keep whatever the system recommended
    // (usually h264). This ensures the video codec is consistent with the
    // photo codec selected in captureToFile.
    if let dims = recordingDims {
      videoSettings?[AVVideoWidthKey] = dims.width
      videoSettings?[AVVideoHeightKey] = dims.height
      let isHEVCCapable =
        fileFormat == .heif
        && capturePhotoOutput.availablePhotoCodecTypes.contains(.hevc)
      if isHEVCCapable {
        videoSettings?[AVVideoCodecKey] = AVVideoCodecType.hevc
      }
    }

    NSLog(
      "DefaultCamera: setupWriter videoSettings=\(videoSettings ?? [:]) recordingDims=\(String(describing: recordingDims)) videoFormat=\(String(format: "0x%08X", videoFormat))"
    )

    let videoWriterInput = mediaSettingsAVWrapper.assetWriterVideoInput(
      withOutputSettings: videoSettings)
    self.videoWriterInput = videoWriterInput

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
    // Reset the unsupported-format latch so that if the user switched to a
    // sensor with an unsupported format during the recording (and the latch
    // was set for that sensor), the post-recording preview can still try to
    // build a renderer for the current sensor's format.
    shaderSourceUnsupported = false
    // Order matters: when both are pending, the aspect-ratio path drops the
    // renderer, making any uniform/pool work performed by the scale path
    // moot. Apply aspect first; the scale path then either operates on the
    // (newly null) renderer — its `?.` chains no-op — or on the live one if
    // no aspect change was pending. `captureScale` is read as a field by
    // `buildRendererIfPossible` on the next rebuild, so the value still
    // sticks either way.
    applyPendingAspectRatioIfNeeded()
    applyPendingCaptureScaleIfNeeded()

    // When `isRecording` is true `startWriting` was already called so `videoWriter.status`
    // is always either `.writing` or `.failed` and `finishWriting` does not throw exceptions so
    // there is no need to check `videoWriter.status`
    videoWriter?.finishWriting { [weak self] in
      guard let strongSelf = self else { return }

      if strongSelf.videoWriter?.status == .completed {
        strongSelf.updateOrientation()
        completion(.success(strongSelf.videoRecordingPath!))
        strongSelf.videoRecordingPath = nil
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

  func captureToFile(completion: @escaping (Result<String, any Error>) -> Void) {
    var settings = AVCapturePhotoSettings()

    if mediaSettings.resolutionPreset == .max {
      settings.isHighResolutionPhotoEnabled = true
    }

    let fileExtension: String
    let isHEVCCodecAvailable = capturePhotoOutput.availablePhotoCodecTypes.contains(.hevc)
    let isHEIF = (fileFormat == .heif && isHEVCCodecAvailable)

    // Eagerly build the renderer if it hasn't been created yet (e.g. photo
    // requested before the first preview sample buffer arrived, or
    // immediately after setAspectRatio dropped the old renderer before the
    // next frame rebuilt it). Without this the photo path silently skips all
    // effects (vignette, crop, capture-scale) for that one capture.
    if videoFrameRenderer == nil, !shaderSourceUnsupported {
      let size = videoDimensionsConverter(captureDevice.flutterActiveFormat)
      buildRendererIfPossible(
        sourceWidth: Int(size.width),
        sourceHeight: Int(size.height),
        sourcePixelFormat: videoFormat)
    }

    let renderer = videoFrameRenderer
    let useShaderPath = (renderer != nil)

    if useShaderPath {
      // Request the uncompressed BGRA pixel buffer so the shader can render
      // straight from VRAM instead of decoding the camera codec back into a
      // CGImage. The output is then re-encoded to the user-selected format
      // by VideoFrameRenderer.encode (CIContext, GPU).
      //
      // `availablePhotoPixelFormatTypes` can be empty on some devices or
      // capture configurations, in which case requesting BGRA would produce
      // an invalid AVCapturePhotoSettings and crash. Fall through to
      // compressed delivery if BGRA is not advertised; the CGImage fallback
      // in photoProcessor will handle it — no visible quality difference.
      let bgraAvailable = capturePhotoOutput.avOutput.availablePhotoPixelFormatTypes
        .contains(kCVPixelFormatType_32BGRA)
      if bgraAvailable {
        settings = AVCapturePhotoSettings(format: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
      } else {
        NSLog(
          "DefaultCamera: BGRA pixel format not available — using compressed delivery for shader path"
        )
        if isHEIF {
          settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        // else: default settings → JPEG compressed delivery
      }
      fileExtension = isHEIF ? "heif" : "jpg"
    } else if isHEIF {
      settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
      fileExtension = "heif"
    } else {
      fileExtension = "jpg"
    }

    if flashMode != .torch {
      settings.flashMode = getAVCaptureFlashMode(for: flashMode)
    }
    settings.photoQualityPrioritization = AVCapturePhotoOutput.QualityPrioritization.speed

    // Defensive: explicitly disable Apple's multi-frame fusion paths so that
    // a future change to device discovery (e.g. adding a virtual multi-camera)
    // cannot silently re-enable computational stacking.
    if capturePhotoOutput.avOutput.isVirtualDeviceFusionSupported {
      settings.isAutoVirtualDeviceFusionEnabled = false
    }
    if capturePhotoOutput.avOutput.isDualCameraFusionSupported {
      settings.isAutoDualCameraFusionEnabled = false
    }

    let path: String
    do {
      path = try getTemporaryFilePath(
        withExtension: fileExtension,
        subfolder: "pictures",
        prefix: "CAP_")
    } catch let error as NSError {
      completion(.failure(DefaultCamera.pigeonErrorFromNSError(error)))
      return
    }

    let photoProcessor: ((AVCapturePhoto) -> Data?)? = renderer == nil
      ? nil
      : { [renderer] photo in
        guard let renderer = renderer else { return nil }
        let utType: CFString = isHEIF ? "public.heic" as CFString : "public.jpeg" as CFString
        // Fast path: the photo was delivered as a raw BGRA pixel buffer.
        if let pixelBuffer = photo.pixelBuffer {
          return renderer.renderImageData(
            sourceBuffer: pixelBuffer,
            destinationUTType: utType,
            metadata: photo.metadata as CFDictionary)
        }
        // Fallback (compressed delivery): decode to CGImage and round-trip
        // through CPU. Should not normally happen — `captureToFile` requests
        // raw BGRA when the shader is active. Logging so a regression
        // (e.g. the format request being silently overridden) is observable.
        if let cgImage = photo.cgImageRepresentation() {
          NSLog(
            "DefaultCamera: photo arrived without pixelBuffer — falling back to CPU CGImage path. This is slow; investigate why BGRA was not delivered."
          )
          return renderer.renderImageData(
            cgImage: cgImage,
            destinationUTType: utType,
            metadata: photo.metadata as CFDictionary)
        }
        return nil
      }

    let savePhotoDelegate = SavePhotoDelegate(
      path: path,
      ioQueue: photoIOQueue,
      photoProcessor: photoProcessor,
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

    updateOrientation(orientation, forCaptureOutput: capturePhotoOutput)
    updateOrientation(orientation, forCaptureOutput: captureVideoOutput)
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

  func setEffectsValues(_ values: PlatformEffectsValues) {
    guard values.vignetteIntensity.isFinite else { return }
    currentEffectsValues = values
    videoFrameRenderer?.updateUniforms { $0.vignetteIntensity = Float(values.vignetteIntensity) }
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

    let crop = VideoFrameRenderer.croppedDimensions(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      targetRatio: aspectRatio)
    NSLog(
      "DefaultCamera: shader pipeline starting at \(sourceWidth)x\(sourceHeight) → \(crop.width)x\(crop.height) (aspect=\(String(describing: aspectRatio))) format=\(String(format: "0x%08X", sourcePixelFormat))"
    )
    let renderer = VideoFrameRenderer(
      width: crop.width, height: crop.height, targetRatio: aspectRatio,
      sourceWidth: sourceWidth, sourceHeight: sourceHeight,
      sourcePixelFormat: sourcePixelFormat)
    videoFrameRenderer = renderer
    if let renderer = renderer {
      renderer.updateUniforms {
        $0.uvScale = crop.uvScale
        $0.captureScale = captureScale
        if let values = currentEffectsValues {
          $0.vignetteIntensity = Float(values.vignetteIntensity)
        }
      }
      updatePreviewSize(
        width: CGFloat(renderer.outputWidth),
        height: CGFloat(renderer.outputHeight))
    } else {
      shaderSourceUnsupported = true
    }
  }

  func setAspectRatio(_ aspectRatio: Double?) {
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
    // output dimensions. Cheap because MetalSetup is cached.
    videoFrameRenderer = nil
    shaderSourceUnsupported = false
  }

  func setCaptureScale(_ scale: Double) {
    // The Dart side (CameraController.setCaptureScale) validates finiteness
    // and clamps to the supported [0.1, 1.0] range, so we trust the input
    // here. Keep a single defensive `isFinite` check so a misbehaving
    // alternative client cannot poison the shader with NaN.
    guard scale.isFinite else { return }
    let scaleValue = Float(scale)
    // The AVAssetWriter and its pixel-buffer adaptor are configured for the
    // renderer's recordingOutput dimensions at recording start. Changing the
    // uniform mid-recording would make `renderForRecording` produce
    // differently-sized buffers that the adaptor would reject (or worse,
    // silently corrupt). Stash the value and apply on stop.
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

  /// Applies an `aspectRatio` change that was deferred during a recording.
  /// Called from `stopVideoRecording` once `isRecording` is back to false.
  /// Rebuilds the renderer so the new ratio takes effect on the next frame.
  private func applyPendingAspectRatioIfNeeded() {
    guard case .set(let pending) = pendingAspectRatio else { return }
    pendingAspectRatio = .none
    guard pending != aspectRatio else { return }
    aspectRatio = pending
    videoFrameRenderer = nil
    shaderSourceUnsupported = false
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

    let orientation = UIDevice.current.orientation
    try? captureDevice.lockForConfiguration()
    // A nil point resets to the center.
    let exposurePoint = cgPoint(
      for: point ?? PlatformPoint(x: 0.5, y: 0.5), withOrientation: orientation)
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

    let orientation = deviceOrientationProvider.orientation
    try? captureDevice.lockForConfiguration()
    // A nil point resets to the center.
    captureDevice.focusPointOfInterest =
      cgPoint(
        for: point ?? PlatformPoint(x: 0.5, y: 0.5),
        withOrientation: orientation)

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
      try captureDevice.lockForConfiguration()
      captureDevice.setWhiteBalanceModeLocked(
        withDeviceWhiteBalanceGains: gains, completionHandler: nil)
      captureDevice.unlockForConfiguration()
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
      captureDevice.whiteBalanceMode = .continuousAutoWhiteBalance
      captureDevice.unlockForConfiguration()
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
    // The KVO closure fires on whatever thread AVFoundation mutates the
    // observed property from — not necessarily `captureSessionQueue`. Hop
    // onto `captureSessionQueue` before touching `lastAutoWhiteBalanceEmission`
    // so the throttle state is mutated on a single serial queue (same one
    // `stopObservingAutoWhiteBalance` and `setWhiteBalance` use).
    whiteBalanceObservation = avDevice.observe(
      \.deviceWhiteBalanceGains, options: [.new]
    ) { [weak self] device, _ in
      guard let self = self else { return }
      let values = device.temperatureAndTintValues(
        for: device.deviceWhiteBalanceGains)
      // Skip non-finite values (can occur transiently right after the
      // device starts). Filter on the calling thread — no need to hop the
      // queue just to discard.
      guard values.temperature.isFinite, values.tint.isFinite else { return }
      let now = Date()
      let temperature = Double(values.temperature)
      let tint = Double(values.tint)
      self.captureSessionQueue.async { [weak self] in
        guard let self = self else { return }
        // Re-check the observation is still active and bound to this device.
        // If it has been torn down (camera switch, lock) we must not emit.
        guard self.whiteBalanceObservation != nil,
          !self.isWhiteBalanceLocked
        else { return }
        if let last = self.lastAutoWhiteBalanceEmission,
          now.timeIntervalSince(last) < DefaultCamera.autoWhiteBalanceMinInterval
        {
          return
        }
        self.lastAutoWhiteBalanceEmission = now
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
    lastAutoWhiteBalanceEmission = nil
  }

  private func cgPoint(
    for point: PlatformPoint, withOrientation orientation: UIDeviceOrientation
  )
    -> CGPoint
  {
    var x = point.x
    var y = point.y
    switch orientation {
    case .portrait:  // 90 ccw
      y = 1 - point.x
      x = point.y
    case .portraitUpsideDown:  // 90 cw
      x = 1 - point.y
      y = point.x
    case .landscapeRight:  // 180
      x = 1 - point.x
      y = 1 - point.y
    case .landscapeLeft:
      // No rotation required
      break
    default:
      // No rotation required
      break
    }
    return CGPoint(x: x, y: y)
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

    // Add the new connections to the session.
    if !videoCaptureSession.canAddInput(captureVideoInput) {
      completion(
        .failure(
          PigeonError(
            code: "VideoError",
            message: "Unable to switch video input",
            details: nil)))
    }
    videoCaptureSession.addInputWithNoConnections(captureVideoInput)

    if !videoCaptureSession.canAddOutput(captureVideoOutput.avOutput) {
      completion(
        .failure(
          PigeonError(
            code: "VideoError",
            message: "Unable to switch video output",
            details: nil)))
    }
    videoCaptureSession.addOutputWithNoConnections(captureVideoOutput.avOutput)

    if !videoCaptureSession.canAddConnection(newConnection) {
      completion(
        .failure(
          PigeonError(
            code: "VideoError",
            message: "Unable to switch video connection",
            details: nil)))
    }
    videoCaptureSession.addConnection(newConnection)
    videoCaptureSession.commitConfiguration()

    // The new sensor may report different dimensions/format. If we're not
    // recording, drop the renderer so the next frame rebuilds it at the new
    // size. While recording we have to keep the existing renderer because
    // the videoAdaptor is locked to its output dimensions — the next sample
    // buffer will detect the source-size change and call
    // `updateSourceDimensions` on the renderer to recompute the vertex-stage
    // `uvScale` so the new source's center-crop still matches the renderer's
    // (locked) output ratio.
    //
    // Always reset shaderSourceUnsupported: the old sensor may have latched
    // it with an unsupported format, but the new sensor might be fine. The
    // next sample buffer will re-set the flag if the new format is also
    // unsupported.
    shaderSourceUnsupported = false
    if !isRecording {
      videoFrameRenderer = nil
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
    // Buffer destined for the AVAssetWriter — at the *captureScale*-narrowed
    // dimensions, with no preview darkening. Distinct from the preview
    // buffer because preview shows the dark border, recording must not.
    var recordingVideoBuffer: CVPixelBuffer?

    if output == captureVideoOutput.avOutput {
      if let newBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
        if videoFrameRenderer == nil, !shaderSourceUnsupported {
          let format = CVPixelBufferGetPixelFormatType(newBuffer)
          let bufferWidth = CVPixelBufferGetWidth(newBuffer)
          let bufferHeight = CVPixelBufferGetHeight(newBuffer)
          buildRendererIfPossible(
            sourceWidth: bufferWidth,
            sourceHeight: bufferHeight,
            sourcePixelFormat: format)
        } else if let renderer = videoFrameRenderer {
          let format = CVPixelBufferGetPixelFormatType(newBuffer)
          let bufferWidth = CVPixelBufferGetWidth(newBuffer)
          let bufferHeight = CVPixelBufferGetHeight(newBuffer)
          let dimsChanged =
            renderer.sourceWidth != bufferWidth || renderer.sourceHeight != bufferHeight
          let formatChanged = renderer.sourcePixelFormat != format

          if dimsChanged || formatChanged {
            if !isRecording {
              // Drop and rebuild: source dimensions or pixel format changed
              // while not recording. The rebuild will recompute uvScale and
              // reset sourcePixelFormat so the correct fragment pipeline is
              // selected going forward. Also resets shaderSourceUnsupported
              // in case the old sensor had an unsupported format that blocked
              // the pipeline.
              videoFrameRenderer = nil
              shaderSourceUnsupported = false
              buildRendererIfPossible(
                sourceWidth: bufferWidth,
                sourceHeight: bufferHeight,
                sourcePixelFormat: format)
            } else if dimsChanged {
              // Recording: keep renderer (AVAssetWriter locked to output dims)
              // but recompute uvScale for the new source size.
              renderer.updateSourceDimensions(width: bufferWidth, height: bufferHeight)
              if formatChanged {
                // Track the new format. submitRender already selects the
                // correct fragment pipeline per-frame, so the video output is
                // correct; tracking here keeps the sourcePixelFormat property
                // consistent with the live source.
                renderer.updateSourcePixelFormat(format)
              }
            } else if formatChanged {
              // Recording, same dimensions, different pixel format. Track the
              // change so sourcePixelFormat stays accurate. submitRender
              // selects the right fragment pipeline from the buffer on every
              // call, so the encoded output is unaffected.
              renderer.updateSourcePixelFormat(format)
            }
          }
        }

        // Preview render (with darkened border): non-blocking — if the GPU
        // pipeline is full we drop the frame instead of falling back to the
        // source buffer. The source may be YUV (which Flutter's BGRA Texture
        // would render as garbage) and even on BGRA the dimensions may not
        // match the rendered preview after an aspect-ratio crop.
        //
        // Note: the identity-bypass optimisation (forwarding the raw AVCapture
        // IOSurface directly to the Flutter texture) has been removed.
        // Flutter holds onto the CVPixelBuffer across frames, which starves
        // AVCapture's internal pool when the bypass path is dominant (the
        // common "no effects, no crop" idle case). Always rendering into our
        // own pool-allocated buffer decouples Flutter's lifetime from
        // AVCapture's pool.
        let previewBuffer: CVPixelBuffer?
        if let renderer = videoFrameRenderer {
          previewBuffer = renderer.render(newBuffer, blocking: false)
        } else {
          // No renderer: source is BGRA (videoFormat default) and matches
          // preview dimensions. Safe to publish directly.
          previewBuffer = newBuffer
        }

        // Recording render (no darkening, scaled dimensions): blocking so we
        // never drop a frame from the MP4. Gate on `.writing` status so we
        // don't waste GPU / recording-pool resources on frames that arrive
        // between isRecording flipping true and the AVAssetWriter actually
        // accepting buffers (the window between startWriting() returning and
        // the writer's state machine transitioning to .writing).
        if isRecording, videoWriter?.status == .writing, let renderer = videoFrameRenderer {
          recordingVideoBuffer = renderer.renderForRecording(newBuffer)
        }

        if let displayBuffer = previewBuffer {
          pixelBufferSynchronizationQueue.sync {
            latestPixelBuffer = displayBuffer
          }
          onFrameAvailable?()
        }
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
            NSLog(
              "DefaultCamera: recordingVideoBuffer nil — dropping recording frame (renderer in flight or pool exhausted)"
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
            let bufW = CVPixelBufferGetWidth(nextBuffer)
            let bufH = CVPixelBufferGetHeight(nextBuffer)
            let bufFmt = CVPixelBufferGetPixelFormatType(nextBuffer)
            let writerStatus = videoWriter?.status.rawValue ?? -1
            let writerError = videoWriter?.error?.localizedDescription ?? "nil"
            NSLog(
              "DefaultCamera: videoAdaptor.append FAILED — buffer=\(bufW)x\(bufH) fmt=\(String(format: "0x%08X", bufFmt)) writerStatus=\(writerStatus) writerError=\(writerError)"
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
