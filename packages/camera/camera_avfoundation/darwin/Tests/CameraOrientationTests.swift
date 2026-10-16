// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import Flutter
import XCTest

@testable import camera_avfoundation

final class CameraOrientationTests: XCTestCase {
  private func createCameraPlugin() -> (
    cameraPlugin: CameraPlugin,
    mockCamera: MockCamera,
    mockEventAPI: MockGlobalEventApi,
    mockDevice: MockCaptureDevice,
    mockDeviceDiscoverer: MockCameraDeviceDiscoverer,
    captureSessionQueue: DispatchQueue
  ) {
    let mockDevice = MockCaptureDevice()
    let mockCamera = MockCamera()
    let mockEventAPI = MockGlobalEventApi()
    let mockDeviceDiscoverer = MockCameraDeviceDiscoverer()
    let captureSessionQueue = DispatchQueue(label: "io.flutter.camera.captureSessionQueue")

    let cameraPlugin = CameraPlugin(
      registry: MockFlutterTextureRegistry(),
      messenger: MockFlutterBinaryMessenger(),
      globalAPI: mockEventAPI,
      deviceDiscoverer: mockDeviceDiscoverer,
      permissionManager: MockCameraPermissionManager(),
      deviceFactory: { _ in mockDevice },
      captureSessionFactory: { MockCaptureSession() },
      captureDeviceInputFactory: MockCaptureDeviceInputFactory(),
      captureSessionQueue: captureSessionQueue
    )
    cameraPlugin.camera = mockCamera

    return (
      cameraPlugin,
      mockCamera,
      mockEventAPI,
      mockDevice,
      mockDeviceDiscoverer,
      captureSessionQueue
    )
  }

  private func sendOrientation(
    _ orientation: UIDeviceOrientation,
    to cameraPlugin: CameraPlugin,
    captureSessionQueue: DispatchQueue
  ) {
    cameraPlugin.orientationChanged(orientation)
    waitForQueueRoundTrip(with: captureSessionQueue)
  }

  func testOrientationNotifications() {
    let (cameraPlugin, _, mockEventAPI, _, _, captureSessionQueue) = createCameraPlugin()

    sendOrientation(.portraitUpsideDown, to: cameraPlugin, captureSessionQueue: captureSessionQueue)
    XCTAssertEqual(mockEventAPI.lastOrientation, .portraitDown)
    sendOrientation(.portrait, to: cameraPlugin, captureSessionQueue: captureSessionQueue)
    XCTAssertEqual(mockEventAPI.lastOrientation, .portraitUp)
    sendOrientation(.landscapeLeft, to: cameraPlugin, captureSessionQueue: captureSessionQueue)
    XCTAssertEqual(mockEventAPI.lastOrientation, .landscapeLeft)
    sendOrientation(.landscapeRight, to: cameraPlugin, captureSessionQueue: captureSessionQueue)
    XCTAssertEqual(mockEventAPI.lastOrientation, .landscapeRight)
  }

  func testGravityOrientation_snapsToTheNearestQuarterTurn() {
    XCTAssertEqual(GravityOrientationObserver.orientation(x: 0, y: -1), .portrait)
    XCTAssertEqual(GravityOrientationObserver.orientation(x: -1, y: 0), .landscapeLeft)
    XCTAssertEqual(GravityOrientationObserver.orientation(x: 1, y: 0), .landscapeRight)
    XCTAssertEqual(GravityOrientationObserver.orientation(x: 0, y: 1), .portraitUpsideDown)
    XCTAssertEqual(GravityOrientationObserver.orientation(x: 0.4, y: -0.9), .portrait)
  }

  func testGravityOrientation_isNilWhenFlatOrNearADiagonal() {
    XCTAssertNil(GravityOrientationObserver.orientation(x: 0.1, y: -0.1))
    XCTAssertNil(GravityOrientationObserver.orientation(x: 0.7, y: -0.7))
  }

  func testOrientationUpdateMustBeOnCaptureSessionQueue() {
    let queueExpectation = expectation(
      description: "Orientation update must happen on the capture session queue")
    let (cameraPlugin, mockCamera, _, _, _, captureSessionQueue) = createCameraPlugin()
    let captureSessionQueueSpecific = DispatchSpecificKey<Void>()
    captureSessionQueue.setSpecific(
      key: captureSessionQueueSpecific,
      value: ())

    mockCamera.setDeviceOrientationStub = { orientation in
      if DispatchQueue.getSpecific(key: captureSessionQueueSpecific) != nil {
        queueExpectation.fulfill()
      }
    }

    cameraPlugin.orientationChanged(.landscapeLeft)
    waitForExpectations(timeout: 30, handler: nil)
  }

  func testOrientationChangedNoRetainCycle() {
    let (_, mockCamera, mockEventAPI, mockDevice, mockDeviceDiscoverer, _) = createCameraPlugin()
    let captureSessionQueue = DispatchQueue(label: "capture_session_queue")
    weak var weakPlugin: CameraPlugin?
    weak var weakDevice = mockDevice

    autoreleasepool {
      let cameraPlugin = CameraPlugin(
        registry: MockFlutterTextureRegistry(),
        messenger: MockFlutterBinaryMessenger(),
        globalAPI: mockEventAPI,
        deviceDiscoverer: mockDeviceDiscoverer,
        permissionManager: MockCameraPermissionManager(),
        deviceFactory: { _ in weakDevice! },
        captureSessionFactory: { MockCaptureSession() },
        captureDeviceInputFactory: MockCaptureDeviceInputFactory(),
        captureSessionQueue: captureSessionQueue
      )
      weakPlugin = cameraPlugin
      cameraPlugin.camera = mockCamera

      cameraPlugin.orientationChanged(.landscapeLeft)
    }

    // Sanity check.
    let cameraDeallocatedExpectation = self.expectation(
      description: "Camera must have been deallocated.")
    captureSessionQueue.async {
      XCTAssertNil(weakPlugin)
      cameraDeallocatedExpectation.fulfill()
    }
    // Awaiting expectation is needed. The test is flaky when checking for nil right away.
    waitForExpectations(timeout: 1, handler: nil)

    var setDeviceOrientationCalled = false
    mockCamera.setDeviceOrientationStub = { orientation in
      if orientation == .landscapeLeft {
        setDeviceOrientationCalled = true
      }
    }

    weak var weakEventAPI = mockEventAPI
    // Must check in captureSessionQueue since orientationChanged dispatches to this queue.
    let expectation = self.expectation(description: "Dispatched to capture session queue")
    captureSessionQueue.async {
      XCTAssertFalse(setDeviceOrientationCalled)
      XCTAssertFalse(weakEventAPI?.deviceOrientationChangedCalled ?? false)
      expectation.fulfill()
    }

    waitForExpectations(timeout: 30, handler: nil)
  }
}
