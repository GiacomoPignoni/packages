// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The still-capture rotation, which is applied by the shader rather than by rotating the decoded
 * bitmap.
 *
 * A transposed or mis-signed matrix here would silently produce photos rotated or mirrored the
 * wrong way, and nothing else in the suite would notice.
 */
@RunWith(RobolectricTestRunner::class)
class CameraStillCaptureRendererTest {
  /** Applies a column-major mat4 to an output-space UV, the way `sampleSource` does. */
  private fun map(matrix: FloatArray, u: Float, v: Float): Pair<Float, Float> {
    val x = matrix[0] * u + matrix[4] * v + matrix[12]
    val y = matrix[1] * u + matrix[5] * v + matrix[13]
    return x to y
  }

  private fun assertMaps(
      matrix: FloatArray,
      from: Pair<Float, Float>,
      to: Pair<Float, Float>,
      corner: String,
  ) {
    val (x, y) = map(matrix, from.first, from.second)
    assertEquals("$corner u", to.first, x, 1e-6f)
    assertEquals("$corner v", to.second, y, 1e-6f)
  }

  @Test
  fun uprightTransform_isTheIdentityForAnUnrotatedCapture() {
    // Null rather than an identity matrix; the pipeline substitutes its own.
    assertNull(CameraStillCaptureRenderer.uprightTransform(0))
  }

  @Test
  fun uprightTransform_turnsAQuarterTurnClockwise() {
    val matrix = CameraStillCaptureRenderer.uprightTransform(90)!!
    // Rotating the source 90 degrees clockwise sends its top-left corner to the output's top
    // right, so the output's top right has to sample the source's top left.
    assertMaps(matrix, 1f to 0f, 0f to 0f, "top-right reads source top-left")
    assertMaps(matrix, 1f to 1f, 1f to 0f, "bottom-right reads source top-right")
    assertMaps(matrix, 0f to 1f, 1f to 1f, "bottom-left reads source bottom-right")
    assertMaps(matrix, 0f to 0f, 0f to 1f, "top-left reads source bottom-left")
  }

  @Test
  fun uprightTransform_turnsAHalfTurn() {
    val matrix = CameraStillCaptureRenderer.uprightTransform(180)!!
    assertMaps(matrix, 0f to 0f, 1f to 1f, "top-left reads source bottom-right")
    assertMaps(matrix, 1f to 1f, 0f to 0f, "bottom-right reads source top-left")
  }

  @Test
  fun uprightTransform_turnsThreeQuarterTurnsClockwise() {
    val matrix = CameraStillCaptureRenderer.uprightTransform(270)!!
    // The inverse of the 90 degree case.
    assertMaps(matrix, 0f to 0f, 1f to 0f, "top-left reads source top-right")
    assertMaps(matrix, 0f to 1f, 0f to 0f, "bottom-left reads source top-left")
    assertMaps(matrix, 1f to 1f, 0f to 1f, "bottom-right reads source bottom-left")
    assertMaps(matrix, 1f to 0f, 1f to 1f, "top-right reads source bottom-right")
  }

  @Test
  fun uprightTransform_staysWithinTheUnitSquare() {
    // Every corner has to land back on a corner: a matrix that sampled outside [0, 1] would clamp
    // against the edge and smear the border of the photo.
    for (rotation in listOf(90, 180, 270)) {
      val matrix = CameraStillCaptureRenderer.uprightTransform(rotation)!!
      for (u in listOf(0f, 1f)) {
        for (v in listOf(0f, 1f)) {
          val (x, y) = map(matrix, u, v)
          assertTrue("rotation $rotation maps ($u, $v) inside the unit square", x in 0f..1f)
          assertTrue("rotation $rotation maps ($u, $v) inside the unit square", y in 0f..1f)
        }
      }
    }
  }

  @Test
  fun isQuarterTurn_onlyForTheTransposingRotations() {
    assertTrue(CameraStillCaptureRenderer.isQuarterTurn(90))
    assertTrue(CameraStillCaptureRenderer.isQuarterTurn(270))
    assertFalse(CameraStillCaptureRenderer.isQuarterTurn(0))
    assertFalse(CameraStillCaptureRenderer.isQuarterTurn(180))
  }
}
