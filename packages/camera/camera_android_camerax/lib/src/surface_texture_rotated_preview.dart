// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import 'rotated_preview_utils.dart';

/// Widget that rotates the camera preview to be upright according to the
/// current user interface orientation.
///
/// Sensor orientation and front-camera mirroring are not this widget's
/// business. Every frame reaches Flutter through the shader pipeline, which
/// samples the camera texture through the transform CameraX composes in
/// `SurfaceOutput.updateTransformMatrix`; because
/// `AndroidCameraCameraX._pinnedTargetRotation` asks for the display's natural
/// orientation, that transform carries the whole sensor rotation and, for a
/// front-facing preview, the mirroring as well. What arrives is therefore
/// already upright in the display's natural orientation and already a selfie
/// view where it should be.
///
/// The one thing the render path cannot know is how far the display has been
/// turned, which is what is left here. The UI is pinned, so the rotation read
/// when the camera is created holds for as long as it is open.
@internal
final class SurfaceTextureRotatedPreview extends StatelessWidget {
  /// Creates [SurfaceTextureRotatedPreview] that will rotate camera preview
  /// according to the rotation of the Android default display.
  const SurfaceTextureRotatedPreview(
    this.initialDefaultDisplayRotation, {
    required this.child,
    super.key,
  });

  /// The rotation of the Android default display when the camera is created
  /// in terms of a Surface rotation constant.
  final int initialDefaultDisplayRotation;

  /// The camera preview [Widget] to rotate.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RotatedBox(
      quarterTurns: getQuarterTurnsFromSurfaceRotationConstant(initialDefaultDisplayRotation),
      child: child,
    );
  }
}
