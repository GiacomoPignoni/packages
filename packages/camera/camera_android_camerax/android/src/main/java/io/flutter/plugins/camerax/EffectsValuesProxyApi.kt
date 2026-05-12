// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

/**
 * ProxyApi implementation for [PlatformEffectsValues]. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
class EffectsValuesProxyApi(override val pigeonRegistrar: ProxyApiRegistrar) :
    PigeonApiPlatformEffectsValues(pigeonRegistrar) {
  override fun pigeon_defaultConstructor(
      vignetteIntensity: Double,
      grainNoisePath: String?,
      grainOpacity: Double,
      grainSize: Double,
      grainBehavior: PlatformGrainBehavior,
      lutFilePath: String?,
      lutIntensity: Double,
      resolution: Double,
      colorShift: Double,
      mist: Double,
      prism: Double,
      cheapFisheye: Boolean,
      bloom: Double,
      diffusion: Double,
  ): PlatformEffectsValues =
      PlatformEffectsValues(
          vignetteIntensity = vignetteIntensity,
          grainNoisePath = grainNoisePath,
          grainOpacity = grainOpacity,
          grainSize = grainSize,
          grainBehavior = grainBehavior,
          lutFilePath = lutFilePath,
          lutIntensity = lutIntensity,
          resolution = resolution,
          colorShift = colorShift,
          mist = mist,
          prism = prism,
          cheapFisheye = cheapFisheye,
          bloom = bloom,
          diffusion = diffusion,
      )

  override fun vignetteIntensity(pigeon_instance: PlatformEffectsValues): Double =
      pigeon_instance.vignetteIntensity

  override fun grainNoisePath(pigeon_instance: PlatformEffectsValues): String? =
      pigeon_instance.grainNoisePath

  override fun grainOpacity(pigeon_instance: PlatformEffectsValues): Double =
      pigeon_instance.grainOpacity

  override fun grainSize(pigeon_instance: PlatformEffectsValues): Double = pigeon_instance.grainSize

  override fun grainBehavior(pigeon_instance: PlatformEffectsValues): PlatformGrainBehavior =
      pigeon_instance.grainBehavior

  override fun lutFilePath(pigeon_instance: PlatformEffectsValues): String? =
      pigeon_instance.lutFilePath

  override fun lutIntensity(pigeon_instance: PlatformEffectsValues): Double =
      pigeon_instance.lutIntensity

  override fun resolution(pigeon_instance: PlatformEffectsValues): Double =
      pigeon_instance.resolution

  override fun colorShift(pigeon_instance: PlatformEffectsValues): Double =
      pigeon_instance.colorShift

  override fun mist(pigeon_instance: PlatformEffectsValues): Double = pigeon_instance.mist

  override fun prism(pigeon_instance: PlatformEffectsValues): Double = pigeon_instance.prism

  override fun cheapFisheye(pigeon_instance: PlatformEffectsValues): Boolean =
      pigeon_instance.cheapFisheye

  override fun bloom(pigeon_instance: PlatformEffectsValues): Double = pigeon_instance.bloom

  override fun diffusion(pigeon_instance: PlatformEffectsValues): Double = pigeon_instance.diffusion
}

/**
 * ProxyApi implementation for [CapturedPicturePaths]. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
class CapturedPicturePathsProxyApi(override val pigeonRegistrar: ProxyApiRegistrar) :
    PigeonApiCapturedPicturePaths(pigeonRegistrar) {
  override fun originalPath(pigeon_instance: CapturedPicturePaths): String? =
      pigeon_instance.originalPath

  override fun processedPath(pigeon_instance: CapturedPicturePaths): String =
      pigeon_instance.processedPath
}
