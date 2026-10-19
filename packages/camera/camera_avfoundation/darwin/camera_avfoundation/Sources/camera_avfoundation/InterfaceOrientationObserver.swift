// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import UIKit

extension UIDeviceOrientation {
  init(quarterTurns: Int) {
    switch (quarterTurns % 4 + 4) % 4 {
    case 1: self = .landscapeLeft
    case 2: self = .portraitUpsideDown
    case 3: self = .landscapeRight
    default: self = .portrait
    }
  }

  var quarterTurns: Int {
    switch self {
    case .landscapeLeft: 1
    case .portraitUpsideDown: 2
    case .landscapeRight: 3
    default: 0
    }
  }

  var videoOrientation: AVCaptureVideoOrientation {
    switch self {
    case .portrait: .portrait
    case .landscapeLeft: .landscapeRight
    case .landscapeRight: .landscapeLeft
    case .portraitUpsideDown: .portraitUpsideDown
    default: .portrait
    }
  }

  func relative(to frame: UIDeviceOrientation) -> UIDeviceOrientation {
    UIDeviceOrientation(quarterTurns: quarterTurns - frame.quarterTurns)
  }
}

final class InterfaceOrientationObserver {
  private var coordinator: NSObject?
  private var observation: NSKeyValueObservation?

  func start(device: AVCaptureDevice?, onChange: @escaping (UIDeviceOrientation) -> Void) {
    #if compiler(>=6.4)
      guard #available(iOS 27.0, *), let device,
        let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
        let layer = scene.keyWindow?.layer
      else { return }

      let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
      observation = coordinator.observe(
        \.videoRotationAngleForHorizonLevelPreview, options: .initial
      ) { coordinator, _ in
        let preview = coordinator.videoRotationAngleForHorizonLevelPreview
        let frame = (0..<4).map(UIDeviceOrientation.init(quarterTurns:)).first {
          let angle = coordinator.videoRotationAngleRelative(
            toDeviceOrientation: $0.videoOrientation)
          return abs((angle - preview).remainder(dividingBy: 360)) < 45
        }
        onChange(frame ?? .portrait)
      }
      self.coordinator = coordinator
    #endif
  }

  func stop() {
    observation = nil
    coordinator = nil
  }
}
