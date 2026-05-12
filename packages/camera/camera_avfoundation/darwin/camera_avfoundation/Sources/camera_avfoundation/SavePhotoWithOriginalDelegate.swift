// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import Foundation

/// Completion handler for `SavePhotoWithOriginalDelegate`.
///
/// On success, both files have been written and `result` carries the two
/// paths. On failure, neither file remains on disk — partial successes are
/// rolled back before the handler is invoked.
typealias SavePhotoWithOriginalCompletion = (
  Result<(originalPath: String, processedPath: String), Error>
) -> Void

/// `AVCapturePhotoCaptureDelegate` that writes the same shutter event to two
/// files: the un-effected original (with `captureScale` preserved) and the
/// shader-processed version. Modelled on `SavePhotoDelegate` so callsites can
/// swap the two with minimal divergence.
///
/// Both processors run on the shared `ioQueue` (off the capture session
/// queue) and both writes are atomic. If either the processor returns nil or
/// the write fails, any sibling file that already landed on disk is deleted
/// before the failure is reported — the caller never has to reason about
/// orphan files.
final class SavePhotoWithOriginalDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  /// File path for the un-effected original photo.
  private let originalPath: String

  /// File path for the shader-processed photo.
  private let processedPath: String

  /// Queue on which both processors and both file writes run.
  private let ioQueue: DispatchQueue

  /// Produces the JPEG/HEIF bytes for the un-effected original.
  /// Returning nil is treated as a failure (no fallback to the raw sensor
  /// frame, to match `SavePhotoDelegate`'s contract).
  private let originalProcessor: (AVCapturePhoto) -> Data?

  /// Produces the JPEG/HEIF bytes for the shader-processed photo.
  /// Returning nil is treated as a failure.
  private let processedProcessor: (AVCapturePhoto) -> Data?

  /// Completion handler. May be invoked on the IO queue (success / IO error)
  /// or on the AV photo-output delegate queue (capture error).
  let completionHandler: SavePhotoWithOriginalCompletion

  /// Exposed for unit tests.
  var originalFilePath: String { originalPath }
  var processedFilePath: String { processedPath }

  init(
    originalPath: String,
    processedPath: String,
    ioQueue: DispatchQueue,
    originalProcessor: @escaping (AVCapturePhoto) -> Data?,
    processedProcessor: @escaping (AVCapturePhoto) -> Data?,
    completionHandler: @escaping SavePhotoWithOriginalCompletion
  ) {
    self.originalPath = originalPath
    self.processedPath = processedPath
    self.ioQueue = ioQueue
    self.originalProcessor = originalProcessor
    self.processedProcessor = processedProcessor
    self.completionHandler = completionHandler
    super.init()
  }

  /// Test-friendly entry point. Mirrors `SavePhotoDelegate.handlePhotoCaptureResult`
  /// but accepts two data providers — one per output — so tests can drive the
  /// processor return values without an `AVCapturePhoto`.
  func handlePhotoCaptureResult(
    error: Error?,
    originalDataProvider: @escaping () -> WritableData?,
    processedDataProvider: @escaping () -> WritableData?
  ) {
    if let error = error {
      completionHandler(.failure(error))
      return
    }

    ioQueue.async { [weak self] in
      guard let self = self else { return }

      // Build both blobs before touching disk so a nil from either side
      // aborts cleanly without leaving a partial write behind.
      guard let originalData = originalDataProvider() else {
        self.completionHandler(.failure(Self.processorError(forOriginal: true)))
        return
      }
      guard let processedData = processedDataProvider() else {
        self.completionHandler(.failure(Self.processorError(forOriginal: false)))
        return
      }

      do {
        try originalData.writeToPath(self.originalPath, options: .atomic)
      } catch {
        self.completionHandler(.failure(error))
        return
      }

      do {
        try processedData.writeToPath(self.processedPath, options: .atomic)
      } catch {
        // The original landed on disk before the processed write failed —
        // delete it so the caller never sees a half-finished capture.
        Self.removeFileIfPresent(at: self.originalPath)
        self.completionHandler(.failure(error))
        return
      }

      self.completionHandler(
        .success((originalPath: self.originalPath, processedPath: self.processedPath)))
    }
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    handlePhotoCaptureResult(
      error: error,
      originalDataProvider: { [originalProcessor] in originalProcessor(photo) },
      processedDataProvider: { [processedProcessor] in processedProcessor(photo) })
  }

  // MARK: - Private helpers

  private static func processorError(forOriginal: Bool) -> NSError {
    let which = forOriginal ? "original" : "processed"
    return NSError(
      domain: "FLTCameraErrorDomain",
      code: -1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Photo processor returned nil data for \(which) image"
      ])
  }

  private static func removeFileIfPresent(at path: String) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return }
    do {
      try fm.removeItem(atPath: path)
    } catch {
      NSLog(
        "SavePhotoWithOriginalDelegate: failed to remove orphan file at \(path): \(error)")
    }
  }
}
