// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';

import '../camera.dart';

/// A widget showing a live camera preview.
class CameraPreview extends StatelessWidget {
  /// Creates a preview widget for the given camera controller.
  const CameraPreview(this.controller, {super.key, this.child});

  /// The controller for the camera that the preview is shown for.
  final CameraController controller;

  /// A widget to overlay on top of the camera preview
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    // Rebuilt on every change, not only on a new size: a lens switch keeps the controller
    // initialized but moves it to a new camera, whose texture only `buildPreview` knows.
    return ValueListenableBuilder<CameraValue>(
      valueListenable: controller,
      builder: (BuildContext context, CameraValue value, Widget? child) {
        if (!value.isInitialized) {
          return Container();
        }

        // Pinned to portrait on every platform: the camera image turns inside the box with
        // the device, and the device orientation reaches the captured file instead.
        return AspectRatio(
          aspectRatio: 1 / value.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[controller.buildPreview(), child ?? Container()],
          ),
        );
      },
      child: child,
    );
  }
}
