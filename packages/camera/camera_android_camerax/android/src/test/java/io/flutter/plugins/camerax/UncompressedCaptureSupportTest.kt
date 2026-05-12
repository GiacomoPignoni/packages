// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.util.Size
import androidx.camera.core.ImageCapture
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.mock
import org.robolectric.RobolectricTestRunner

/**
 * The two judgements the uncompressed capture path lets a device overturn it with.
 *
 * Both are size comparisons, and both have a wrong answer that is invisible in a photo: calling a
 * 16:9 crop of a 4:3 sensor a downgrade turns the feature off on hardware that was coping, and
 * calling a record-sized still acceptable leaves every photo at a fraction of the resolution it
 * should have been. The reading of the camera's characteristics around them needs a real device;
 * what is pinned here is where the line sits.
 */
@RunWith(RobolectricTestRunner::class)
class UncompressedCaptureSupportTest {
  private val fullSize = Size(4032, 3024)

  @Test
  fun isDowngrade_isFalseForAStillAtTheSizeJpegOffers() {
    assertFalse(UncompressedCaptureSupport.isDowngrade(fullSize, fullSize))
  }

  @Test
  fun isDowngrade_isFalseForADifferentlyShapedStillOfTheSameOrder() {
    // A 16:9 still on a 4:3 sensor is the crop that was asked for, not a fallback - and it is
    // exactly three quarters of the area, so the threshold has to clear that comfortably.
    assertFalse(UncompressedCaptureSupport.isDowngrade(Size(4032, 2268), fullSize))
  }

  @Test
  fun isDowngrade_isTrueForARecordSizedStill() {
    // What a device that cannot configure a full-resolution uncompressed still alongside the
    // preview and video streams falls back to, and the failure that is otherwise silent: 2MP where
    // the sensor offers 12.
    assertTrue(UncompressedCaptureSupport.isDowngrade(Size(1920, 1080), fullSize))
  }

  @Test
  fun offersFullSizeYuv_isTrueWhenTheFormatsReachTheSameSize() {
    assertTrue(UncompressedCaptureSupport.offersFullSizeYuv(fullSize, fullSize))
  }

  @Test
  fun offersFullSizeYuv_isFalseWhenUncompressedStillsAreCapped() {
    // Some devices publish their full sensor size for JPEG only. Every photo would come out at the
    // smaller size, so this one never gets as far as being bound.
    assertFalse(UncompressedCaptureSupport.offersFullSizeYuv(Size(1920, 1440), fullSize))
  }

  @Test
  fun offersFullSizeYuv_isFalseWhenEitherFormatIsMissing() {
    assertFalse(UncompressedCaptureSupport.offersFullSizeYuv(null, fullSize))
    assertFalse(UncompressedCaptureSupport.offersFullSizeYuv(fullSize, null))
  }

  @Test
  fun uncompressedIn_findsOnlyACaptureThisFeatureBuilt() {
    // Every other reason a bind can fail - an unavailable camera, a lifecycle that has already
    // stopped - must not cost the device a format it was coping with, so a bind is only blamed on
    // the buffer format when the format was in use.
    val marked = mock(ImageCapture::class.java)
    val plain = mock(ImageCapture::class.java)
    val preview: UseCase = mock(Preview::class.java)
    UncompressedCaptureSupport.markUncompressed(marked)

    assertSame(marked, UncompressedCaptureSupport.uncompressedIn(listOf(preview, marked)))
    assertNull(UncompressedCaptureSupport.uncompressedIn(listOf(preview, plain)))
    assertNull(UncompressedCaptureSupport.uncompressedIn(listOf(preview)))
  }
}
