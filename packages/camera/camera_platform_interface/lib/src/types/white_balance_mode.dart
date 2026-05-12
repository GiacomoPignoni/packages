// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The possible white balance modes that can be set for a camera.
enum WhiteBalanceMode {
  /// Automatically determine white balance.
  auto,

  /// Lock the white balance to a specific value.
  locked,
}

/// Returns the white balance mode as a String.
String serializeWhiteBalanceMode(WhiteBalanceMode whiteBalanceMode) {
  switch (whiteBalanceMode) {
    case WhiteBalanceMode.locked:
      return 'locked';
    case WhiteBalanceMode.auto:
      return 'auto';
  }
}

/// Returns the white balance mode for a given String.
WhiteBalanceMode deserializeWhiteBalanceMode(String str) {
  switch (str) {
    case 'locked':
      return WhiteBalanceMode.locked;
    case 'auto':
      return WhiteBalanceMode.auto;
    default:
      throw ArgumentError('"$str" is not a valid WhiteBalanceMode value');
  }
}
