// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.graphics.Bitmap
import android.graphics.Matrix
import android.opengl.GLES30
import androidx.annotation.VisibleForTesting
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Renders a still capture through [CameraGlPipeline] off-screen.
 *
 * The Metal renderer has a dedicated photo command queue for this; here the still shares the
 * preview's context and therefore its compiled programs, grain texture and LUT — a photo cannot
 * drift from what the preview showed.
 *
 * Every function must run on the thread that owns the EGL context.
 */
object CameraStillCaptureRenderer {
  /**
   * Target-set key for the still-capture path, distinct from the `SurfaceOutput` instances the live
   * outputs are keyed by.
   */
  private val TARGET_KEY = Any()

  /**
   * Renders `bitmap` at the plan's output size and reads the result back.
   *
   * `rotationDegrees` is the capture's sensor orientation, a multiple of 90. It is applied by the
   * shader through the source transform rather than by rotating `bitmap`, which saves the path a
   * second full-size allocation and a full-frame resample.
   */
  internal fun render(
      eglCore: EglCore,
      pipeline: CameraGlPipeline,
      bitmap: Bitmap,
      plan: CameraEffectsManager.StillCapturePlan,
      rotationDegrees: Int,
  ): Bitmap {
    // The frame is rendered into the FBO below; the context just needs some surface bound, and the
    // shared 1x1 one is always available.
    eglCore.makeDefaultCurrent()

    val sourceTexture = GlUtil.createTextureFromBitmap(bitmap, GLES30.GL_CLAMP_TO_EDGE)
    return renderSource(
        pipeline = pipeline,
        source =
            CameraGlPipeline.Source(
                textureId = sourceTexture,
                kind = CameraGlPipeline.SourceKind.BITMAP,
                transform = uprightTransform(rotationDegrees),
            ),
        sourceTextures = intArrayOf(sourceTexture),
        plan = plan,
    )
  }

  /**
   * Renders an uncompressed capture, converting it to RGB in the sampler.
   *
   * The path a still normally takes. Two textures go up instead of one, and they carry half the
   * bytes of the RGBA the JPEG path used to decode to - a 12MP frame is 18.7MB of luma and chroma
   * against 50MB of RGBA - so this is both a decode and an upload cheaper.
   */
  internal fun render(
      eglCore: EglCore,
      pipeline: CameraGlPipeline,
      yuv: CameraYuvImage,
      plan: CameraEffectsManager.StillCapturePlan,
      rotationDegrees: Int,
      fullRange: Boolean,
  ): Bitmap {
    eglCore.makeDefaultCurrent()

    val lumaTexture = GlUtil.createLumaTexture(yuv.luma, yuv.width, yuv.height)
    val chromaTexture = GlUtil.createChromaTexture(yuv.chroma, yuv.chromaWidth, yuv.chromaHeight)
    return renderSource(
        pipeline = pipeline,
        source =
            CameraGlPipeline.Source(
                textureId = lumaTexture,
                kind = CameraGlPipeline.SourceKind.YUV,
                chromaTextureId = chromaTexture,
                yuvFullRange = fullRange,
                transform = uprightTransform(rotationDegrees),
            ),
        sourceTextures = intArrayOf(lumaTexture, chromaTexture),
        plan = plan,
    )
  }

  /** Renders a prepared source into a new bitmap, releasing `sourceTextures` when done. */
  private fun renderSource(
      pipeline: CameraGlPipeline,
      source: CameraGlPipeline.Source,
      sourceTextures: IntArray,
      plan: CameraEffectsManager.StillCapturePlan,
  ): Bitmap {
    val targetTexture =
        GlUtil.createTargetTexture(plan.outputWidth, plan.outputHeight, halfFloat = false)
    val framebuffer = GlUtil.createFramebuffer(targetTexture)
    try {
      pipeline.render(
          source = source,
          uniforms = plan.uniforms,
          outputWidth = plan.outputWidth,
          outputHeight = plan.outputHeight,
          framebuffer = framebuffer,
          targetKey = TARGET_KEY,
          // Rasterize upside down so the bottom-up `glReadPixels` below lands the rows the right
          // way up. The alternative - flipping the pixels afterwards - costs two full-frame
          // integer arrays, which for a 12MP capture is around 96MB of pure churn.
          flipOutputY = true,
      )
      return readPixels(framebuffer, plan.outputWidth, plan.outputHeight)
    } finally {
      GlUtil.deleteFramebuffer(framebuffer)
      GlUtil.deleteTexture(targetTexture)
      sourceTextures.forEach(GlUtil::deleteTexture)
      // A quarter of a full-resolution photo on each axis is tens of megabytes per target, far too
      // much to pin between captures for a path that runs once a shutter press. The live outputs
      // keep theirs; this one is rebuilt next time. Matches `releasePhotoAuxBlurResources`.
      pipeline.releaseTargets(TARGET_KEY)
    }
  }

  /**
   * Applies the same aspect-ratio crop, capture scale and rotation as [render], without any shader
   * effect.
   *
   * This is the un-effected original of `takePictureWithOriginal` on the compressed fallback path.
   * Cropping in software rather than through the pipeline keeps the original's pixels bit-exact
   * with the decoded JPEG's — a multiple-of-90 rotation with filtering off is a pure pixel
   * permutation, so that holds even when the frame has to be turned upright.
   *
   * The uncompressed path cannot do this: its frame only becomes RGB in the sampler, so there is no
   * decoded bitmap to take a sub-rect of and the original goes through the pipeline with the
   * neutral uniform set [CameraEffectsManager.neutralPlan] builds. Both are the frame with no
   * effect applied; only this one is also a byte-for-byte copy.
   *
   * `bitmap` is the capture as decoded, still in sensor orientation.
   */
  internal fun cropOriginal(
      bitmap: Bitmap,
      plan: CameraEffectsManager.StillCapturePlan,
      rotationDegrees: Int,
  ): Bitmap {
    // The capture scale narrows the sampled area inside the aspect-ratio crop, so the region to
    // keep is the crop shrunk by the scale, centred on the same point.
    val scale = plan.uniforms.captureScale.coerceIn(0f, 1f)
    var width = max(2, (plan.crop.width * scale).roundToInt())
    var height = max(2, (plan.crop.height * scale).roundToInt())
    // The plan is expressed in upright space while `bitmap` has not been turned yet, so a quarter
    // turn means the rectangle to cut out is the transpose of the one the plan describes.
    if (isQuarterTurn(rotationDegrees)) {
      val swap = width
      width = height
      height = swap
    }
    width = width.coerceAtMost(bitmap.width)
    height = height.coerceAtMost(bitmap.height)
    val x = ((bitmap.width - width) / 2).coerceAtLeast(0)
    val y = ((bitmap.height - height) / 2).coerceAtLeast(0)

    if (rotationDegrees == 0) {
      if (x == 0 && y == 0 && width == bitmap.width && height == bitmap.height) {
        return bitmap
      }
      return Bitmap.createBitmap(bitmap, x, y, width, height)
    }
    // Sub-rect and rotation in a single call, so the original never needs a full-size intermediate
    // the way a rotate-then-crop would. `filter = false` keeps it a lossless permutation.
    val matrix = Matrix().apply { postRotate(rotationDegrees.toFloat()) }
    return Bitmap.createBitmap(bitmap, x, y, width, height, matrix, false)
  }

  /**
   * Output UV to source UV for a capture that has to be turned `rotationDegrees` clockwise to sit
   * upright, or null for the identity.
   *
   * Column-major, as `glUniformMatrix4fv` wants it, and authored in the shaders' top-left origin UV
   * space. Only the four quarter turns `ImageInfo.getRotationDegrees` documents are handled.
   */
  @VisibleForTesting
  internal fun uprightTransform(rotationDegrees: Int): FloatArray? =
      when (rotationDegrees) {
        // (u, v) -> (v, 1 - u)
        90 -> floatArrayOf(0f, -1f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 1f, 0f, 1f)
        // (u, v) -> (1 - u, 1 - v)
        180 -> floatArrayOf(-1f, 0f, 0f, 0f, 0f, -1f, 0f, 0f, 0f, 0f, 1f, 0f, 1f, 1f, 0f, 1f)
        // (u, v) -> (1 - v, u)
        270 -> floatArrayOf(0f, 1f, 0f, 0f, -1f, 0f, 0f, 0f, 0f, 0f, 1f, 0f, 1f, 0f, 0f, 1f)
        else -> null
      }

  /** Whether `rotationDegrees` transposes the frame's width and height. */
  internal fun isQuarterTurn(rotationDegrees: Int): Boolean =
      rotationDegrees == 90 || rotationDegrees == 270

  private fun readPixels(framebuffer: Int, width: Int, height: Int): Bitmap {
    val buffer = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.nativeOrder())
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer)
    GLES30.glReadPixels(0, 0, width, height, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, buffer)
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
    buffer.rewind()

    // No flip needed: the pass was rasterized upside down, so glReadPixels' bottom-up read has
    // already put row 0 at the top, which is what `copyPixelsFromBuffer` expects.
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    bitmap.copyPixelsFromBuffer(buffer)
    return bitmap
  }
}
