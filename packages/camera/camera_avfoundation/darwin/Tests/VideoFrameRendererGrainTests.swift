// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import CoreGraphics
import ImageIO
import Metal
import XCTest

@testable import camera_avfoundation

/// Unit tests for VideoFrameRenderer grain-overlay methods:
/// updateGrainSize, clearGrainTexture, loadGrainTexture, and grainUVScale.
final class VideoFrameRendererGrainTests: XCTestCase {

  // MARK: - Helpers

  /// Returns a renderer, or skips the test if Metal is unavailable (e.g. on CI
  /// without a GPU).
  private func makeRenderer() throws -> VideoFrameRenderer {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Metal not available on this host")
    }
    guard let r = VideoFrameRenderer(width: 640, height: 480) else {
      XCTFail("VideoFrameRenderer init returned nil despite Metal being available")
      throw XCTSkip("renderer unavailable")
    }
    return r
  }

  /// Writes a minimal 2×2 BGRA PNG to a temp path and returns that path.
  private func makeTempPNG() -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("grain_unit_test_\(UUID().uuidString).png")
    let side = 2
    var pixels = [UInt8](repeating: 128, count: side * side * 4)
    // Make it fully opaque so MTKTextureLoader does not reject it.
    for i in stride(from: 3, through: pixels.count - 1, by: 4) {
      pixels[i] = 255
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
      data: &pixels,
      width: side,
      height: side,
      bitsPerComponent: 8,
      bytesPerRow: side * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return url.path
  }

  // MARK: - updateGrainSize

  func testUpdateGrainSize_storesValue() throws {
    let renderer = try makeRenderer()
    renderer.updateGrainSize(0.42)
    XCTAssertEqual(renderer.grainSizeForTesting, 0.42, accuracy: 0.0001)
  }

  func testUpdateGrainSize_zero_stored() throws {
    let renderer = try makeRenderer()
    renderer.updateGrainSize(0.0)
    XCTAssertEqual(renderer.grainSizeForTesting, 0.0, accuracy: 0.0001)
  }

  func testUpdateGrainSize_largerThanOne_stored() throws {
    // Values > 1 are valid (zoomed-in grain); they should be stored as-is.
    let renderer = try makeRenderer()
    renderer.updateGrainSize(2.5)
    XCTAssertEqual(renderer.grainSizeForTesting, 2.5, accuracy: 0.0001)
  }

  func testUpdateGrainSize_concurrentWritesDoNotCrash() throws {
    let renderer = try makeRenderer()
    let group = DispatchGroup()
    for i in 0..<200 {
      group.enter()
      DispatchQueue.global().async {
        renderer.updateGrainSize(Float(i % 100) / 100.0)
        group.leave()
      }
    }
    group.wait()
    // Any finite value in [0, 1) is acceptable; the main goal is no crash /
    // data race detected by TSan.
    XCTAssertTrue(renderer.grainSizeForTesting.isFinite)
  }

  // MARK: - clearGrainTexture

  func testClearGrainTexture_zeropsGrainOpacityInUniforms() throws {
    let renderer = try makeRenderer()
    renderer.updateUniforms { $0.grainOpacity = 0.9 }
    renderer.clearGrainTexture()
    XCTAssertEqual(renderer.snapshotUniforms().grainOpacity, 0.0, accuracy: 0.0001)
  }

  func testClearGrainTexture_nilsGrainTexture() throws {
    let renderer = try makeRenderer()
    // The texture starts nil; clear should leave it nil (no crash).
    renderer.clearGrainTexture()
    XCTAssertNil(renderer.grainTextureForTesting)
  }

  func testClearGrainTexture_bothOpacityAndTextureZeroedAfterReturn() throws {
    // After clearGrainTexture() returns, a render pass must never observe
    // opacity > 0 with a nil texture.  The fix (zero opacity first, then nil
    // the texture) means that after the call both invariants hold.
    let renderer = try makeRenderer()
    renderer.updateUniforms { $0.grainOpacity = 1.0 }
    renderer.clearGrainTexture()
    XCTAssertEqual(renderer.snapshotUniforms().grainOpacity, 0.0, accuracy: 0.0001)
    XCTAssertNil(renderer.grainTextureForTesting)
  }

  // MARK: - loadGrainTexture

  func testLoadGrainTexture_setsPendingPathSynchronously() throws {
    let renderer = try makeRenderer()
    let path = "/tmp/test_grain_\(UUID().uuidString).png"
    renderer.loadGrainTexture(path: path)
    XCTAssertEqual(renderer.pendingGrainTexturePathForTesting, path)
  }

  func testLoadGrainTexture_latestCallWinsPendingPath() throws {
    let renderer = try makeRenderer()
    renderer.loadGrainTexture(path: "/tmp/old.png")
    renderer.loadGrainTexture(path: "/tmp/new.png")
    XCTAssertEqual(renderer.pendingGrainTexturePathForTesting, "/tmp/new.png")
  }

  func testLoadGrainTexture_staleCallbackDoesNotOverridePendingPath() throws {
    let renderer = try makeRenderer()
    // Both paths are non-existent so the load callbacks will fail — but the
    // pendingGrainTexturePath must still reflect the *last* call.
    renderer.loadGrainTexture(path: "/nonexistent/stale_\(UUID().uuidString).png")
    renderer.loadGrainTexture(path: "/nonexistent/current_\(UUID().uuidString).png")
    let currentPath = renderer.pendingGrainTexturePathForTesting ?? ""
    XCTAssertTrue(currentPath.contains("current"), "pending path should be the most recent one")
  }

  func testLoadGrainTexture_validPathLoadsTexture() throws {
    let renderer = try makeRenderer()
    let pngPath = makeTempPNG()
    let exp = expectation(description: "grain texture loaded")
    renderer.loadGrainTexture(path: pngPath)
    // Poll on a background queue; MTKTextureLoader calls back asynchronously.
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
      XCTAssertNotNil(
        renderer.grainTextureForTesting,
        "grainTexture should be non-nil after loading a valid image")
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
  }

  func testLoadGrainTexture_missingPathLeavesTextureNil() throws {
    let renderer = try makeRenderer()
    let exp = expectation(description: "load attempt finished")
    renderer.loadGrainTexture(path: "/nonexistent/no_such_file.png")
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
      XCTAssertNil(
        renderer.grainTextureForTesting,
        "grainTexture must remain nil when the file does not exist")
      exp.fulfill()
    }
    waitForExpectations(timeout: 3)
  }

  func testLoadGrainTexture_clearAfterLoad_nilsTexture() throws {
    let renderer = try makeRenderer()
    let pngPath = makeTempPNG()
    let exp = expectation(description: "texture loaded then cleared")
    renderer.loadGrainTexture(path: pngPath)
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
      renderer.clearGrainTexture()
      XCTAssertNil(renderer.grainTextureForTesting)
      XCTAssertEqual(renderer.snapshotUniforms().grainOpacity, 0.0, accuracy: 0.0001)
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
  }

  // MARK: - grainUVScale static helper

  func testGrainUVScale_squareOutput() {
    // 100×100, grainSize=0.1 → cellPx = 0.1 * 100 = 10 → scale = (10, 10)
    let scale = VideoFrameRenderer.grainUVScale(grainSize: 0.1, outputWidth: 100, outputHeight: 100)
    XCTAssertEqual(scale.x, 10.0, accuracy: 0.001)
    XCTAssertEqual(scale.y, 10.0, accuracy: 0.001)
  }

  func testGrainUVScale_landscapeOutput() {
    // 640×480, grainSize=0.1 → cellPx = 0.1 * 480 = 48
    // scale = (640/48, 480/48) ≈ (13.333, 10.0)
    let scale = VideoFrameRenderer.grainUVScale(grainSize: 0.1, outputWidth: 640, outputHeight: 480)
    XCTAssertEqual(scale.x, 640.0 / 48.0, accuracy: 0.001)
    XCTAssertEqual(scale.y, 480.0 / 48.0, accuracy: 0.001)
  }

  func testGrainUVScale_portraitOutput() {
    // 480×640, grainSize=0.2 → cellPx = 0.2 * 480 = 96
    let scale = VideoFrameRenderer.grainUVScale(grainSize: 0.2, outputWidth: 480, outputHeight: 640)
    XCTAssertEqual(scale.x, 480.0 / 96.0, accuracy: 0.001)
    XCTAssertEqual(scale.y, 640.0 / 96.0, accuracy: 0.001)
  }

  func testGrainUVScale_grainSizeOne_shortSideFillsOneTile() {
    // 200×100, grainSize=1.0 → cellPx = 1.0 * 100 = 100
    // scale = (200/100, 100/100) = (2.0, 1.0)
    let scale = VideoFrameRenderer.grainUVScale(grainSize: 1.0, outputWidth: 200, outputHeight: 100)
    XCTAssertEqual(scale.x, 2.0, accuracy: 0.001)
    XCTAssertEqual(scale.y, 1.0, accuracy: 0.001)
  }

  func testGrainUVScale_grainSizeLargerThanOne() {
    // 100×100, grainSize=2.0 → cellPx = 2.0 * 100 = 200
    // scale = (100/200, 100/200) = (0.5, 0.5)
    let scale = VideoFrameRenderer.grainUVScale(grainSize: 2.0, outputWidth: 100, outputHeight: 100)
    XCTAssertEqual(scale.x, 0.5, accuracy: 0.001)
    XCTAssertEqual(scale.y, 0.5, accuracy: 0.001)
  }

  func testGrainUVScale_zeroGrainSizeClampedToAvoidDivideByZero() {
    // grainSize=0 → clamped to 0.001; cellPx = max(0.001 * 100, 1.0) = 1.0
    // scale = (100/1, 100/1) = (100, 100)
    let scale = VideoFrameRenderer.grainUVScale(grainSize: 0.0, outputWidth: 100, outputHeight: 100)
    XCTAssertTrue(scale.x.isFinite && scale.x > 0, "x scale must be finite and positive")
    XCTAssertTrue(scale.y.isFinite && scale.y > 0, "y scale must be finite and positive")
  }

  func testGrainUVScale_verySmallGrainSizeClampedCellPxToOne() {
    // grainSize=0.001, 100×100 → gs=0.001, cellPx = max(0.001 * 100, 1.0) = 1.0
    // scale = (100, 100)
    let scale = VideoFrameRenderer.grainUVScale(
      grainSize: 0.001, outputWidth: 100, outputHeight: 100)
    XCTAssertEqual(scale.x, 100.0, accuracy: 0.001)
    XCTAssertEqual(scale.y, 100.0, accuracy: 0.001)
  }

  // MARK: - Grain axis swap (photo vs preview orientation)

  // Photo buffers arrive in sensor (landscape) orientation and are rotated 90°
  // by EXIF when displayed. Without compensating, grainUVScale.x drives what
  // becomes the display-vertical axis and .y drives display-horizontal —
  // exactly a 90° rotation relative to the preview.  The fix is to swap X/Y
  // so that, after EXIF rotation, tiles appear at the same physical size and
  // orientation as in the live preview.

  func testGrainUVScale_photoAxisSwap_squareOutputIsSymmetric() {
    // For a square output the swap has no visible effect; verify it is still
    // computed correctly.
    let normal = VideoFrameRenderer.grainUVScale(grainSize: 0.1, outputWidth: 100, outputHeight: 100)
    let swapped = SIMD2<Float>(normal.y, normal.x)
    XCTAssertEqual(swapped.x, swapped.y, accuracy: 0.001)
  }

  func testGrainUVScale_photoAxisSwap_landscapeSensorMatchesPortraitDisplay() {
    // Simulate a 4:3 portrait capture:
    //   Preview buffer: 480×640 portrait (width < height)
    //   Photo buffer:   640×480 landscape (sensor orientation, EXIF rotates CW)
    //
    // After the EXIF rotation the photo is displayed as 480×640 — the same as
    // the preview.  grainUVScale for the preview drives display-x with .x and
    // display-y with .y.  For the photo (after the swap fix) the .x/.y after
    // swapping must match the preview's .x/.y in display space:
    //   photo buffer .x (sensor-x = display-y after rotation) → swapped to .y
    //   photo buffer .y (sensor-y = display-x after rotation) → swapped to .x
    let grainSize: Float = 0.1

    // Preview (portrait 480×640): cellPx = 0.1 * 480 = 48
    let preview = VideoFrameRenderer.grainUVScale(
      grainSize: grainSize, outputWidth: 480, outputHeight: 640)

    // Photo sensor buffer (landscape 640×480), then swap axes
    let photoRaw = VideoFrameRenderer.grainUVScale(
      grainSize: grainSize, outputWidth: 640, outputHeight: 480)
    let photoSwapped = SIMD2<Float>(photoRaw.y, photoRaw.x)

    // In display space:
    //   display-x tiling: preview.x == photoSwapped.x
    //   display-y tiling: preview.y == photoSwapped.y
    XCTAssertEqual(preview.x, photoSwapped.x, accuracy: 0.001,
      "grain tile density along display-x must match between preview and photo")
    XCTAssertEqual(preview.y, photoSwapped.y, accuracy: 0.001,
      "grain tile density along display-y must match between preview and photo")
  }

  func testGrainUVScale_withoutSwap_photoAndPreviewAxesAreTransposed() {
    // Confirm the *original* bug: without swapping, .x and .y are exchanged
    // between preview and photo in display space.
    let grainSize: Float = 0.1
    let preview = VideoFrameRenderer.grainUVScale(
      grainSize: grainSize, outputWidth: 480, outputHeight: 640)
    let photoRaw = VideoFrameRenderer.grainUVScale(
      grainSize: grainSize, outputWidth: 640, outputHeight: 480)
    // Without the swap, display-x tiling comes from photoRaw.y and
    // display-y tiling from photoRaw.x, which are the wrong way round.
    XCTAssertEqual(preview.x, photoRaw.y, accuracy: 0.001,
      "without swap: preview.x matches photoRaw.y — axes are transposed (the bug)")
    XCTAssertEqual(preview.y, photoRaw.x, accuracy: 0.001,
      "without swap: preview.y matches photoRaw.x — axes are transposed (the bug)")
  }
}
