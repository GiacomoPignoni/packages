// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.annotation.SuppressLint
import androidx.camera.core.CameraEffect
import androidx.camera.core.SurfaceProcessor
import org.junit.Assert.assertEquals
import org.junit.Test
import org.mockito.Mockito.mock

@SuppressLint("RestrictedApi")
class ShaderCameraEffectTest {
  private val effect =
      CameraEffectsManager.ShaderCameraEffect(mock(SurfaceProcessor::class.java), { it.run() }) {}

  @Test
  fun targetsThePreviewAndTheRecording() {
    assertEquals(CameraEffect.PREVIEW or CameraEffect.VIDEO_CAPTURE, effect.targets)
  }

  @Test
  fun asksForOneOutputPerTarget() {
    // With a single output for both, `StreamSharing` copies one rendering to the preview and the
    // encoder, and the preview zooms into the capture-scale rect for the length of a recording.
    assertEquals(CameraEffect.OUTPUT_OPTION_ONE_FOR_EACH_TARGET, effect.outputOption)
  }

  @Test
  fun leavesTheTransformationAtItsDefault() {
    // The five-argument overload takes a transformation where the output option would be expected,
    // and passing the output option to it lands here as a rotation the graph is not built for.
    assertEquals(CameraEffect.TRANSFORMATION_ARBITRARY, effect.transformation)
  }
}
