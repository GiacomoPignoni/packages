// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.view.Surface

/**
 * The OpenGL ES 3.0 context shared by the preview, video and still-capture render paths.
 *
 * One context means one set of compiled programs and one copy of the grain and LUT textures, no
 * matter how many outputs are attached — the same arrangement `VideoFrameRenderer` gets for free
 * from a single `MTLDevice`.
 *
 * Every method must be called from the thread that owns the context.
 */
class EglCore {
  private val display: EGLDisplay
  private val config: EGLConfig
  private val context: EGLContext

  /** Whether the driver can render into half-float colour attachments. */
  val supportsHalfFloatTargets: Boolean

  /**
   * A 1x1 surface kept around solely so the thread always has something current.
   *
   * `glCreateShader` and friends silently return 0 when no context is current, so any GL work that
   * happens outside a frame — compiling programs, uploading the grain and LUT textures, rendering a
   * still — needs a surface to be bound first.
   */
  private val defaultSurface: EGLSurface

  init {
    display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    check(display != EGL14.EGL_NO_DISPLAY) { "Unable to get an EGL display" }

    val version = IntArray(2)
    check(EGL14.eglInitialize(display, version, 0, version, 1)) { "Unable to initialize EGL" }

    val attributes =
        intArrayOf(
            EGL14.EGL_RED_SIZE,
            8,
            EGL14.EGL_GREEN_SIZE,
            8,
            EGL14.EGL_BLUE_SIZE,
            8,
            EGL14.EGL_ALPHA_SIZE,
            8,
            EGL14.EGL_RENDERABLE_TYPE,
            EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            // Both window surfaces (preview, video) and pbuffers (still capture) are created from
            // this
            // one config, so it has to advertise both.
            EGL14.EGL_SURFACE_TYPE,
            EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
    val configs = arrayOfNulls<EGLConfig>(1)
    val configCount = IntArray(1)
    check(
        EGL14.eglChooseConfig(display, attributes, 0, configs, 0, configs.size, configCount, 0) &&
            configCount[0] > 0) {
          "No suitable EGL config for OpenGL ES 3.0"
        }
    config = configs[0]!!

    context =
        EGL14.eglCreateContext(
            display,
            config,
            EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE),
            0,
        )
    check(context != EGL14.EGL_NO_CONTEXT) { "Unable to create an EGL ES 3.0 context" }

    defaultSurface = createOffscreenSurface(1, 1)
    // Leave it current: from here on the owning thread always has a usable context.
    makeCurrent(defaultSurface)
    supportsHalfFloatTargets =
        GlUtil.extensions().contains("GL_EXT_color_buffer_half_float") ||
            GlUtil.extensions().contains("GL_EXT_color_buffer_float")
  }

  /**
   * Binds the always-available 1x1 surface.
   *
   * Call this whenever a real output surface is no longer the right target — after presenting a
   * frame, or before GL work that is not tied to any output.
   */
  fun makeDefaultCurrent() {
    makeCurrent(defaultSurface)
  }

  /** Creates a surface that renders into `surface`. */
  fun createWindowSurface(surface: Surface): EGLSurface {
    val eglSurface =
        EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
    check(eglSurface != EGL14.EGL_NO_SURFACE) { "Unable to create an EGL window surface" }
    return eglSurface
  }

  /** Creates an offscreen surface, used to make the context current for still capture. */
  fun createOffscreenSurface(width: Int, height: Int): EGLSurface {
    val eglSurface =
        EGL14.eglCreatePbufferSurface(
            display,
            config,
            intArrayOf(EGL14.EGL_WIDTH, width, EGL14.EGL_HEIGHT, height, EGL14.EGL_NONE),
            0,
        )
    check(eglSurface != EGL14.EGL_NO_SURFACE) { "Unable to create an EGL pbuffer surface" }
    return eglSurface
  }

  fun makeCurrent(eglSurface: EGLSurface) {
    check(EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) {
      "eglMakeCurrent failed"
    }
  }

  fun makeNothingCurrent() {
    EGL14.eglMakeCurrent(
        display,
        EGL14.EGL_NO_SURFACE,
        EGL14.EGL_NO_SURFACE,
        EGL14.EGL_NO_CONTEXT,
    )
  }

  /**
   * Stamps the frame's capture timestamp onto the surface before presenting it.
   *
   * The video encoder derives its sample timestamps from this, so dropping it would give the
   * recording a timeline of its own that drifts away from the audio.
   */
  fun setPresentationTime(eglSurface: EGLSurface, nanoseconds: Long) {
    EGLExt.eglPresentationTimeANDROID(display, eglSurface, nanoseconds)
  }

  /** Returns false when the surface has already been abandoned by its consumer. */
  fun swapBuffers(eglSurface: EGLSurface): Boolean = EGL14.eglSwapBuffers(display, eglSurface)

  fun releaseSurface(eglSurface: EGLSurface) {
    EGL14.eglDestroySurface(display, eglSurface)
  }

  fun release() {
    makeNothingCurrent()
    EGL14.eglDestroySurface(display, defaultSurface)
    EGL14.eglDestroyContext(display, context)
    EGL14.eglReleaseThread()
    EGL14.eglTerminate(display)
  }
}
