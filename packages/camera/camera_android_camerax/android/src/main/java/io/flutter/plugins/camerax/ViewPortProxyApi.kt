// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

import android.util.Rational
import androidx.camera.core.ViewPort

/**
 * ProxyApi implementation for [ViewPort].
 *
 * `ViewPort` has no public constructor, so the default constructor is built here rather than
 * generated.
 */
class ViewPortProxyApi(pigeonRegistrar: ProxyApiRegistrar) : PigeonApiViewPort(pigeonRegistrar) {
  override fun pigeon_defaultConstructor(
      aspectRatioWidth: Long,
      aspectRatioHeight: Long,
      rotation: Long,
  ): ViewPort =
      ViewPort.Builder(
              Rational(aspectRatioWidth.toInt(), aspectRatioHeight.toInt()),
              rotation.toInt(),
          )
          // Center-crop rather than fit: the requested shape has to be filled edge to edge, which
          // is
          // what makes the cropped surface the size of the crop instead of the size of a letterbox.
          .setScaleType(ViewPort.FILL_CENTER)
          .build()
}
