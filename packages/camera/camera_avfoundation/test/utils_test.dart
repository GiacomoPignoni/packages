// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:camera_avfoundation/src/messages.g.dart';
import 'package:camera_avfoundation/src/utils.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Utility methods', () {
    test('Should convert CameraLensDirection values correctly', () {
      expect(
        cameraLensDirectionFromPlatform(PlatformCameraLensDirection.back),
        CameraLensDirection.back,
      );
      expect(
        cameraLensDirectionFromPlatform(PlatformCameraLensDirection.front),
        CameraLensDirection.front,
      );
      expect(
        cameraLensDirectionFromPlatform(PlatformCameraLensDirection.external),
        CameraLensDirection.external,
      );
    });

    test(
        'cameraDescriptionFromPlatform should pass through equivalentFocalLength',
        () {
      final platform = PlatformCameraDescription(
        name: 'test',
        lensDirection: PlatformCameraLensDirection.back,
        lensType: PlatformCameraLensType.wide,
        equivalentFocalLength: 26.0,
      );
      final description = cameraDescriptionFromPlatform(platform);

      expect(description.equivalentFocalLength, 26.0);
    });

    test(
        'cameraDescriptionFromPlatform should pass through null equivalentFocalLength',
        () {
      final platform = PlatformCameraDescription(
        name: 'test',
        lensDirection: PlatformCameraLensDirection.back,
        lensType: PlatformCameraLensType.wide,
      );
      final description = cameraDescriptionFromPlatform(platform);

      expect(description.equivalentFocalLength, null);
    });

    test('serializeDeviceOrientation() should serialize correctly', () {
      expect(
        serializeDeviceOrientation(DeviceOrientation.portraitUp),
        PlatformDeviceOrientation.portraitUp,
      );
      expect(
        serializeDeviceOrientation(DeviceOrientation.portraitDown),
        PlatformDeviceOrientation.portraitDown,
      );
      expect(
        serializeDeviceOrientation(DeviceOrientation.landscapeRight),
        PlatformDeviceOrientation.landscapeRight,
      );
      expect(
        serializeDeviceOrientation(DeviceOrientation.landscapeLeft),
        PlatformDeviceOrientation.landscapeLeft,
      );
    });

    test('deviceOrientationFromPlatform() should convert correctly', () {
      expect(
        deviceOrientationFromPlatform(PlatformDeviceOrientation.portraitUp),
        DeviceOrientation.portraitUp,
      );
      expect(
        deviceOrientationFromPlatform(PlatformDeviceOrientation.portraitDown),
        DeviceOrientation.portraitDown,
      );
      expect(
        deviceOrientationFromPlatform(PlatformDeviceOrientation.landscapeRight),
        DeviceOrientation.landscapeRight,
      );
      expect(
        deviceOrientationFromPlatform(PlatformDeviceOrientation.landscapeLeft),
        DeviceOrientation.landscapeLeft,
      );
    });
  });
}
