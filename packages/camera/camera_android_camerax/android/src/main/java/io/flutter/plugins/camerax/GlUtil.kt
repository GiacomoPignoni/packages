// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.graphics.Bitmap
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.GLUtils
import java.nio.ByteBuffer

/** Small helpers over the raw GLES entry points, so the renderer reads as pipeline logic. */
object GlUtil {
  /** GLES' initial value for `GL_UNPACK_ALIGNMENT`, restored after an upload that changes it. */
  private const val DEFAULT_UNPACK_ALIGNMENT = 4

  fun extensions(): String = GLES30.glGetString(GLES30.GL_EXTENSIONS) ?: ""

  /**
   * Compiles and links a program.
   *
   * `fragmentSource` already carries its own `#version` line (see [CameraShaderSource]), whereas
   * the shared vertex source is used verbatim by every pass.
   */
  fun buildProgram(vertexSource: String, fragmentSource: String): Int {
    val vertexShader = compileShader(GLES30.GL_VERTEX_SHADER, vertexSource)
    val fragmentShader =
        try {
          compileShader(GLES30.GL_FRAGMENT_SHADER, fragmentSource)
        } catch (e: RuntimeException) {
          GLES30.glDeleteShader(vertexShader)
          throw e
        }
    try {
      val program = GLES30.glCreateProgram()
      check(program != 0) { "glCreateProgram failed" }
      GLES30.glAttachShader(program, vertexShader)
      GLES30.glAttachShader(program, fragmentShader)
      GLES30.glLinkProgram(program)

      val status = IntArray(1)
      GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, status, 0)
      if (status[0] != GLES30.GL_TRUE) {
        val log = GLES30.glGetProgramInfoLog(program)
        GLES30.glDeleteProgram(program)
        throw RuntimeException("Failed to link camera shader program: $log")
      }
      return program
    } finally {
      // Once linked (or if linking/creation failed), the shaders are no longer needed: a linked
      // program keeps its own reference, and a failed program has nothing to keep.
      GLES30.glDeleteShader(vertexShader)
      GLES30.glDeleteShader(fragmentShader)
    }
  }

  private fun compileShader(type: Int, source: String): Int {
    val shader = GLES30.glCreateShader(type)
    check(shader != 0) { "glCreateShader failed" }
    GLES30.glShaderSource(shader, source)
    GLES30.glCompileShader(shader)

    val status = IntArray(1)
    GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
    if (status[0] != GLES30.GL_TRUE) {
      val log = GLES30.glGetShaderInfoLog(shader)
      GLES30.glDeleteShader(shader)
      throw RuntimeException("Failed to compile camera shader: $log")
    }
    return shader
  }

  /** Creates the external texture a `SurfaceTexture` renders the camera frames into. */
  fun createExternalTexture(): Int {
    val ids = IntArray(1)
    GLES30.glGenTextures(1, ids, 0)
    GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, ids[0])
    setSampling(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_CLAMP_TO_EDGE)
    GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
    return ids[0]
  }

  /**
   * Creates a colour-attachment texture of the given size.
   *
   * `halfFloat` targets are used for the intermediate linear-light passes, where 8 bits per channel
   * visibly bands in the shadows. Callers fall back to 8-bit when the device cannot render to half
   * float.
   */
  fun createTargetTexture(width: Int, height: Int, halfFloat: Boolean): Int {
    val ids = IntArray(1)
    GLES30.glGenTextures(1, ids, 0)
    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, ids[0])
    GLES30.glTexImage2D(
        GLES30.GL_TEXTURE_2D,
        0,
        if (halfFloat) GLES30.GL_RGBA16F else GLES30.GL_RGBA8,
        width,
        height,
        0,
        GLES30.GL_RGBA,
        if (halfFloat) GLES30.GL_HALF_FLOAT else GLES30.GL_UNSIGNED_BYTE,
        null,
    )
    setSampling(GLES30.GL_TEXTURE_2D, GLES30.GL_CLAMP_TO_EDGE)
    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
    return ids[0]
  }

  /** Uploads `bitmap` into a new texture with the given wrap mode. */
  fun createTextureFromBitmap(bitmap: Bitmap, wrap: Int): Int {
    val ids = IntArray(1)
    GLES30.glGenTextures(1, ids, 0)
    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, ids[0])
    GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, bitmap, 0)
    setSampling(GLES30.GL_TEXTURE_2D, wrap)
    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
    return ids[0]
  }

  /**
   * Uploads the luma plane of a `YUV_420_888` capture into a new single-channel texture.
   *
   * `luma` must already be tightly packed; see [CameraYuvImage.packLuma].
   */
  fun createLumaTexture(luma: ByteBuffer, width: Int, height: Int): Int =
      createUnalignedTexture(
          buffer = luma,
          width = width,
          height = height,
          internalFormat = GLES30.GL_R8,
          format = GLES30.GL_RED,
      )

  /**
   * Uploads interleaved chroma into a new two-channel (U, V) texture at half resolution.
   *
   * `chroma` must already be tightly packed; see [CameraYuvImage.packChroma].
   */
  fun createChromaTexture(chroma: ByteBuffer, width: Int, height: Int): Int =
      createUnalignedTexture(
          buffer = chroma,
          width = width,
          height = height,
          internalFormat = GLES30.GL_RG8,
          format = GLES30.GL_RG,
      )

  /**
   * Uploads a tightly packed byte buffer into a new texture.
   *
   * The unpack alignment has to drop to 1 for these: the default of 4 would have the driver expect
   * every row to start on a four-byte boundary, which a one- or two-channel row of an odd width
   * does not. It is put back afterwards so the rest of the pipeline, which uploads four-byte RGBA,
   * is not left depending on state this function happened to change.
   */
  private fun createUnalignedTexture(
      buffer: ByteBuffer,
      width: Int,
      height: Int,
      internalFormat: Int,
      format: Int,
  ): Int {
    val ids = IntArray(1)
    GLES30.glGenTextures(1, ids, 0)
    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, ids[0])
    GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 1)
    buffer.position(0)
    GLES30.glTexImage2D(
        GLES30.GL_TEXTURE_2D,
        0,
        internalFormat,
        width,
        height,
        0,
        format,
        GLES30.GL_UNSIGNED_BYTE,
        buffer,
    )
    GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, DEFAULT_UNPACK_ALIGNMENT)
    setSampling(GLES30.GL_TEXTURE_2D, GLES30.GL_CLAMP_TO_EDGE)
    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
    return ids[0]
  }

  private fun setSampling(target: Int, wrap: Int) {
    GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
    GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
    GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_WRAP_S, wrap)
    GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_WRAP_T, wrap)
  }

  /** Creates a framebuffer with `texture` as its colour attachment. */
  fun createFramebuffer(texture: Int): Int {
    val ids = IntArray(1)
    GLES30.glGenFramebuffers(1, ids, 0)
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, ids[0])
    GLES30.glFramebufferTexture2D(
        GLES30.GL_FRAMEBUFFER,
        GLES30.GL_COLOR_ATTACHMENT0,
        GLES30.GL_TEXTURE_2D,
        texture,
        0,
    )
    val status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
    check(status == GLES30.GL_FRAMEBUFFER_COMPLETE) { "Incomplete framebuffer: $status" }
    return ids[0]
  }

  fun deleteTexture(texture: Int) {
    if (texture != 0) {
      GLES30.glDeleteTextures(1, intArrayOf(texture), 0)
    }
  }

  fun deleteFramebuffer(framebuffer: Int) {
    if (framebuffer != 0) {
      GLES30.glDeleteFramebuffers(1, intArrayOf(framebuffer), 0)
    }
  }

  /** Draws the fullscreen triangle the vertex stage generates from `gl_VertexID`. */
  fun drawFullscreenTriangle() {
    GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
  }
}
