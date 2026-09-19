// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import XCTest

@testable import camera_avfoundation

/// Covers the manual half of deferred start: when the session is asked to
/// initialize its deferred outputs, and — just as importantly — when it must
/// not be. `runDeferredStartWhenNeeded` throws if the session is still in
/// automatic mode, so the guard around it is load-bearing.
///
/// Whether `DefaultCamera.init` actually engages manual mode is not covered
/// here: it depends on `isDeferredStartSupported` / `isManualDeferredStartSupported`
/// reported by a real `AVCapturePhotoOutput` attached to a real
/// `AVCaptureSession`, neither of which exists behind these mocks.
final class CameraDeferredStartTests: XCTestCase {
  private func createCamera() -> (DefaultCamera, MockCaptureSession, DispatchQueue) {
    let configuration = CameraTestUtils.createTestCameraConfiguration()
    let session = configuration.videoCaptureSession as! MockCaptureSession
    let camera = CameraTestUtils.createTestCamera(configuration)
    return (camera, session, configuration.captureSessionQueue)
  }

  /// Delivers one video sample buffer, as AVFoundation would.
  private func deliverFrame(to camera: DefaultCamera) {
    let output = camera.captureVideoOutput.avOutput
    camera.captureOutput(
      output,
      didOutput: CameraTestUtils.createTestSampleBuffer(),
      from: CameraTestUtils.createTestConnection(output))
  }

  func testCopyPixelBuffer_requestsDeferredStartOnce_whenManualModeEngaged() {
    let (camera, session, captureSessionQueue) = createCamera()
    camera.usesManualDeferredStart = true

    deliverFrame(to: camera)
    _ = camera.copyPixelBuffer()?.takeRetainedValue()
    deliverFrame(to: camera)
    _ = camera.copyPixelBuffer()?.takeRetainedValue()
    // Drain the hop `copyPixelBuffer` makes onto the capture session queue.
    captureSessionQueue.sync {}

    XCTAssertEqual(
      session.requestDeferredStartCallCount, 1,
      "Deferred start must be requested exactly once, on the first frame Flutter takes.")
  }

  func testCopyPixelBuffer_doesNotRequestDeferredStart_whenSessionStaysAutomatic() {
    let (camera, session, captureSessionQueue) = createCamera()

    deliverFrame(to: camera)
    _ = camera.copyPixelBuffer()?.takeRetainedValue()
    captureSessionQueue.sync {}

    XCTAssertEqual(
      session.requestDeferredStartCallCount, 0,
      "Requesting deferred start in automatic mode throws; it must stay unrequested.")
  }

  func testCopyPixelBuffer_doesNotRequestDeferredStart_whenNoFrameIsAvailable() {
    let (camera, session, captureSessionQueue) = createCamera()
    camera.usesManualDeferredStart = true

    // No sample buffer delivered, so there is nothing to hand the compositor
    // and preview is not on screen yet.
    XCTAssertNil(camera.copyPixelBuffer())
    captureSessionQueue.sync {}

    XCTAssertEqual(session.requestDeferredStartCallCount, 0)
  }

  func testSetDescription_rearmsDeferredStart_forTheNewConfigurationCommit() {
    let (camera, session, captureSessionQueue) = createCamera()
    camera.usesManualDeferredStart = true

    deliverFrame(to: camera)
    _ = camera.copyPixelBuffer()?.takeRetainedValue()
    captureSessionQueue.sync {}
    XCTAssertEqual(session.requestDeferredStartCallCount, 1)

    // A device swap commits afresh, which re-defers the outputs; the request
    // already spent above no longer covers them.
    captureSessionQueue.sync { camera.commitVideoConfiguration() }
    deliverFrame(to: camera)
    _ = camera.copyPixelBuffer()?.takeRetainedValue()
    captureSessionQueue.sync {}

    XCTAssertEqual(
      session.requestDeferredStartCallCount, 2,
      "Each configuration commit needs its own request.")
  }

  func testInit_leavesSessionInAutomaticMode_whenManualIsUnsupported() {
    let (camera, session, _) = createCamera()

    XCTAssertTrue(
      session.automaticDeferredStartEnabled,
      "Without manual support the session must be left alone — AVFoundation still defers, "
        + "just on its own schedule.")
    XCTAssertFalse(camera.usesManualDeferredStart)
  }
}
