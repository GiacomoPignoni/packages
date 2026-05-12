// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

/**
 * Visual effect parameters forwarded to the OpenGL ES shader pipeline.
 *
 * Mirrors `PlatformEffectsValues` in `camera_avfoundation`; the two must stay in sync so the same
 * `EffectsValues` renders the same on both platforms.
 */
data class PlatformEffectsValues(
    val vignetteIntensity: Double,
    val grainNoisePath: String?,
    val grainOpacity: Double,
    val grainSize: Double,
    val grainBehavior: PlatformGrainBehavior,
    val lutFilePath: String?,
    val lutIntensity: Double,
    val resolution: Double,
    val colorShift: Double,
    val mist: Double,
    val prism: Double,
    val cheapFisheye: Boolean,
    val bloom: Double,
    val diffusion: Double,
)

/** Paths to the files produced by `ImageCapture.takePictureWithEffects`. */
data class CapturedPicturePaths(val originalPath: String?, val processedPath: String)
