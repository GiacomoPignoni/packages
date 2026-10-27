// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeController extends ValueNotifier<CameraValue> implements CameraController {
  FakeController() : super(const CameraValue.uninitialized(fakeDescription));

  static const CameraDescription fakeDescription = CameraDescription(
    name: '',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 0,
    lensType: CameraLensType.ultraWide,
  );

  @override
  Future<void> dispose() async {
    super.dispose();
  }

  @override
  Widget buildPreview() {
    return Texture(textureId: cameraId);
  }

  @override
  int cameraId = CameraController.kUninitializedCameraId;

  @override
  void debugCheckIsDisposed() {}

  @override
  bool get enableAudio => false;

  @override
  Future<double> getExposureOffsetStepSize() async => 1.0;

  @override
  Future<double> getMaxExposureOffset() async => 1.0;

  @override
  Future<double> getMaxZoomLevel() async => 1.0;

  @override
  Future<double> getMinExposureOffset() async => 1.0;

  @override
  Future<double> getMinZoomLevel() async => 1.0;

  @override
  ImageFormatGroup? get imageFormatGroup => null;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> lockCaptureOrientation([DeviceOrientation? orientation]) async {}

  @override
  Future<void> pauseVideoRecording() async {}

  @override
  Future<void> prepareForVideoRecording() async {}

  @override
  ResolutionPreset get resolutionPreset => ResolutionPreset.low;

  @override
  MediaSettings get mediaSettings => const MediaSettings(
    resolutionPreset: ResolutionPreset.low,
    fps: 15,
    videoBitrate: 200000,
    audioBitrate: 32000,
    enableAudio: true,
  );

  @override
  Future<void> resumeVideoRecording() async {}

  @override
  Future<void> setExposureMode(ExposureMode mode) async {}

  @override
  Future<double> setExposureOffset(double offset) async => offset;

  @override
  Future<void> setExposurePoint(Offset? point) async {}

  @override
  Future<void> setFlashMode(FlashMode mode) async {}

  @override
  Future<Iterable<FlashMode>> getSupportedFlashModes() async => const [];

  @override
  Future<void> setFocusMode(FocusMode mode) async {}

  @override
  Future<void> setFocusPoint(Offset? point) async {}

  @override
  Future<void> setWhiteBalance(WhiteBalanceValues? values) async {}

  @override
  Future<bool> supportsWhiteBalance() async => false;

  @override
  Stream<({double temperature, double tint})> get autoWhiteBalanceValues =>
      const Stream<({double temperature, double tint})>.empty();

  @override
  Future<void> setZoomLevel(double zoom) async {}

  @override
  Future<void> startImageStream(onLatestImageAvailable onAvailable) async {}

  @override
  Future<void> startVideoRecording({
    onLatestImageAvailable? onAvailable,
    bool enablePersistentRecording = true,
  }) async {}

  @override
  Future<void> stopImageStream() async {}

  @override
  Future<XFile> stopVideoRecording() async => XFile('');

  @override
  Future<XFile> takePicture() async => XFile('');

  @override
  Future<(XFile, XFile)> takePictureWithOriginal() async => (XFile(''), XFile(''));

  @override
  Future<void> unlockCaptureOrientation() async {}

  @override
  Future<void> pausePreview() async {}

  @override
  Future<void> resumePreview() async {}

  @override
  Future<void> setDescription(CameraDescription description) async {}

  @override
  CameraDescription get description => value.description;

  @override
  Future<void> setVideoStabilizationMode(
    VideoStabilizationMode mode, {
    bool allowFallback = true,
  }) async {}

  @override
  Future<Iterable<VideoStabilizationMode>> getSupportedVideoStabilizationModes() async =>
      <VideoStabilizationMode>[];

  @override
  Future<void> setJpegImageQuality(int quality) async {}

  @override
  bool supportsImageStreaming() => true;

  @override
  Future<void> setEffectsValues(EffectsValues values) async {}

  @override
  Future<void> setAspectRatio(double? aspectRatio) async {}

  @override
  Future<void> setCaptureScale(double scale) async {}

  @override
  Future<void> setCaptureCornerRadius(double radius) async {}

  @override
  Future<void> setPreviewEffectsEnabled(bool enabled) async {}

  @override
  Future<void> setMirrorFrontCamera(bool mirror) async {}
}

void main() {
  testWidgets('the preview stays portrait however the device is held', (WidgetTester tester) async {
    final controller = FakeController();
    addTearDown(controller.dispose);
    controller.value = controller.value.copyWith(
      isInitialized: true,
      isRecordingVideo: true,
      deviceOrientation: DeviceOrientation.landscapeLeft,
      recordingOrientation: const Optional<DeviceOrientation>.fromNullable(
        DeviceOrientation.landscapeRight,
      ),
      previewSize: const Size(640, 480),
    );

    await tester.pumpWidget(
      Directionality(textDirection: TextDirection.ltr, child: CameraPreview(controller)),
    );

    expect(find.byType(RotatedBox), findsNothing);
    expect(tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio, 480 / 640);
    expect(find.byType(Texture), findsOneWidget);
  });

  testWidgets('the preview follows the controller to a new camera of the same size', (
    WidgetTester tester,
  ) async {
    final controller = FakeController();
    addTearDown(controller.dispose);
    controller.value = controller.value.copyWith(
      isInitialized: true,
      previewSize: const Size(640, 480),
    );

    await tester.pumpWidget(
      Directionality(textDirection: TextDirection.ltr, child: CameraPreview(controller)),
    );

    controller.cameraId = 7;
    controller.value = controller.value.copyWith(previewSize: const Size(640, 480));
    await tester.pump();

    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 7);
  });
}
