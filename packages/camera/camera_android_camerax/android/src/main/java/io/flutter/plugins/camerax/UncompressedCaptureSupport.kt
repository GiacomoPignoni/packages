// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.params.StreamConfigurationMap
import android.util.Log
import android.util.Size
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraInfo
import androidx.camera.core.ImageCapture
import androidx.camera.core.UseCase
import java.util.Collections
import java.util.WeakHashMap

/**
 * Decides whether stills are captured uncompressed on this device, and withdraws that decision when
 * the device turns out not to cope.
 *
 * Asking `ImageCapture` for a `YUV_420_888` buffer skips the ISP's JPEG encode and the decode that
 * used to undo it, which is worth ~140ms of CPU on a 12MP frame. What it costs is a guarantee: a
 * full-resolution JPEG still stream alongside a preview and a video stream is in the camera2
 * guaranteed stream-combination tables at every hardware level, and the uncompressed equivalent is
 * not below `FULL`. A device that cannot manage it has two ways of saying so, and the quieter one
 * is the more damaging:
 * - it refuses the configuration at bind time, which is loud and recoverable; or
 * - CameraX negotiates a smaller `YUV_420_888` size than the JPEG stream would have been, and every
 *   photo silently comes out at a fraction of the sensor's resolution.
 *
 * So the format is chosen per device rather than compiled in, and both failures feed back: the
 * first through [onBindFailed], the second through [onBound]. Either withdraws uncompressed capture
 * for the rest of the process, and since the Dart side builds a fresh `ImageCapture` every time it
 * opens a camera, the next camera to open is already on the JPEG path.
 */
object UncompressedCaptureSupport {
  private const val TAG = "UncompressedCapture"

  /**
   * How much smaller than the camera's largest JPEG a negotiated still may be before it counts as a
   * downgrade rather than as rounding.
   *
   * Compared by area, and generous on purpose. The two formats' size lists need not offer the same
   * shapes, and a 4:3 sensor whose largest uncompressed still is a 16:9 crop of its largest JPEG is
   * doing what was asked rather than falling back - at exactly three quarters of the area, which is
   * why the line cannot sit there. A real downgrade is not a matter of shape: it is a device
   * dropping from `MAXIMUM` to `RECORD`, which is 12MP to 2MP, and lands far below this.
   */
  private const val ACCEPTABLE_AREA_FRACTION = 0.5

  /** Set once a device has failed at either of the two ways it can fail. */
  @Volatile private var withdrawn = false

  /** The device capability query's answer, computed once. */
  @Volatile private var deviceSupport: Boolean? = null

  /**
   * The `ImageCapture` instances that were built uncompressed.
   *
   * So a bind failure is only blamed on the buffer format when the format was actually in use.
   * Weakly held: a use case that has gone away cannot be the subject of a later bind.
   */
  private val uncompressedCaptures: MutableSet<ImageCapture> =
      Collections.synchronizedSet(Collections.newSetFromMap(WeakHashMap()))

  /**
   * Whether the next `ImageCapture` should ask for an uncompressed buffer.
   *
   * The capability half of the answer is cached: it reads camera characteristics, which do not
   * change while the process is alive.
   */
  @JvmStatic
  fun isSupported(context: Context): Boolean {
    if (withdrawn) {
      return false
    }
    return deviceSupport ?: queryDeviceSupport(context).also { deviceSupport = it }
  }

  /** Records that `imageCapture` was built with an uncompressed buffer format. */
  @JvmStatic
  fun markUncompressed(imageCapture: ImageCapture) {
    uncompressedCaptures.add(imageCapture)
  }

  /**
   * Withdraws uncompressed capture if the bind that just failed involved an uncompressed still.
   *
   * The caller still fails this bind - there is no second `ImageCapture` to retry it with, since
   * the Dart side owns the one that was passed in. What this buys is that the *next* camera the
   * plugin opens builds a JPEG `ImageCapture` and works, rather than the device being unable to
   * open a camera until the app is reinstalled.
   */
  @JvmStatic
  fun onBindFailed(useCases: List<UseCase>, cause: Throwable) {
    // Total, like [onBound] and for a sharper version of the same reason: this runs inside the
    // catch block that is about to rethrow `cause`, and an exception escaping here would replace
    // the real failure with this one.
    try {
      if (withdrawn || uncompressedIn(useCases) == null) {
        return
      }
      withdraw(
          "binding an uncompressed still stream failed (${cause.message}); the next camera to" +
              " open will capture JPEG")
    } catch (e: Exception) {
      Log.w(TAG, "Could not check whether the failed bind used an uncompressed still", e)
    }
  }

  /**
   * Checks what CameraX negotiated for an uncompressed still, and withdraws on a downgrade.
   *
   * The resolution is logged either way. Without it the silent failure this guards against stays
   * silent: nothing else in the pipeline knows what size the still stream was supposed to be, so a
   * photo that comes back at a fraction of the sensor's resolution looks like a photo.
   */
  @JvmStatic
  fun onBound(useCases: List<UseCase>, cameraInfo: CameraInfo?) {
    // Total: this runs on the success path of a bind that has already worked, so nothing it does
    // may turn a camera that opened into a camera that did not.
    try {
      val imageCapture = uncompressedIn(useCases) ?: return
      val negotiated = imageCapture.resolutionInfo?.resolution
      if (negotiated == null) {
        Log.w(TAG, "The uncompressed still stream reported no resolution after binding")
        return
      }
      val largestJpeg = cameraInfo?.let { largestSizeFor(it, ImageFormat.JPEG) }
      Log.i(TAG, "Uncompressed still stream bound at $negotiated (largest JPEG: $largestJpeg)")
      if (largestJpeg == null || withdrawn) {
        return
      }
      if (isDowngrade(negotiated, largestJpeg)) {
        withdraw(
            "the uncompressed still stream negotiated $negotiated where JPEG offers up to" +
                " $largestJpeg; the next camera to open will capture JPEG")
      }
    } catch (e: Exception) {
      Log.w(TAG, "Could not check the still stream's negotiated resolution", e)
    }
  }

  private fun withdraw(reason: String) {
    withdrawn = true
    Log.w(TAG, "Falling back to compressed still capture: $reason")
  }

  /** The uncompressed `ImageCapture` among `useCases`, or null if there is none. */
  @VisibleForTesting
  internal fun uncompressedIn(useCases: List<UseCase>): ImageCapture? =
      useCases.filterIsInstance<ImageCapture>().firstOrNull { uncompressedCaptures.contains(it) }

  /**
   * Whether a negotiated still size is a downgrade from what JPEG offers rather than a crop of it.
   */
  @VisibleForTesting
  internal fun isDowngrade(negotiated: Size, largestJpeg: Size): Boolean =
      area(negotiated) < area(largestJpeg) * ACCEPTABLE_AREA_FRACTION

  /** Whether a camera offering these two largest still sizes can be asked for an uncompressed. */
  @VisibleForTesting
  internal fun offersFullSizeYuv(largestYuv: Size?, largestJpeg: Size?): Boolean =
      largestYuv != null && largestJpeg != null && area(largestYuv) >= area(largestJpeg)

  /**
   * Whether every camera this plugin can open offers `YUV_420_888` at the size it offers JPEG.
   *
   * This is the part of the risk that can be settled before anything is bound: a device whose
   * largest uncompressed still is smaller than its largest JPEG will downgrade every photo, and it
   * says so in its characteristics. The stream-*combination* limits that produce the same downgrade
   * only for certain sets of streams cannot be read this way, which is what [onBound] is for.
   */
  private fun queryDeviceSupport(context: Context): Boolean {
    val manager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
    if (manager == null) {
      Log.w(TAG, "No camera manager available; capturing JPEG")
      return false
    }
    return try {
      // Only the cameras the plugin can select. An external or depth camera that will never be
      // opened must not veto the format for the ones that will.
      val ids =
          manager.cameraIdList.filter { id ->
            val facing =
                manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
            facing == CameraMetadata.LENS_FACING_BACK ||
                facing == CameraMetadata.LENS_FACING_FRONT
          }
      if (ids.isEmpty()) {
        Log.w(TAG, "No front or back camera found; capturing JPEG")
        false
      } else {
        ids.all { id -> supportsFullSizeYuv(manager, id) }
      }
    } catch (e: Exception) {
      // A capability query that cannot be answered is not a reason to fail; it is a reason to take
      // the path that has always worked. Broadly caught because `CameraManager` throws both
      // `CameraAccessException` and, on some devices, unchecked failures from the HAL.
      Log.w(TAG, "Could not read the cameras' still-capture formats; capturing JPEG", e)
      false
    }
  }

  private fun supportsFullSizeYuv(manager: CameraManager, cameraId: String): Boolean {
    val map =
        manager
            .getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
    if (map == null) {
      Log.w(TAG, "Camera $cameraId reports no stream configuration map; capturing JPEG")
      return false
    }
    val largestYuv = largestSize(map, ImageFormat.YUV_420_888)
    val largestJpeg = largestSize(map, ImageFormat.JPEG)
    if (offersFullSizeYuv(largestYuv, largestJpeg)) {
      return true
    }
    Log.w(
        TAG,
        "Camera $cameraId tops out at $largestYuv uncompressed against $largestJpeg as JPEG;" +
            " capturing JPEG so photos keep the sensor's resolution",
    )
    return false
  }

  /** The largest still size `cameraInfo`'s camera offers in `format`, or null if it offers none. */
  @OptIn(markerClass = [ExperimentalCamera2Interop::class])
  private fun largestSizeFor(cameraInfo: CameraInfo, format: Int): Size? =
      try {
        Camera2CameraInfo.from(cameraInfo)
            .getCameraCharacteristic(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.let { largestSize(it, format) }
      } catch (e: Exception) {
        // Only ever used to put a bound resolution in context, so it is never worth raising over.
        Log.w(TAG, "Could not read the camera's supported sizes", e)
        null
      }

  private fun largestSize(map: StreamConfigurationMap, format: Int): Size? =
      map.getOutputSizes(format)?.maxByOrNull { area(it) }

  private fun area(size: Size): Long = size.width.toLong() * size.height.toLong()
}
