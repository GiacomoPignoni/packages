// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import CoreMotion
import UIKit

/// Tracks how the device is held from gravity, so it keeps working under the system rotation lock,
/// which freezes `UIDevice.orientation`.
///
/// The last orientation survives `stop()`, so after a restart only a real change is reported.
final class GravityOrientationObserver {
  private let motionManager = CMMotionManager()
  private var orientation = UIDeviceOrientation.portrait

  func start(onChange: @escaping (UIDeviceOrientation) -> Void) {
    guard motionManager.isAccelerometerAvailable, !motionManager.isAccelerometerActive else {
      return
    }
    motionManager.accelerometerUpdateInterval = 0.1
    motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
      guard let self = self, let acceleration = data?.acceleration,
        let orientation = Self.orientation(x: acceleration.x, y: acceleration.y),
        orientation != self.orientation
      else { return }
      self.orientation = orientation
      onChange(orientation)
    }
  }

  func stop() {
    motionManager.stopAccelerometerUpdates()
  }

  /// Snaps gravity in the screen plane to a quarter turn. Nil while the device lies flat or sits
  /// within 15° of a diagonal, so the orientation only flips once the device is turned past 60°.
  static func orientation(x: Double, y: Double) -> UIDeviceOrientation? {
    guard hypot(x, y) > 0.4 else { return nil }
    let degrees = atan2(x, -y) * 180 / .pi
    let quarterTurns = (degrees / 90).rounded()
    guard abs(degrees - quarterTurns * 90) <= 30 else { return nil }
    switch quarterTurns {
    case 0: return .portrait
    case 1: return .landscapeRight
    case -1: return .landscapeLeft
    default: return .portraitUpsideDown
    }
  }
}
