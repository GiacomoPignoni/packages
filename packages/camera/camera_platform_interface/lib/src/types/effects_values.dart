// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Visual effect parameters applied by the camera shader pipeline.
///
/// Pass an instance to [CameraPlatform.setEffectsValues].
/// On platforms that do not support shader effects every field is ignored.
class EffectsValues {
  /// Creates an [EffectsValues].
  const EffectsValues({this.vignetteIntensity = 0.0})
    : assert(
        vignetteIntensity >= 0.0 && vignetteIntensity <= 1.0,
        'vignetteIntensity must be between 0.0 and 1.0',
      );

  /// Radial darkening toward the frame edges (0.0 = off, 1.0 = full vignette).
  final double vignetteIntensity;
}
