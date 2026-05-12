// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The plane packs are the one part of the uncompressed capture path that has to understand a layout
 * the device chose, so each layout a `YUV_420_888` buffer is allowed to use is pinned here.
 *
 * Every chroma case describes the same 2x2 chroma image, so they can all be checked against one
 * expected interleaving.
 */
class CameraYuvImageTest {
  private val width = 2
  private val height = 2

  /** (U, V) pairs, row-major: the packed form every layout must produce. */
  private val expected = byteArrayOf(10, 20, 11, 21, 12, 22, 13, 23)

  @Test
  fun packsUnpaddedLuma() {
    val plane = buffer(1, 2, 3, 4)

    val packed = CameraYuvImage.packLuma(plane, rowStride = 2, width = width, height = height)

    assertEquals(listOf<Byte>(1, 2, 3, 4), packed.toByteArray().toList())
  }

  @Test
  fun packsLumaWithRowPadding() {
    // The common case at full resolution: rows padded out to a stride wider than the image. The
    // padding must not reach the texture, which is uploaded without any unpack row length.
    val plane = buffer(1, 2, 0, 0, 3, 4, 0, 0)

    val packed = CameraYuvImage.packLuma(plane, rowStride = 4, width = width, height = height)

    assertEquals(listOf<Byte>(1, 2, 3, 4), packed.toByteArray().toList())
  }

  @Test
  fun packsLumaWhoseLastRowIsNotPadded() {
    // A plane whose buffer ends on the final sample rather than on the padding after it, which is
    // how a device is free to report the last row.
    val plane = buffer(1, 2, 0, 0, 3, 4)

    val packed = CameraYuvImage.packLuma(plane, rowStride = 4, width = width, height = height)

    assertEquals(listOf<Byte>(1, 2, 3, 4), packed.toByteArray().toList())
  }

  @Test
  fun packedLumaOutlivesThePlaneItCameFrom() {
    // The pack is a copy, not a window: an `ImageProxy`'s planes are reclaimed when the image is
    // closed, and the upload is not guaranteed to have happened by then.
    val backing = ByteArray(4) { (it + 1).toByte() }
    val plane = ByteBuffer.wrap(backing)

    val packed = CameraYuvImage.packLuma(plane, rowStride = 2, width = width, height = height)
    backing.fill(0)

    assertEquals(listOf<Byte>(1, 2, 3, 4), packed.toByteArray().toList())
  }

  @Test
  fun packsFullyPlanarChroma() {
    // I420: separate U and V planes, one byte per sample.
    val u = buffer(10, 11, 12, 13)
    val v = buffer(20, 21, 22, 23)

    val packed =
        CameraYuvImage.packChroma(
            u = u,
            v = v,
            uRowStride = 2,
            vRowStride = 2,
            pixelStride = 1,
            width = width,
            height = height,
        )

    assertEquals(expected.toList(), packed.toByteArray().toList())
  }

  @Test
  fun packsPlanarChromaWithRowPadding() {
    // Rows padded out to a stride wider than the image, which is the common case at full
    // resolution: the padding must not reach the texture.
    val u = buffer(10, 11, 0, 0, 12, 13, 0, 0)
    val v = buffer(20, 21, 0, 0, 22, 23, 0, 0)

    val packed =
        CameraYuvImage.packChroma(
            u = u,
            v = v,
            uRowStride = 4,
            vRowStride = 4,
            pixelStride = 1,
            width = width,
            height = height,
        )

    assertEquals(expected.toList(), packed.toByteArray().toList())
  }

  @Test
  fun packsSemiPlanarNv12Chroma() {
    // NV12: one interleaved UVUV plane. The U plane's buffer starts at the first U.
    val interleaved = byteArrayOf(10, 20, 11, 21, 12, 22, 13, 23)
    val u = ByteBuffer.wrap(interleaved)
    // The V plane starts one byte in, on the first V sample.
    val v = ByteBuffer.wrap(interleaved, 1, interleaved.size - 1).slice()

    val packed =
        CameraYuvImage.packChroma(
            u = u,
            v = v,
            uRowStride = 4,
            vRowStride = 4,
            pixelStride = 2,
            width = width,
            height = height,
        )

    assertEquals(expected.toList(), packed.toByteArray().toList())
  }

  @Test
  fun packsSemiPlanarNv21Chroma() {
    // NV21: the same interleaving the other way round, VUVU. `planes[1]` (U) therefore points one
    // byte into the buffer, and reading pairs from there still yields (U, V) - the case that runs
    // a byte off the end on the final sample.
    val interleaved = byteArrayOf(20, 10, 21, 11, 22, 12, 23, 13)
    val u = ByteBuffer.wrap(interleaved, 1, interleaved.size - 1).slice()
    val v = ByteBuffer.wrap(interleaved)

    val packed =
        CameraYuvImage.packChroma(
            u = u,
            v = v,
            uRowStride = 4,
            vRowStride = 4,
            pixelStride = 2,
            width = width,
            height = height,
        )

    assertEquals(expected.toList(), packed.toByteArray().toList())
  }

  private fun buffer(vararg values: Int): ByteBuffer =
      ByteBuffer.wrap(ByteArray(values.size) { values[it].toByte() })

  private fun ByteBuffer.toByteArray(): ByteArray {
    position(0)
    return ByteArray(limit()).also { get(it) }
  }
}
