// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureResult
import android.os.Build
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The Exif a still capture carries, rebuilt from the camera's own capture result.
 *
 * An uncompressed capture has no Exif segment to copy: the tags the old path lifted off the ISP's
 * JPEG were written by the ISP as part of encoding it, and there is no longer a JPEG. The same
 * facts are available from the `CaptureResult` for the frame, which is where the ISP read them
 * from, so they are read there and written onto the file this plugin encodes instead.
 *
 * Everything here is best-effort. Metadata is worth having, but never worth failing a photo the
 * user has already taken, so a device that does not report a key simply omits its tag.
 */
object CaptureMetadata {
  private const val TAG = "CaptureMetadata"

  /**
   * Writes what is known about the capture onto `exif`.
   *
   * `takenAt` is the wall-clock time of the shutter press; `CaptureResult` timestamps are on a
   * monotonic clock with no defined epoch and so cannot date a photo.
   */
  fun populate(exif: ExifInterface, result: CaptureResult?, takenAt: Date) {
    exif.setAttribute(ExifInterface.TAG_MAKE, Build.MANUFACTURER)
    exif.setAttribute(ExifInterface.TAG_MODEL, Build.MODEL)

    val timestamp = DATE_FORMAT.format(takenAt)
    exif.setAttribute(ExifInterface.TAG_DATETIME, timestamp)
    exif.setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, timestamp)
    exif.setAttribute(ExifInterface.TAG_DATETIME_DIGITIZED, timestamp)

    if (result == null) {
      return
    }
    try {
      // Seconds, as a rational the tag can hold: `SENSOR_EXPOSURE_TIME` is in nanoseconds.
      result.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let {
        exif.setAttribute(ExifInterface.TAG_EXPOSURE_TIME, (it / 1_000_000_000.0).toString())
      }
      result.get(CaptureResult.SENSOR_SENSITIVITY)?.let {
        exif.setAttribute(ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY, it.toString())
      }
      result.get(CaptureResult.LENS_APERTURE)?.let {
        exif.setAttribute(ExifInterface.TAG_F_NUMBER, it.toString())
      }
      result.get(CaptureResult.LENS_FOCAL_LENGTH)?.let {
        exif.setAttribute(ExifInterface.TAG_FOCAL_LENGTH, asRational(it))
      }
      result.get(CaptureResult.LENS_FOCUS_DISTANCE)?.let {
        // Dioptres in the capture result, metres in the tag; 0 is "focused at infinity", which has
        // no finite distance to report.
        if (it > 0f) {
          exif.setAttribute(ExifInterface.TAG_SUBJECT_DISTANCE, asRational(1f / it))
        }
      }
      result.get(CaptureResult.CONTROL_AWB_MODE)?.let {
        exif.setAttribute(
            ExifInterface.TAG_WHITE_BALANCE,
            if (it == CameraMetadata.CONTROL_AWB_MODE_AUTO) {
              ExifInterface.WHITEBALANCE_AUTO.toString()
            } else {
              ExifInterface.WHITEBALANCE_MANUAL.toString()
            },
        )
      }
      result.get(CaptureResult.FLASH_STATE)?.let {
        // Bit 0 of the Exif flash tag is "flash fired"; the rest describe return detection and
        // modes a `CaptureResult` does not distinguish.
        val fired = it == CameraMetadata.FLASH_STATE_FIRED
        exif.setAttribute(ExifInterface.TAG_FLASH, if (fired) "1" else "0")
      }
      result.get(CaptureResult.CONTROL_AE_MODE)?.let {
        exif.setAttribute(
            ExifInterface.TAG_EXPOSURE_MODE,
            if (it == CameraMetadata.CONTROL_AE_MODE_OFF) {
              ExifInterface.EXPOSURE_MODE_MANUAL.toString()
            } else {
              ExifInterface.EXPOSURE_MODE_AUTO.toString()
            },
        )
      }
    } catch (e: IllegalArgumentException) {
      // `CaptureResult.get` throws for a key the device does not publish rather than returning
      // null, so one unsupported key must not cost the tags that follow it.
      Log.w(TAG, "Could not read part of the capture result", e)
    }
  }

  /** Exif wants rationals; a plain decimal is not valid in these tags on every reader. */
  private fun asRational(value: Float): String {
    val denominator = 1000
    return "${(value * denominator).toInt()}/$denominator"
  }

  private val DATE_FORMAT = SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US)
}
