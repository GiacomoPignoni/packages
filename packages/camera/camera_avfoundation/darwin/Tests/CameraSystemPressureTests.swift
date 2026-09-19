// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import XCTest

@testable import camera_avfoundation

/// A writer input that can hand over a real `AVAssetWriterInput`.
///
/// `setupWriter` reaches through to it to stamp the video track's transform,
/// which the shared `MockAssetWriterInput` deliberately refuses; nothing here
/// is ever appended to, so an unattached input is enough.
private final class RecordingAssetWriterInput: NSObject, AssetWriterInput {
  let avInput: AVAssetWriterInput
  var expectsMediaDataInRealTime = false
  var isReadyForMoreMediaData = false

  init(mediaType: AVMediaType, outputSettings: [String: Any]) {
    avInput = AVAssetWriterInput(mediaType: mediaType, outputSettings: outputSettings)
  }

  func append(_ sampleBuffer: CMSampleBuffer) -> Bool { true }
}

/// Keeps `setupWriter` off the real capture hardware. The device-locking
/// overrides are no-ops so the wrapper never fights the frame-duration writes
/// these tests are actually measuring.
private final class RecordingMediaSettingsAVWrapper: FLTCamMediaSettingsAVWrapper {
  private let videoInput = RecordingAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 1920,
      AVVideoHeightKey: 1080,
    ])
  private let audioInput = RecordingAssetWriterInput(
    mediaType: .audio,
    outputSettings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44100.0,
      AVNumberOfChannelsKey: 1,
    ])

  override func lockDevice(_ captureDevice: CaptureDevice) throws {}
  override func unlockDevice(_ captureDevice: CaptureDevice) {}
  override func setMinFrameDuration(_ duration: CMTime, on captureDevice: CaptureDevice) {}
  override func setMaxFrameDuration(_ duration: CMTime, on captureDevice: CaptureDevice) {}
  override func addInput(_ writerInput: AssetWriterInput, to writer: AssetWriter) {}

  override func assetWriterAudioInput(withOutputSettings outputSettings: [String: Any]?)
    -> AssetWriterInput
  { audioInput }

  override func assetWriterVideoInput(withOutputSettings outputSettings: [String: Any]?)
    -> AssetWriterInput
  { videoInput }

  override func recommendedVideoSettingsForAssetWriter(
    withFileType fileType: AVFileType, for output: CaptureVideoDataOutput
  ) -> [String: Any]? { [:] }
}

/// Covers how the camera adapts to `AVCaptureDevice.systemPressureState`.
///
/// The KVO wiring itself is not covered: it observes the real
/// `AVCaptureDevice`, which `MockCaptureDevice` deliberately refuses to vend.
/// These tests drive `applySystemPressureLevel` directly — the same entry
/// point the observation hops onto `captureSessionQueue` to call.
final class CameraSystemPressureTests: XCTestCase {
  /// 60 fps expressed as a minimum frame duration.
  private static let sixtyFps = CMTimeMake(value: 1, timescale: 60)
  /// 15 fps: slower than any ceiling pressure applies.
  private static let fifteenFps = CMTimeMake(value: 1, timescale: 15)

  private func createCamera(
    minFrameDuration: CMTime = CameraSystemPressureTests.sixtyFps
  ) -> (DefaultCamera, MockCaptureDevice, DispatchQueue) {
    let configuration = CameraTestUtils.createTestCameraConfiguration()
    let camera = CameraTestUtils.createTestCamera(configuration)
    let device = camera.captureDevice as! MockCaptureDevice
    device.activeVideoMinFrameDuration = minFrameDuration
    device.activeVideoMaxFrameDuration = minFrameDuration
    return (camera, device, configuration.captureSessionQueue)
  }

  /// As `createCamera`, but with the asset-writer graph mocked out so
  /// `startVideoRecording` actually puts the camera into `isRecording`.
  private func createRecordingCamera(
    minFrameDuration: CMTime = CameraSystemPressureTests.sixtyFps
  ) -> (DefaultCamera, MockCaptureDevice, DispatchQueue) {
    let configuration = CameraTestUtils.createTestCameraConfiguration()
    let assetWriter = MockAssetWriter()
    assetWriter.statusStub = { .writing }
    assetWriter.finishWritingStub = { handler in handler() }
    configuration.assetWriterFactory = { _, _ in assetWriter }
    configuration.inputPixelBufferAdaptorFactory = { _, _ in
      MockAssetWriterInputPixelBufferAdaptor()
    }
    configuration.mediaSettingsWrapper = RecordingMediaSettingsAVWrapper()

    let camera = CameraTestUtils.createTestCamera(configuration)
    let device = camera.captureDevice as! MockCaptureDevice
    device.activeVideoMinFrameDuration = minFrameDuration
    device.activeVideoMaxFrameDuration = minFrameDuration
    return (camera, device, configuration.captureSessionQueue)
  }

  /// `applySystemPressureLevel` asserts it runs on the capture session queue.
  private func apply(
    _ level: AVCaptureDevice.SystemPressureState.Level,
    to camera: DefaultCamera,
    on queue: DispatchQueue
  ) {
    queue.sync { camera.applySystemPressureLevel(level) }
  }

  private func fps(_ duration: CMTime) -> Double {
    return (1.0 / CMTimeGetSeconds(duration)).rounded()
  }

  /// A sample buffer the Metal path can actually ingest.
  /// `CameraTestUtils.createTestSampleBuffer` allocates without IOSurface
  /// backing, which `CVMetalTextureCacheCreateTextureFromImage` refuses — the
  /// render then fails and no frame reaches the texture regardless of the
  /// divisor.
  private func createRenderableSampleBuffer() -> CMSampleBuffer {
    let attributes: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA,
      attributes as CFDictionary, &pixelBuffer)

    var formatDescription: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer!,
      formatDescriptionOut: &formatDescription)

    var timingInfo = CMSampleTimingInfo(
      duration: CMTimeMake(value: 1, timescale: 44100),
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid)

    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer!,
      formatDescription: formatDescription!,
      sampleTiming: &timingInfo,
      sampleBufferOut: &sampleBuffer)
    return sampleBuffer!
  }

  func testNominal_leavesDeviceAndPreviewAlone() {
    let (camera, device, queue) = createCamera()

    apply(.nominal, to: camera, on: queue)

    XCTAssertEqual(camera.previewFrameDivisor, 1)
    XCTAssertEqual(fps(device.activeVideoMinFrameDuration), 60)
  }

  func testSerious_halvesPreviewRate_andCapsDeviceAt30() {
    let (camera, device, queue) = createCamera()

    apply(.serious, to: camera, on: queue)

    XCTAssertEqual(camera.previewFrameDivisor, 2)
    XCTAssertEqual(fps(device.activeVideoMinFrameDuration), 30)
    XCTAssertEqual(
      device.activeVideoMaxFrameDuration, CameraSystemPressureTests.sixtyFps,
      "Throttling must not raise the device's minimum frame rate — that would stop the sensor "
        + "lengthening its exposure in low light.")
  }

  func testCritical_thinsPreviewFurther_andCapsDeviceAt24() {
    let (camera, device, queue) = createCamera()

    apply(.critical, to: camera, on: queue)

    XCTAssertEqual(camera.previewFrameDivisor, 3)
    XCTAssertEqual(fps(device.activeVideoMinFrameDuration), 24)
  }

  func testSteppingBackFromCritical_relaxesTheCeiling_ratherThanLatching() {
    let (camera, device, queue) = createCamera()

    apply(.critical, to: camera, on: queue)
    apply(.serious, to: camera, on: queue)

    XCTAssertEqual(
      fps(device.activeVideoMinFrameDuration), 30,
      "Easing from critical to serious must relax the ceiling, not stay at the lowest rate seen.")
  }

  func testReturningToNominal_restoresTheConfiguredRateExactly() {
    let (camera, device, queue) = createCamera()

    apply(.critical, to: camera, on: queue)
    apply(.nominal, to: camera, on: queue)

    XCTAssertEqual(camera.previewFrameDivisor, 1)
    XCTAssertEqual(device.activeVideoMinFrameDuration, CameraSystemPressureTests.sixtyFps)
    XCTAssertEqual(device.activeVideoMaxFrameDuration, CameraSystemPressureTests.sixtyFps)
  }

  func testDeviceSlowerThanTheCeiling_isNeverSpedUp() {
    let (camera, device, queue) = createCamera(
      minFrameDuration: CameraSystemPressureTests.fifteenFps)

    apply(.critical, to: camera, on: queue)

    XCTAssertEqual(
      device.activeVideoMinFrameDuration, CameraSystemPressureTests.fifteenFps,
      "Pressure may only slow the device down, never raise it toward the ceiling.")
    XCTAssertEqual(
      camera.previewFrameDivisor, 3,
      "The preview lever still applies even when the device is already slow enough.")
  }

  func testFormatThatCannotReachTheCeiling_keepsItsRate() {
    let (camera, device, queue) = createCamera()
    let format = MockCaptureDeviceFormat()
    format.flutterVideoSupportedFrameRateRanges = [
      MockFrameRateRange(minFrameRate: 60, maxFrameRate: 60)
    ]
    device.flutterActiveFormat = format

    apply(.critical, to: camera, on: queue)

    XCTAssertEqual(
      device.activeVideoMinFrameDuration, CameraSystemPressureTests.sixtyFps,
      "24 fps is outside this format's supported ranges; setting it would throw "
        + "NSInvalidArgumentException.")
  }

  func testCeilingIsClampedIntoTheFormatsSupportedRange() {
    let (camera, device, queue) = createCamera(
      minFrameDuration: CMTimeMake(value: 1, timescale: 120))
    let format = MockCaptureDeviceFormat()
    format.flutterVideoSupportedFrameRateRanges = [
      MockFrameRateRange(minFrameRate: 40, maxFrameRate: 120)
    ]
    device.flutterActiveFormat = format

    apply(.critical, to: camera, on: queue)

    XCTAssertEqual(
      fps(device.activeVideoMinFrameDuration), 40,
      "A 24 fps ceiling must land on the slowest rate the format can actually deliver.")
  }

  func testPressureDuringRecording_leavesTheRecordedFrameRateAlone_untilItStops() {
    let (camera, device, queue) = createRecordingCamera()

    // Started from this thread rather than on `queue`: `setupWriter` reaches
    // `upgradeAudioSessionCategory`, which hops to main and would deadlock
    // against a `queue.sync` held by the main thread.
    camera.startVideoRecording(completion: { _ in }, messengerForStreaming: nil)
    XCTAssertTrue(camera.isRecording)

    apply(.critical, to: camera, on: queue)

    XCTAssertEqual(
      fps(device.activeVideoMinFrameDuration), 60,
      "Capping the device mid-take would turn a 60 fps recording into a 24 fps one partway "
        + "through the file.")
    XCTAssertEqual(
      camera.previewFrameDivisor, 3,
      "The preview lever has no effect on the file, so it still applies while recording.")

    let stopped = expectation(description: "recording stopped")
    camera.stopVideoRecording(completion: { _ in stopped.fulfill() })
    wait(for: [stopped], timeout: 5)

    XCTAssertEqual(
      fps(device.activeVideoMinFrameDuration), 24,
      "The withheld ceiling must land once the file is closed.")
  }

  /// The device-swap half of this (`setDescriptionWhileRecording`) is not
  /// covered: it rebinds both KVO observations to the incoming device, which
  /// means reaching for the real `AVCaptureDevice` that `MockCaptureDevice`
  /// refuses to vend. `close()` exercises the same `restoreFrameRate`
  /// call without that.
  func testClose_handsTheDeviceBackItsConfiguredRate() {
    let (camera, device, queue) = createCamera()

    apply(.critical, to: camera, on: queue)
    XCTAssertEqual(fps(device.activeVideoMinFrameDuration), 24)

    queue.sync { camera.close() }

    XCTAssertEqual(device.activeVideoMinFrameDuration, CameraSystemPressureTests.sixtyFps)
  }

  func testRepeatedLevel_isIgnored() {
    let (camera, device, queue) = createCamera()

    apply(.serious, to: camera, on: queue)
    // Mimic the device having been reconfigured by something else; a repeated
    // notification at the same level must not re-apply the ceiling over it.
    device.activeVideoMinFrameDuration = CameraSystemPressureTests.sixtyFps
    apply(.serious, to: camera, on: queue)

    XCTAssertEqual(fps(device.activeVideoMinFrameDuration), 60)
  }

  func testPreviewDivisor_dropsInterveningFramesFromTheTexture() {
    let (camera, _, queue) = createCamera()
    // An aspect-ratio crop makes the renderer's output differ from the source,
    // which is enough for `canBypassPreview` to decline — otherwise the frame
    // is published straight through and the divisor never gets a say.
    queue.sync { camera.setAspectRatio(1.5) }
    apply(.serious, to: camera, on: queue)

    let output = camera.captureVideoOutput.avOutput
    let connection = CameraTestUtils.createTestConnection(output)

    var deliveredFrames = 0
    for _ in 0..<4 {
      camera.captureOutput(
        output, didOutput: createRenderableSampleBuffer(), from: connection)
      if camera.copyPixelBuffer()?.takeRetainedValue() != nil {
        deliveredFrames += 1
      }
    }

    XCTAssertEqual(
      deliveredFrames, 2,
      "At divisor 2 only every other frame should reach the preview texture.")
  }
}
