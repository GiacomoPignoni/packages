// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import CoreGraphics
import ImageIO
import Metal
import XCTest

@testable import camera_avfoundation

/// Unit tests for VideoFrameRenderer LUT methods: decodeLutPng,
/// loadLutTexture, and clearLutTexture.
final class VideoFrameRendererLutTests: XCTestCase {

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

  /// Writes a synthetic identity LUT atlas PNG to a temp path and returns
  /// that path. The atlas is an 8×8 row-major grid of (side/8)² tiles:
  /// within a tile x = red, y = green (top to bottom); the tile index is
  /// the blue slice. `side` defaults to the valid 512 and can be overridden
  /// to produce a wrong-size atlas.
  private func makeLutPNG(side: Int = 512) -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("lut_unit_test_\(UUID().uuidString).png")
    let tile = side / 8
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    for row in 0..<side {
      let tileY = row / tile
      let y = row % tile
      for col in 0..<side {
        let tileX = col / tile
        let x = col % tile
        let slice = tileY * 8 + tileX
        let i = (row * side + col) * 4
        pixels[i] = UInt8(x * 255 / max(tile - 1, 1))
        pixels[i + 1] = UInt8(y * 255 / max(tile - 1, 1))
        pixels[i + 2] = UInt8(slice * 255 / 63)
        pixels[i + 3] = 255  // opaque, so premultiplication is the identity
      }
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

  /// Asserts the decoded RGBA8 buffer holds (r, g, b) at pixel (col, row),
  /// with ±1 tolerance to absorb codec / colour-space rounding.
  private func assertPixel(
    _ pixels: [UInt8], col: Int, row: Int, r: Int, g: Int, b: Int,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let i = (row * 512 + col) * 4
    XCTAssertLessThanOrEqual(
      abs(Int(pixels[i]) - r), 1, "red at (\(col),\(row))", file: file, line: line)
    XCTAssertLessThanOrEqual(
      abs(Int(pixels[i + 1]) - g), 1, "green at (\(col),\(row))", file: file, line: line)
    XCTAssertLessThanOrEqual(
      abs(Int(pixels[i + 2]) - b), 1, "blue at (\(col),\(row))", file: file, line: line)
  }

  // MARK: - decodeLutPng

  func testDecodeLutPng_validAtlas_returnsExpectedBytes() throws {
    let path = makeLutPNG()
    let pixels = try VideoFrameRenderer.decodeLutPng(path: path)
    XCTAssertEqual(pixels.count, 512 * 512 * 4)

    // Top-left texel: tile 0 (blue slice 0), local (0, 0) → black.
    assertPixel(pixels, col: 0, row: 0, r: 0, g: 0, b: 0)
    // Bottom-right texel: tile 63, local (63, 63) → white.
    assertPixel(pixels, col: 511, row: 511, r: 255, g: 255, b: 255)
    // Mid-tile texel: tile row 3, tile col 2 → slice 26; local (10, 20).
    // r = 10*255/63 = 40, g = 20*255/63 = 80, b = 26*255/63 = 105.
    assertPixel(pixels, col: 2 * 64 + 10, row: 3 * 64 + 20, r: 40, g: 80, b: 105)
  }

  func testDecodeLutPng_wrongSize_throwsWrongDimensions() {
    let path = makeLutPNG(side: 256)
    XCTAssertThrowsError(try VideoFrameRenderer.decodeLutPng(path: path)) { error in
      guard
        case VideoFrameRenderer.LutPngError.wrongDimensions(_, let width, let height) = error
      else {
        XCTFail("expected LutPngError.wrongDimensions, got \(error)")
        return
      }
      XCTAssertEqual(width, 256)
      XCTAssertEqual(height, 256)
    }
  }

  func testDecodeLutPng_nonImageFile_throws() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("lut_unit_test_\(UUID().uuidString).png")
    try XCTUnwrap("definitely not a PNG".data(using: .utf8)).write(to: url)
    // Depending on the OS, ImageIO reports a non-image file as either an
    // incomplete source or a decode failure — only require *some* LutPngError.
    XCTAssertThrowsError(try VideoFrameRenderer.decodeLutPng(path: url.path)) { error in
      XCTAssertTrue(
        error is VideoFrameRenderer.LutPngError,
        "expected a LutPngError, got \(error)")
    }
  }

  func testDecodeLutPng_missingFile_throws() {
    let path = "/nonexistent/lut_unit_test_\(UUID().uuidString).png"
    XCTAssertThrowsError(try VideoFrameRenderer.decodeLutPng(path: path)) { error in
      XCTAssertTrue(
        error is VideoFrameRenderer.LutPngError,
        "expected a LutPngError, got \(error)")
    }
  }

  // MARK: - loadLutTexture

  func testLoadLutTexture_setsPendingPathSynchronously() throws {
    let renderer = try makeRenderer()
    let path = "/tmp/test_lut_\(UUID().uuidString).png"
    renderer.loadLutTexture(path: path)
    XCTAssertEqual(renderer.pendingLutTexturePathForTesting, path)
  }

  func testLoadLutTexture_latestCallWinsPendingPath() throws {
    let renderer = try makeRenderer()
    renderer.loadLutTexture(path: "/nonexistent/stale_\(UUID().uuidString).png")
    let currentPath = "/nonexistent/current_\(UUID().uuidString).png"
    renderer.loadLutTexture(path: currentPath)
    XCTAssertEqual(renderer.pendingLutTexturePathForTesting, currentPath)
  }

  func testLoadLutTexture_validPathLoadsTexture() throws {
    let renderer = try makeRenderer()
    let pngPath = makeLutPNG()
    let exp = expectation(description: "lut texture loaded")
    renderer.loadLutTexture(path: pngPath)
    // Poll on a background queue; the decode runs asynchronously on
    // lutLoadQueue.
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
      let texture = renderer.lutTextureForTesting
      XCTAssertNotNil(
        texture, "lutTexture should be non-nil after loading a valid atlas")
      XCTAssertEqual(texture?.textureType, .type2D)
      XCTAssertEqual(texture?.pixelFormat, .rgba8Unorm)
      XCTAssertEqual(texture?.width, 512)
      XCTAssertEqual(texture?.height, 512)
      exp.fulfill()
    }
    waitForExpectations(timeout: 5)
  }

  func testLoadLutTexture_wrongSizePngLeavesTextureNil() throws {
    let renderer = try makeRenderer()
    let pngPath = makeLutPNG(side: 256)
    let exp = expectation(description: "load attempt finished")
    renderer.loadLutTexture(path: pngPath)
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
      XCTAssertNil(
        renderer.lutTextureForTesting,
        "lutTexture must remain nil for a wrong-size atlas")
      exp.fulfill()
    }
    waitForExpectations(timeout: 3)
  }

  func testLoadLutTexture_missingPathLeavesTextureNil() throws {
    let renderer = try makeRenderer()
    let exp = expectation(description: "load attempt finished")
    renderer.loadLutTexture(path: "/nonexistent/no_such_lut.png")
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
      XCTAssertNil(
        renderer.lutTextureForTesting,
        "lutTexture must remain nil when the file does not exist")
      exp.fulfill()
    }
    waitForExpectations(timeout: 3)
  }

  func testLoadLutTexture_cacheHitIsSynchronousAfterClear() throws {
    let renderer = try makeRenderer()
    // Unique temp path per test so the class-level NSCache cannot leak
    // entries across tests.
    let pngPath = makeLutPNG()
    let loaded = expectation(description: "first load completes")
    renderer.loadLutTexture(path: pngPath)
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
      XCTAssertNotNil(renderer.lutTextureForTesting)
      loaded.fulfill()
    }
    waitForExpectations(timeout: 5)

    renderer.clearLutTexture()
    XCTAssertNil(renderer.lutTextureForTesting)

    // Reloading the same path must hit the class-level cache and publish
    // the texture synchronously, without a queue round-trip.
    renderer.loadLutTexture(path: pngPath)
    XCTAssertNotNil(
      renderer.lutTextureForTesting,
      "second load of a cached path should complete synchronously")
  }

  // MARK: - clearLutTexture

  func testClearLutTexture_zeroesLutIntensityAndNilsTexture() throws {
    let renderer = try makeRenderer()
    renderer.updateUniforms { $0.lutIntensity = 1.0 }
    renderer.clearLutTexture()
    XCTAssertEqual(renderer.snapshotUniforms().lutIntensity, 0.0, accuracy: 0.0001)
    XCTAssertNil(renderer.lutTextureForTesting)
  }
}
