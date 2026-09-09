// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import CoreGraphics
import ImageIO
import Metal
import XCTest

@testable import camera_avfoundation

/// Unit tests for the VideoFrameRenderer overlay methods: loadOverlayTexture,
/// clearOverlayTexture, and the effect the overlay has on `canBypassPreview`.
///
/// Mirrors `VideoFrameRendererGrainTests` / `VideoFrameRendererLutTests`, with
/// two differences worth noting: the overlay accepts an image of any size (it
/// is stretched, not tiled), and it is the one effect whose "is it on?" lives
/// in a texture rather than in a uniform, which is what the bypass tests here
/// are about.
final class VideoFrameRendererOverlayTests: XCTestCase {

  // MARK: - Helpers

  /// Returns a renderer, or skips the test if Metal is unavailable (e.g. on CI
  /// without a GPU).
  private func makeRenderer(width: Int = 640, height: Int = 480) throws -> VideoFrameRenderer {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Metal not available on this host")
    }
    guard let r = VideoFrameRenderer(width: width, height: height) else {
      XCTFail("VideoFrameRenderer init returned nil despite Metal being available")
      throw XCTSkip("renderer unavailable")
    }
    return r
  }

  /// Writes a `width`×`height` PNG with a semi-transparent pixel to a temp path.
  ///
  /// Non-square by default, and deliberately not opaque: the overlay's whole
  /// point is an alpha channel, and a non-square image must be accepted where
  /// the LUT would reject it.
  private func makeTempPNG(width: Int = 4, height: Int = 2) -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("overlay_unit_test_\(UUID().uuidString).png")
    var pixels = [UInt8](repeating: 100, count: width * height * 4)
    for i in stride(from: 3, through: pixels.count - 1, by: 4) {
      pixels[i] = 128
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return url.path
  }

  // MARK: - loadOverlayTexture

  func testLoadOverlayTexture_setsPendingPathSynchronously() throws {
    let renderer = try makeRenderer()
    let path = "/tmp/test_overlay_\(UUID().uuidString).png"
    renderer.loadOverlayTexture(path: path)
    XCTAssertEqual(renderer.pendingOverlayTexturePathForTesting, path)
  }

  func testLoadOverlayTexture_latestCallWinsPendingPath() throws {
    let renderer = try makeRenderer()
    renderer.loadOverlayTexture(path: "/tmp/old_overlay.png")
    renderer.loadOverlayTexture(path: "/tmp/new_overlay.png")
    XCTAssertEqual(renderer.pendingOverlayTexturePathForTesting, "/tmp/new_overlay.png")
  }

  func testLoadOverlayTexture_nonSquareImageLoads() throws {
    // Unlike the LUT, which demands exactly 512×512, any shape is valid here:
    // the shader stretches the overlay across the frame.
    let renderer = try makeRenderer()
    let pngPath = makeTempPNG(width: 4, height: 2)
    let exp = expectation(description: "overlay texture loaded")
    renderer.loadOverlayTexture(path: pngPath)
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
      XCTAssertNotNil(
        renderer.overlayTextureForTesting,
        "overlayTexture should be non-nil after loading a valid image")
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
  }

  func testLoadOverlayTexture_missingPathLeavesTextureNil() throws {
    let renderer = try makeRenderer()
    let exp = expectation(description: "load attempt finished")
    renderer.loadOverlayTexture(path: "/nonexistent/no_such_overlay.png")
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
      XCTAssertNil(
        renderer.overlayTextureForTesting,
        "overlayTexture must remain nil when the file does not exist")
      exp.fulfill()
    }
    waitForExpectations(timeout: 3)
  }

  func testClearOverlayTexture_afterLoad_nilsTextureAndPath() throws {
    let renderer = try makeRenderer()
    let pngPath = makeTempPNG()
    let exp = expectation(description: "texture loaded then cleared")
    renderer.loadOverlayTexture(path: pngPath)
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
      renderer.clearOverlayTexture()
      XCTAssertNil(renderer.overlayTextureForTesting)
      XCTAssertNil(renderer.pendingOverlayTexturePathForTesting)
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
  }

  func testClearOverlayTexture_withNothingLoaded_isNoOp() throws {
    let renderer = try makeRenderer()
    renderer.clearOverlayTexture()
    XCTAssertNil(renderer.overlayTextureForTesting)
    XCTAssertNil(renderer.pendingOverlayTexturePathForTesting)
  }

  // MARK: - canBypassPreview

  func testCanBypassPreview_isTrueWithNoEffects() throws {
    let renderer = try makeRenderer(width: 64, height: 48)
    XCTAssertTrue(
      renderer.canBypassPreview(
        sourcePixelFormat: kCVPixelFormatType_32BGRA, sourceWidth: 64, sourceHeight: 48),
      "a renderer with every effect off should bypass the GPU pass")
  }

  func testCanBypassPreview_isFalseWhileAnOverlayIsLoaded() throws {
    // The regression this guards: the overlay is the only effect not
    // represented by a non-zero uniform, so a bypass check that looked only at
    // uniforms would publish the source buffer and drop the overlay entirely.
    let renderer = try makeRenderer(width: 64, height: 48)
    let pngPath = makeTempPNG()
    let exp = expectation(description: "overlay loaded")
    renderer.loadOverlayTexture(path: pngPath)
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
      XCTAssertNotNil(renderer.overlayTextureForTesting, "precondition: overlay must be loaded")
      XCTAssertFalse(
        renderer.canBypassPreview(
          sourcePixelFormat: kCVPixelFormatType_32BGRA, sourceWidth: 64, sourceHeight: 48),
        "an active overlay must force the render pass")
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
  }

  func testCanBypassPreview_isTrueAgainAfterClearingTheOverlay() throws {
    let renderer = try makeRenderer(width: 64, height: 48)
    let pngPath = makeTempPNG()
    let exp = expectation(description: "overlay loaded then cleared")
    renderer.loadOverlayTexture(path: pngPath)
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
      renderer.clearOverlayTexture()
      XCTAssertTrue(
        renderer.canBypassPreview(
          sourcePixelFormat: kCVPixelFormatType_32BGRA, sourceWidth: 64, sourceHeight: 48),
        "clearing the overlay should restore the bypass")
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
  }

  // MARK: - adoptTextures

  func testAdoptTextures_carriesTheOverlayAcrossARendererRebuild() throws {
    // A renderer rebuild (an aspect-ratio change) must not flash a frame
    // without the overlay while the new renderer re-decodes the file.
    let old = try makeRenderer()
    let new = try makeRenderer()
    let pngPath = makeTempPNG()
    let exp = expectation(description: "overlay adopted")
    old.loadOverlayTexture(path: pngPath)
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
      XCTAssertNotNil(old.overlayTextureForTesting, "precondition: overlay must be loaded")
      new.adoptTextures(from: old)
      XCTAssertNotNil(new.overlayTextureForTesting)
      XCTAssertEqual(new.pendingOverlayTexturePathForTesting, pngPath)
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
  }
}
