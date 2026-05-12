// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import androidx.camera.core.ImageCapture
import java.util.Collections
import java.util.WeakHashMap

/**
 * Keeps the camera's own result for the last few frames, so a still capture can be given the
 * exposure it was actually taken with.
 *
 * An uncompressed capture arrives with no Exif segment - the tags the JPEG path copied were written
 * by the ISP as part of encoding, and there is no longer an encode - so the shutter speed, ISO,
 * aperture and the rest have to come from the request that produced the frame. This is the
 * supported way to reach it: a session capture callback attached through `Camera2Interop`, the same
 * mechanism [ImageAnalysisProxyApi] and [VideoCaptureProxyApi] already use.
 *
 * Results are held by sensor timestamp because the callback sees every frame in the session, the
 * preview's included, and the one that matters is the one whose timestamp the delivered
 * [androidx.camera.core.ImageProxy] carries.
 */
class CaptureResultCache {
  private val results = LinkedHashMap<Long, TotalCaptureResult>()
  private var latest: TotalCaptureResult? = null

  /** Hand this to `Camera2Interop.Extender.setSessionCaptureCallback`. */
  val captureCallback: CameraCaptureSession.CaptureCallback =
      object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureCompleted(
            session: CameraCaptureSession,
            request: CaptureRequest,
            result: TotalCaptureResult,
        ) {
          val timestamp = result.get(CaptureResult.SENSOR_TIMESTAMP) ?: return
          synchronized(this@CaptureResultCache) {
            latest = result
            results[timestamp] = result
            // The still's result is looked up as soon as the frame is delivered, so only a handful
            // of frames ever need to be kept - and at 30fps an unbounded map would grow for the
            // life of the camera.
            while (results.size > MAX_RESULTS) {
              val eldest = results.keys.iterator()
              eldest.next()
              eldest.remove()
            }
          }
        }
      }

  /**
   * The result for the frame captured at `timestamp`, or the most recent one.
   *
   * The fallback is deliberate: a device whose delivered image and capture result disagree on the
   * timestamp still gets metadata from the right moment, give or take a frame, which is much closer
   * to the truth than no exposure data at all.
   */
  fun resultFor(timestamp: Long): CaptureResult? =
      synchronized(this) { results[timestamp] ?: latest }

  companion object {
    private const val MAX_RESULTS = 8

    /**
     * The cache belonging to each live [ImageCapture].
     *
     * Held here rather than on the ProxyApi, which does not outlive a call:
     * `getPigeonApiImageCapture` builds a fresh one every time, so a field there would be shared
     * with nothing. Weak keys so a discarded use case takes its cache with it.
     */
    private val caches: MutableMap<ImageCapture, CaptureResultCache> =
        Collections.synchronizedMap(WeakHashMap())

    @JvmStatic
    fun register(imageCapture: ImageCapture, cache: CaptureResultCache) {
      caches[imageCapture] = cache
    }

    /** The cache for `imageCapture`, or null if none was attached. */
    @JvmStatic fun of(imageCapture: ImageCapture): CaptureResultCache? = caches[imageCapture]
  }
}
