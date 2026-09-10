// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CameraLensDirection tests', () {
    test('CameraLensDirection should contain 3 options', () {
      const List<CameraLensDirection> values = CameraLensDirection.values;

      expect(values.length, 3);
    });

    test('CameraLensDirection enum should have items in correct index', () {
      const List<CameraLensDirection> values = CameraLensDirection.values;

      expect(values[0], CameraLensDirection.front);
      expect(values[1], CameraLensDirection.back);
      expect(values[2], CameraLensDirection.external);
    });
  });

  group('CameraDescription tests', () {
    test('Constructor should initialize all properties', () {
      const description = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
        lensType: CameraLensType.ultraWide,
        equivalentFocalLength: 26.0,
      );

      expect(description.name, 'Test');
      expect(description.lensDirection, CameraLensDirection.front);
      expect(description.sensorOrientation, 90);
      expect(description.lensType, CameraLensType.ultraWide);
      expect(description.equivalentFocalLength, 26.0);
    });

    test('Constructor should default equivalentFocalLength to null', () {
      const description = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
      );

      expect(description.equivalentFocalLength, null);
    });

    test('equals should return true if objects are the same', () {
      const firstDescription = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
        lensType: CameraLensType.ultraWide,
        equivalentFocalLength: 26.0,
      );
      const secondDescription = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
        lensType: CameraLensType.ultraWide,
        equivalentFocalLength: 26.0,
      );

      expect(firstDescription == secondDescription, true);
    });

    test('equals should return true even when equivalentFocalLength differs '
        '(field is intentionally excluded from equality)', () {
      const firstDescription = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
        lensType: CameraLensType.ultraWide,
        equivalentFocalLength: 26.0,
      );
      const secondDescription = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
        lensType: CameraLensType.ultraWide,
        equivalentFocalLength: 52.0,
      );

      expect(firstDescription == secondDescription, true);
      expect(firstDescription.hashCode, secondDescription.hashCode);
    });

    test('equals should return false if name is different', () {
      const firstDescription = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
        lensType: CameraLensType.ultraWide,
      );
      const secondDescription = CameraDescription(
        name: 'Testing',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
        lensType: CameraLensType.ultraWide,
      );

      expect(firstDescription == secondDescription, false);
    });

    test('equals should return false if lens direction is different', () {
      const firstDescription = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
        lensType: CameraLensType.ultraWide,
      );
      const secondDescription = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
        lensType: CameraLensType.ultraWide,
      );

      expect(firstDescription == secondDescription, false);
    });

    test('equals should return true if sensor orientation is different', () {
      const firstDescription = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 0,
        lensType: CameraLensType.ultraWide,
      );
      const secondDescription = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
        lensType: CameraLensType.ultraWide,
      );

      expect(firstDescription == secondDescription, true);
    });

    test('hashCode should match hashCode of all equality-tested properties', () {
      const description = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 0,
        lensType: CameraLensType.ultraWide,
        equivalentFocalLength: 26.0,
      );
      final int expectedHashCode = Object.hash(
        description.name,
        description.lensDirection,
        description.lensType,
      );

      expect(description.hashCode, expectedHashCode);
    });

    test('toString should return correct string representation', () {
      const description = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
        lensType: CameraLensType.ultraWide,
        equivalentFocalLength: 26.0,
      );

      expect(
        description.toString(),
        'CameraDescription(Test, CameraLensDirection.front, 90, CameraLensType.ultraWide, 26.0, [])',
      );
    });

    test('constituent lenses default to none and stay out of equality', () {
      // A camera that lists the lenses it switches between is the same camera as one described
      // without them: the lenses say more about it, they do not make it a different device.
      const description = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      );
      const withLenses = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
        constituentLenses: <ConstituentLens>[
          ConstituentLens(zoomRatio: 0.59, equivalentFocalLength: 13.5),
          ConstituentLens(zoomRatio: 2.9, equivalentFocalLength: 66.4),
        ],
      );

      expect(description.constituentLenses, isEmpty);
      expect(withLenses, description);
      expect(withLenses.hashCode, description.hashCode);
      expect(withLenses.constituentLenses.first.zoomRatio, 0.59);
    });

    test('ConstituentLens equality is by ratio and focal length', () {
      const lens = ConstituentLens(zoomRatio: 2.9, equivalentFocalLength: 66.4);

      expect(lens, const ConstituentLens(zoomRatio: 2.9, equivalentFocalLength: 66.4));
      expect(
        lens.hashCode,
        const ConstituentLens(zoomRatio: 2.9, equivalentFocalLength: 66.4).hashCode,
      );
      expect(lens, isNot(const ConstituentLens(zoomRatio: 3.0, equivalentFocalLength: 66.4)));
      expect(lens.toString(), 'ConstituentLens(2.9, 66.4)');
      expect(const ConstituentLens(zoomRatio: 1.0).equivalentFocalLength, isNull);
    });

    test('toString should show null when equivalentFocalLength is not set', () {
      const description = CameraDescription(
        name: 'Test',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 90,
      );

      expect(
        description.toString(),
        'CameraDescription(Test, CameraLensDirection.front, 90, CameraLensType.unknown, null, [])',
      );
    });
  });
}
