// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation

@testable import camera_avfoundation

/// Mock implementation of `AssetWriterInput` protocol which allows injecting a custom
/// implementation.
final class MockAssetWriterInput: NSObject, AssetWriterInput {
  var appendStub: ((CMSampleBuffer) -> Bool)?

  /// An unattached input, enough for code that only stamps properties such as the track transform.
  let avInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)

  var expectsMediaDataInRealTime = false

  var isReadyForMoreMediaData = false

  func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
    return appendStub?(sampleBuffer) ?? false
  }
}
