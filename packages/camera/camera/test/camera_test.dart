// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

List<CameraDescription> get mockAvailableCameras => <CameraDescription>[
  const CameraDescription(
    name: 'camBack',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
  ),
  const CameraDescription(
    name: 'camFront',
    lensDirection: CameraLensDirection.front,
    sensorOrientation: 180,
  ),
];

int get mockInitializeCamera => 13;

CameraInitializedEvent get mockOnCameraInitializedEvent =>
    const CameraInitializedEvent(13, 75, 75, ExposureMode.auto, true, FocusMode.auto, true);

/// Emitted by `onCameraResolutionChanged` while non-null, to stand in for a
/// host that reports the preview surface's own size during `initializeCamera`.
CameraResolutionChangedEvent? mockOnCameraResolutionChangedEvent;

DeviceOrientationChangedEvent get mockOnDeviceOrientationChangedEvent =>
    const DeviceOrientationChangedEvent(DeviceOrientation.portraitUp);

CameraClosingEvent get mockOnCameraClosingEvent => const CameraClosingEvent(13);

CameraErrorEvent get mockOnCameraErrorEvent => const CameraErrorEvent(13, 'closing');

XFile mockTakePicture = XFile('foo/bar.png');

(XFile, XFile) mockTakePictureWithOriginal = (
  XFile('foo/bar_original.png'),
  XFile('foo/bar_processed.png'),
);

XFile mockVideoRecordingXFile = XFile('foo/bar.mpeg');

bool mockPlatformException = false;

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  group('camera', () {
    test('debugCheckIsDisposed should not throw assertion error when disposed', () {
      const description = MockCameraDescription();
      final controller = CameraController(description, ResolutionPreset.low);

      controller.dispose();

      expect(controller.debugCheckIsDisposed, returnsNormally);
    });

    test('debugCheckIsDisposed should throw assertion error when not disposed', () {
      const description = MockCameraDescription();
      final controller = CameraController(description, ResolutionPreset.low);

      expect(() => controller.debugCheckIsDisposed(), throwsAssertionError);
    });

    test('availableCameras() has camera', () async {
      CameraPlatform.instance = MockCameraPlatform();

      final List<CameraDescription> camList = await availableCameras();

      expect(camList, equals(mockAvailableCameras));
    });
  });

  group('$CameraController', () {
    setUpAll(() {
      CameraPlatform.instance = MockCameraPlatform();
    });

    test('Can be initialized', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      expect(cameraController.value.aspectRatio, 1);
      expect(cameraController.value.previewSize, const Size(75, 75));
      expect(cameraController.value.isInitialized, isTrue);
    });

    test('keeps a preview size the platform reported while initializing', () async {
      // The host reports the size of the surface it actually draws into, which
      // accounts for any crop it applies; `CameraInitializedEvent` carries the
      // camera's uncropped output. Finishing initialization must not fall back
      // to the latter, or the preview is laid out to a shape the texture does
      // not have — the symptom being a stretched preview after a lens switch,
      // until something unrelated made the host report its size again.
      mockOnCameraResolutionChangedEvent = const CameraResolutionChangedEvent(13, 60, 80);
      addTearDown(() => mockOnCameraResolutionChangedEvent = null);

      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      expect(cameraController.value.previewSize, const Size(60, 80));
    });

    test('can be initialized with media settings', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.low,
        fps: 15,
        videoBitrate: 200000,
        audioBitrate: 32000,
        enableAudio: false,
      );
      await cameraController.initialize();

      expect(cameraController.value.aspectRatio, 1);
      expect(cameraController.value.previewSize, const Size(75, 75));
      expect(cameraController.value.isInitialized, isTrue);
      expect(cameraController.resolutionPreset, ResolutionPreset.low);
      expect(cameraController.enableAudio, false);
      expect(cameraController.mediaSettings.fps, 15);
      expect(cameraController.mediaSettings.videoBitrate, 200000);
      expect(cameraController.mediaSettings.audioBitrate, 32000);
    });

    test('default constructor initializes media settings', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      expect(cameraController.resolutionPreset, ResolutionPreset.max);
      expect(cameraController.enableAudio, true);
      expect(cameraController.mediaSettings.fps, isNull);
      expect(cameraController.mediaSettings.videoBitrate, isNull);
      expect(cameraController.mediaSettings.audioBitrate, isNull);
    });

    test('can be disposed', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      expect(cameraController.value.aspectRatio, 1);
      expect(cameraController.value.previewSize, const Size(75, 75));
      expect(cameraController.value.isInitialized, isTrue);

      await cameraController.dispose();

      verify(CameraPlatform.instance.dispose(13)).called(1);
    });

    test('initialize() throws CameraException when disposed', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      expect(cameraController.value.aspectRatio, 1);
      expect(cameraController.value.previewSize, const Size(75, 75));
      expect(cameraController.value.isInitialized, isTrue);

      await cameraController.dispose();

      verify(CameraPlatform.instance.dispose(13)).called(1);

      expect(
        cameraController.initialize,
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'Error description',
            'initialize was called on a disposed CameraController',
          ),
        ),
      );
    });

    test('initialize() throws $CameraException on $PlatformException ', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      mockPlatformException = true;

      expect(
        cameraController.initialize,
        throwsA(
          isA<CameraException>().having((CameraException error) => error.description, 'foo', 'bar'),
        ),
      );
      mockPlatformException = false;
    });

    test('initialize() sets imageFormat', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await cameraController.initialize();
      verify(
        CameraPlatform.instance.initializeCamera(13, imageFormatGroup: ImageFormatGroup.yuv420),
      ).called(1);
    });

    test('initialize() applies the aspect ratio before frames start flowing', () async {
      // The ratio lives on the controller, not in `MediaSettings`, so a camera
      // rebuilt by `setDescription` starts uncropped unless it is applied
      // before `initializeCamera`. Applying it after means the host builds the
      // preview twice and the frames in between arrive at the wrong shape.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      await cameraController.setAspectRatio(1.0);

      // A `setDescription` rebuilds the camera; the ratio has to survive it.
      clearInteractions(CameraPlatform.instance);
      await cameraController.setDescription(
        const CameraDescription(
          name: 'cam2',
          lensDirection: CameraLensDirection.front,
          sensorOrientation: 90,
        ),
      );

      verifyInOrder(<Object?>[
        CameraPlatform.instance.setAspectRatio(13, 1.0),
        CameraPlatform.instance.initializeCamera(13),
      ]);
      // The mock is shared and only built in `setUpAll`, so the `dispose` this
      // `setDescription` recorded would otherwise surface in the next test.
      clearInteractions(CameraPlatform.instance);
    });

    test('a constructed aspect ratio reaches createCamera, so nothing re-binds', () async {
      // A controller replaced to change the resolution preset carries none of
      // the old one's state, so there is no `setAspectRatio` to hoist ahead of
      // `initializeCamera` — the ratio has to travel with the camera settings
      // or the first frames arrive at the camera's own shape.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const description = CameraDescription(
        name: 'cam',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      );
      final cameraController = CameraController(
        description,
        ResolutionPreset.veryHigh,
        aspectRatio: 1.0,
      );

      expect(cameraController.mediaSettings.aspectRatio, 1.0);

      // Verified through the mock's own signatures, whose parameters are
      // nullable so `any` and `captureAny` type-check against them.
      final mockPlatform = CameraPlatform.instance as MockCameraPlatform;
      clearInteractions(mockPlatform);
      await cameraController.initialize();

      final settings =
          verify(mockPlatform.createCameraWithSettings(any, captureAny)).captured.single
              as MediaSettings;
      expect(settings.aspectRatio, 1.0);
      // Already in place before the camera was built, so re-applying it would
      // only cost a second bind.
      verifyNever(mockPlatform.setAspectRatio(any, any));
      clearInteractions(mockPlatform);
    });

    test('setDescription waits for initialize before calling dispose', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
        imageFormatGroup: ImageFormatGroup.bgra8888,
      );

      final initializeCompleter = Completer<void>();
      when(
        CameraPlatform.instance.initializeCamera(
          mockInitializeCamera,
          imageFormatGroup: ImageFormatGroup.bgra8888,
        ),
      ).thenAnswer((_) => initializeCompleter.future);

      unawaited(cameraController.initialize());

      final Future<void> setDescriptionFuture = cameraController.setDescription(
        const CameraDescription(
          name: 'cam2',
          lensDirection: CameraLensDirection.front,
          sensorOrientation: 90,
        ),
      );
      verifyNever(CameraPlatform.instance.dispose(mockInitializeCamera));

      initializeCompleter.complete();

      await setDescriptionFuture;
      verify(CameraPlatform.instance.dispose(mockInitializeCamera));
    });

    test('prepareForVideoRecording() calls $CameraPlatform ', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      await cameraController.prepareForVideoRecording();

      verify(CameraPlatform.instance.prepareForVideoRecording()).called(1);
    });

    test('takePicture() throws $CameraException when uninitialized ', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      expect(
        cameraController.takePicture(),
        throwsA(
          isA<CameraException>()
              .having(
                (CameraException error) => error.code,
                'code',
                'Uninitialized CameraController',
              )
              .having(
                (CameraException error) => error.description,
                'description',
                'takePicture() was called on an uninitialized CameraController.',
              ),
        ),
      );
    });

    test('takePicture() throws $CameraException when takePicture is true', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      cameraController.value = cameraController.value.copyWith(isTakingPicture: true);
      expect(
        cameraController.takePicture(),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'Previous capture has not returned yet.',
            'takePicture was called before the previous capture returned.',
          ),
        ),
      );
    });

    test('takePicture() returns $XFile', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      final XFile xFile = await cameraController.takePicture();

      expect(xFile.path, mockTakePicture.path);
    });

    test('takePicture() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      mockPlatformException = true;
      expect(
        cameraController.takePicture(),
        throwsA(
          isA<CameraException>().having((CameraException error) => error.description, 'foo', 'bar'),
        ),
      );
      mockPlatformException = false;
    });

    test('takePictureWithOriginal() throws $CameraException when uninitialized', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      expect(
        cameraController.takePictureWithOriginal(),
        throwsA(
          isA<CameraException>()
              .having(
                (CameraException error) => error.code,
                'code',
                'Uninitialized CameraController',
              )
              .having(
                (CameraException error) => error.description,
                'description',
                'takePictureWithOriginal() was called on an uninitialized CameraController.',
              ),
        ),
      );
    });

    test(
      'takePictureWithOriginal() throws $CameraException when isTakingPicture is true',
      () async {
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        cameraController.value = cameraController.value.copyWith(isTakingPicture: true);
        expect(
          cameraController.takePictureWithOriginal(),
          throwsA(
            isA<CameraException>().having(
              (CameraException error) => error.description,
              'Previous capture has not returned yet.',
              'takePictureWithOriginal was called before the previous capture returned.',
            ),
          ),
        );
      },
    );

    test('takePictureWithOriginal() returns (original, processed) record', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      final (XFile original, XFile processed) = await cameraController.takePictureWithOriginal();

      expect(original.path, mockTakePictureWithOriginal.$1.path);
      expect(processed.path, mockTakePictureWithOriginal.$2.path);
      expect(cameraController.value.isTakingPicture, isFalse);
    });

    test('takePictureWithOriginal() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      mockPlatformException = true;
      await expectLater(
        cameraController.takePictureWithOriginal(),
        throwsA(
          isA<CameraException>().having((CameraException error) => error.description, 'foo', 'bar'),
        ),
      );
      expect(cameraController.value.isTakingPicture, isFalse);
      mockPlatformException = false;
    });

    test('startVideoRecording() throws $CameraException when uninitialized', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      expect(
        cameraController.startVideoRecording(),
        throwsA(
          isA<CameraException>()
              .having(
                (CameraException error) => error.code,
                'code',
                'Uninitialized CameraController',
              )
              .having(
                (CameraException error) => error.description,
                'description',
                'startVideoRecording() was called on an uninitialized CameraController.',
              ),
        ),
      );
    });
    test('startVideoRecording() throws $CameraException when recording videos', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();

      cameraController.value = cameraController.value.copyWith(isRecordingVideo: true);

      expect(
        cameraController.startVideoRecording(),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'A video recording is already started.',
            'startVideoRecording was called when a recording is already started.',
          ),
        ),
      );
    });

    test('getMaxZoomLevel() throws $CameraException when uninitialized', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      expect(
        cameraController.getMaxZoomLevel,
        throwsA(
          isA<CameraException>()
              .having(
                (CameraException error) => error.code,
                'code',
                'Uninitialized CameraController',
              )
              .having(
                (CameraException error) => error.description,
                'description',
                'getMaxZoomLevel() was called on an uninitialized CameraController.',
              ),
        ),
      );
    });

    test('getMaxZoomLevel() throws $CameraException when disposed', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      await cameraController.dispose();

      expect(
        cameraController.getMaxZoomLevel,
        throwsA(
          isA<CameraException>()
              .having((CameraException error) => error.code, 'code', 'Disposed CameraController')
              .having(
                (CameraException error) => error.description,
                'description',
                'getMaxZoomLevel() was called on a disposed CameraController.',
              ),
        ),
      );
    });

    test('getMaxZoomLevel() throws $CameraException when a platform exception occured.', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      when(
        CameraPlatform.instance.getMaxZoomLevel(mockInitializeCamera),
      ).thenThrow(CameraException('TEST_ERROR', 'This is a test error messge'));

      expect(
        cameraController.getMaxZoomLevel,
        throwsA(
          isA<CameraException>()
              .having((CameraException error) => error.code, 'code', 'TEST_ERROR')
              .having(
                (CameraException error) => error.description,
                'description',
                'This is a test error messge',
              ),
        ),
      );
    });

    test('getMaxZoomLevel() returns max zoom level.', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      when(
        CameraPlatform.instance.getMaxZoomLevel(mockInitializeCamera),
      ).thenAnswer((_) => Future<double>.value(42.0));

      final double maxZoomLevel = await cameraController.getMaxZoomLevel();
      expect(maxZoomLevel, 42.0);
    });

    test('getMinZoomLevel() throws $CameraException when uninitialized', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      expect(
        cameraController.getMinZoomLevel,
        throwsA(
          isA<CameraException>()
              .having(
                (CameraException error) => error.code,
                'code',
                'Uninitialized CameraController',
              )
              .having(
                (CameraException error) => error.description,
                'description',
                'getMinZoomLevel() was called on an uninitialized CameraController.',
              ),
        ),
      );
    });

    test('getMinZoomLevel() throws $CameraException when disposed', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      await cameraController.dispose();

      expect(
        cameraController.getMinZoomLevel,
        throwsA(
          isA<CameraException>()
              .having((CameraException error) => error.code, 'code', 'Disposed CameraController')
              .having(
                (CameraException error) => error.description,
                'description',
                'getMinZoomLevel() was called on a disposed CameraController.',
              ),
        ),
      );
    });

    test('getMinZoomLevel() throws $CameraException when a platform exception occured.', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      when(
        CameraPlatform.instance.getMinZoomLevel(mockInitializeCamera),
      ).thenThrow(CameraException('TEST_ERROR', 'This is a test error messge'));

      expect(
        cameraController.getMinZoomLevel,
        throwsA(
          isA<CameraException>()
              .having((CameraException error) => error.code, 'code', 'TEST_ERROR')
              .having(
                (CameraException error) => error.description,
                'description',
                'This is a test error messge',
              ),
        ),
      );
    });

    test('getMinZoomLevel() returns max zoom level.', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      when(
        CameraPlatform.instance.getMinZoomLevel(mockInitializeCamera),
      ).thenAnswer((_) => Future<double>.value(42.0));

      final double maxZoomLevel = await cameraController.getMinZoomLevel();
      expect(maxZoomLevel, 42.0);
    });

    test('setZoomLevel() throws $CameraException when uninitialized', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      expect(
        () => cameraController.setZoomLevel(42.0),
        throwsA(
          isA<CameraException>()
              .having(
                (CameraException error) => error.code,
                'code',
                'Uninitialized CameraController',
              )
              .having(
                (CameraException error) => error.description,
                'description',
                'setZoomLevel() was called on an uninitialized CameraController.',
              ),
        ),
      );
    });

    test('setZoomLevel() throws $CameraException when disposed', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      await cameraController.dispose();

      expect(
        () => cameraController.setZoomLevel(42.0),
        throwsA(
          isA<CameraException>()
              .having((CameraException error) => error.code, 'code', 'Disposed CameraController')
              .having(
                (CameraException error) => error.description,
                'description',
                'setZoomLevel() was called on a disposed CameraController.',
              ),
        ),
      );
    });

    test('setZoomLevel() throws $CameraException when a platform exception occured.', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      when(
        CameraPlatform.instance.setZoomLevel(mockInitializeCamera, 42.0),
      ).thenThrow(CameraException('TEST_ERROR', 'This is a test error messge'));

      expect(
        () => cameraController.setZoomLevel(42),
        throwsA(
          isA<CameraException>()
              .having((CameraException error) => error.code, 'code', 'TEST_ERROR')
              .having(
                (CameraException error) => error.description,
                'description',
                'This is a test error messge',
              ),
        ),
      );

      reset(CameraPlatform.instance);
    });

    test('setZoomLevel() completes and calls method channel with correct value.', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      await cameraController.setZoomLevel(42.0);

      verify(CameraPlatform.instance.setZoomLevel(mockInitializeCamera, 42.0)).called(1);
    });

    test('setFlashMode() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      await cameraController.setFlashMode(FlashMode.always);

      verify(
        CameraPlatform.instance.setFlashMode(cameraController.cameraId, FlashMode.always),
      ).called(1);
    });

    test('setFlashMode() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      when(
        CameraPlatform.instance.setFlashMode(cameraController.cameraId, FlashMode.always),
      ).thenThrow(PlatformException(code: 'TEST_ERROR', message: 'This is a test error message'));

      expect(
        cameraController.setFlashMode(FlashMode.always),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('setJpegImageQuality() calls CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      await cameraController.setJpegImageQuality(50);

      verify(CameraPlatform.instance.setJpegImageQuality(cameraController.cameraId, 50)).called(1);
    });

    test('setJpegImageQuality() throws CameraException on PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      when(
        CameraPlatform.instance.setJpegImageQuality(cameraController.cameraId, 50),
      ).thenThrow(PlatformException(code: 'TEST_ERROR', message: 'This is a test error message'));

      expect(
        cameraController.setJpegImageQuality(50),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('setJpegImageQuality() throws ArgumentError for invalid values', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      expect(() => cameraController.setJpegImageQuality(0), throwsA(isA<ArgumentError>()));
      expect(() => cameraController.setJpegImageQuality(101), throwsA(isA<ArgumentError>()));
    });

    test('getSupportedFlashModes() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      when(
        CameraPlatform.instance.getSupportedFlashModes(cameraController.cameraId),
      ).thenAnswer((_) async => <FlashMode>[FlashMode.off, FlashMode.auto, FlashMode.always]);

      final Iterable<FlashMode> modes = await cameraController.getSupportedFlashModes();

      verify(CameraPlatform.instance.getSupportedFlashModes(cameraController.cameraId)).called(1);
      expect(modes, <FlashMode>[FlashMode.off, FlashMode.auto, FlashMode.always]);
    });

    test('setExposureMode() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      await cameraController.setExposureMode(ExposureMode.auto);

      verify(
        CameraPlatform.instance.setExposureMode(cameraController.cameraId, ExposureMode.auto),
      ).called(1);
    });

    test('setExposureMode() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      when(
        CameraPlatform.instance.setExposureMode(cameraController.cameraId, ExposureMode.auto),
      ).thenThrow(PlatformException(code: 'TEST_ERROR', message: 'This is a test error message'));

      expect(
        cameraController.setExposureMode(ExposureMode.auto),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('setWhiteBalance(null) calls $CameraPlatform and switches to auto', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      await cameraController.setWhiteBalance(null);

      verify(CameraPlatform.instance.setWhiteBalance(cameraController.cameraId, null)).called(1);
      expect(cameraController.value.whiteBalanceValues, null);
      expect(cameraController.value.whiteBalanceMode, WhiteBalanceMode.auto);
    });

    test('setWhiteBalance(values) forwards values and locks white balance', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      final values = WhiteBalanceValues(temperature: 5500, tint: 25);
      await cameraController.setWhiteBalance(values);

      verify(CameraPlatform.instance.setWhiteBalance(cameraController.cameraId, values)).called(1);
      expect(cameraController.value.whiteBalanceValues, values);
      expect(cameraController.value.whiteBalanceMode, WhiteBalanceMode.locked);
    });

    test('supportsWhiteBalance() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      when(
        CameraPlatform.instance.supportsWhiteBalance(cameraController.cameraId),
      ).thenAnswer((_) async => true);

      expect(await cameraController.supportsWhiteBalance(), isTrue);
      verify(CameraPlatform.instance.supportsWhiteBalance(cameraController.cameraId)).called(1);
    });

    test('supportsWhiteBalance() throws $CameraException when not initialized', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      expect(cameraController.supportsWhiteBalance(), throwsA(isA<CameraException>()));
    });

    test('autoWhiteBalanceValues forwards values from the platform stream', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      final ({double temperature, double tint}) value =
          await cameraController.autoWhiteBalanceValues.first;

      expect(value.temperature, 5500);
      expect(value.tint, 12);
    });

    test('setExposurePoint() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      await cameraController.setExposurePoint(const Offset(0.5, 0.5));

      verify(
        CameraPlatform.instance.setExposurePoint(
          cameraController.cameraId,
          const Point<double>(0.5, 0.5),
        ),
      ).called(1);
    });

    test('setExposurePoint() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      when(
        CameraPlatform.instance.setExposurePoint(
          cameraController.cameraId,
          const Point<double>(0.5, 0.5),
        ),
      ).thenThrow(PlatformException(code: 'TEST_ERROR', message: 'This is a test error message'));

      expect(
        cameraController.setExposurePoint(const Offset(0.5, 0.5)),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('getMinExposureOffset() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      when(
        CameraPlatform.instance.getMinExposureOffset(cameraController.cameraId),
      ).thenAnswer((_) => Future<double>.value(0.0));

      await cameraController.getMinExposureOffset();

      verify(CameraPlatform.instance.getMinExposureOffset(cameraController.cameraId)).called(1);
    });

    test('getMinExposureOffset() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      when(
        CameraPlatform.instance.getMinExposureOffset(cameraController.cameraId),
      ).thenThrow(CameraException('TEST_ERROR', 'This is a test error message'));

      expect(
        cameraController.getMinExposureOffset(),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('getMaxExposureOffset() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      when(
        CameraPlatform.instance.getMaxExposureOffset(cameraController.cameraId),
      ).thenAnswer((_) => Future<double>.value(1.0));

      await cameraController.getMaxExposureOffset();

      verify(CameraPlatform.instance.getMaxExposureOffset(cameraController.cameraId)).called(1);
    });

    test('getMaxExposureOffset() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      when(
        CameraPlatform.instance.getMaxExposureOffset(cameraController.cameraId),
      ).thenThrow(CameraException('TEST_ERROR', 'This is a test error message'));

      expect(
        cameraController.getMaxExposureOffset(),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('getExposureOffsetStepSize() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      when(
        CameraPlatform.instance.getExposureOffsetStepSize(cameraController.cameraId),
      ).thenAnswer((_) => Future<double>.value(0.0));

      await cameraController.getExposureOffsetStepSize();

      verify(
        CameraPlatform.instance.getExposureOffsetStepSize(cameraController.cameraId),
      ).called(1);
    });

    test('getExposureOffsetStepSize() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      when(
        CameraPlatform.instance.getExposureOffsetStepSize(cameraController.cameraId),
      ).thenThrow(CameraException('TEST_ERROR', 'This is a test error message'));

      expect(
        cameraController.getExposureOffsetStepSize(),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('setExposureOffset() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      when(
        CameraPlatform.instance.getMinExposureOffset(cameraController.cameraId),
      ).thenAnswer((_) async => -1.0);
      when(
        CameraPlatform.instance.getMaxExposureOffset(cameraController.cameraId),
      ).thenAnswer((_) async => 2.0);
      when(
        CameraPlatform.instance.getExposureOffsetStepSize(cameraController.cameraId),
      ).thenAnswer((_) async => 1.0);
      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 1.0),
      ).thenAnswer((_) async => 1.0);

      await cameraController.setExposureOffset(1.0);

      verify(CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 1.0)).called(1);
    });

    test('setExposureOffset() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      when(
        CameraPlatform.instance.getMinExposureOffset(cameraController.cameraId),
      ).thenAnswer((_) async => -1.0);
      when(
        CameraPlatform.instance.getMaxExposureOffset(cameraController.cameraId),
      ).thenAnswer((_) async => 2.0);
      when(
        CameraPlatform.instance.getExposureOffsetStepSize(cameraController.cameraId),
      ).thenAnswer((_) async => 1.0);
      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 1.0),
      ).thenThrow(CameraException('TEST_ERROR', 'This is a test error message'));

      expect(
        cameraController.setExposureOffset(1.0),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('setExposureOffset() throws $CameraException when offset is out of bounds', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      when(
        CameraPlatform.instance.getMinExposureOffset(cameraController.cameraId),
      ).thenAnswer((_) async => -1.0);
      when(
        CameraPlatform.instance.getMaxExposureOffset(cameraController.cameraId),
      ).thenAnswer((_) async => 2.0);
      when(
        CameraPlatform.instance.getExposureOffsetStepSize(cameraController.cameraId),
      ).thenAnswer((_) async => 1.0);
      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 0.0),
      ).thenAnswer((_) async => 0.0);
      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, -1.0),
      ).thenAnswer((_) async => 0.0);
      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 2.0),
      ).thenAnswer((_) async => 0.0);

      expect(
        cameraController.setExposureOffset(3.0),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'exposureOffsetOutOfBounds',
            'The provided exposure offset was outside the supported range for this device.',
          ),
        ),
      );
      expect(
        cameraController.setExposureOffset(-2.0),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'exposureOffsetOutOfBounds',
            'The provided exposure offset was outside the supported range for this device.',
          ),
        ),
      );

      await cameraController.setExposureOffset(0.0);
      await cameraController.setExposureOffset(-1.0);
      await cameraController.setExposureOffset(2.0);

      verify(CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 0.0)).called(1);
      verify(CameraPlatform.instance.setExposureOffset(cameraController.cameraId, -1.0)).called(1);
      verify(CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 2.0)).called(1);
    });

    test('setExposureOffset() rounds offset to nearest step', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      when(
        CameraPlatform.instance.getMinExposureOffset(cameraController.cameraId),
      ).thenAnswer((_) async => -1.2);
      when(
        CameraPlatform.instance.getMaxExposureOffset(cameraController.cameraId),
      ).thenAnswer((_) async => 1.2);
      when(
        CameraPlatform.instance.getExposureOffsetStepSize(cameraController.cameraId),
      ).thenAnswer((_) async => 0.4);

      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, -1.2),
      ).thenAnswer((_) async => -1.2);
      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, -0.8),
      ).thenAnswer((_) async => -0.8);
      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, -0.4),
      ).thenAnswer((_) async => -0.4);
      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 0.0),
      ).thenAnswer((_) async => 0.0);
      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 0.4),
      ).thenAnswer((_) async => 0.4);
      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 0.8),
      ).thenAnswer((_) async => 0.8);
      when(
        CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 1.2),
      ).thenAnswer((_) async => 1.2);

      await cameraController.setExposureOffset(1.2);
      await cameraController.setExposureOffset(-1.2);
      await cameraController.setExposureOffset(0.1);
      await cameraController.setExposureOffset(0.2);
      await cameraController.setExposureOffset(0.3);
      await cameraController.setExposureOffset(0.4);
      await cameraController.setExposureOffset(0.5);
      await cameraController.setExposureOffset(0.6);
      await cameraController.setExposureOffset(0.7);
      await cameraController.setExposureOffset(-0.1);
      await cameraController.setExposureOffset(-0.2);
      await cameraController.setExposureOffset(-0.3);
      await cameraController.setExposureOffset(-0.4);
      await cameraController.setExposureOffset(-0.5);
      await cameraController.setExposureOffset(-0.6);
      await cameraController.setExposureOffset(-0.7);

      verify(CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 0.8)).called(2);
      verify(CameraPlatform.instance.setExposureOffset(cameraController.cameraId, -0.8)).called(2);
      verify(CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 0.0)).called(2);
      verify(CameraPlatform.instance.setExposureOffset(cameraController.cameraId, 0.4)).called(4);
      verify(CameraPlatform.instance.setExposureOffset(cameraController.cameraId, -0.4)).called(4);
    });

    test(
      'getSupportedVideoStabilizationModes() returns off when device supports no mode',
      () async {
        // arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );

        await cameraController.initialize();
        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[]);

        // act
        final Iterable<VideoStabilizationMode> modes = await cameraController
            .getSupportedVideoStabilizationModes();

        // assert
        expect(modes, <VideoStabilizationMode>[VideoStabilizationMode.off]);
      },
    );

    test(
      'getSupportedVideoStabilizationModes() returns off when device supports only off',
      () async {
        // arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );

        await cameraController.initialize();
        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[VideoStabilizationMode.off]);

        // act
        final Iterable<VideoStabilizationMode> modes = await cameraController
            .getSupportedVideoStabilizationModes();

        // assert
        expect(modes, <VideoStabilizationMode>[VideoStabilizationMode.off]);
      },
    );

    test('getSupportedVideoStabilizationModes() returns off and level1', () async {
      // arrange
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      when(
        CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
      ).thenAnswer(
        (_) async => <VideoStabilizationMode>[
          VideoStabilizationMode.off,
          VideoStabilizationMode.level1,
        ],
      );

      // act
      final Iterable<VideoStabilizationMode> modes = await cameraController
          .getSupportedVideoStabilizationModes();

      // assert
      expect(modes, <VideoStabilizationMode>[
        VideoStabilizationMode.off,
        VideoStabilizationMode.level1,
      ]);
    });

    test('getSupportedVideoStabilizationModes() returns off, level1 and level2', () async {
      // arrange
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      when(
        CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
      ).thenAnswer(
        (_) async => <VideoStabilizationMode>[
          VideoStabilizationMode.off,
          VideoStabilizationMode.level1,
          VideoStabilizationMode.level2,
        ],
      );

      // act
      final Iterable<VideoStabilizationMode> modes = await cameraController
          .getSupportedVideoStabilizationModes();

      // assert
      expect(modes, <VideoStabilizationMode>[
        VideoStabilizationMode.off,
        VideoStabilizationMode.level1,
        VideoStabilizationMode.level2,
      ]);
    });

    test('getSupportedVideoStabilizationModes() returns all modes', () async {
      // arrange
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      await cameraController.initialize();
      when(
        CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
      ).thenAnswer(
        (_) async => <VideoStabilizationMode>[
          VideoStabilizationMode.off,
          VideoStabilizationMode.level1,
          VideoStabilizationMode.level2,
          VideoStabilizationMode.level3,
        ],
      );

      // act
      final Iterable<VideoStabilizationMode> modes = await cameraController
          .getSupportedVideoStabilizationModes();

      // assert
      expect(modes, <VideoStabilizationMode>[
        VideoStabilizationMode.off,
        VideoStabilizationMode.level1,
        VideoStabilizationMode.level2,
        VideoStabilizationMode.level3,
      ]);
    });

    test('setVideoStabilizationMode() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      when(
        CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
      ).thenAnswer(
        (_) async => <VideoStabilizationMode>[
          VideoStabilizationMode.off,
          VideoStabilizationMode.level1,
        ],
      );

      when(
        CameraPlatform.instance.setVideoStabilizationMode(
          cameraController.cameraId,
          VideoStabilizationMode.level1,
        ),
      ).thenThrow(PlatformException(code: 'TEST_ERROR', message: 'This is a test error message'));

      expect(
        cameraController.setVideoStabilizationMode(VideoStabilizationMode.level1),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test(
      'setVideoStabilizationMode() with fallback never calls CameraPlatform.instance.setVideoStabilizationMode when no supported mode is available',
      () async {
        //// The purpose of this test is to ensure that when no video stabilization mode is supported,
        //// then all calls to setVideoStabilizationMode with fallback will not result in any
        //// call to CameraPlatform.instance.setVideoStabilizationMode.

        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[]);

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.off);
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level1);
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level2);
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level3);

        // assert
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.off when off is requested and only off is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).thenAnswer((_) => Future<void>(() {}));
        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[VideoStabilizationMode.off]);

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.off);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.off when level1 is requested and only off is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[VideoStabilizationMode.off]);

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level1);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.off when level2 is requested and only off is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).thenAnswer((_) => Future<void>(() {}));
        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[VideoStabilizationMode.off]);

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level2);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.off when level3 is requested and only off is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).thenAnswer((_) => Future<void>(() {}));
        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[VideoStabilizationMode.off]);

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level3);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.off when off is requested and only off and level1 are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).thenAnswer((_) => Future<void>(() {}));
        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.off);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.level1 when level1 is requested and only off and level1 are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
          ],
        );
        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level1);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.level1 when level2 is requested and only off and level1 are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level2);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.level1 when level3 is requested and only off and level1 are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level3);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.off when off is requested and all levels are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
            VideoStabilizationMode.level2,
            VideoStabilizationMode.level3,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.off);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.level1 when level1 is requested and all levels are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).thenAnswer((_) => Future<void>(() {}));
        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
            VideoStabilizationMode.level2,
            VideoStabilizationMode.level3,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level1);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.level2 when level2 is requested and all levels are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
            VideoStabilizationMode.level2,
            VideoStabilizationMode.level3,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level2);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() with fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.level3 when level3 is requested and all levels available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
            VideoStabilizationMode.level2,
            VideoStabilizationMode.level3,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(VideoStabilizationMode.level3);

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback calls never calls CameraPlatform.instance.setVideoStabilizationMode when off is requested no supported mode is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[]);

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(
          VideoStabilizationMode.off,
          allowFallback: false,
        );

        // assert
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback throws $ArgumentError when level1 is requested and no supported mode is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[]);

        clearInteractions(CameraPlatform.instance);

        // assert
        expect(
          // act
          cameraController.setVideoStabilizationMode(
            VideoStabilizationMode.level1,
            allowFallback: false,
          ),
          throwsA(isA<ArgumentError>().having((ArgumentError error) => error.name, 'name', 'mode')),
        );

        // assert
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback throws $ArgumentError when level2 is requested and no supported mode is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[]);

        clearInteractions(CameraPlatform.instance);

        // assert
        expect(
          // act
          cameraController.setVideoStabilizationMode(
            VideoStabilizationMode.level2,
            allowFallback: false,
          ),
          throwsA(isA<ArgumentError>().having((ArgumentError error) => error.name, 'name', 'mode')),
        );

        // assert
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback throws $ArgumentError when level3 is requested and no supported mode is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[]);

        clearInteractions(CameraPlatform.instance);

        // assert
        expect(
          // act
          cameraController.setVideoStabilizationMode(
            VideoStabilizationMode.level3,
            allowFallback: false,
          ),
          throwsA(isA<ArgumentError>().having((ArgumentError error) => error.name, 'name', 'mode')),
        );

        // assert
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.off when off is requested and only off is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[VideoStabilizationMode.off]);

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(
          VideoStabilizationMode.off,
          allowFallback: false,
        );

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback throws $ArgumentError when level1 is requested and only off is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[VideoStabilizationMode.off]);

        clearInteractions(CameraPlatform.instance);

        // assert
        expect(
          // act
          cameraController.setVideoStabilizationMode(
            VideoStabilizationMode.level1,
            allowFallback: false,
          ),
          throwsA(isA<ArgumentError>().having((ArgumentError error) => error.name, 'name', 'mode')),
        );

        // assert
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback throws $ArgumentError when level2 is requested and only off is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[VideoStabilizationMode.off]);

        clearInteractions(CameraPlatform.instance);

        // assert
        expect(
          // act
          cameraController.setVideoStabilizationMode(
            VideoStabilizationMode.level2,
            allowFallback: false,
          ),
          throwsA(isA<ArgumentError>().having((ArgumentError error) => error.name, 'name', 'mode')),
        );

        // assert
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback throws $ArgumentError when level3 is requested and only off is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer((_) async => <VideoStabilizationMode>[VideoStabilizationMode.off]);

        clearInteractions(CameraPlatform.instance);

        // assert
        expect(
          // act
          cameraController.setVideoStabilizationMode(
            VideoStabilizationMode.level3,
            allowFallback: false,
          ),
          throwsA(isA<ArgumentError>().having((ArgumentError error) => error.name, 'name', 'mode')),
        );

        // assert
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.off when off is requested and all level1 is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(
          VideoStabilizationMode.off,
          allowFallback: false,
        );

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.level1 when level1 is requested and level1 is available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(
          VideoStabilizationMode.level1,
          allowFallback: false,
        );

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback throws $ArgumentError when level2 is requested and only off and level1 are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // assert
        expect(
          // act
          cameraController.setVideoStabilizationMode(
            VideoStabilizationMode.level2,
            allowFallback: false,
          ),
          throwsA(isA<ArgumentError>().having((ArgumentError error) => error.name, 'name', 'mode')),
        );

        // assert
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.off when off is requested and all levels are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
            VideoStabilizationMode.level2,
            VideoStabilizationMode.level3,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(
          VideoStabilizationMode.off,
          allowFallback: false,
        );

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.level1 when level1 is requested and all levels are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
            VideoStabilizationMode.level2,
            VideoStabilizationMode.level3,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(
          VideoStabilizationMode.level1,
          allowFallback: false,
        );

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.level2 when level2 is requested and all levels are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            mockInitializeCamera,
            VideoStabilizationMode.level2,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
            VideoStabilizationMode.level2,
            VideoStabilizationMode.level3,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(
          VideoStabilizationMode.level2,
          allowFallback: false,
        );

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        );
      },
    );

    test(
      'setVideoStabilizationMode() without fallback calls CameraPlatform.instance.setVideoStabilizationMode with VideoStabilizationMode.level3 when level3 is requested and all levels are available',
      () async {
        //arrange
        final cameraController = CameraController(
          const CameraDescription(
            name: 'cam',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90,
          ),
          ResolutionPreset.max,
        );
        await cameraController.initialize();

        when(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        ).thenAnswer((_) => Future<void>(() {}));

        when(
          CameraPlatform.instance.getSupportedVideoStabilizationModes(mockInitializeCamera),
        ).thenAnswer(
          (_) async => <VideoStabilizationMode>[
            VideoStabilizationMode.off,
            VideoStabilizationMode.level1,
            VideoStabilizationMode.level2,
            VideoStabilizationMode.level3,
          ],
        );

        clearInteractions(CameraPlatform.instance);

        // act
        await cameraController.setVideoStabilizationMode(
          VideoStabilizationMode.level3,
          allowFallback: false,
        );

        // assert
        verify(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level3,
          ),
        ).called(1);

        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.off,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level1,
          ),
        );
        verifyNever(
          CameraPlatform.instance.setVideoStabilizationMode(
            cameraController.cameraId,
            VideoStabilizationMode.level2,
          ),
        );
      },
    );

    test('pausePreview() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      cameraController.value = cameraController.value.copyWith(
        deviceOrientation: DeviceOrientation.portraitUp,
      );

      await cameraController.pausePreview();

      verify(CameraPlatform.instance.pausePreview(cameraController.cameraId)).called(1);
      expect(cameraController.value.isPreviewPaused, equals(true));
      expect(cameraController.value.previewPauseOrientation, DeviceOrientation.portraitUp);
    });

    test('pausePreview() does not call $CameraPlatform when already paused', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      cameraController.value = cameraController.value.copyWith(isPreviewPaused: true);

      await cameraController.pausePreview();

      verifyNever(CameraPlatform.instance.pausePreview(cameraController.cameraId));
      expect(cameraController.value.isPreviewPaused, equals(true));
    });

    test('pausePreview() sets previewPauseOrientation according to locked orientation', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      cameraController.value = cameraController.value.copyWith(
        isPreviewPaused: false,
        deviceOrientation: DeviceOrientation.portraitUp,
        lockedCaptureOrientation: const Optional<DeviceOrientation>.of(
          DeviceOrientation.landscapeRight,
        ),
      );

      await cameraController.pausePreview();

      expect(cameraController.value.deviceOrientation, equals(DeviceOrientation.portraitUp));
      expect(
        cameraController.value.previewPauseOrientation,
        equals(DeviceOrientation.landscapeRight),
      );
    });

    test('pausePreview() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      when(
        CameraPlatform.instance.pausePreview(cameraController.cameraId),
      ).thenThrow(PlatformException(code: 'TEST_ERROR', message: 'This is a test error message'));

      expect(
        cameraController.pausePreview(),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('resumePreview() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      cameraController.value = cameraController.value.copyWith(isPreviewPaused: true);

      await cameraController.resumePreview();

      verify(CameraPlatform.instance.resumePreview(cameraController.cameraId)).called(1);
      expect(cameraController.value.isPreviewPaused, equals(false));
    });

    test('resumePreview() does not call $CameraPlatform when not paused', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      cameraController.value = cameraController.value.copyWith(isPreviewPaused: false);

      await cameraController.resumePreview();

      verifyNever(CameraPlatform.instance.resumePreview(cameraController.cameraId));
      expect(cameraController.value.isPreviewPaused, equals(false));
    });

    test('resumePreview() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      cameraController.value = cameraController.value.copyWith(isPreviewPaused: true);
      when(
        CameraPlatform.instance.resumePreview(cameraController.cameraId),
      ).thenThrow(PlatformException(code: 'TEST_ERROR', message: 'This is a test error message'));

      expect(
        cameraController.resumePreview(),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('lockCaptureOrientation() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      await cameraController.lockCaptureOrientation();
      expect(cameraController.value.lockedCaptureOrientation, equals(DeviceOrientation.portraitUp));
      await cameraController.lockCaptureOrientation(DeviceOrientation.landscapeRight);
      expect(
        cameraController.value.lockedCaptureOrientation,
        equals(DeviceOrientation.landscapeRight),
      );

      verify(
        CameraPlatform.instance.lockCaptureOrientation(
          cameraController.cameraId,
          DeviceOrientation.portraitUp,
        ),
      ).called(1);
      verify(
        CameraPlatform.instance.lockCaptureOrientation(
          cameraController.cameraId,
          DeviceOrientation.landscapeRight,
        ),
      ).called(1);
    });

    test('lockCaptureOrientation() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      when(
        CameraPlatform.instance.lockCaptureOrientation(
          cameraController.cameraId,
          DeviceOrientation.portraitUp,
        ),
      ).thenThrow(PlatformException(code: 'TEST_ERROR', message: 'This is a test error message'));

      expect(
        cameraController.lockCaptureOrientation(DeviceOrientation.portraitUp),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('unlockCaptureOrientation() calls $CameraPlatform', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      await cameraController.unlockCaptureOrientation();
      expect(cameraController.value.lockedCaptureOrientation, equals(null));

      verify(CameraPlatform.instance.unlockCaptureOrientation(cameraController.cameraId)).called(1);
    });

    test('unlockCaptureOrientation() throws $CameraException on $PlatformException', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      when(
        CameraPlatform.instance.unlockCaptureOrientation(cameraController.cameraId),
      ).thenThrow(PlatformException(code: 'TEST_ERROR', message: 'This is a test error message'));

      expect(
        cameraController.unlockCaptureOrientation(),
        throwsA(
          isA<CameraException>().having(
            (CameraException error) => error.description,
            'TEST_ERROR',
            'This is a test error message',
          ),
        ),
      );
    });

    test('error from onCameraError is received', () async {
      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();

      expect(cameraController.value.hasError, isTrue);
      expect(cameraController.value.errorDescription, mockOnCameraErrorEvent.description);
    });
  });

  group('does not update value after dispose', () {
    test('when initialization completes after dispose', () async {
      final platform = MockDelayedInitializeCameraPlatform();
      CameraPlatform.instance = platform;

      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );

      final Future<void> initializeFuture = cameraController.initialize();
      await pumpEventQueue();

      // Dispose while initialization is still in flight, then let it complete.
      final Future<void> disposeFuture = cameraController.dispose();
      platform.initializeCameraCompleter.complete();

      await expectLater(initializeFuture, completes);
      await disposeFuture;
    });

    test('when a camera error event arrives after dispose', () async {
      final platform = MockControllableErrorCameraPlatform();
      CameraPlatform.instance = platform;

      final cameraController = CameraController(
        const CameraDescription(
          name: 'cam',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.max,
      );
      await cameraController.initialize();
      await cameraController.dispose();

      // A camera error arriving after dispose must not update `value`.
      platform.cameraErrorController.add(const CameraErrorEvent(13, 'late error'));
      await pumpEventQueue();

      expect(cameraController.value.errorDescription, isNull);
    });
  });
}

class MockCameraPlatform extends Mock with MockPlatformInterfaceMixin implements CameraPlatform {
  // Overridden rather than left to `Mock`, which answers a `Future`-returning
  // method with null, so the ordering against `initializeCamera` can be
  // verified.
  @override
  Future<void> setAspectRatio(int? cameraId, double? aspectRatio) async =>
      super.noSuchMethod(Invocation.method(#setAspectRatio, <Object?>[cameraId, aspectRatio]));

  @override
  Future<void> initializeCamera(
    int? cameraId, {
    ImageFormatGroup? imageFormatGroup = ImageFormatGroup.unknown,
  }) async => super.noSuchMethod(
    Invocation.method(
      #initializeCamera,
      <Object?>[cameraId],
      <Symbol, dynamic>{#imageFormatGroup: imageFormatGroup},
    ),
  );

  @override
  Future<void> dispose(int? cameraId) async {
    return super.noSuchMethod(Invocation.method(#dispose, <Object?>[cameraId]));
  }

  @override
  Future<List<CameraDescription>> availableCameras() =>
      Future<List<CameraDescription>>.value(mockAvailableCameras);

  // Parameters widened to nullable, like `initializeCamera` above, so `any` and
  // `captureAny` can be used against them.
  @override
  Future<int> createCameraWithSettings(
    CameraDescription? cameraDescription,
    MediaSettings? mediaSettings,
  ) {
    // Recorded so tests can assert on the settings a camera is built with. The
    // result stays fixed rather than coming from the stub, because callers here
    // need a real camera id.
    super.noSuchMethod(
      Invocation.method(#createCameraWithSettings, <Object?>[cameraDescription, mediaSettings]),
    );
    return mockPlatformException
        ? throw PlatformException(code: 'foo', message: 'bar')
        : Future<int>.value(mockInitializeCamera);
  }

  @override
  Future<int> createCamera(
    CameraDescription description,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) => createCameraWithSettings(description, null);

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream<CameraInitializedEvent>.value(mockOnCameraInitializedEvent);

  @override
  Stream<CameraClosingEvent> onCameraClosing(int cameraId) =>
      Stream<CameraClosingEvent>.value(mockOnCameraClosingEvent);

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      Stream<CameraErrorEvent>.value(mockOnCameraErrorEvent);

  @override
  Stream<CameraResolutionChangedEvent> onCameraResolutionChanged(int cameraId) {
    final CameraResolutionChangedEvent? event = mockOnCameraResolutionChangedEvent;
    return event == null
        ? const Stream<CameraResolutionChangedEvent>.empty()
        : Stream<CameraResolutionChangedEvent>.value(event);
  }

  @override
  Stream<CameraAutoWhiteBalanceChangedEvent> onAutoWhiteBalanceChanged(int cameraId) {
    // The real platform emits continuously while auto-WB is active. Mimic
    // that with a periodic source so a subscriber attaching *after* the
    // controller has wired its upstream still sees an event (single-shot
    // `Stream.value` would race and silently drop, since the controller's
    // public stream is broadcast and doesn't buffer pre-subscription).
    return Stream<CameraAutoWhiteBalanceChangedEvent>.periodic(
      const Duration(milliseconds: 10),
      (_) => CameraAutoWhiteBalanceChangedEvent(cameraId, 5500, 12),
    );
  }

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      Stream<DeviceOrientationChangedEvent>.value(mockOnDeviceOrientationChangedEvent);

  @override
  Future<XFile> takePicture(int cameraId) => mockPlatformException
      ? throw PlatformException(code: 'foo', message: 'bar')
      : Future<XFile>.value(mockTakePicture);

  @override
  Future<(XFile, XFile)> takePictureWithOriginal(int cameraId) => mockPlatformException
      ? throw PlatformException(code: 'foo', message: 'bar')
      : Future<(XFile, XFile)>.value(mockTakePictureWithOriginal);

  @override
  Future<void> prepareForVideoRecording() async =>
      super.noSuchMethod(Invocation.method(#prepareForVideoRecording, null));

  @override
  Future<void> startVideoRecording(int cameraId, {Duration? maxVideoDuration}) {
    // Ignore maxVideoDuration, as it is unimplemented and deprecated.
    return startVideoCapturing(VideoCaptureOptions(cameraId));
  }

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {}

  @override
  Future<XFile> stopVideoRecording(int cameraId) {
    return Future<XFile>.value(mockVideoRecordingXFile);
  }

  @override
  Future<void> lockCaptureOrientation(int? cameraId, DeviceOrientation? orientation) async => super
      .noSuchMethod(Invocation.method(#lockCaptureOrientation, <Object?>[cameraId, orientation]));

  @override
  Future<void> unlockCaptureOrientation(int? cameraId) async =>
      super.noSuchMethod(Invocation.method(#unlockCaptureOrientation, <Object?>[cameraId]));

  @override
  Future<void> pausePreview(int? cameraId) async =>
      super.noSuchMethod(Invocation.method(#pausePreview, <Object?>[cameraId]));

  @override
  Future<void> resumePreview(int? cameraId) async =>
      super.noSuchMethod(Invocation.method(#resumePreview, <Object?>[cameraId]));

  @override
  Future<double> getMaxZoomLevel(int? cameraId) async =>
      super.noSuchMethod(
            Invocation.method(#getMaxZoomLevel, <Object?>[cameraId]),
            returnValue: Future<double>.value(1.0),
          )
          as Future<double>;

  @override
  Future<double> getMinZoomLevel(int? cameraId) async =>
      super.noSuchMethod(
            Invocation.method(#getMinZoomLevel, <Object?>[cameraId]),
            returnValue: Future<double>.value(0.0),
          )
          as Future<double>;

  @override
  Future<void> setZoomLevel(int? cameraId, double? zoom) async =>
      super.noSuchMethod(Invocation.method(#setZoomLevel, <Object?>[cameraId, zoom]));

  @override
  Future<void> setFlashMode(int? cameraId, FlashMode? mode) async =>
      super.noSuchMethod(Invocation.method(#setFlashMode, <Object?>[cameraId, mode]));

  @override
  Future<Iterable<FlashMode>> getSupportedFlashModes(int? cameraId) =>
      super.noSuchMethod(
            Invocation.method(#getSupportedFlashModes, <Object?>[cameraId]),
            returnValue: Future<List<FlashMode>>.value(<FlashMode>[]),
            returnValueForMissingStub: Future<List<FlashMode>>.value(<FlashMode>[]),
          )
          as Future<Iterable<FlashMode>>;

  @override
  Future<void> setExposureMode(int? cameraId, ExposureMode? mode) async =>
      super.noSuchMethod(Invocation.method(#setExposureMode, <Object?>[cameraId, mode]));

  @override
  Future<void> setExposurePoint(int? cameraId, Point<double>? point) async =>
      super.noSuchMethod(Invocation.method(#setExposurePoint, <Object?>[cameraId, point]));

  @override
  Future<void> setWhiteBalance(int? cameraId, WhiteBalanceValues? values) async =>
      super.noSuchMethod(
        Invocation.method(#setWhiteBalance, <Object?>[cameraId, values]),
        returnValue: Future<void>.value(),
      );

  @override
  Future<bool> supportsWhiteBalance(int? cameraId) =>
      super.noSuchMethod(
            Invocation.method(#supportsWhiteBalance, <Object?>[cameraId]),
            returnValue: Future<bool>.value(false),
            returnValueForMissingStub: Future<bool>.value(false),
          )
          as Future<bool>;

  @override
  Future<double> getMinExposureOffset(int? cameraId) async =>
      super.noSuchMethod(
            Invocation.method(#getMinExposureOffset, <Object?>[cameraId]),
            returnValue: Future<double>.value(0.0),
          )
          as Future<double>;

  @override
  Future<double> getMaxExposureOffset(int? cameraId) async =>
      super.noSuchMethod(
            Invocation.method(#getMaxExposureOffset, <Object?>[cameraId]),
            returnValue: Future<double>.value(1.0),
          )
          as Future<double>;

  @override
  Future<double> getExposureOffsetStepSize(int? cameraId) async =>
      super.noSuchMethod(
            Invocation.method(#getExposureOffsetStepSize, <Object?>[cameraId]),
            returnValue: Future<double>.value(1.0),
          )
          as Future<double>;

  @override
  Future<double> setExposureOffset(int? cameraId, double? offset) async =>
      super.noSuchMethod(
            Invocation.method(#setExposureOffset, <Object?>[cameraId, offset]),
            returnValue: Future<double>.value(1.0),
          )
          as Future<double>;

  @override
  Future<Iterable<VideoStabilizationMode>> getSupportedVideoStabilizationModes(int cameraId) {
    return super.noSuchMethod(
          Invocation.method(#getSupportedVideoStabilizationModes, <Object?>[cameraId]),
          returnValue: Future<Iterable<VideoStabilizationMode>>.value(<VideoStabilizationMode>[]),
        )
        as Future<Iterable<VideoStabilizationMode>>;
  }

  @override
  Future<void> setVideoStabilizationMode(int cameraId, VideoStabilizationMode mode) async =>
      super.noSuchMethod(Invocation.method(#setVideoStabilizationMode, <Object?>[cameraId, mode]));

  @override
  Future<void> setJpegImageQuality(int? cameraId, int? quality) async =>
      super.noSuchMethod(Invocation.method(#setJpegImageQuality, <Object?>[cameraId, quality]));
}

class MockCameraDescription extends CameraDescription {
  /// Creates a new camera description with the given properties.
  const MockCameraDescription()
    : super(name: 'Test', lensDirection: CameraLensDirection.back, sensorOrientation: 0);

  @override
  CameraLensDirection get lensDirection => CameraLensDirection.back;

  @override
  String get name => 'back';
}

/// A platform whose [initializeCamera] only completes once
/// [initializeCameraCompleter] is completed, so a test can dispose the
/// controller while initialization is still in flight.
class MockDelayedInitializeCameraPlatform extends MockCameraPlatform {
  final Completer<void> initializeCameraCompleter = Completer<void>();

  @override
  Future<void> initializeCamera(
    int? cameraId, {
    ImageFormatGroup? imageFormatGroup = ImageFormatGroup.unknown,
  }) => initializeCameraCompleter.future;
}

/// A platform whose camera error events are driven by [cameraErrorController],
/// so a test can emit an error after the controller has been disposed.
class MockControllableErrorCameraPlatform extends MockCameraPlatform {
  final StreamController<CameraErrorEvent> cameraErrorController =
      StreamController<CameraErrorEvent>.broadcast();

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => cameraErrorController.stream;
}
