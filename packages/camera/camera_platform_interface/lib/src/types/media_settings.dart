// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_equals_and_hash_code_on_mutable_classes

import 'resolution_preset.dart';

/// Recording media settings.
///
/// Used in [CameraPlatform.createCameraWithSettings].
/// Allows to tune recorded video parameters, such as resolution, frame rate, bitrate.
/// If [fps], [videoBitrate] or [audioBitrate] are passed, they must be greater than zero.
class MediaSettings {
  /// Creates a [MediaSettings].
  const MediaSettings({
    this.resolutionPreset,
    this.fps,
    this.videoBitrate,
    this.audioBitrate,
    this.enableAudio = false,
    this.aspectRatio,
  }) : assert(fps == null || fps > 0, 'fps must be null or greater than zero'),
       assert(
         videoBitrate == null || videoBitrate > 0,
         'videoBitrate must be null or greater than zero',
       ),
       assert(
         audioBitrate == null || audioBitrate > 0,
         'audioBitrate must be null or greater than zero',
       );

  /// [ResolutionPreset] affect the quality of video recording and image capture.
  final ResolutionPreset? resolutionPreset;

  /// Rate at which frames should be captured by the camera in frames per second.
  final int? fps;

  /// The video encoding bit rate for recording.
  final int? videoBitrate;

  /// The audio encoding bit rate for recording.
  final int? audioBitrate;

  /// Controls audio presence in recorded video.
  final bool enableAudio;

  /// Aspect ratio (width/height) applied as a center-crop to preview, photo,
  /// and video.
  ///
  /// Carried here rather than only through `setAspectRatio` so the crop is in
  /// place before the camera starts producing frames, instead of being applied
  /// to one that is already running.
  ///
  /// `null` names no ratio, which leaves whichever crop is already in effect
  /// alone — a camera rebuilt to change [resolutionPreset] keeps the one the
  /// last camera had, as it keeps every other setting the platform's render
  /// pipeline holds. Call `setAspectRatio(null)` to actually clear a crop;
  /// with none ever set, no ratio means no crop.
  final double? aspectRatio;

  @override
  bool operator ==(Object other) {
    if (identical(other, this)) {
      return true;
    }
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is MediaSettings &&
        resolutionPreset == other.resolutionPreset &&
        fps == other.fps &&
        videoBitrate == other.videoBitrate &&
        audioBitrate == other.audioBitrate &&
        enableAudio == other.enableAudio &&
        aspectRatio == other.aspectRatio;
  }

  @override
  int get hashCode =>
      Object.hash(resolutionPreset, fps, videoBitrate, audioBitrate, enableAudio, aspectRatio);

  @override
  String toString() {
    return 'MediaSettings{'
        'resolutionPreset: $resolutionPreset, '
        'fps: $fps, '
        'videoBitrate: $videoBitrate, '
        'audioBitrate: $audioBitrate, '
        'enableAudio: $enableAudio, '
        'aspectRatio: $aspectRatio}';
  }
}
