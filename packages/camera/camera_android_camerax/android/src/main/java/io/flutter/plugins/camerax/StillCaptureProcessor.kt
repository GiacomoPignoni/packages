// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.hardware.camera2.CaptureResult
import android.util.Log
import androidx.camera.core.ImageProxy
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.Date

/**
 * Turns one in-memory capture into the file (or pair of files) Dart expects.
 *
 * The Android counterpart of `SavePhotoDelegate` / `SavePhotoWithOriginalDelegate`: both files come
 * from the same shutter event, the original carrying the configured crop but none of the shader
 * effects.
 */
object StillCaptureProcessor {
  private const val TAG = "StillCaptureProcessor"
  private const val TEMPORARY_FILE_NAME = "CAP"
  private const val ORIGINAL_TEMPORARY_FILE_NAME = "CAP_ORIG"
  private const val JPG_FILE_TYPE = ".jpg"
  private const val JPEG_QUALITY = 95

  /**
   * Whether the device's `YUV_420_888` captures use full-range luma rather than studio swing.
   *
   * Not something a `YUV_420_888` buffer describes, and the one part of the layout that has to be
   * assumed. Full range is both the common case and what a JFIF JPEG uses, so it keeps this path's
   * colours on the ones the decode path produced. If photos come out with lifted, milky blacks and
   * clipped highlights, this is the switch: set it to false.
   */
  private const val YUV_FULL_RANGE = true

  /**
   * Renders `image` through the effects pipeline and writes the result to the cache directory.
   *
   * When `includeOriginal` is true the un-effected frame is written alongside it.
   */
  @JvmStatic
  fun process(
      image: ImageProxy,
      effectsManager: CameraEffectsManager,
      includeOriginal: Boolean,
      cacheDir: File,
      captureResult: CaptureResult?,
  ): CapturedPicturePaths =
      if (image.format == ImageFormat.YUV_420_888) {
        processYuv(image, effectsManager, includeOriginal, cacheDir, captureResult)
      } else {
        // A device that would not configure an uncompressed still stream, or a capture taken
        // before the buffer format was applied. Slower by a full JPEG decode, but correct.
        processJpeg(image, effectsManager, includeOriginal, cacheDir)
      }

  /**
   * The uncompressed path.
   *
   * No decode: the planes go to the GPU as they arrived and become RGB in the sampler. The original
   * is rendered too, through a neutral uniform set, since there is no decoded bitmap to take a
   * sub-rect of.
   */
  private fun processYuv(
      image: ImageProxy,
      effectsManager: CameraEffectsManager,
      includeOriginal: Boolean,
      cacheDir: File,
      captureResult: CaptureResult?,
  ): CapturedPicturePaths {
    val takenAt = Date()
    val yuv = CameraYuvImage.from(image)
    val rotation = quarterTurn(image.imageInfo.rotationDegrees)
    val transposed = CameraStillCaptureRenderer.isQuarterTurn(rotation)
    val uprightWidth = if (transposed) yuv.height else yuv.width
    val uprightHeight = if (transposed) yuv.width else yuv.height
    val plan = effectsManager.stillCapturePlan(uprightWidth, uprightHeight)

    val originalPath =
        if (includeOriginal) {
          val original =
              effectsManager.renderStill(
                  yuv,
                  effectsManager.neutralPlan(plan),
                  rotation,
                  YUV_FULL_RANGE,
              )
          try {
            write(original, cacheDir, ORIGINAL_TEMPORARY_FILE_NAME, null, captureResult, takenAt)
          } finally {
            original.recycle()
          }
        } else {
          null
        }

    val processedPath =
        try {
          val processed = effectsManager.renderStill(yuv, plan, rotation, YUV_FULL_RANGE)
          try {
            write(processed, cacheDir, TEMPORARY_FILE_NAME, null, captureResult, takenAt)
          } finally {
            processed.recycle()
          }
        } catch (e: Throwable) {
          originalPath?.let { File(it).delete() }
          throw e
        }

    return CapturedPicturePaths(originalPath = originalPath, processedPath = processedPath)
  }

  /** The compressed fallback, unchanged from before uncompressed capture was configured. */
  private fun processJpeg(
      image: ImageProxy,
      effectsManager: CameraEffectsManager,
      includeOriginal: Boolean,
      cacheDir: File,
  ): CapturedPicturePaths {
    val bytes = readBytes(image)
    val sourceExif = readExif(bytes)
    // Decoded once, in sensor orientation. The quarter turn that brings it upright is applied by
    // the shader for the processed photo and folded into the crop for the original, so no
    // full-size rotated copy is ever made.
    val decoded =
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalStateException("Failed to decode the captured image")

    try {
      val rotation = quarterTurn(image.imageInfo.rotationDegrees)
      // The plan is expressed in upright space, which is the decoded frame transposed on a
      // quarter turn.
      val transposed = CameraStillCaptureRenderer.isQuarterTurn(rotation)
      val uprightWidth = if (transposed) decoded.height else decoded.width
      val uprightHeight = if (transposed) decoded.width else decoded.height
      val plan = effectsManager.stillCapturePlan(uprightWidth, uprightHeight)

      val originalPath =
          if (includeOriginal) {
            val original = CameraStillCaptureRenderer.cropOriginal(decoded, plan, rotation)
            try {
              write(original, cacheDir, ORIGINAL_TEMPORARY_FILE_NAME, sourceExif, null, null)
            } finally {
              if (original !== decoded) original.recycle()
            }
          } else {
            null
          }

      val processedPath =
          try {
            val processed = effectsManager.renderStill(decoded, plan, rotation)
            try {
              write(processed, cacheDir, TEMPORARY_FILE_NAME, sourceExif, null, null)
            } finally {
              if (processed !== decoded) processed.recycle()
            }
          } catch (e: Throwable) {
            // The original, if any, was already written to disk; without this it would be
            // orphaned in the cache directory every time rendering the processed photo fails.
            originalPath?.let { File(it).delete() }
            throw e
          }

      return CapturedPicturePaths(originalPath = originalPath, processedPath = processedPath)
    } finally {
      decoded.recycle()
    }
  }

  private fun readBytes(image: ImageProxy): ByteArray {
    val buffer = image.planes[0].buffer
    val bytes = ByteArray(buffer.remaining())
    buffer.get(bytes)
    return bytes
  }

  /**
   * Normalises `ImageInfo.getRotationDegrees` to one of the four quarter turns.
   *
   * The API documents it as already being one of them; anything else is a device behaving oddly and
   * is treated as no rotation, since [CameraStillCaptureRenderer] has no transform for it.
   */
  private fun quarterTurn(rotationDegrees: Int): Int {
    val normalized = ((rotationDegrees % 360) + 360) % 360
    if (normalized % 90 != 0) {
      Log.w(TAG, "Ignoring an unexpected capture rotation of $rotationDegrees degrees")
      return 0
    }
    return normalized
  }

  /** The capture's Exif metadata, or null when it cannot be read. */
  private fun readExif(bytes: ByteArray): ExifInterface? =
      try {
        ExifInterface(ByteArrayInputStream(bytes))
      } catch (e: IOException) {
        Log.w(TAG, "Could not read the capture's Exif metadata", e)
        null
      }

  /**
   * Encodes `bitmap` to a new file and gives it the capture's metadata.
   *
   * Exactly one of `sourceExif` (the compressed path, which copies the ISP's own tags) and
   * `image`/`takenAt` (the uncompressed path, which has none to copy and rebuilds them from the
   * capture result) carries the metadata.
   */
  private fun write(
      bitmap: Bitmap,
      cacheDir: File,
      prefix: String,
      sourceExif: ExifInterface?,
      captureResult: CaptureResult?,
      takenAt: Date?,
  ): String {
    val file = File.createTempFile(prefix, JPG_FILE_TYPE, cacheDir)
    try {
      FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, it) }
      writeExif(sourceExif, captureResult, takenAt, file, bitmap.width, bitmap.height)
    } catch (e: Throwable) {
      // Nothing downstream will ever look at a file whose own write failed; without this it is
      // orphaned in the cache directory instead.
      file.delete()
      throw e
    }
    return file.absolutePath
  }

  /**
   * Copies the capture's Exif metadata onto a file the pipeline has just written.
   *
   * `Bitmap.compress` writes a bare JPEG, so without this every photo loses its capture time, GPS
   * fix, exposure settings and lens information — everything CameraX carried through on the old
   * file-backed capture path, and everything `VideoFrameRenderer` threads into its encodes on iOS.
   *
   * Only the tags that still describe the file after it has been re-encoded are copied. Tags
   * describing the *original* JPEG's layout are not: thumbnail and strip offsets point into a file
   * that no longer exists, and the maker note is usually keyed to absolute offsets in it.
   *
   * A failure here is logged rather than raised. Metadata is worth having, but not worth losing an
   * already-written photo over.
   */
  private fun writeExif(
      source: ExifInterface?,
      captureResult: CaptureResult?,
      takenAt: Date?,
      file: File,
      width: Int,
      height: Int,
  ) {
    if (source == null && takenAt == null) {
      return
    }
    try {
      val destination = ExifInterface(file)
      if (source != null) {
        for (tag in COPIED_TAGS) {
          source.getAttribute(tag)?.let { destination.setAttribute(tag, it) }
        }
      } else if (takenAt != null) {
        // An uncompressed capture carries no Exif segment; the same facts come off the capture
        // result instead.
        CaptureMetadata.populate(destination, captureResult, takenAt)
      }
      // The rotation is baked into the pixels of both outputs, so the tag has to say so. Carrying
      // the sensor's value over would have every viewer turn an already-upright photo a second
      // time.
      destination.setAttribute(
          ExifInterface.TAG_ORIENTATION,
          ExifInterface.ORIENTATION_NORMAL.toString(),
      )
      // Both outputs are cropped and possibly scaled, so the sensor's dimensions no longer
      // describe them.
      destination.setAttribute(ExifInterface.TAG_IMAGE_WIDTH, width.toString())
      destination.setAttribute(ExifInterface.TAG_IMAGE_LENGTH, height.toString())
      destination.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, width.toString())
      destination.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, height.toString())
      destination.saveAttributes()
    } catch (e: IOException) {
      Log.w(TAG, "Could not copy the capture's Exif metadata", e)
    }
  }

  /**
   * The tags carried from the capture onto the written files.
   *
   * Orientation and the dimension tags are deliberately absent: [copyExif] sets those from the
   * written image rather than copying them.
   */
  private val COPIED_TAGS =
      arrayOf(
          // When it was taken.
          ExifInterface.TAG_DATETIME,
          ExifInterface.TAG_DATETIME_ORIGINAL,
          ExifInterface.TAG_DATETIME_DIGITIZED,
          ExifInterface.TAG_OFFSET_TIME,
          ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
          ExifInterface.TAG_OFFSET_TIME_DIGITIZED,
          ExifInterface.TAG_SUBSEC_TIME,
          ExifInterface.TAG_SUBSEC_TIME_ORIGINAL,
          ExifInterface.TAG_SUBSEC_TIME_DIGITIZED,
          // What took it.
          ExifInterface.TAG_MAKE,
          ExifInterface.TAG_MODEL,
          ExifInterface.TAG_SOFTWARE,
          ExifInterface.TAG_BODY_SERIAL_NUMBER,
          ExifInterface.TAG_LENS_MAKE,
          ExifInterface.TAG_LENS_MODEL,
          ExifInterface.TAG_LENS_SERIAL_NUMBER,
          ExifInterface.TAG_LENS_SPECIFICATION,
          // How it was exposed.
          ExifInterface.TAG_EXPOSURE_TIME,
          ExifInterface.TAG_F_NUMBER,
          ExifInterface.TAG_EXPOSURE_PROGRAM,
          ExifInterface.TAG_EXPOSURE_MODE,
          ExifInterface.TAG_EXPOSURE_BIAS_VALUE,
          ExifInterface.TAG_EXPOSURE_INDEX,
          ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
          ExifInterface.TAG_ISO_SPEED,
          ExifInterface.TAG_SENSITIVITY_TYPE,
          ExifInterface.TAG_SHUTTER_SPEED_VALUE,
          ExifInterface.TAG_APERTURE_VALUE,
          ExifInterface.TAG_MAX_APERTURE_VALUE,
          ExifInterface.TAG_BRIGHTNESS_VALUE,
          ExifInterface.TAG_METERING_MODE,
          ExifInterface.TAG_LIGHT_SOURCE,
          ExifInterface.TAG_FLASH,
          ExifInterface.TAG_WHITE_BALANCE,
          ExifInterface.TAG_SCENE_CAPTURE_TYPE,
          ExifInterface.TAG_SENSING_METHOD,
          ExifInterface.TAG_SUBJECT_DISTANCE,
          ExifInterface.TAG_SUBJECT_DISTANCE_RANGE,
          ExifInterface.TAG_DIGITAL_ZOOM_RATIO,
          ExifInterface.TAG_FOCAL_LENGTH,
          ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
          ExifInterface.TAG_COLOR_SPACE,
          // Where it was taken.
          ExifInterface.TAG_GPS_VERSION_ID,
          ExifInterface.TAG_GPS_LATITUDE,
          ExifInterface.TAG_GPS_LATITUDE_REF,
          ExifInterface.TAG_GPS_LONGITUDE,
          ExifInterface.TAG_GPS_LONGITUDE_REF,
          ExifInterface.TAG_GPS_ALTITUDE,
          ExifInterface.TAG_GPS_ALTITUDE_REF,
          ExifInterface.TAG_GPS_TIMESTAMP,
          ExifInterface.TAG_GPS_DATESTAMP,
          ExifInterface.TAG_GPS_PROCESSING_METHOD,
          ExifInterface.TAG_GPS_SPEED,
          ExifInterface.TAG_GPS_SPEED_REF,
          ExifInterface.TAG_GPS_TRACK,
          ExifInterface.TAG_GPS_TRACK_REF,
          ExifInterface.TAG_GPS_IMG_DIRECTION,
          ExifInterface.TAG_GPS_IMG_DIRECTION_REF,
          ExifInterface.TAG_GPS_DOP,
          ExifInterface.TAG_GPS_MAP_DATUM,
          // Attribution.
          ExifInterface.TAG_ARTIST,
          ExifInterface.TAG_COPYRIGHT,
          ExifInterface.TAG_IMAGE_DESCRIPTION,
          ExifInterface.TAG_USER_COMMENT,
      )
}
