// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'overlay_blend_mode.dart';

/// Controls where grain is visible across the tonal range.
enum GrainBehavior {
  /// Grain is applied uniformly (additive) across all tones — visible on both
  /// dark and light areas.
  overlay,

  /// Grain is scaled by the inverse luminance of each pixel so it fades out
  /// on bright areas and is most visible in shadows.
  darkOnly,
}

/// Visual effect parameters applied by the camera shader pipeline.
///
/// Pass an instance to [CameraPlatform.setEffectsValues].
/// On platforms that do not support shader effects every field is ignored.
class EffectsValues {
  /// Creates an [EffectsValues].
  const EffectsValues({
    this.vignetteIntensity = 0.0,
    this.grainNoisePath,
    this.grainOpacity = 0.0,
    this.grainSize = 0.1,
    this.grainBehavior = GrainBehavior.overlay,
    this.lutFilePath,
    this.lutIntensity = 0.0,
    this.overlayFilePath,
    this.overlayBlendMode = OverlayBlendMode.srcOver,
    this.resolution = 0.0,
    this.colorShift = 0.0,
    this.mist = 0.0,
    this.prism = 0.0,
    this.cheapFisheye = false,
    this.bloom = 0.0,
    this.diffusion = 0.0,
  }) : // Each `>= lo && <= hi` check on the bounded fields below also
       // implicitly rejects NaN (every comparison with NaN is false) and
       // ±infinity, so the Swift platform side can drop its per-field
       // `isFinite` guards. `grainSize` has no upper bound and needs the
       // explicit `< double.infinity` to do the same.
       assert(
         vignetteIntensity >= 0.0 && vignetteIntensity <= 1.0,
         'vignetteIntensity must be a finite value between 0.0 and 1.0',
       ),
       assert(
         grainOpacity >= 0.0 && grainOpacity <= 1.0,
         'grainOpacity must be a finite value between 0.0 and 1.0',
       ),
       assert(
         grainSize >= 0.0 && grainSize < double.infinity,
         'grainSize must be a finite value >= 0.0',
       ),
       assert(
         lutIntensity >= 0.0 && lutIntensity <= 1.0,
         'lutIntensity must be a finite value between 0.0 and 1.0',
       ),
       assert(
         resolution >= 0.0 && resolution <= 1.0,
         'resolution must be a finite value between 0.0 and 1.0',
       ),
       assert(
         colorShift >= 0.0 && colorShift <= 1.0,
         'colorShift must be a finite value between 0.0 and 1.0',
       ),
       assert(mist >= 0.0 && mist <= 1.0, 'mist must be a finite value between 0.0 and 1.0'),
       assert(prism >= 0.0 && prism <= 1.0, 'prism must be a finite value between 0.0 and 1.0'),
       assert(bloom >= 0.0 && bloom <= 1.0, 'bloom must be a finite value between 0.0 and 1.0'),
       assert(
         diffusion >= 0.0 && diffusion <= 1.0,
         'diffusion must be a finite value between 0.0 and 1.0',
       );

  /// Radial darkening toward the frame edges (0.0 = off, 1.0 = full vignette).
  final double vignetteIntensity;

  /// Absolute file path to the grain/noise source image.
  ///
  /// When null the grain effect is disabled regardless of [grainOpacity].
  /// On platforms that do not support grain this field is ignored.
  final String? grainNoisePath;

  /// Opacity of the grain overlay (0.0 = off, 1.0 = fully applied).
  final double grainOpacity;

  /// Controls where grain is visible across the tonal range.
  final GrainBehavior grainBehavior;

  /// Size of the grain tile relative to the output frame's shorter side (>= 0.0).
  ///
  /// The value is a direct linear multiplier: at **1.0** one grain tile exactly
  /// spans the shorter output dimension (the coarsest "natural" size); values
  /// **below 1.0** tile the image more finely; values **above 1.0** make the
  /// tile larger than the frame, zooming into fewer, bigger grain features.
  ///
  /// The scale is resolution-independent: the same value produces visually
  /// identical grain size in the preview, in captured photos, and in recorded
  /// video, regardless of their differing pixel dimensions. Tiles are always
  /// square in output pixels — no stretching on landscape or non-square outputs.
  final double grainSize;

  /// Absolute file path to a 3D LUT color-grade image.
  ///
  /// The image must be a 512×512 PNG containing a 64×64×64 color cube laid
  /// out as an 8×8 grid of 64×64 tiles: within a tile, x = red (0..63) and
  /// y = green (0..63, top to bottom); the tile index in row-major order
  /// (left-to-right, top-to-bottom) selects the blue slice (0..63).
  ///
  /// When null the LUT color filter is disabled regardless of [lutIntensity].
  /// Other effects in this [EffectsValues] still apply.
  /// On platforms that do not support LUT color grading this field is ignored.
  final String? lutFilePath;

  /// Intensity of the LUT color filter (0.0 = no effect, 1.0 = full LUT).
  ///
  /// Ignored when [lutFilePath] is null.
  final double lutIntensity;

  /// Absolute file path to a PNG composited over the frame.
  ///
  /// The image is stretched to fill the frame, ignoring its own aspect ratio,
  /// so author it at the aspect ratio the camera is configured for. It is
  /// applied last — after every other effect in this [EffectsValues] — and
  /// appears in the preview, in captured photos and in recorded video alike.
  /// The un-effected `original` of
  /// [CameraPlatform.takePictureWithOriginal] never carries it.
  ///
  /// Author the image in the orientation [CameraPreview] displays; the
  /// platform turns it to match each of the preview, photo and video paths.
  ///
  /// In the preview the overlay covers exactly the area a capture would keep,
  /// so it stops at the edge of the capture-scale rect rather than extending
  /// into the dimmed border around it.
  ///
  /// Transparency comes from the PNG's own alpha channel — there is no
  /// separate opacity control. When null the overlay is disabled and
  /// [overlayBlendMode] is ignored. On platforms that do not support overlays
  /// this field is ignored.
  final String? overlayFilePath;

  /// How [overlayFilePath] is combined with the frame beneath it.
  ///
  /// Ignored when [overlayFilePath] is null.
  final OverlayBlendMode overlayBlendMode;

  /// Simulates a low-resolution sensor (0.0 = off, 1.0 = full strength).
  ///
  /// Applies a soft Gaussian blur and a luma-pulled desaturation to mimic the
  /// look of an old camera's poor optics and color reproduction.
  final double resolution;

  /// Chromatic aberration strength (0.0 = off, 1.0 = full strength).
  ///
  /// Splits the red and blue channels along a small UV offset to emulate the
  /// color fringing characteristic of cheap or aged lenses.
  final double colorShift;

  /// Dreamy mist / Orton-style soft glow (0.0 = off, 1.0 = full strength).
  ///
  /// Combines a wide Gaussian blur with a brightened screen blend and a
  /// slight contrast reduction to simulate atmospheric haze and lens
  /// diffusion.
  final double mist;

  /// Radial chromatic motion blur — "prism" effect (0.0 = off, 1.0 = full).
  ///
  /// Smears the red, green, and blue channels along the radial axis with a
  /// short multi-tap accumulation, producing a rainbow fringe that vanishes
  /// at the frame centre and peaks at the corners.
  final double prism;

  /// Cheap clip-on fisheye lens simulation.
  ///
  /// When true, the live image is barrel-distorted inside a circular mask
  /// with a softly feathered edge; pixels outside the circle render black.
  final bool cheapFisheye;

  /// Highlight bloom — light-bleed glow (0.0 = off, 1.0 = full strength).
  ///
  /// Extracts pixels above a brightness threshold, blurs them into a wide halo,
  /// and adds the glow back on top so bright areas bleed light. Unlike
  /// [mist], which diffuses the whole frame, bloom only affects highlights.
  final double bloom;

  /// Diffusion — soft-focus filter (0.0 = off, 1.0 = full strength).
  ///
  /// Mixes the frame toward a wide Gaussian blur of itself, softening fine
  /// detail across the whole tonal range like a Pro-Mist diffusion filter.
  /// Unlike [bloom] it affects the entire frame uniformly, and unlike [mist]
  /// it neither brightens nor lifts contrast — it only softens.
  final double diffusion;
}
