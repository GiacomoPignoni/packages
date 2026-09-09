// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// How the overlay image is combined with the camera frame beneath it.
///
/// The modes are the separable Porter-Duff/W3C blend modes both supported
/// platforms can render identically. Each is applied per colour channel on
/// non-linear sRGB values — the same space Photoshop, Skia and CSS define
/// these modes in — and the result is then mixed back in by the overlay
/// pixel's alpha.
enum OverlayBlendMode {
  /// The overlay replaces the frame wherever it is opaque (normal alpha
  /// compositing). Fully transparent overlay pixels leave the frame untouched.
  srcOver,

  /// Multiplies the two colours. The result is always darker than either
  /// input; white leaves the frame unchanged and black forces black.
  multiply,

  /// Multiplies the inverses of the two colours. The result is always lighter
  /// than either input; black leaves the frame unchanged and white forces
  /// white.
  screen,

  /// [multiply] on dark parts of the frame and [screen] on light parts,
  /// keeping highlights and shadows while boosting contrast. The frame decides
  /// which is used — the mirror of [hardLight].
  overlay,

  /// Keeps the darker of the two colours per channel.
  darken,

  /// Keeps the lighter of the two colours per channel.
  lighten,

  /// Brightens the frame to reflect the overlay. The lighter the overlay, the
  /// stronger the effect; black leaves the frame unchanged.
  colorDodge,

  /// Darkens the frame to reflect the overlay. The darker the overlay, the
  /// stronger the effect; white leaves the frame unchanged.
  colorBurn,

  /// A softer [hardLight]: dark overlay areas darken and light areas lighten,
  /// as if a diffused spotlight were shone on the frame.
  softLight,

  /// [multiply] on dark parts of the overlay and [screen] on light parts. The
  /// overlay decides which is used — the mirror of [overlay].
  hardLight,

  /// The absolute difference of the two colours. White inverts the frame and
  /// black leaves it unchanged.
  difference,

  /// Like [difference] but with lower contrast in the midtones.
  exclusion,
}
