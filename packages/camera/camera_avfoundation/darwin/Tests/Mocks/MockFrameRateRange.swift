// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import CoreMedia
import Foundation

@testable import camera_avfoundation

/// A mock implementation of `FrameRateRange` that allows mocking the class properties.
final class MockFrameRateRange: NSObject, FrameRateRange {
  var minFrameRate: Float64
  var maxFrameRate: Float64
  var minFrameDuration: CMTime
  var maxFrameDuration: CMTime

  /// Initializes a `MockFrameRateRange` with the given frame rate range.
  /// Durations are derived from the rates, as `AVFrameRateRange` does.
  init(minFrameRate: Float64, maxFrameRate: Float64) {
    self.minFrameRate = minFrameRate
    self.maxFrameRate = maxFrameRate
    minFrameDuration = CMTime(seconds: 1 / maxFrameRate, preferredTimescale: 600)
    maxFrameDuration = CMTime(seconds: 1 / minFrameRate, preferredTimescale: 600)
  }
}
