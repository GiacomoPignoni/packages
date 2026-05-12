// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.graphics.ImageFormat
import androidx.annotation.VisibleForTesting
import androidx.camera.core.ImageProxy
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The planes of one `YUV_420_888` capture, packed the way the GL sampler wants them.
 *
 * `ImageCapture` is configured to deliver uncompressed frames, so the still path no longer decodes
 * a JPEG the ISP just encoded. What arrives instead is three planes whose layout the device is free
 * to choose, and the choice is what this class normalises: luma is packed tightly at full
 * resolution, and chroma into one interleaved (U, V) buffer at half resolution.
 *
 * Packing chroma on the CPU rather than uploading the planes as they lie is deliberate. The
 * alternative - a texture per plane, or reading a semi-planar plane as two channels - has to know
 * whether the device produced NV12, NV21 or I420, and reading the interleaved case straight from
 * the U plane runs one byte off the end of the buffer on the last texel. The pack is a row-wise
 * copy of a quarter-size plane: a few milliseconds against the ~140ms JPEG decode it replaces, and
 * it is layout-agnostic.
 *
 * Luma is copied rather than referenced for a different reason: lifetime. An `ImageProxy`'s planes
 * are windows onto a buffer the camera reclaims when the image is closed, and the upload is not
 * guaranteed to have finished by then. `CameraEffectsManager` gives up on a render thread that has
 * not answered in five seconds and lets the capture callback - and so the `close` in its `finally`
 * - return, while the block it gave up on stays queued and runs whenever that thread frees up.
 * Handing `glTexImage2D` a pointer into a reclaimed buffer is a native crash rather than a caught
 * exception, so nothing here outlives the image it came from. The copy is a plain memcpy of ~12MB
 * on a 12MP frame, against the ~140ms JPEG decode this path exists to avoid.
 */
class CameraYuvImage
private constructor(
    val width: Int,
    val height: Int,
    val luma: ByteBuffer,
    val chroma: ByteBuffer,
    val chromaWidth: Int,
    val chromaHeight: Int,
) {
  companion object {
    /**
     * Reads `image`, which must be `YUV_420_888`.
     *
     * Every plane is copied, so the result stays valid after `image` is closed.
     */
    fun from(image: ImageProxy): CameraYuvImage {
      require(image.format == ImageFormat.YUV_420_888) {
        "Expected a YUV_420_888 capture but got format ${image.format}"
      }
      val yPlane = image.planes[0]
      val uPlane = image.planes[1]
      val vPlane = image.planes[2]
      // 4:2:0, so chroma is half resolution on each axis. Rounded up, because an odd dimension
      // still needs the partial sample.
      val chromaWidth = (image.width + 1) / 2
      val chromaHeight = (image.height + 1) / 2
      return CameraYuvImage(
          width = image.width,
          height = image.height,
          luma =
              packLuma(
                  plane = yPlane.buffer,
                  rowStride = yPlane.rowStride,
                  width = image.width,
                  height = image.height,
              ),
          chroma =
              packChroma(
                  u = uPlane.buffer,
                  v = vPlane.buffer,
                  uRowStride = uPlane.rowStride,
                  vRowStride = vPlane.rowStride,
                  pixelStride = uPlane.pixelStride,
                  width = chromaWidth,
                  height = chromaHeight,
              ),
          chromaWidth = chromaWidth,
          chromaHeight = chromaHeight,
      )
    }

    /**
     * Copies the luma plane into a tightly packed buffer of its own.
     *
     * The row padding a device is free to leave between rows is dropped here rather than left for
     * `GL_UNPACK_ROW_LENGTH` to skip, so the upload needs no unpack state and the texture's rows
     * are exactly `width` bytes. `YUV_420_888` guarantees the luma plane a pixel stride of 1, so a
     * row is a contiguous run and this is one memcpy per row.
     */
    @VisibleForTesting
    internal fun packLuma(
        plane: ByteBuffer,
        rowStride: Int,
        width: Int,
        height: Int,
    ): ByteBuffer {
      val packed = ByteBuffer.allocateDirect(width * height).order(ByteOrder.nativeOrder())
      val row = ByteArray(width)
      for (y in 0 until height) {
        val offset = y * rowStride
        require(plane.limit() - offset >= width) {
          "A luma row runs past the end of its plane: needed $width bytes at $offset," +
              " found ${plane.limit() - offset}"
        }
        plane.position(offset)
        plane.get(row, 0, width)
        packed.put(row)
      }
      packed.position(0)
      return packed
    }

    /**
     * Packs the U and V planes into one tightly interleaved (U, V) buffer.
     *
     * Indexes both planes by their own `pixelStride`, which is what makes it layout-agnostic: I420
     * (`pixelStride == 1`, separate planes), NV12 (`2`, interleaved UVUV) and NV21 (`2`,
     * interleaved VUVU) all come out the same way round.
     *
     * The tempting shortcut for the interleaved layouts - bulk-copying a row straight out of the U
     * plane, since its bytes already alternate - is wrong for NV21: `planes[1]` points at the first
     * U, which in a VUVU buffer is followed by the *next* pixel's V, so every chroma sample lands
     * one pixel to the left. Each row is instead read once in bulk and de-interleaved through a
     * primitive array, which costs a few milliseconds on a quarter-size plane and cannot be fooled
     * by the ordering.
     */
    @VisibleForTesting
    internal fun packChroma(
        u: ByteBuffer,
        v: ByteBuffer,
        uRowStride: Int,
        vRowStride: Int,
        pixelStride: Int,
        width: Int,
        height: Int,
    ): ByteBuffer {
      val packed = ByteBuffer.allocateDirect(width * height * 2).order(ByteOrder.nativeOrder())
      // The span a row occupies, which is shorter than the stride on the last row of an
      // interleaved plane: the buffer ends on the final sample, not on the padding after it.
      val rowSpan = (width - 1) * pixelStride + 1
      val uRow = ByteArray(uRowStride.coerceAtLeast(rowSpan))
      val vRow = ByteArray(vRowStride.coerceAtLeast(rowSpan))
      val out = ByteArray(width * 2)
      for (y in 0 until height) {
        readRow(u, y * uRowStride, uRow, rowSpan)
        readRow(v, y * vRowStride, vRow, rowSpan)
        for (x in 0 until width) {
          out[x * 2] = uRow[x * pixelStride]
          out[x * 2 + 1] = vRow[x * pixelStride]
        }
        packed.put(out)
      }
      packed.position(0)
      return packed
    }

    /** Reads one plane row into `row`, taking as much as the buffer still holds. */
    private fun readRow(plane: ByteBuffer, offset: Int, row: ByteArray, minimumBytes: Int) {
      val available = minOf(row.size, plane.limit() - offset)
      require(available >= minimumBytes) {
        "A chroma row runs past the end of its plane: needed $minimumBytes bytes at $offset," +
            " found $available"
      }
      plane.position(offset)
      plane.get(row, 0, available)
    }
  }
}
