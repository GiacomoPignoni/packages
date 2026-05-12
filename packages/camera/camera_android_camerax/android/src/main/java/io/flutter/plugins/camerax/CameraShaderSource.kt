// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax

/**
 * GLSL ES 3.0 port of `CameraShader.metal` in `camera_avfoundation`.
 *
 * The two files must stay in step: the same `EffectsValues` is expected to render the same on both
 * platforms, so every effect here mirrors its Metal counterpart function-for-function, including
 * the constants and the order they run in.
 *
 * Differences forced by the platform, none of which change the output:
 * - Metal's `kSourceFormat` function constant becomes a `#define` prepended at compile time. There
 *   is no YUV decode to specialise for: the camera arrives as an `samplerExternalOES` that the
 *   driver has already converted, and stills arrive as an ordinary `sampler2D` bitmap.
 * - Metal's templated sampler functors become a plain `sampleSource` function, since each compiled
 *   variant has exactly one source kind.
 * - Metal writes into an sRGB destination view and gets the linear -> sRGB encode for free. GLES
 *   has no dependable equivalent on a `SurfaceTexture` target, so the main pass encodes explicitly
 *   as its last step.
 * - The bloom halo and frame blur are blurred by [GAUSSIAN_FRAGMENT] rather than
 *   `MPSImageGaussianBlur`, which has no Android equivalent.
 *
 * One deliberate divergence, where matching Metal would have been a bug: the two aux extract passes
 * box-filter their 4x downsample through [AUX_DOWNSAMPLE]'s `sampleSourceBox` instead of taking the
 * single tap the Metal version takes. The reason is in that function's comment. The bloom threshold
 * is a uniform here rather than Metal's compile-time constant for the same underlying reason - the
 * two platforms hand the shader differently tone-mapped highlights.
 *
 * UV convention: the vertex stage emits a top-left origin UV, matching Metal. `sampleSource`
 * converts to GL's bottom-left origin for the external texture only; every other texture in the
 * pipeline is both written and read through this same convention, so it cancels out.
 */
object CameraShaderSource {
  /** Prepended to a fragment shader whose source is the camera's `SurfaceTexture`. */
  const val DEFINE_SOURCE_EXTERNAL =
      "#version 300 es\n" +
          "#extension GL_OES_EGL_image_external_essl3 : require\n" +
          "#define SOURCE_EXTERNAL 1\n" +
          "#define SOURCE_YUV 0\n"

  /** Prepended to a fragment shader whose source is a still-capture bitmap. */
  const val DEFINE_SOURCE_2D =
      "#version 300 es\n#define SOURCE_EXTERNAL 0\n#define SOURCE_YUV 0\n"

  /**
   * Prepended to a fragment shader whose source is an uncompressed `YUV_420_888` capture.
   *
   * The still path takes this one: `ImageCapture` is configured for an uncompressed buffer, so
   * there is no JPEG to decode and the chroma upsample and colour conversion the decoder used to do
   * on the CPU happen here, in the sampler, for free.
   */
  const val DEFINE_SOURCE_YUV =
      "#version 300 es\n#define SOURCE_EXTERNAL 0\n#define SOURCE_YUV 1\n"

  /** Prepended to fragment shaders that do not read the camera source at all. */
  const val DEFINE_NO_SOURCE = "#version 300 es\n"

  /**
   * Shared by every pass.
   *
   * `uUvScale` is the center-anchored aspect-ratio crop, so a pre-pass rendered with this vertex
   * shader covers exactly the region the main pass will sample - on a 9:16 crop of a 16:9 sensor
   * that avoids ~1.8x of wasted blur work, the same saving the Metal version documents.
   */
  const val VERTEX =
      """#version 300 es
precision highp float;

uniform vec2 uUvScale;

// +1 to rasterize normally, -1 to rasterize upside down.
//
// The still-capture path reads its result back with `glReadPixels`, which starts at the
// framebuffer's bottom-left, while a Bitmap's first row is its top one. Flipping the geometry
// rather than the readback is what lets that path avoid a full-frame CPU flip: the two inversions
// cancel and the buffer comes out upright. Only `gl_Position` moves - `vUv` is untouched, so every
// effect samples exactly what it would have unflipped.
uniform float uFlipY;

out vec2 vUv;

void main() {
  // Fullscreen triangle: one primitive covers the whole NDC quad, sparing the rasterizer the
  // diagonal seam of a two-triangle quad.
  vec2 positions[3] = vec2[3](vec2(-1.0, -3.0), vec2(-1.0, 1.0), vec2(3.0, 1.0));
  vec2 uvs[3] = vec2[3](vec2(0.0, 2.0), vec2(0.0, 0.0), vec2(2.0, 0.0));
  vec2 position = positions[gl_VertexID];
  gl_Position = vec4(position.x, position.y * uFlipY, 0.0, 1.0);
  vUv = (uvs[gl_VertexID] - 0.5) * uUvScale + 0.5;
}
"""

  /**
   * Maps one of this pipeline's UVs onto a texture an earlier pass rendered into.
   *
   * Shared verbatim by every stage that reads an intermediate target. It has no counterpart in the
   * Metal version, where a render target's first row is its top one.
   */
  private const val RENDERED_TARGET_UV =
      """
// A framebuffer's first row sits at the bottom in GL's coordinate system, while these shaders count
// UVs from the top the way the Metal original does. Anything an earlier pass rendered therefore
// reads back flipped vertically, and every fetch from an intermediate target has to go through
// here. Uploaded textures - the still-capture bitmap, the grain tile, the LUT atlas - need no such
// flip: `glTexImage2D` puts their first row at t = 0, which is already the top-row convention.
vec2 renderedTargetUv(vec2 uv) {
  return vec2(uv.x, 1.0 - uv.y);
}
"""

  /**
   * Source sampling, colour transfer and the small helpers every fragment stage needs.
   *
   * Concatenated after the `#version`/`#define` prefix and before a pass body.
   */
  private const val COMMON =
      """
precision highp float;
precision highp int;
""" +
          RENDERED_TARGET_UV +
          """

#if SOURCE_EXTERNAL
uniform samplerExternalOES uSource;
#elif SOURCE_YUV
// Single-channel luma at full resolution, and the two chroma channels interleaved at half
// resolution. `GL_LINEAR` on the chroma texture is what upsamples it back to full size, which is
// the same bilinear reconstruction a JPEG decoder would have done - only on the sampler rather
// than over 12 million CPU-side pixels.
uniform sampler2D uSourceY;
uniform sampler2D uSourceUV;
// 1.0 for full-range (JFIF) luma, 0.0 for studio-swing 16-235.
uniform float uYuvFullRange;
#else
uniform sampler2D uSource;
#endif

// Output UV -> source UV. For the camera this is the composed sensor-to-buffer transform handed
// over by CameraX's SurfaceOutput; for a still-capture bitmap it is the quarter turn that brings
// the sensor's buffer upright. Rotating here rather than rotating the Bitmap saves the still path
// a full-frame copy and resample, and puts both source kinds on the same footing: the shader body
// only ever works in output space.
uniform mat4 uSourceTransform;

// Center-anchored aspect-ratio crop, shared with the vertex stage. The fragment stage needs it to
// map source UVs into the cropped span of the pre-pass and aux blur textures.
uniform vec2 uUvScale;

in vec2 vUv;
out vec4 fragColor;

// ============================================================================
// Colour-space transfer (IEC 61966-2-1 sRGB)
// ============================================================================
//
// The proper piecewise transfer, not a pow(x, 2.2) approximation. The approximation compresses
// dark values unevenly and is the source of banding in shadows and low-saturation skies after the
// LUT lookup.

vec3 linearToSrgb(vec3 c) {
  c = clamp(c, 0.0, 1.0);
  vec3 lo = c * 12.92;
  vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
  return mix(hi, lo, vec3(lessThanEqual(c, vec3(0.0031308))));
}

vec3 srgbToLinear(vec3 c) {
  c = clamp(c, 0.0, 1.0);
  vec3 lo = c / 12.92;
  vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
  return mix(hi, lo, vec3(lessThanEqual(c, vec3(0.04045))));
}

// BT.601 luma weights, shared by the desaturation, mist, and grain masks.
float luminance(vec3 c) {
  return dot(c, vec3(0.299, 0.587, 0.114));
}

// Camera-source fetch in linear light.
//
// Both source kinds deliver gamma-encoded sRGB - the driver has already done the YUV conversion
// for the external texture, and still-capture bitmaps are decoded JPEG - so both are linearised
// here, which is where Metal's sRGB texture view did the same job in hardware.
#if SOURCE_YUV
// BT.601, the colour space Android's camera HALs produce `YUV_420_888` in and the one a JFIF JPEG
// is encoded against - so a photo taken through this path lands on the same colours the decoded
// JPEG used to deliver.
//
// The range is a uniform rather than a constant because it is the one part of the layout a
// `YUV_420_888` buffer does not describe: most HALs hand back full-range luma, some hand back
// studio swing, and the two differ by a visible ~7% lift in the blacks.
vec3 yuvToSrgb(float y, vec2 uv) {
  float luma = mix((y - 0.0625) * (255.0 / 219.0), y, uYuvFullRange);
  float chromaScale = mix(255.0 / 224.0, 1.0, uYuvFullRange);
  vec2 chroma = (uv - 0.5) * chromaScale;
  return clamp(
      vec3(
          luma + 1.402 * chroma.y,
          luma - 0.344136 * chroma.x - 0.714136 * chroma.y,
          luma + 1.772 * chroma.x),
      0.0,
      1.0);
}
#endif

vec3 sampleSource(vec2 uv) {
#if SOURCE_EXTERNAL
  // Flip into GL's bottom-left origin before the transform, which CameraX authored against that
  // convention.
  vec2 glUv = vec2(uv.x, 1.0 - uv.y);
  vec2 t = (uSourceTransform * vec4(glUv, 0.0, 1.0)).xy;
#else
  // No flip: `glTexImage2D` puts an uploaded bitmap's first row at t = 0, which already matches
  // the top-left convention these shaders count UVs in, so the transform is authored there too.
  vec2 t = (uSourceTransform * vec4(uv, 0.0, 1.0)).xy;
#endif
#if SOURCE_YUV
  // Both planes are sampled at the same normalised coordinate: the chroma texture is half the size
  // in each axis, so the sampler maps the same UV onto it and interpolates.
  return srgbToLinear(yuvToSrgb(texture(uSourceY, t).r, texture(uSourceUV, t).rg));
#else
  return srgbToLinear(texture(uSource, t).rgb);
#endif
}
"""

  /** Uniform declarations mirroring `CameraUniforms` in `CameraShaderTypes.h`, field for field. */
  private const val UNIFORMS =
      """
uniform float uVignetteIntensity;
uniform float uCaptureScale;
uniform float uDarkenOutside;
uniform float uOutputAspect;
uniform float uGrainOpacity;
uniform vec2 uGrainOffset;
uniform vec2 uGrainUVScale;
uniform float uGrainSwapUV;
uniform float uLutIntensity;
uniform float uCaptureCornerRadius;
uniform float uResolution;
uniform float uColorShift;
uniform float uMist;
uniform float uGrainBehavior;
uniform float uCheapFisheye;
uniform float uPrism;
uniform float uBloom;
uniform float uDiffusion;
// 1.0 to dither the final quantization, 0.0 to leave it alone. See `CameraUniforms.dither`.
uniform float uDither;

uniform sampler2D uGrainTexture;
uniform sampler2D uLutTexture;
uniform sampler2D uPreBlurredTexture;
uniform sampler2D uBloomTexture;
uniform sampler2D uFrameBlurTexture;

// Dimensions of the camera source in pixels; drives every pixel-space tap offset.
uniform vec2 uSourceSize;
"""

  /** The main pass: everything from the crop through to the final sRGB encode. */
  val MAIN_FRAGMENT =
      COMMON +
          UNIFORMS +
          """
// ============================================================================
// Crop & rounded-rect SDF
// ============================================================================

// Signed-distance function for a rounded rectangle centred at the origin. `halfExtent` is square
// (same value on both axes). Negative inside, 0 on the boundary, positive outside.
float roundedRectSDF(vec2 p, float halfExtent, float r) {
  vec2 q = abs(p) - halfExtent + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// sampleUv     - UV to sample in source space.
// localUv      - fragment position normalized to [0,1] across the scaled inner rect; used by the
//                vignette and grain.
// insideScaled - whether this fragment falls inside the scaled rect.
vec2 gSampleUv;
vec2 gLocalUv;
bool gInsideScaled;

void computeCropContext(vec2 uv) {
  // Guard against zero/near-zero captureScale to prevent divide-by-zero NaN.
  float cs = max(uCaptureScale, 1e-4);
  vec2 cropCenter = vec2(0.5);
  // d in [-1, 1] across the full aspect-ratio crop.
  vec2 d = (uv - cropCenter) / (uUvScale * 0.5);

  // Capture passes (darkenOutside == 0): destination *is* the scaled rect, sample only the inner
  // area, and localUv covers [0,1] across the destination. Every fragment is "inside" so the
  // vignette runs corner-to-corner of the saved file - the same physical region as in the preview.
  //
  // Preview passes (darkenOutside > 0): destination is the full aspect crop, sample at the
  // original uv, and localUv is normalized to the *inner* rect so the vignette tracks the captured
  // area, going outside [0,1] for the dimmed border (the vignette is skipped there via
  // insideScaled).
  if (uDarkenOutside <= 0.0) {
    gSampleUv = (uv - cropCenter) * cs + cropCenter;
    gLocalUv = d * 0.5 + 0.5;
    gInsideScaled = true;
  } else {
    gSampleUv = uv;
    gLocalUv = (d / cs) * 0.5 + 0.5;
    // r is clamped so it cannot exceed the half-extent, which would collapse two sides into a
    // circle.
    float r = min(uCaptureCornerRadius, cs);
    gInsideScaled = roundedRectSDF(d, cs, r) <= 0.0;
  }
}

vec3 applyDarkening(vec3 rgb) {
  return gInsideScaled ? rgb : rgb * (1.0 - uDarkenOutside);
}

// ============================================================================
// Cheap fisheye lens
// ============================================================================
//
// Simulates a clip-on plastic fisheye placed in front of the camera: barrel distortion inside a
// circular mask, black outside. Operates in the captured rect's local space (localUv mapped to
// [-1,1] and aspect-corrected so the disk is round in pixel space).
//
// Distortion: rn = r/edge in the unit disk, then rn' = mix(rn, rn*rn, k). Centre is magnified, rim
// slightly compressed. Boundary (rn=1) is fixed so the warped sample never escapes the captured
// source rect.
//
// Trade-off - multi-tap effects sample at the warped sampleUv: the warp runs before the old-camera
// and prism effects, and those use fixed source-space tap offsets. Magnified regions (disk centre)
// get a visibly wider blur on screen, compressed regions (rim) a tighter one. Accepted as part of
// the cheap-lens aesthetic; fixing it would need an extra render target so the post-processed
// image could be warped as a final pass.
//
// Returns a soft alpha mask: 0.0 outside the lens disk (caller renders black), (0,1) inside the
// rim feather band, 1.0 inside the disk core. Also warps gSampleUv and writes rimFactor (0 at the
// centre, 1 at the rim) for the rim fringe below.
float applyCheapFisheye(out float rimFactor) {
  rimFactor = 0.0;
  vec2 p = (gLocalUv - 0.5) * 2.0;
  p.x *= uOutputAspect;
  float r = length(p);

  // Size the disk to the shorter pixel-space half-extent so it stays a true circle on any aspect
  // ratio (with `padding` of breathing room around it). The y half-extent is always 1.0; the x
  // half-extent is uOutputAspect.
  const float padding = 0.075;
  float edge = min(uOutputAspect, 1.0) * (1.0 - padding);
  float feather = edge * 0.06;
  if (r >= edge) return 0.0;

  float rn = r / edge;
  rimFactor = rn;
  const float k = 0.5;
  float rnDistorted = mix(rn, rn * rn, k);
  float scale = (rn > 1e-5) ? (rnDistorted / rn) : (1.0 - k);

  vec2 pDistorted = p * scale;
  pDistorted.x /= uOutputAspect;
  vec2 localUvDistorted = pDistorted * 0.5 + 0.5;

  float cs = max(uCaptureScale, 1e-4);
  gSampleUv += (localUvDistorted - gLocalUv) * uUvScale * cs;

  // Anti-aliased rim: the boundary fades to black over a thin band so it reads as a glass lens
  // edge instead of a hard mask.
  return smoothstep(edge, edge - feather, r);
}

// ============================================================================
// Radial chromatic aberration
// ============================================================================
//
// Shared R/B split used by the old-camera colour shift and the fisheye rim fringe: sample red and
// blue at +/- `shift` (UV units) along the radial axis from the frame centre and mix them in by
// `weight`. The exact-centre fragment has no radial axis and is left untouched.
vec3 applyRadialCA(vec3 rgb, vec2 sampleUv, float shift, float weight) {
  vec2 caVec = sampleUv - 0.5;
  float len = length(caVec);
  if (len <= 1e-5) return rgb;
  vec2 caShift = caVec * (shift / len);
  rgb.r = mix(rgb.r, sampleSource(clamp(sampleUv + caShift, 0.0, 1.0)).r, weight);
  rgb.b = mix(rgb.b, sampleSource(clamp(sampleUv - caShift, 0.0, 1.0)).b, weight);
  return rgb;
}

// A cheap plastic lens bends red and blue by slightly different amounts, strongest where light
// hits the glass at the steepest angle - the disk rim. Ramps the shared radial CA in via
// smoothstep on rimFactor so the centre stays clean and only the rim fringes.
vec3 applyFisheyeRimCA(vec3 rgb, vec2 sampleUv, float rimFactor) {
  float caStrength = smoothstep(0.7, 1.0, rimFactor);
  if (caStrength <= 0.0) return rgb;
  return applyRadialCA(rgb, sampleUv, caStrength * 0.012, caStrength * 0.85);
}

// ============================================================================
// Prism (radial chromatic motion blur)
// ============================================================================

const int kPrismSamples = 5;

vec3 applyPrism(vec3 color, vec2 sampleUv, vec2 localUv, float biggerSide) {
  // Strength and radial direction are computed in *local* UV space (the normalised cropped output)
  // so the rainbow fringe peaks at the corners of the visible image. Using sampleUv (source UV)
  // would anchor the peak to the source corners, which fall outside the visible area whenever a
  // crop is active, and the fringe would never reach full strength in the displayed crop. Sampling
  // still happens in source-UV space, so the radial unit vector is mapped back through
  // uUvScale * captureScale to keep the smear visually radial even on non-uniform crops.
  float strength = clamp(length((localUv - 0.5) * 2.0) - 0.5, 0.0, 1.0);
  if (strength <= 0.0) return color;

  float cs = max(uCaptureScale, 1e-4);
  vec2 radial = (localUv - 0.5) * uUvScale * cs;
  float radialLen = length(radial);
  if (radialLen <= 1e-5) return color;
  radial /= radialLen;

  // Convert per-channel pixel offsets to UV space once.
  vec2 perPixelStep = radial / uSourceSize;
  float baseOffsetPx = strength * uPrism * biggerSide * 0.1;

  vec2 redOffset = -perPixelStep * (baseOffsetPx * 1.0);
  vec2 greenOffset = -perPixelStep * (baseOffsetPx * 1.5);
  vec2 blueOffset = -perPixelStep * (baseOffsetPx * 2.0);
  vec2 stepDelta = perPixelStep * (baseOffsetPx / float(kPrismSamples));

  vec3 accum = vec3(0.0);
  for (int i = 0; i < kPrismSamples; ++i) {
    accum.r += sampleSource(clamp(sampleUv + redOffset, 0.0, 1.0)).r;
    accum.g += sampleSource(clamp(sampleUv + greenOffset, 0.0, 1.0)).g;
    accum.b += sampleSource(clamp(sampleUv + blueOffset, 0.0, 1.0)).b;
    redOffset -= stepDelta;
    greenOffset -= stepDelta;
    blueOffset -= stepDelta;
  }
  // Mix the raw smear into the incoming colour by strength so the centre stays intact and the
  // fringe ramps in toward the corners. Runs before the LUT so the smeared corners get graded
  // together with the rest of the frame.
  return mix(color, accum * (1.0 / float(kPrismSamples)), strength);
}

// ============================================================================
// Single-pass effects (vignette, LUT)
// ============================================================================

// Vignette in linear-light space. `uv` is normalized [0,1] within the scaled rect so the vignette
// tracks the captured area, not the full crop.
//
// `aspectRatio` is width/height of the destination rect in pixels. Without aspect compensation the
// distance calc is in square UV space, so on a tall crop the long-axis corners darken sooner than
// the short-axis ones. Scaling the horizontal component restores the circular shape in pixel
// space.
vec3 applyVignette(vec3 rgb, vec2 uv, float intensity, float aspectRatio) {
  vec2 offset = (uv - 0.5) * 2.0;
  offset.x *= aspectRatio;
  float distSq = dot(offset, offset);
  float vignette = 1.0 - intensity * smoothstep(0.0, 1.0, distSq);
  return rgb * pow(vignette, 2.2);
}

// 3D LUT colour filter, stored as a 512x512 PNG atlas: an 8x8 row-major grid of 64x64 tiles
// forming a 64x64x64 cube. Within a tile x = red and y = green (top to bottom); the tile index is
// the blue slice. LUT images are authored for sRGB-encoded input, so the value is encoded linear
// -> sRGB before the lookup and decoded back afterwards.
//
// GL cannot hardware-filter across atlas tiles, so trilinear is manual: one hardware-bilinear tap
// in each of the two blue-adjacent tiles (the tap interpolates red/green), then a lerp between the
// taps on the blue fraction. Each tap is clamped to the [0.5, 63.5] texel range inside its tile so
// the bilinear footprint can never bleed into a neighbouring tile.

const float kLutTileSize = 64.0;
const int kLutTilesPerRow = 8;
const float kLutAtlasSize = 512.0;

vec3 sampleLutSlice(vec2 rg, int slice) {
  vec2 tileOrigin =
      vec2(float(slice % kLutTilesPerRow), float(slice / kLutTilesPerRow)) * kLutTileSize;
  vec2 texel = tileOrigin + clamp(rg + 0.5, 0.5, kLutTileSize - 0.5);
  return texture(uLutTexture, texel * (1.0 / kLutAtlasSize)).rgb;
}

vec3 applyLut(vec3 rgb, float intensity) {
  vec3 srgbIn = linearToSrgb(rgb);
  vec2 rg = srgbIn.rg * (kLutTileSize - 1.0);
  float b = srgbIn.b * (kLutTileSize - 1.0);
  // b == 63 degenerates to slice0 = 62 with bFrac = 1.0 - full weight on the last slice without
  // reading past the final tile.
  int slice0 = min(int(b), int(kLutTileSize) - 2);
  float bFrac = b - float(slice0);
  vec3 c0 = sampleLutSlice(rg, slice0);
  vec3 c1 = sampleLutSlice(rg, slice0 + 1);
  vec3 lutLinear = srgbToLinear(mix(c0, c1, bFrac));
  return mix(rgb, lutLinear, intensity);
}

// ============================================================================
// Old-camera (low-res blur + chromatic aberration + desaturation)
// ============================================================================
//
// The blur is a 7-tap symmetric 1D Gaussian (W(x) = exp(-2x^2/9)) applied separably - horizontal
// half in a pre-pass, vertical half here. Each half is collapsed from 7 raw taps to 4 bilinear
// taps by pairing adjacent texels and sampling at a weighted fractional offset, so the total cost
// is 4 + 4 = 8 weighted samples instead of 7x7 = 49. Weights are pre-normalised (sum = 1). The
// effective filter is still a perfectly symmetric Gaussian; only the sampling pattern is
// asymmetric.

const int kOldCamBilinearTaps = 4;
const float kOldCamBilinearOffsets[4] =
    float[4](-2.247670180, -0.444671006, 1.339245006, 3.000000000);
const float kOldCamBilinearWeights[4] =
    float[4](0.147912196, 0.487437944, 0.328025442, 0.036624418);

// Vertical half of the separable Gaussian, plus chromatic aberration and desaturation. The
// pre-pass has already written horizontally-blurred linear RGB into uPreBlurredTexture; this walks
// it vertically with the same 4-tap bilinear kernel. CA still reads the un-blurred source - the
// colour fringes must come from the raw image, not the smoothed version.
//
// uUvScale matches the vertex shader's center-anchored UV crop and is also applied by the pre-pass
// vertex shader, so the intermediate texture's [0,1] UV span maps to the cropped region of the
// source. Converting source UV -> pre-pass UV is therefore (s - 0.5) / uvScale + 0.5, and a step
// in source-UV space scales to step / uvScale in pre-pass space.
vec3 applyOldCamera(vec2 sampleUv, vec2 texelSize, float biggerSide) {
  float blurRadius = uResolution * biggerSide * 0.02;

  vec3 lrColor;
  if (blurRadius > 0.0) {
    float stepY = (blurRadius / 3.0) * texelSize.y;
    vec2 sampleUvPre = (sampleUv - 0.5) / uUvScale + 0.5;
    float stepYPre = stepY / uUvScale.y;
    lrColor = vec3(0.0);
    for (int k = 0; k < kOldCamBilinearTaps; ++k) {
      vec2 sampleAt =
          clamp(sampleUvPre + vec2(0.0, kOldCamBilinearOffsets[k] * stepYPre), 0.0, 1.0);
      lrColor += texture(uPreBlurredTexture, renderedTargetUv(sampleAt)).rgb * kOldCamBilinearWeights[k];
    }
  } else {
    lrColor = sampleSource(sampleUv);
  }

  if (uColorShift > 0.0) {
    float caOffset = uColorShift * biggerSide * 0.05 * texelSize.x;
    lrColor = applyRadialCA(lrColor, sampleUv, caOffset, uColorShift * 0.2);
  }

  // Luma-pulled desaturation tied to the blur strength.
  if (uResolution > 0.0) {
    float lrLuma = luminance(lrColor);
    lrColor = mix(lrColor, vec3(lrLuma), uResolution * 0.2);
  }

  return clamp(lrColor, 0.0, 1.0);
}

// ============================================================================
// Mist, bloom, diffusion (composed from renderer-blurred auxiliary textures)
// ============================================================================

// Gain on the blurred halo at bloom == 1 (additive, so it clips fast).
const float kBloomGain = 1.5;
// Blur weight at diffusion == 1. Kept below 1 so full strength reads as strongly soft rather than
// defocused.
const float kDiffusionMaxMix = 0.7;

// Composes the mist look from the original colour and a wide Gaussian blur:
//   1. Brightened "Orton" base from the squared blur.
//   2. Screen blend toward the bright blur - glow on highlights. Masked by the pixel's own
//      luminance so shadows and blacks are not lifted, which otherwise made the photo look faded
//      at high intensity.
//   3. Soft diffusion: mix sharp toward blur.
vec3 composeMist(vec3 color, vec3 blur, float mist) {
  vec3 brightBlur = blur * blur;
  vec3 screenBlend = 1.0 - (1.0 - color) * (1.0 - brightBlur);
  float lum = luminance(color);
  color = mix(color, screenBlend, mist * 0.75 * lum);
  color = mix(color, blur, mist * 0.25);
  return clamp(color, 0.0, 1.0);
}

// ============================================================================
// Final sRGB-space perturbations: grain + dither
// ============================================================================
//
// Both are authored in perceptual (sRGB) space:
//   * Real sensor grain is added by the readout electronics *after* the tone curve, so on a
//     display it looks equally strong in shadows, midtones and highlights. Adding the same
//     amplitude in linear light would be 3-4x more visible in shadows than in skies - the "grain
//     only shows on dark pixels" symptom.
//   * Dither breaks up the posterized contours produced by the final 8-bit quantization, which is
//     in sRGB-encoded space. One LSB == 1/255 there.
//
// Combining them into one encode/decode pair saves an sRGB roundtrip.

// PCG-style integer hash. Bit-mixes a 32-bit input to a 32-bit output with uniform distribution.
uint pcgHash(uint v) {
  v = v * 747796405u + 2891336453u;
  uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
  return (w >> 22u) ^ w;
}

// Triangular PDF noise on [-1, 1] from the packed fragment coordinate. The sum of two i.i.d.
// uniforms gives the canonical TPDF dither. The 24-bit mask is the largest fp32-exact spacing.
float ditherTriangular(vec2 fragCoord) {
  uvec2 p = uvec2(fragCoord);
  uint h1 = pcgHash(p.x + p.y * 0x9E3779B9u);
  uint h2 = pcgHash(p.y + p.x * 0x85EBCA6Bu);
  float u1 = float(h1 & 0xFFFFFFu) * (1.0 / 16777216.0);
  float u2 = float(h2 & 0xFFFFFFu) * (1.0 / 16777216.0);
  return u1 + u2 - 1.0;
}

// Applies grain and dither in one sRGB encode/decode pair. Grain is skipped when grainOpacity is
// 0, dither when uDither is.
//
// With both off there is nothing to perturb, and the encode/decode pair is not merely wasted: it
// is the whole reason this function has to be skipped rather than run with zero amplitude. The
// still-capture path renders its un-effected original through here, and a round trip that has to
// survive being byte-compared is one the pipeline should not be making at all.
vec3 applySrgbPerturbations(vec3 rgb, float grainOpacity, vec2 grainUv, vec2 fragCoord) {
  if (grainOpacity <= 0.0 && uDither <= 0.0) {
    return rgb;
  }

  vec3 srgb = linearToSrgb(rgb);

  if (grainOpacity > 0.0) {
    // uGrainTexture is bound with GL_REPEAT, matching Metal's address::repeat sampler.
    vec2 gUv = fract(grainUv * uGrainUVScale + uGrainOffset);
    vec3 grain = texture(uGrainTexture, gUv).rgb - 0.5;
    if (uGrainBehavior > 0.5) {
      // Dark-only: additive grain scaled by inverse sRGB luminance so it fades out on highlights
      // and is most visible in shadows.
      float luma = luminance(srgb);
      float mask = pow(1.0 - luma, 3.25);
      srgb += grain * grainOpacity * mask;
    } else {
      // Overlay (uniform): additive grain visible across all tones.
      srgb += grain * grainOpacity;
    }
  }

  srgb += ditherTriangular(fragCoord) * uDither / 255.0;
  return srgbToLinear(clamp(srgb, 0.0, 1.0));
}

// ============================================================================
// Post-process pipeline
// ============================================================================
//
// Pipeline order: lens/sensor sim -> atmospheric -> colour grade -> darken -> final perturbations
// -> vignette.
//
// The LUT must run AFTER the multi-tap effects (old-cam, prism) because those re-sample the raw
// source per tap and would discard any earlier LUT-graded value - and after mist/diffusion/bloom,
// whose renderer-blurred textures are likewise derived from the ungraded source. The vignette runs
// last so it darkens grain and every other effect.
void main() {
  computeCropContext(vUv);

  float fisheyeMask = 1.0;
  float fisheyeRim = 0.0;
  if (uCheapFisheye > 0.5 && gInsideScaled) {
    fisheyeMask = applyCheapFisheye(fisheyeRim);
    if (fisheyeMask <= 0.0) {
      fragColor = vec4(0.0, 0.0, 0.0, 1.0);
      return;
    }
  }

  vec3 rgb = sampleSource(gSampleUv);

  if (gInsideScaled) {
    vec2 texelSize = 1.0 / uSourceSize;
    float biggerSide = max(uSourceSize.x, uSourceSize.y);
    // Source UV -> aux blur-texture UV, shared by mist, diffusion and bloom (their
    // renderer-blurred textures all span the uvScale-cropped source region). No clamp is needed at
    // the sample sites: those textures are bound with GL_CLAMP_TO_EDGE.
    vec2 auxBlurUv = renderedTargetUv((gSampleUv - 0.5) / uUvScale + 0.5);

    if (uResolution > 0.0 || uColorShift > 0.0) {
      rgb = applyOldCamera(gSampleUv, texelSize, biggerSide);
    }
    if (uMist > 0.0) {
      rgb = composeMist(rgb, texture(uFrameBlurTexture, auxBlurUv).rgb, uMist);
    }
    if (uDiffusion > 0.0) {
      // Soft-focus: mix toward the renderer-blurred full frame. Runs before bloom so the additive
      // halo stays luminous on top of the softened base.
      rgb = mix(rgb, texture(uFrameBlurTexture, auxBlurUv).rgb, uDiffusion * kDiffusionMaxMix);
    }
    if (uBloom > 0.0) {
      vec3 glow = texture(uBloomTexture, auxBlurUv).rgb;
      rgb = clamp(rgb + glow * (uBloom * kBloomGain), 0.0, 1.0);
    }
    if (uCheapFisheye > 0.5) {
      rgb = applyFisheyeRimCA(rgb, gSampleUv, fisheyeRim);
    }
    if (uPrism > 0.0) {
      rgb = applyPrism(rgb, gSampleUv, gLocalUv, biggerSide);
    }
    if (uLutIntensity > 0.0) {
      rgb = applyLut(rgb, uLutIntensity);
    }
  }

  rgb = applyDarkening(rgb);

  // Grain runs only inside the scaled rect; dither always runs (one global encode/decode pair).
  float effectiveGrainOpacity = gInsideScaled ? uGrainOpacity : 0.0;
  vec2 grainUv = uGrainSwapUV > 0.5 ? gLocalUv.yx : gLocalUv;
  rgb = applySrgbPerturbations(rgb, effectiveGrainOpacity, grainUv, gl_FragCoord.xy);

  if (gInsideScaled) {
    rgb = applyVignette(rgb, gLocalUv, uVignetteIntensity, uOutputAspect);
  }

  rgb *= fisheyeMask;

  // Metal renders into an sRGB view and gets this encode for free; GLES does it explicitly.
  fragColor = vec4(linearToSrgb(rgb), 1.0);
}
"""

  /**
   * Horizontal half of the old-camera separable Gaussian.
   *
   * Renders at source resolution over the uvScale-cropped region and writes linear-light RGB into
   * an intermediate texture the main pass then walks vertically.
   */
  val PREPASS_H_FRAGMENT =
      COMMON +
          """
uniform float uResolution;
uniform vec2 uSourceSize;

const int kOldCamBilinearTaps = 4;
const float kOldCamBilinearOffsets[4] =
    float[4](-2.247670180, -0.444671006, 1.339245006, 3.000000000);
const float kOldCamBilinearWeights[4] =
    float[4](0.147912196, 0.487437944, 0.328025442, 0.036624418);

void main() {
  float biggerSide = max(uSourceSize.x, uSourceSize.y);
  // The blur radius and step mirror the vertical half computed in applyOldCamera.
  float blurRadius = uResolution * biggerSide * 0.02;
  float stepX = (blurRadius / 3.0) * (1.0 / uSourceSize.x);

  vec3 sum = vec3(0.0);
  for (int k = 0; k < kOldCamBilinearTaps; ++k) {
    vec2 sampleAt = clamp(vUv + vec2(kOldCamBilinearOffsets[k] * stepX, 0.0), 0.0, 1.0);
    sum += sampleSource(sampleAt) * kOldCamBilinearWeights[k];
  }
  fragColor = vec4(sum, 1.0);
}
"""

  /**
   * The downsample both aux extract passes read their source through.
   *
   * Concatenated after [COMMON], which defines the `sampleSource` it builds on.
   */
  private const val AUX_DOWNSAMPLE =
      """
// One aux texel expressed in source-UV units: uUvScale / auxSize. The renderer knows both, so it
// hands the ratio over rather than making every fragment recover it.
uniform vec2 uAuxTexel;

// Averages the source footprint one aux texel stands for.
//
// The aux targets are a quarter of the output on each axis, so one aux texel covers a 4x4 block of
// source texels. A single tap reads one 2x2 corner of that block and throws the other 75% away.
// That is harmless for the preview, whose stream the ISP has already low-passed on its way down
// from the sensor - a highlight arrives smeared over many pixels and survives being point-sampled.
// It is not harmless for a still, which reaches this pass at full sensor resolution and unfiltered:
// a sharp specular highlight lands between the taps, never makes it into the bright pass, and the
// bloom halo that was plainly visible in the preview is missing from the saved photo. Mist and
// diffusion lose the same energy, but with no threshold downstream to turn it into a cliff, the
// loss reads as a slightly weaker blur rather than a missing effect.
//
// Four bilinear taps at +/- a quarter of an aux texel sit exactly on source-texel boundaries at a
// 4x ratio, so each averages a 2x2 block and the four together cover all 16 texels once: an exact
// 4x4 box for the price of four fetches. Off-ratio (the still's uvScale crop can shift it slightly)
// they degrade into a wider-but-still-symmetric average, which is the harmless direction. Taps a
// quarter texel outside the crop at the frame edge need no clamp - every source this pass reads is
// bound GL_CLAMP_TO_EDGE.
vec3 sampleSourceBox(vec2 uv) {
  vec2 o = uAuxTexel * 0.25;
  return 0.25 * (sampleSource(uv + vec2(-o.x, -o.y)) +
                 sampleSource(uv + vec2( o.x, -o.y)) +
                 sampleSource(uv + vec2(-o.x,  o.y)) +
                 sampleSource(uv + vec2( o.x,  o.y)));
}
"""

  /**
   * Bloom bright-pass: keeps only the above-threshold highlights, weighted by excess luminance.
   *
   * Rendered at quarter resolution over the uvScale-cropped region; [GAUSSIAN_FRAGMENT] then
   * spreads it into the halo the main pass adds back.
   */
  val BLOOM_BRIGHT_FRAGMENT =
      COMMON +
          AUX_DOWNSAMPLE +
          """
// Linear-light highlight cutoff; higher blooms only the brightest pixels.
//
// A uniform rather than Metal's compile-time constant. The cutoff is applied to linear light, so
// the default 0.75 is about 226/255 in sRGB, and the weight ramps from there to 1.0 over the last
// 29 codes - a narrow window that sits exactly where a camera pipeline's highlight handling
// differs most. A preview stream clips a bright lamp to 255 and blooms it at full weight; the
// same lamp in a still that the ISP has rolled off lands near 240 and blooms at a third of that.
// Keeping it settable lets that be tuned per platform without recompiling the shader.
uniform float uBloomThreshold;

void main() {
  vec3 c = sampleSourceBox(vUv);
  float w = clamp((luminance(c) - uBloomThreshold) / (1.0 - uBloomThreshold), 0.0, 1.0);
  fragColor = vec4(c * w, 1.0);
}
"""

  /**
   * Frame-blur downsample feeding mist and diffusion.
   *
   * Writes the decoded frame as linear RGB at quarter resolution; 8-bit linear would band in
   * shadows, so the target is half-float where the device supports it.
   */
  val FRAME_BLUR_DOWNSAMPLE_FRAGMENT =
      COMMON +
          AUX_DOWNSAMPLE +
          """
void main() {
  fragColor = vec4(sampleSourceBox(vUv), 1.0);
}
"""

  /**
   * One half of a separable Gaussian over an already-rendered texture.
   *
   * Stands in for `MPSImageGaussianBlur`, which the Metal renderer uses for the bloom halo and the
   * mist/diffusion frame blur. Runs twice per blur - once horizontally, once vertically.
   *
   * The weights are computed from `uSigma` rather than baked in, because the two callers use
   * different sigmas and both scale with the working resolution. Taps are spread over +/-3 sigma,
   * which captures over 99% of the kernel's mass. Both blurs run at quarter resolution, so the
   * fetch count is not worth optimising into bilinear pairs.
   */
  val GAUSSIAN_FRAGMENT =
      DEFINE_NO_SOURCE +
          """
precision highp float;
""" +
          RENDERED_TARGET_UV +
          """
uniform sampler2D uBlurSource;
// Unit step along the blur axis: (1/width, 0) horizontally or (0, 1/height) vertically.
uniform vec2 uBlurDirection;
// Gaussian standard deviation, in texels of the source texture.
uniform float uSigma;

in vec2 vUv;
out vec4 fragColor;

const int kTapsPerSide = 9;

void main() {
  float sigma = max(uSigma, 0.5);
  float texelStep = (3.0 * sigma) / float(kTapsPerSide);

  // Flipped here as well as at the final read, so a blur pass leaves its target in the same
  // orientation it found it - the aux chain then reads the same whether it ran one pass or two.
  vec2 base = renderedTargetUv(vUv);

  vec3 sum = texture(uBlurSource, base).rgb;
  float weightSum = 1.0;
  for (int i = 1; i <= kTapsPerSide; ++i) {
    float distance = float(i) * texelStep;
    float weight = exp(-0.5 * (distance / sigma) * (distance / sigma));
    vec2 offset = uBlurDirection * distance;
    sum += texture(uBlurSource, clamp(base + offset, 0.0, 1.0)).rgb * weight;
    sum += texture(uBlurSource, clamp(base - offset, 0.0, 1.0)).rgb * weight;
    weightSum += 2.0 * weight;
  }
  fragColor = vec4(sum / weightSum, 1.0);
}
"""
}
