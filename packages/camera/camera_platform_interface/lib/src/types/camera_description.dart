// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

/// The direction the camera is facing.
enum CameraLensDirection {
  /// Front facing camera (a user looking at the screen is seen by the camera).
  front,

  /// Back facing camera (a user looking at the screen is not seen by the camera).
  back,

  /// External camera which may not be mounted to the device.
  external,
}

/// Represents various built-in camera lens types available on a device.
///
/// Each lens type offers different focal lengths and capabilities for capturing images.
enum CameraLensType {
  /// A built-in wide-angle camera device type.
  wide,

  /// A built-in camera device type with a longer focal length than a wide-angle camera.
  telephoto,

  /// A built-in camera device type with a shorter focal length than a wide-angle camera.
  ultraWide,

  /// Unknown camera device type.
  unknown,
}

/// One of the lenses a camera switches between as it is zoomed.
///
/// A phone that reaches three rear lenses through a single camera — Android
/// calls that camera a logical multi-camera, AVFoundation calls it a virtual
/// device — does not offer those lenses as cameras of their own: the only way
/// to reach one is to zoom the camera to the ratio where the device switches
/// to it. This describes one such lens, so an app can offer them as the 0.5x,
/// 1x and 3x its user expects.
@immutable
class ConstituentLens {
  /// Creates a description of a lens reached at [zoomRatio].
  const ConstituentLens({required this.zoomRatio, this.equivalentFocalLength});

  /// The zoom ratio, relative to the camera's own lens, at which this lens is
  /// used.
  ///
  /// 1.0 is the camera's own lens, a ratio below 1 a wider one, above 1 a
  /// longer one. Pass it to `CameraController.setZoomLevel` to select this
  /// lens on a camera that is already open. Devices switch at or near this
  /// ratio rather than exactly on it, so a caller wanting to be sure of the
  /// longer lens should ask for slightly more than it says.
  final double zoomRatio;

  /// The approximate 35mm-equivalent focal length of this lens, in
  /// millimetres, or null where the device does not report enough to compute
  /// one.
  final double? equivalentFocalLength;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConstituentLens &&
          runtimeType == other.runtimeType &&
          zoomRatio == other.zoomRatio &&
          equivalentFocalLength == other.equivalentFocalLength;

  @override
  int get hashCode => Object.hash(zoomRatio, equivalentFocalLength);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'ConstituentLens')}($zoomRatio, $equivalentFocalLength)';
}

/// Properties of a camera device.
@immutable
class CameraDescription {
  /// Creates a new camera description with the given properties.
  const CameraDescription({
    required this.name,
    required this.lensDirection,
    required this.sensorOrientation,
    this.lensType = CameraLensType.unknown,
    this.equivalentFocalLength,
    this.constituentLenses = const <ConstituentLens>[],
  });

  /// The name of the camera device.
  final String name;

  /// The direction the camera is facing.
  final CameraLensDirection lensDirection;

  /// Clockwise angle through which the output image needs to be rotated to be upright on the device screen in its native orientation.
  ///
  /// **Range of valid values:**
  /// 0, 90, 180, 270
  ///
  /// On Android, also defines the direction of rolling shutter readout, which
  /// is from top to bottom in the sensor's coordinate system.
  final int sensorOrientation;

  /// The type of lens the camera has.
  final CameraLensType lensType;

  /// The approximate 35mm-equivalent focal length of the lens, in millimetres.
  ///
  /// Derived from the lens's current active-format diagonal field of view, so
  /// the value reflects a snapshot of the device at discovery time and may
  /// differ between formats of the same physical lens. For that reason it is
  /// **excluded from `==` and `hashCode`** — two descriptions of the same
  /// camera at different active formats still compare equal.
  ///
  /// Available on iOS (AVFoundation) and Android (CameraX); `null` where the
  /// platform does not report enough about the lens to derive one.
  final double? equivalentFocalLength;

  /// The lenses this camera switches between as it is zoomed, shortest first.
  ///
  /// Empty for a camera that is a single lens, which is every camera on a
  /// device that publishes each of its lenses separately. A camera that stands
  /// for several — Android's logical multi-camera, AVFoundation's virtual
  /// device — lists them here, because a lens the device keeps behind such a
  /// camera cannot be opened on its own.
  ///
  /// A platform may still describe such a lens as a camera of its own in
  /// `availableCameras`, one that opens this camera and zooms it; Android
  /// does. This is what those are built from, and it says which lens each of
  /// them stands for.
  ///
  /// Like [equivalentFocalLength], excluded from `==` and `hashCode`: it
  /// describes the same camera in more detail rather than identifying a
  /// different one.
  final List<ConstituentLens> constituentLenses;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraDescription &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          lensDirection == other.lensDirection &&
          lensType == other.lensType;

  @override
  int get hashCode => Object.hash(name, lensDirection, lensType);

  @override
  String toString() {
    return '${objectRuntimeType(this, 'CameraDescription')}('
        '$name, $lensDirection, $sensorOrientation, $lensType, $equivalentFocalLength, '
        '$constituentLenses)';
  }
}
