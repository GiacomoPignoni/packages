// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CameraShaderTypes_h
#define CameraShaderTypes_h

#include <simd/simd.h>

// Types shared between the Swift renderer (VideoFrameRenderer.swift) and the
// Metal shaders (CameraShader.metal). Compiling this one header on both sides
// is what keeps the uniform-buffer ABI, the source-format function constant,
// and the texture bind slots in agreement — never redeclare these in either
// language.

// Source pixel format a render pipeline is specialised for. Bound to the
// `kSourceFormat` function constant (index 0) at pipeline-creation time.
typedef enum CameraShaderSourceFormat {
  CameraShaderSourceFormatBGRA = 0,
  CameraShaderSourceFormatYuvFullRange = 1,   // 420f
  CameraShaderSourceFormatYuvVideoRange = 2,  // 420v
} CameraShaderSourceFormat;

// Texture bind slots, fixed across source formats and passes. Every pass
// binds the source (or Y plane) and CbCr at slots 0–1 — CbCr is dummy-bound
// for BGRA and never sampled — and the main pass adds the auxiliary textures
// behind them.
typedef enum CameraShaderTextureIndex {
  CameraShaderTextureSource = 0,      // BGRA source or Y plane
  CameraShaderTextureCbCr = 1,        // interleaved chroma plane (dummy for BGRA)
  CameraShaderTextureGrain = 2,       // grain/noise overlay
  CameraShaderTextureLut = 3,         // colour-grade LUT
  CameraShaderTexturePreBlurred = 4,  // horizontal half of the old-camera blur
  CameraShaderTextureBloom = 5,       // renderer-blurred bloom halo
  CameraShaderTextureFrameBlur = 6,   // renderer-blurred frame (mist + diffusion)
  CameraShaderTextureOverlay = 7,     // user PNG composited over the finished frame
} CameraShaderTextureIndex;

// Blend mode used to composite the overlay PNG over the finished frame. The
// raw values are the wire format: `PlatformOverlayBlendMode` is declared in the
// same order, so the pigeon enum's index crosses into `overlayBlendMode`
// unchanged. Every mode is separable (applied per channel) and defined on
// non-linear sRGB values, which is the space `applyOverlay` blends in.
typedef enum CameraShaderBlendMode {
  CameraShaderBlendModeSrcOver = 0,
  CameraShaderBlendModeMultiply = 1,
  CameraShaderBlendModeScreen = 2,
  CameraShaderBlendModeOverlay = 3,
  CameraShaderBlendModeDarken = 4,
  CameraShaderBlendModeLighten = 5,
  CameraShaderBlendModeColorDodge = 6,
  CameraShaderBlendModeColorBurn = 7,
  CameraShaderBlendModeSoftLight = 8,
  CameraShaderBlendModeHardLight = 9,
  CameraShaderBlendModeDifference = 10,
  CameraShaderBlendModeExclusion = 11,
} CameraShaderBlendMode;

// Per-draw uniforms, bound at buffer index 0 of both shader stages. The
// declaration order below *is* the buffer ABI — Swift writes the raw bytes
// with `setVertexBytes`/`setFragmentBytes`.
typedef struct {
  // 0 = no vignette, 1 = full strength.
  float vignetteIntensity;
  // Center-anchored UV transform: shrink (uvScale < 1) to crop the sampled
  // sub-rect of the source. (1, 1) = identity (no crop).
  vector_float2 uvScale;
  // Inner-rect "capture scale" applied on top of the aspect-ratio crop.
  // 0.1–1.0; 1.0 = no extra narrowing. Capture passes use this to shrink the
  // sampled area; preview passes use it together with `darkenOutside` to draw
  // the full crop with the area outside the scaled rect dimmed.
  float captureScale;
  // 0.0 = no darkening (capture passes); ~0.4 = dim the area outside the
  // scaled rect (preview passes).
  float darkenOutside;
  // Aspect ratio (width / height) of the rendered output in pixels, so the
  // vignette's circular distance calculation compensates for non-square
  // outputs.
  float outputAspect;
  // Grain/noise overlay intensity. 0 = no grain (or no texture bound).
  float grainOpacity;
  // Random UV shift updated at 24 fps by the grain animation timer.
  vector_float2 grainOffset;
  // Maps fragment [0,1] UV → grain texture UV, encoding physical pixel size.
  vector_float2 grainUVScale;
  // 1.0 when the pixel buffer is in sensor (landscape) orientation and a 90°
  // EXIF rotation will be applied by the viewer (photo path). Swaps the UV
  // axes used for grain sampling so the pattern matches the live preview.
  float grainSwapUV;
  // LUT color-filter intensity. 0 = no LUT (or no LUT bound), 1 = full LUT.
  float lutIntensity;
  // Corner radius of the captureScale rect in the same [-1,1] d-space as the
  // scaled rectangle. 0 = square corners. Only affects preview passes where
  // `darkenOutside > 0`.
  float captureCornerRadius;
  // Low-resolution sensor simulation (0 = off, 1 = full). Drives a soft
  // Gaussian blur and a luma-pulled desaturation amount.
  float resolution;
  // Chromatic aberration strength (0 = off, 1 = full). Splits R/B along a
  // small radial UV offset to emulate old-lens colour fringing.
  float colorShift;
  // Dreamy mist / Orton soft-glow strength (0 = off, 1 = full). Combines a
  // wide Gaussian blur with a brightened screen blend and a slight contrast
  // reduction for an atmospheric haze look.
  float mist;
  // Grain tonal mask: 0 = overlay (uniform), 1 = dark-only (grain scaled by
  // inverse sRGB luminance so it fades out on bright areas).
  float grainBehavior;
  // Cheap fisheye lens simulation. 0 = off, 1 = on.
  float cheapFisheye;
  // Radial chromatic motion blur ("prism"). 0 = off, 1 = full. Smears R/G/B
  // along the radial axis with a short multi-tap accumulation. Strength
  // ramps from zero at the frame centre to its peak at the corners.
  float prism;
  // Highlight bloom (0 = off, 1 = full). Extracts pixels above a luminance
  // threshold, blurs them into a wide halo, and adds the glow back so bright
  // areas bleed light. Unlike `mist`, only highlights contribute.
  float bloom;
  // Diffusion / soft-focus filter (0 = off, 1 = full). Mixes the frame toward
  // a wide Gaussian blur of itself, softening fine detail across the whole
  // tonal range. Unlike `bloom` it is not limited to highlights, and unlike
  // `mist` it neither brightens nor lifts contrast — it only softens.
  float diffusion;
  // 1.0 when an overlay texture is bound and should be composited, 0.0
  // otherwise. Zeroed whenever the overlay slot holds the dummy texture, so
  // the shader never samples a stand-in.
  float overlayEnabled;
  // Which `CameraShaderBlendMode` to composite the overlay with, held as a
  // float like every other discrete field in this struct (see `grainBehavior`,
  // `cheapFisheye`). Rounded back to an integer in the shader.
  float overlayBlendMode;
  // Quarter turns (0-3) applied to the overlay's UV before sampling, bringing
  // the image the caller authored in display orientation into the orientation
  // this particular pass renders in. The preview and recording passes render
  // portrait and need none; the photo pass renders in sensor orientation and
  // does. Only Metal's photo pass sets it; Android's two paths both present
  // the frame the same way up and leave it at 0.
  float overlayQuarterTurns;
} CameraUniforms;

#endif  // CameraShaderTypes_h
