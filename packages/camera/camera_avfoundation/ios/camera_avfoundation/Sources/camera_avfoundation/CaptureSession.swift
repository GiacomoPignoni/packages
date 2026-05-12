// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation

/// A protocol which is a direct passthrough to AVCaptureSession.
/// It exists to allow replacing AVCaptureSession in tests.
protocol CaptureSession: NSObjectProtocol {
  var sessionPreset: AVCaptureSession.Preset { get set }
  var inputs: [AVCaptureInput] { get }
  var outputs: [AVCaptureOutput] { get }
  var automaticallyConfiguresApplicationAudioSession: Bool { get set }
  var isRunning: Bool { get }

  /// Whether the underlying session supports continuing to deliver camera
  /// frames while the app shares the foreground with another app on iPad
  /// (Split View / Slide Over / Stage Manager). Maps to
  /// `AVCaptureSession.isMultitaskingCameraAccessSupported` on iOS 16+ and is
  /// always `false` on earlier OS versions.
  var multitaskingCameraAccessSupported: Bool { get }

  /// Enables/disables multitasking camera access. Only meaningful when
  /// `multitaskingCameraAccessSupported` is `true`; the setter is a no-op on
  /// older OS versions. Maps to
  /// `AVCaptureSession.isMultitaskingCameraAccessEnabled` on iOS 16+.
  var multitaskingCameraAccessEnabled: Bool { get set }

  func beginConfiguration()
  func commitConfiguration()
  func startRunning()
  func stopRunning()
  func canSetSessionPreset(_ preset: AVCaptureSession.Preset) -> Bool
  func addInputWithNoConnections(_ input: CaptureInput)
  func addOutputWithNoConnections(_ output: AVCaptureOutput)
  func addConnection(_ connection: AVCaptureConnection)
  func addInput(_ input: CaptureInput)
  func addOutput(_ output: AVCaptureOutput)
  func removeInput(_ input: CaptureInput)
  func removeOutput(_ output: AVCaptureOutput)
  func canAddInput(_ input: CaptureInput) -> Bool
  func canAddOutput(_ output: AVCaptureOutput) -> Bool
  func canAddConnection(_ connection: AVCaptureConnection) -> Bool
}

extension AVCaptureSession: CaptureSession {
  var multitaskingCameraAccessSupported: Bool {
    if #available(iOS 16.0, *) {
      return isMultitaskingCameraAccessSupported
    }
    return false
  }

  var multitaskingCameraAccessEnabled: Bool {
    get {
      if #available(iOS 16.0, *) {
        return isMultitaskingCameraAccessEnabled
      }
      return false
    }
    set {
      if #available(iOS 16.0, *) {
        isMultitaskingCameraAccessEnabled = newValue
      }
    }
  }

  func addInputWithNoConnections(_ input: CaptureInput) {
    addInputWithNoConnections(input.avInput)
  }

  func addInput(_ input: CaptureInput) {
    addInput(input.avInput)
  }

  func removeInput(_ input: CaptureInput) {
    removeInput(input.avInput)
  }

  func canAddInput(_ input: CaptureInput) -> Bool {
    canAddInput(input.avInput)
  }
}
