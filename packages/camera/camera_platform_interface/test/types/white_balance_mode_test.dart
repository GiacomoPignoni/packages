// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:camera_platform_interface/src/types/white_balance_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WhiteBalanceMode should contain 2 options', () {
    const List<WhiteBalanceMode> values = WhiteBalanceMode.values;

    expect(values.length, 2);
  });

  test('WhiteBalanceMode enum should have items in correct index', () {
    const List<WhiteBalanceMode> values = WhiteBalanceMode.values;

    expect(values[0], WhiteBalanceMode.auto);
    expect(values[1], WhiteBalanceMode.locked);
  });

  test('serializeWhiteBalanceMode() should serialize correctly', () {
    expect(serializeWhiteBalanceMode(WhiteBalanceMode.auto), 'auto');
    expect(serializeWhiteBalanceMode(WhiteBalanceMode.locked), 'locked');
  });

  test('deserializeWhiteBalanceMode() should deserialize correctly', () {
    expect(deserializeWhiteBalanceMode('auto'), WhiteBalanceMode.auto);
    expect(deserializeWhiteBalanceMode('locked'), WhiteBalanceMode.locked);
  });

  test('deserializeWhiteBalanceMode() should throw on invalid input', () {
    expect(() => deserializeWhiteBalanceMode('invalid'), throwsArgumentError);
  });
}
