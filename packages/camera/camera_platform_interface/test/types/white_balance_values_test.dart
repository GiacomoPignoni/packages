// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WhiteBalanceValues', () {
    test('accepts values inside the supported ranges', () {
      final values = WhiteBalanceValues(temperature: 5500, tint: 25);
      expect(values.temperature, 5500);
      expect(values.tint, 25);
    });

    test('rejects temperatures outside range', () {
      expect(
        () => WhiteBalanceValues(temperature: WhiteBalanceValues.minTemperature - 1, tint: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => WhiteBalanceValues(temperature: WhiteBalanceValues.maxTemperature + 1, tint: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects non-finite temperatures', () {
      expect(
        () => WhiteBalanceValues(temperature: double.nan, tint: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => WhiteBalanceValues(temperature: double.infinity, tint: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects tints outside range', () {
      expect(
        () => WhiteBalanceValues(temperature: 5500, tint: WhiteBalanceValues.minTint - 1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => WhiteBalanceValues(temperature: 5500, tint: WhiteBalanceValues.maxTint + 1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects non-finite tints', () {
      expect(
        () => WhiteBalanceValues(temperature: 5500, tint: double.nan),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('equality is based on temperature and tint', () {
      expect(
        WhiteBalanceValues(temperature: 5500, tint: 25),
        equals(WhiteBalanceValues(temperature: 5500, tint: 25)),
      );
      expect(
        WhiteBalanceValues(temperature: 5500, tint: 25),
        isNot(equals(WhiteBalanceValues(temperature: 5500, tint: 30))),
      );
    });

    test('toString contains both fields', () {
      final text = WhiteBalanceValues(temperature: 5500, tint: 25).toString();
      expect(text, contains('5500'));
      expect(text, contains('25'));
    });
  });
}
