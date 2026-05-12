// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import Flutter
import Foundation

/// The completion handler block for save photo operations.
/// Can be called from either main queue or IO queue.
/// If success, `path` will be present and `error` will be nil. Otherwise, `path` will be nil and
/// `error` will be present.
/// path - the path for successfully saved photo file.
/// error - photo capture error or IO error.
typealias SavePhotoDelegateCompletionHandler = (String?, Error?) -> Void

/// Delegate object that handles photo capture results.
class SavePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  /// The file path for the captured photo.
  private let path: String

  /// The queue on which captured photos are written to disk.
  private let ioQueue: DispatchQueue

  /// Pre-save processor. Its return value is written to disk; returning nil is
  /// treated as a capture failure (do not silently fall back to the raw sensor
  /// frame — it would be wrong-sized or un-cropped).
  private let photoProcessor: (AVCapturePhoto) -> Data?

  /// The completion handler block for capture and save photo operations.
  let completionHandler: SavePhotoDelegateCompletionHandler

  /// The path for captured photo file.
  /// Exposed for unit tests to verify the captured photo file path.
  var filePath: String {
    path
  }

  /// Initialize a photo capture delegate.
  /// path - the path for captured photo file.
  /// ioQueue - the queue on which captured photos are written to disk.
  /// completionHandler - The completion handler block for save photo operations. Can
  /// be called from either main queue or IO queue.
  init(
    path: String,
    ioQueue: DispatchQueue,
    photoProcessor: @escaping (AVCapturePhoto) -> Data? = { $0.fileDataRepresentation() },
    completionHandler: @escaping SavePhotoDelegateCompletionHandler
  ) {
    self.path = path
    self.ioQueue = ioQueue
    self.photoProcessor = photoProcessor
    self.completionHandler = completionHandler
    super.init()
  }

  /// Handler to write captured photo data into a file.
  /// - Parameters:
  ///   - error: The capture error
  ///   - photoDataProvider: A closure that provides photo data
  func handlePhotoCaptureResult(
    error: Error?,
    photoDataProvider: @escaping () -> WritableData?
  ) {
    if let error = error {
      completionHandler(nil, error)
      return
    }

    ioQueue.async { [weak self] in
      guard let strongSelf = self else { return }

      guard let data = photoDataProvider() else {
        // The processor explicitly returned nil, which means it could not
        // process the photo (e.g. the Metal render failed). Falling back to
        // the unprocessed sensor frame would silently produce a wrong-sized
        // or un-cropped photo, so we surface this as an error instead.
        strongSelf.completionHandler(
          nil,
          NSError(
            domain: "FLTCameraErrorDomain",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Photo processor returned nil data"]))
        return
      }

      do {
        try data.writeToPath(strongSelf.path, options: .atomic)
        strongSelf.completionHandler(strongSelf.path, nil)
      } catch {
        strongSelf.completionHandler(nil, error)
      }
    }
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    handlePhotoCaptureResult(error: error) { [photoProcessor] in photoProcessor(photo) }
  }
}
