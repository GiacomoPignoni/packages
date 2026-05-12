// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

/// The locked white balance values of the camera, expressed as a color
/// temperature in Kelvin and a tint offset.
///
/// Used by `CameraController.setWhiteBalance` to lock the white balance.
/// Passing `null` to that method enables automatic white balance instead.
@immutable
class WhiteBalanceValues {
  /// Creates a [WhiteBalanceValues].
  ///
  /// [temperature] must be a finite Kelvin value in the inclusive range
  /// `[WhiteBalanceValues.minTemperature, WhiteBalanceValues.maxTemperature]`.
  /// [tint] must be a finite value in the inclusive range
  /// `[WhiteBalanceValues.minTint, WhiteBalanceValues.maxTint]`.
  WhiteBalanceValues({
    required this.temperature,
    required this.tint,
  }) {
    if (temperature.isNaN ||
        temperature.isInfinite ||
        temperature < minTemperature ||
        temperature > maxTemperature) {
      throw ArgumentError.value(
        temperature,
        'temperature',
        'temperature must be a finite value between $minTemperature and $maxTemperature inclusive',
      );
    }
    if (tint.isNaN || tint.isInfinite || tint < minTint || tint > maxTint) {
      throw ArgumentError.value(
        tint,
        'tint',
        'tint must be a finite value between $minTint and $maxTint inclusive',
      );
    }
  }

  /// The minimum color temperature in Kelvin that can be set for a camera.
  static const double minTemperature = 1800;
  /// The maximum color temperature in Kelvin that can be set for a camera.
  static const double maxTemperature = 9800;

  /// The minimum tint offset that can be set for a camera.
  static const double minTint = -50;
  /// The maximum tint offset that can be set for a camera.
  static const double maxTint = 50;

  /// The color temperature in Kelvin.
  final double temperature;

  /// The tint offset, where `0` is neutral.
  final double tint;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WhiteBalanceValues &&
          other.temperature == temperature &&
          other.tint == tint;

  @override
  int get hashCode => Object.hash(temperature, tint);

  @override
  String toString() => 'WhiteBalanceValues(temperature: $temperature, '
      'tint: $tint)';
}
