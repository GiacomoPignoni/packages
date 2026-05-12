// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraGeometryTest {
  @Test
  fun evenRound_neverProducesAnOddDimension() {
    // H.264/HEVC encoders reject odd dimensions on most configurations.
    for (value in 0..200) {
      assertEquals(0, CameraGeometry.evenRound(value.toFloat()) % 2)
    }
  }

  @Test
  fun evenRound_hasAFloorOfTwo() {
    assertEquals(2, CameraGeometry.evenRound(0f))
    assertEquals(2, CameraGeometry.evenRound(1f))
    assertEquals(2, CameraGeometry.evenRound(-10f))
  }

  @Test
  fun croppedDimensions_cropsTopAndBottomForAWiderTarget() {
    // 1080x1920 (9:16) cropped to 16:9 keeps the full width.
    val crop = CameraGeometry.croppedDimensions(1080, 1920, 16.0 / 9.0)
    assertEquals(1080, crop.width)
    assertEquals(608, crop.height)
    assertEquals(1f, crop.uvScaleX, 1e-6f)
    assertTrue(crop.uvScaleY < 1f)
  }

  @Test
  fun croppedDimensions_cropsLeftAndRightForATallerTarget() {
    // 1920x1080 (16:9) cropped to 1:1 keeps the full height.
    val crop = CameraGeometry.croppedDimensions(1920, 1080, 1.0)
    assertEquals(1080, crop.width)
    assertEquals(1080, crop.height)
    assertTrue(crop.uvScaleX < 1f)
    assertEquals(1f, crop.uvScaleY, 1e-6f)
  }

  @Test
  fun croppedDimensions_isIdentityWhenTheRatioAlreadyMatches() {
    val crop = CameraGeometry.croppedDimensions(1920, 1080, 1920.0 / 1080.0)
    assertEquals(1920, crop.width)
    assertEquals(1080, crop.height)
    assertEquals(1f, crop.uvScaleX, 1e-6f)
    assertEquals(1f, crop.uvScaleY, 1e-6f)
  }

  @Test
  fun croppedDimensions_treatsUnusableRatiosAsNoCrop() {
    for (ratio in listOf(null, 0.0, -1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
      val crop = CameraGeometry.croppedDimensions(1920, 1080, ratio)
      assertEquals("ratio $ratio should not crop", 1920, crop.width)
      assertEquals("ratio $ratio should not crop", 1080, crop.height)
      assertEquals(1f, crop.uvScaleX, 1e-6f)
      assertEquals(1f, crop.uvScaleY, 1e-6f)
    }
  }

  @Test
  fun croppedDimensions_roundsAnOddSourceToEvenEvenWithoutACrop() {
    val crop = CameraGeometry.croppedDimensions(1921, 1081, null)
    assertEquals(0, crop.width % 2)
    assertEquals(0, crop.height % 2)
  }

  @Test
  fun grainUvScale_makesOneTileSpanTheShorterSideAtOne() {
    val (x, y) = CameraGeometry.grainUvScale(1f, 1920, 1080)
    // The shorter side is covered by exactly one tile; the longer side repeats it.
    assertEquals(1f, y, 1e-4f)
    assertEquals(1920f / 1080f, x, 1e-4f)
  }

  @Test
  fun grainUvScale_isResolutionIndependent() {
    // The same grain size has to look the same in the preview, a photo and a video despite their
    // different pixel dimensions, so the UV scale only depends on the aspect ratio.
    val (previewX, previewY) = CameraGeometry.grainUvScale(0.1f, 1280, 720)
    val (photoX, photoY) = CameraGeometry.grainUvScale(0.1f, 3840, 2160)
    assertEquals(previewX / previewY, photoX / photoY, 1e-4f)
  }

  @Test
  fun grainUvScale_survivesAZeroGrainSize() {
    val (x, y) = CameraGeometry.grainUvScale(0f, 1920, 1080)
    assertTrue(x.isFinite())
    assertTrue(y.isFinite())
  }

  @Test
  fun effectiveAspectRatio_keepsARatioThatMatchesTheSourceOrientation() {
    assertEquals(1.5, CameraGeometry.effectiveAspectRatio(1.5, 1920, 1080)!!, 1e-9)
    assertEquals(0.75, CameraGeometry.effectiveAspectRatio(0.75, 1080, 1920)!!, 1e-9)
  }

  @Test
  fun effectiveAspectRatio_invertsARatioThatFightsTheSourceOrientation() {
    // The preview arrives in sensor orientation, which is landscape, while the shape the user asked
    // for is expressed in the orientation they see. A 3:4 request has to crop to 4:3 in the buffer
    // so that it reads as 3:4 once the buffer is rotated for display.
    assertEquals(4.0 / 3.0, CameraGeometry.effectiveAspectRatio(0.75, 1920, 1080)!!, 1e-9)
    assertEquals(0.75, CameraGeometry.effectiveAspectRatio(4.0 / 3.0, 1080, 1920)!!, 1e-9)
  }

  @Test
  fun effectiveAspectRatio_leavesSquareAndUnusableRatiosAlone() {
    assertEquals(1.0, CameraGeometry.effectiveAspectRatio(1.0, 1920, 1080)!!, 1e-9)
    assertNull(CameraGeometry.effectiveAspectRatio(null, 1920, 1080))
    // An unusable ratio is passed straight through rather than inverted; `croppedDimensions` is
    // what decides it means "no crop".
    assertEquals(0.0, CameraGeometry.effectiveAspectRatio(0.0, 1920, 1080)!!, 1e-9)
    val crop = CameraGeometry.croppedDimensions(1920, 1080, 0.0)
    assertEquals(1f, crop.uvScaleX, 1e-6f)
    assertEquals(1f, crop.uvScaleY, 1e-6f)
  }

  @Test
  fun croppedDimensions_squareCropOfALandscapeOutputNarrowsOnlyTheHorizontalUv() {
    val crop = CameraGeometry.croppedDimensions(1920, 1080, 1.0)
    assertEquals(1080, crop.width)
    assertEquals(1080, crop.height)
    assertEquals(1080f / 1920f, crop.uvScaleX, 1e-6f)
    assertEquals(1f, crop.uvScaleY, 1e-6f)
  }
}
