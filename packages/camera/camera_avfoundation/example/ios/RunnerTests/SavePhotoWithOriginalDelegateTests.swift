// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import XCTest

@testable import camera_avfoundation

final class SavePhotoWithOriginalDelegateTests: XCTestCase {
  private func makeDelegate(
    originalPath: String = "/tmp/test_original",
    processedPath: String = "/tmp/test_processed",
    ioQueue: DispatchQueue = DispatchQueue(label: "test_io"),
    completion: @escaping SavePhotoWithOriginalCompletion
  ) -> SavePhotoWithOriginalDelegate {
    // The processor closures are unused by `handlePhotoCaptureResult`; the
    // test paths feed the dataProvider closures directly, exactly as the
    // single-output delegate tests do.
    return SavePhotoWithOriginalDelegate(
      originalPath: originalPath,
      processedPath: processedPath,
      ioQueue: ioQueue,
      originalProcessor: { _ in nil },
      processedProcessor: { _ in nil },
      completionHandler: completion)
  }

  func testHandlePhotoCaptureResult_failsImmediatelyOnCaptureError() {
    let completionExpectation = expectation(
      description: "Capture errors propagate synchronously.")
    let captureError = NSError(domain: "test", code: 7, userInfo: nil)
    let delegate = makeDelegate { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        XCTAssertEqual(captureError, error as NSError)
      }
      completionExpectation.fulfill()
    }

    delegate.handlePhotoCaptureResult(
      error: captureError,
      originalDataProvider: { nil },
      processedDataProvider: { nil })

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testHandlePhotoCaptureResult_failsWhenOriginalProcessorReturnsNil() {
    let completionExpectation = expectation(
      description: "Nil original data must surface as an error.")
    let delegate = makeDelegate { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        XCTAssertEqual((error as NSError).domain, "FLTCameraErrorDomain")
      }
      completionExpectation.fulfill()
    }

    delegate.handlePhotoCaptureResult(
      error: nil,
      originalDataProvider: { nil },
      processedDataProvider: { MockWritableData() })

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testHandlePhotoCaptureResult_failsWhenProcessedProcessorReturnsNil() {
    let completionExpectation = expectation(
      description: "Nil processed data must surface as an error.")
    let delegate = makeDelegate { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        XCTAssertEqual((error as NSError).domain, "FLTCameraErrorDomain")
      }
      completionExpectation.fulfill()
    }

    delegate.handlePhotoCaptureResult(
      error: nil,
      originalDataProvider: { MockWritableData() },
      processedDataProvider: { nil })

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testHandlePhotoCaptureResult_writesBothFilesOnSuccess() {
    let completionExpectation = expectation(
      description: "Both files must be written on success.")
    let originalPath = "/tmp/test_original"
    let processedPath = "/tmp/test_processed"
    var originalWritten = false
    var processedWritten = false

    let originalData = MockWritableData()
    originalData.writeToFileStub = { path, _ in
      XCTAssertEqual(path, originalPath)
      originalWritten = true
    }

    let processedData = MockWritableData()
    processedData.writeToFileStub = { path, _ in
      XCTAssertEqual(path, processedPath)
      processedWritten = true
    }

    let delegate = makeDelegate(
      originalPath: originalPath, processedPath: processedPath
    ) { result in
      switch result {
      case .success(let paths):
        XCTAssertEqual(paths.originalPath, originalPath)
        XCTAssertEqual(paths.processedPath, processedPath)
        XCTAssertTrue(originalWritten)
        XCTAssertTrue(processedWritten)
      case .failure:
        XCTFail("Expected success")
      }
      completionExpectation.fulfill()
    }

    delegate.handlePhotoCaptureResult(
      error: nil,
      originalDataProvider: { originalData },
      processedDataProvider: { processedData })

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testHandlePhotoCaptureResult_rollsBackOriginalIfProcessedWriteFails() {
    let completionExpectation = expectation(
      description: "Failed processed write must roll back the original file.")
    let originalPath =
      NSTemporaryDirectory() + "save_photo_dual_rollback_\(UUID().uuidString).bin"
    let processedPath = "/tmp/test_processed_should_not_write"
    let writeError = NSError(domain: "ProcessedWriteFailure", code: 13, userInfo: nil)

    let originalData = MockWritableData()
    originalData.writeToFileStub = { path, options in
      // Touch the file so the rollback has something concrete to delete.
      try Data().write(to: URL(fileURLWithPath: path), options: options)
    }

    let processedData = MockWritableData()
    processedData.writeToFileStub = { _, _ in throw writeError }

    let delegate = makeDelegate(
      originalPath: originalPath, processedPath: processedPath
    ) { result in
      switch result {
      case .success:
        XCTFail("Expected failure")
      case .failure(let error):
        XCTAssertEqual(error as NSError, writeError)
        XCTAssertFalse(
          FileManager.default.fileExists(atPath: originalPath),
          "Original file must be removed when the processed write fails.")
      }
      completionExpectation.fulfill()
    }

    delegate.handlePhotoCaptureResult(
      error: nil,
      originalDataProvider: { originalData },
      processedDataProvider: { processedData })

    waitForExpectations(timeout: 30, handler: nil)
  }

  /// `AVCapturePhoto` has no public initializer, so synthesize a placeholder
  /// for tests of `photoOutput(_:didFinishProcessingPhoto:error:)` paths that
  /// never read any property off the photo. The Objective-C isa still points
  /// at the underlying `NSObject` class, so dealloc routes through NSObject
  /// and ARC release is safe.
  private func placeholderPhoto() -> AVCapturePhoto {
    return unsafeBitCast(NSObject(), to: AVCapturePhoto.self)
  }

  func testPhotoOutput_capturesProcessorsAndForwardsToCompletion() {
    // Exercises the actual `AVCapturePhotoCaptureDelegate` entry point so a
    // refactor of the closure-based dispatch (`{ [originalProcessor] in
    // originalProcessor(photo) }`) cannot silently break production while
    // the `handlePhotoCaptureResult`-driven tests above stay green.
    let completionExpectation = expectation(
      description: "photoOutput must route through to completion on success.")
    var originalCalled = false
    var processedCalled = false

    let originalData = MockWritableData()
    originalData.writeToFileStub = { _, _ in }
    let processedData = MockWritableData()
    processedData.writeToFileStub = { _, _ in }

    let delegate = SavePhotoWithOriginalDelegate(
      originalPath: "/tmp/test_original",
      processedPath: "/tmp/test_processed",
      ioQueue: DispatchQueue(label: "test_io"),
      originalProcessor: { _ in originalCalled = true; return originalData },
      processedProcessor: { _ in processedCalled = true; return processedData }
    ) { result in
      if case .failure = result {
        XCTFail("Expected success")
      }
      XCTAssertTrue(originalCalled)
      XCTAssertTrue(processedCalled)
      completionExpectation.fulfill()
    }

    delegate.photoOutput(
      AVCapturePhotoOutput(),
      didFinishProcessingPhoto: placeholderPhoto(),
      error: nil)

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testPhotoOutput_propagatesCaptureErrorWithoutInvokingProcessors() {
    let completionExpectation = expectation(
      description: "photoOutput must surface capture errors without touching processors.")
    let captureError = NSError(domain: "test", code: 7, userInfo: nil)

    let delegate = SavePhotoWithOriginalDelegate(
      originalPath: "/tmp/test_original",
      processedPath: "/tmp/test_processed",
      ioQueue: DispatchQueue(label: "test_io"),
      originalProcessor: { _ in XCTFail("processor must not run on error"); return nil },
      processedProcessor: { _ in XCTFail("processor must not run on error"); return nil }
    ) { result in
      if case .failure(let error) = result {
        XCTAssertEqual(captureError, error as NSError)
      } else {
        XCTFail("Expected failure")
      }
      completionExpectation.fulfill()
    }

    delegate.photoOutput(
      AVCapturePhotoOutput(),
      didFinishProcessingPhoto: placeholderPhoto(),
      error: captureError)

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testHandlePhotoCaptureResult_runsProvidersAndWritesOnIOQueue() {
    let originalProviderOnIOQueue = expectation(
      description: "Original data provider must run on the io queue.")
    let processedProviderOnIOQueue = expectation(
      description: "Processed data provider must run on the io queue.")
    let originalWriteOnIOQueue = expectation(
      description: "Original file write must run on the io queue.")
    let processedWriteOnIOQueue = expectation(
      description: "Processed file write must run on the io queue.")
    let completionExpectation = expectation(
      description: "Completion must fire on success.")

    let ioQueue = DispatchQueue(label: "test_io")
    let ioSpecific = DispatchSpecificKey<Void>()
    ioQueue.setSpecific(key: ioSpecific, value: ())

    let originalData = MockWritableData()
    originalData.writeToFileStub = { _, _ in
      if DispatchQueue.getSpecific(key: ioSpecific) != nil {
        originalWriteOnIOQueue.fulfill()
      }
    }

    let processedData = MockWritableData()
    processedData.writeToFileStub = { _, _ in
      if DispatchQueue.getSpecific(key: ioSpecific) != nil {
        processedWriteOnIOQueue.fulfill()
      }
    }

    let delegate = makeDelegate(ioQueue: ioQueue) { _ in
      completionExpectation.fulfill()
    }

    delegate.handlePhotoCaptureResult(
      error: nil,
      originalDataProvider: {
        if DispatchQueue.getSpecific(key: ioSpecific) != nil {
          originalProviderOnIOQueue.fulfill()
        }
        return originalData
      },
      processedDataProvider: {
        if DispatchQueue.getSpecific(key: ioSpecific) != nil {
          processedProviderOnIOQueue.fulfill()
        }
        return processedData
      })

    waitForExpectations(timeout: 30, handler: nil)
  }
}
