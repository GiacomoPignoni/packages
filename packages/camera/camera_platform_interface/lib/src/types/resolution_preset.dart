// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Affect the quality of video recording and image capture:
///
/// A preset is treated as a target resolution, and exact values are not
/// guaranteed. Platform implementations may fall back to a higher or lower
/// resolution if a specific preset is not available.
enum ResolutionPreset {
  /// 352x288 on iOS, ~240p on Android and Web
  low,

  /// ~480p
  medium,

  /// ~720p
  high,

  /// ~1080p
  veryHigh,

  /// ~2160p
  ultraHigh,

  /// The highest resolution available.
  max,

  /// Optimized for still-image capture. On iOS this maps to
  /// `AVCaptureSession.Preset.photo`, which configures the sensor to deliver
  /// the largest still-image resolution it supports (e.g. 24MP / 48MP on
  /// recent iPhones) at the cost of a reduced video stream (~1440p on most
  /// devices). Use this when photo quality matters more than video
  /// resolution; prefer [max] or [ultraHigh] for video-first applications.
  ///
  /// On platforms that do not have a photo-specific preset, this falls back
  /// to the same behaviour as [max].
  photo,
}
