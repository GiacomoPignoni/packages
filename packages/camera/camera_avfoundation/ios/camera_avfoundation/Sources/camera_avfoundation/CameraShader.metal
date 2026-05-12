#include <metal_stdlib>

// `CameraUniforms`, the source-format constants, and the texture bind slots
// are shared with the Swift renderer through this header — the single source
// of truth for the cross-language ABI.
#include "../camera_avfoundation_shader_types/include/CameraShaderTypes.h"

using namespace metal;

// ============================================================================
// Vertex stage
// ============================================================================

struct VertexOut {
  float4 position [[position]];
  float2 uv;
};

// Fullscreen triangle shared by the main and pre-pass vertex stages: a single
// primitive covers the whole NDC quad, sparing the rasterizer the diagonal seam
// of a two-triangle quad. The UV is center-anchored so `uvScale` shrinks (or
// expands) the sampled sub-rect around (0.5, 0.5) for cropping.
static inline VertexOut fullscreenTriangle(uint vid, float2 uvScale) {
  float2 positions[3] = {float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0)};
  float2 uvs[3] = {float2(0.0, 2.0), float2(0.0, 0.0), float2(2.0, 0.0)};
  VertexOut out;
  out.position = float4(positions[vid], 0.0, 1.0);
  out.uv = (uvs[vid] - 0.5) * uvScale + 0.5;
  return out;
}

vertex VertexOut camera_vertex(
    uint vid [[vertex_id]],
    constant CameraUniforms& uniforms [[buffer(0)]]) {
  return fullscreenTriangle(vid, uniforms.uvScale);
}

// ============================================================================
// Colour-space transfer (IEC 61966-2-1 sRGB)
// ============================================================================
//
// The proper piecewise transfer — not a pow(x, 2.2) approximation. The
// approximation compresses dark values unevenly and is the source of banding
// in shadows and low-saturation skies after the LUT lookup.

static inline float3 linearToSrgb(float3 c) {
  c = saturate(c);
  float3 lo = c * 12.92;
  float3 hi = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
  return select(hi, lo, c <= float3(0.0031308));
}

static inline float3 srgbToLinear(float3 c) {
  c = saturate(c);
  float3 lo = c / 12.92;
  float3 hi = pow((c + 0.055) / 1.055, float3(2.4));
  return select(hi, lo, c <= float3(0.04045));
}

// BT.601 luma weights, shared by the desaturation, mist, and grain masks.
static inline float luminance(float3 c) {
  return dot(c, float3(0.299, 0.587, 0.114));
}

// ============================================================================
// YUV decode (BT.709)
// ============================================================================
//
// CbCr is centred at 0.5; subtract once and apply the matrix. Result is
// gamma-encoded RGB, then linearised so the downstream pipeline can do its
// math in linear light (and the sRGB destination view encodes on write).

// BT.709 matrix on centred Cb/Cr, then linearise the gamma-encoded result.
static inline float3 yuvToLinear(float y, float2 cbcr) {
  float3 c;
  c.r = y + 1.5748 * cbcr.y;
  c.g = y - 0.1873 * cbcr.x - 0.4681 * cbcr.y;
  c.b = y + 1.8556 * cbcr.x;
  return srgbToLinear(saturate(c));
}

// Full-range Y'CbCr (420f).
static inline float3 sampleYuvFull(
    float2 uv, texture2d<float> yTex, texture2d<float> cbcrTex, sampler s) {
  float y = yTex.sample(s, uv).r;
  float2 cbcr = cbcrTex.sample(s, uv).rg - float2(0.5);
  return yuvToLinear(y, cbcr);
}

// Video-range Y'CbCr (420v): Y ∈ [16/255, 235/255], CbCr ∈ [16/255, 240/255].
static inline float3 sampleYuvVideo(
    float2 uv, texture2d<float> yTex, texture2d<float> cbcrTex, sampler s) {
  float y = (yTex.sample(s, uv).r - 16.0 / 255.0) * (255.0 / 219.0);
  float2 cbcr = (cbcrTex.sample(s, uv).rg - float2(128.0 / 255.0)) * (255.0 / 224.0);
  return yuvToLinear(y, cbcr);
}

// ============================================================================
// Crop & rounded-rect SDF
// ============================================================================

// Signed-distance function for a rounded rectangle centred at the origin.
// `halfExtent` is square (same value on both axes). Returns negative inside,
// 0 on the boundary, positive outside.
static inline float roundedRectSDF(float2 p, float halfExtent, float r) {
  float2 q = abs(p) - halfExtent + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Output of `computeCropContext`.
//   sampleUv     — UV to sample in source space.
//   localUv      — fragment position normalized to [0,1] across the scaled
//                  inner rect; used by the vignette and grain.
//   insideScaled — whether this fragment falls inside the scaled rect.
struct CropContext {
  float2 sampleUv;
  float2 localUv;
  bool insideScaled;
};

static inline CropContext computeCropContext(
    float2 uv,
    float2 uvScale,
    float captureScale,
    float darkenOutside,
    float captureCornerRadius) {
  // Guard against zero/near-zero captureScale to prevent divide-by-zero NaN.
  float cs = max(captureScale, 1e-4);
  float2 cropCenter = float2(0.5);
  // d in [-1, 1] across the full aspect-ratio crop.
  float2 d = (uv - cropCenter) / (uvScale * 0.5);

  CropContext ctx;
  // Capture passes (darkenOutside == 0): destination *is* the scaled rect,
  // sample only the inner area, and `localUv` covers [0,1] across the
  // destination. Every fragment is "inside" so the vignette runs corner-
  // to-corner of the saved file — same physical region as in the preview.
  //
  // Preview passes (darkenOutside > 0): destination is the full aspect
  // crop, sample at the original uv, and `localUv` is normalized to the
  // *inner* rect so the vignette tracks the captured area, going outside
  // [0,1] for the dimmed border (we skip the vignette there via
  // `insideScaled`).
  if (darkenOutside <= 0.0) {
    ctx.sampleUv = (uv - cropCenter) * cs + cropCenter;
    ctx.localUv = d * 0.5 + 0.5;
    ctx.insideScaled = true;
  } else {
    ctx.sampleUv = uv;
    ctx.localUv = (d / cs) * 0.5 + 0.5;
    // r is clamped so it cannot exceed the half-extent (which would
    // collapse two sides into a circle).
    float r = min(captureCornerRadius, cs);
    ctx.insideScaled = roundedRectSDF(d, cs, r) <= 0.0;
  }
  return ctx;
}

static inline float3 applyDarkening(float3 rgb, bool insideScaled, float darkenOutside) {
  return insideScaled ? rgb : rgb * (1.0 - darkenOutside);
}

// ============================================================================
// Cheap fisheye lens
// ============================================================================
//
// Simulates a clip-on plastic fisheye placed in front of the camera: barrel
// distortion inside a circular mask, black outside. Operates in the captured
// rect's local space (`localUv` mapped to [-1,1] and aspect-corrected so the
// disk is round in pixel space).
//
// Distortion: rn = r/edge in the unit disk, then rn' = mix(rn, rn*rn, k).
// Center is magnified, rim slightly compressed. Boundary (rn=1) is fixed so
// the warped sample never escapes the captured source rect.
//
// `sampleUv = 0.5 + (localUv - 0.5) * uvScale * captureScale` holds in both
// capture and preview paths (see computeCropContext), so a local-UV shift
// maps to a source-UV shift via the same factor.
//
// Trade-off — multi-tap effects sample at the warped sampleUv: the warp runs
// before applyOldCamera / applyPrism (see renderCamera), and those effects
// use fixed source-space tap offsets. Magnified regions (disk centre) get a
// visibly wider blur on screen, compressed regions (rim) get a tighter one.
// Accepted as part of the cheap-lens aesthetic; fixing it would require an
// extra render target so the post-processed image can be warped as a final
// pass.
//
// Returns a soft alpha mask:
//   0.0       — outside the lens disk (caller should render black)
//   ∈ (0, 1)  — inside the rim feather band (smooth fade)
//   1.0       — inside the disk core
// Also updates `sampleUv` with the barrel-warped lookup and writes
// `rimFactor` (0 at the center, 1 at the rim) for downstream rim effects.
static inline float applyCheapFisheye(
    thread float2& sampleUv,
    thread float& rimFactor,
    float2 localUv,
    float2 uvScale,
    float captureScale,
    float outputAspect) {
  float2 p = (localUv - 0.5) * 2.0;
  p.x *= outputAspect;
  float r = length(p);

  // Size the disk to the shorter pixel-space half-extent so it stays a true
  // circle on any aspect ratio (with `padding` of breathing room around it).
  // y half-extent is always 1.0; x half-extent is `outputAspect`.
  const float padding = 0.075;
  float edge = min(outputAspect, 1.0) * (1.0 - padding);
  float feather = edge * 0.06;
  if (r >= edge) return 0.0;

  float rn = r / edge;
  rimFactor = rn;
  const float k = 0.5;
  float rnDistorted = mix(rn, rn * rn, k);
  float scale = (rn > 1e-5) ? (rnDistorted / rn) : (1.0 - k);

  float2 pDistorted = p * scale;
  pDistorted.x /= outputAspect;
  float2 localUvDistorted = pDistorted * 0.5 + 0.5;

  float cs = max(captureScale, 1e-4);
  sampleUv += (localUvDistorted - localUv) * uvScale * cs;

  // Anti-aliased rim: the boundary fades to black over a thin band so it
  // reads as a glass lens edge instead of a hard mask.
  return smoothstep(edge, edge - feather, r);
}

// ============================================================================
// Sampler functors & source-format specialisation
// ============================================================================
//
// MSL (C++14) lets struct functors carry textures and a sampler. The
// templated multi-tap effects below take one of these and call it for every
// tap, so the per-format sampling logic lives in exactly one place.

// Plain RGB texture fetch (no YUV/sRGB decode). Used for the BGRA camera source
// and for the pre-blurred intermediate, which is already linear-light RGB at
// source resolution.
struct RgbSampleFn {
  texture2d<float> tex;
  sampler s;
  float3 operator()(float2 uv) const { return tex.sample(s, uv).rgb; }
};

// Source pixel format, bound at pipeline-creation time. One fragment entry
// point per pass serves all three formats; the renderer compiles one
// specialised pipeline per format, so the branches in `SourceSampleFn` fold
// away — codegen matches hand-written per-format functions. Values are the
// shared `CameraShaderSourceFormat` constants.
constant int kSourceFormat [[function_constant(0)]];
constant bool kIsYuvFull = (kSourceFormat == CameraShaderSourceFormatYuvFullRange);
constant bool kIsYuvVideo = (kSourceFormat == CameraShaderSourceFormatYuvVideoRange);

// Camera-source fetch, specialised by `kSourceFormat`. For YUV formats `tex0`
// is the Y plane and `cbcrTex` the interleaved chroma plane; for BGRA `tex0`
// is the source itself and `cbcrTex` is dummy-bound (never sampled).
struct SourceSampleFn {
  texture2d<float> tex0;
  texture2d<float> cbcrTex;
  sampler s;
  float3 operator()(float2 uv) const {
    if (kIsYuvFull) return sampleYuvFull(uv, tex0, cbcrTex, s);
    if (kIsYuvVideo) return sampleYuvVideo(uv, tex0, cbcrTex, s);
    return tex0.sample(s, uv).rgb;
  }
};

// ============================================================================
// Radial chromatic aberration
// ============================================================================
//
// Shared R/B split used by the old-camera colour shift and the fisheye rim
// fringe: sample red and blue at ±`shift` (UV units) along the radial axis
// from the frame centre and mix them in by `weight`. The exact-centre
// fragment has no radial axis and is left untouched.
template <typename SampleFn>
static inline float3 applyRadialCA(
    float3 rgb, float2 sampleUv, float shift, float weight, SampleFn sampleColor) {
  float2 caVec = sampleUv - 0.5;
  float len = length(caVec);
  if (len <= 1e-5) return rgb;
  float2 caShift = caVec * (shift / len);
  rgb.r = mix(rgb.r, sampleColor(clamp(sampleUv + caShift, 0.0, 1.0)).r, weight);
  rgb.b = mix(rgb.b, sampleColor(clamp(sampleUv - caShift, 0.0, 1.0)).b, weight);
  return rgb;
}

// ============================================================================
// Fisheye rim chromatic aberration
// ============================================================================
//
// A cheap plastic lens bends red and blue wavelengths by slightly different
// amounts, with the effect strongest where light hits glass at the steepest
// angle — the disk rim. Ramps the shared radial CA in via smoothstep on
// `rimFactor` so the centre stays clean and only the rim fringes.
template <typename SampleFn>
static inline float3 applyFisheyeRimCA(
    float3 rgb, float2 sampleUv, float rimFactor, SampleFn sampleColor) {
  float caStrength = smoothstep(0.7, 1.0, rimFactor);
  if (caStrength <= 0.0) return rgb;
  return applyRadialCA(
      rgb, sampleUv, caStrength * 0.012, caStrength * 0.85, sampleColor);
}

// ============================================================================
// Prism (radial chromatic motion blur)
// ============================================================================
//
// Smears R/G/B along the radial axis with a short multi-tap accumulation,
// yielding a rainbow streak that vanishes at the centre and peaks at the
// corners. Mirrors the reference motion-chromatic shader with falloff=0 and
// inputScale=1 (both drop out of the math); kPrismSamples replaces the
// GLES "for(i<100) break" pattern that only existed because GLES needed a
// constant loop bound.

constant int kPrismSamples = 5;

template <typename SampleFn>
static inline float3 applyPrism(
    float3 color,
    float2 sampleUv,
    float2 localUv,
    float2 uvScale,
    float captureScale,
    float2 sourceSize,
    float biggerSide,
    float prism,
    SampleFn sampleColor) {
  // Strength + radial direction are computed in *local* UV space (the
  // normalised cropped output) so the rainbow fringe peaks at the corners
  // of the visible image. Using `sampleUv` (source UV) would anchor the
  // peak to the source corners — which fall outside the visible area
  // whenever an aspect-ratio or capture-scale crop is active — and the
  // fringe would never actually reach full strength in the displayed crop.
  // Sampling still happens in source-UV space, so the radial unit vector
  // is mapped back through `uvScale * captureScale` to keep the smear
  // visually radial even on non-uniform crops.
  float strength = saturate(length((localUv - 0.5) * 2.0) - 0.5);
  if (strength <= 0.0) return color;

  float cs = max(captureScale, 1e-4);
  float2 radial = (localUv - 0.5) * uvScale * cs;
  float radialLen = length(radial);
  if (radialLen <= 1e-5) return color;
  radial /= radialLen;

  // Convert per-channel pixel offsets to UV space once.
  float2 perPixelStep = radial / sourceSize;
  float baseOffsetPx = strength * prism * biggerSide * 0.1;

  float2 redOffset   = -perPixelStep * (baseOffsetPx * 1.0);
  float2 greenOffset = -perPixelStep * (baseOffsetPx * 1.5);
  float2 blueOffset  = -perPixelStep * (baseOffsetPx * 2.0);
  float2 stepDelta   = perPixelStep * (baseOffsetPx / float(kPrismSamples));

  float3 accum = float3(0.0);
  for (int i = 0; i < kPrismSamples; ++i) {
    accum.r += sampleColor(clamp(sampleUv + redOffset,   0.0, 1.0)).r;
    accum.g += sampleColor(clamp(sampleUv + greenOffset, 0.0, 1.0)).g;
    accum.b += sampleColor(clamp(sampleUv + blueOffset,  0.0, 1.0)).b;
    redOffset   -= stepDelta;
    greenOffset -= stepDelta;
    blueOffset  -= stepDelta;
  }
  // Mix the raw smear into the incoming colour by strength so the centre
  // stays intact and the rainbow fringe ramps in toward the corners. Runs
  // before the LUT so the smeared corners get graded together with the rest
  // of the frame.
  return mix(color, accum * (1.0 / float(kPrismSamples)), strength);
}

// ============================================================================
// Single-pass effects (vignette, LUT)
// ============================================================================

// Vignette in linear-light space. `uv` is normalized [0,1] within the
// scaled rect so the vignette tracks the captured area, not the full crop.
//
// `aspectRatio` = width/height of the destination rect in pixels. Without
// aspect compensation the distance calc is in square UV space, so on a
// tall crop (e.g. 9:16) the long-axis corners darken sooner than the
// short-axis corners. Multiplying the horizontal component by the aspect
// ratio restores the circular shape in pixel space.
static inline float3 applyVignette(
    float3 rgb, float2 uv, float intensity, float aspectRatio) {
  float2 offset = (uv - 0.5) * 2.0;        // [-1, 1] in UV space
  offset.x *= aspectRatio;                 // scale to pixel-aspect space
  float distSq = dot(offset, offset);
  float vignette = 1.0 - intensity * smoothstep(0.0, 1.0, distSq);
  return rgb * pow(vignette, 2.2);
}

// 3D LUT colour filter, stored as a 512×512 PNG atlas: an 8×8 row-major
// grid (left→right, top→bottom) of 64×64 tiles forming a 64×64×64 cube.
// Within a tile x = red (0..63) and y = green (0..63, top to bottom); the
// tile index is the blue slice. LUT images are authored for sRGB-encoded
// input, so we encode linear → sRGB before the lookup and decode the
// result back to linear.
//
// Metal cannot hardware-filter across atlas tiles, so trilinear is manual:
// one hardware-bilinear tap in each of the two blue-adjacent tiles (the
// tap interpolates red/green), then a lerp between the taps on the blue
// fraction. Each tap is clamped to the [0.5, 63.5] texel range inside its
// tile so the bilinear footprint can never bleed into a neighbouring tile.

constant float kLutTileSize = 64.0;   // one blue slice is 64×64 texels
constant int kLutTilesPerRow = 8;     // 8×8 grid of tiles
constant float kLutAtlasSize = 512.0; // kLutTileSize * kLutTilesPerRow

// One bilinear tap inside the tile for blue slice `slice`. `rg` is the
// red/green coordinate scaled to texel-index space [0, 63]; the texel
// centre of index i sits at i + 0.5.
static inline float3 sampleLutSlice(
    texture2d<float, access::sample> lutTex, float2 rg, int slice) {
  constexpr sampler lutSampler(mag_filter::linear, min_filter::linear,
                               address::clamp_to_edge);
  float2 tileOrigin = float2(float(slice % kLutTilesPerRow),
                             float(slice / kLutTilesPerRow)) * kLutTileSize;
  float2 texel = tileOrigin + clamp(rg + 0.5, 0.5, kLutTileSize - 0.5);
  return lutTex.sample(lutSampler, texel * (1.0 / kLutAtlasSize)).rgb;
}

static inline float3 applyLut(
    float3 rgb, texture2d<float, access::sample> lutTex, float intensity) {
  float3 srgbIn = linearToSrgb(rgb);            // saturates → [0, 1]
  float2 rg = srgbIn.rg * (kLutTileSize - 1.0); // [0, 63]
  float b = srgbIn.b * (kLutTileSize - 1.0);    // [0, 63]
  // b == 63 degenerates to slice0 = 62 with bFrac = 1.0 — full weight on
  // the last slice without reading past the final tile.
  int slice0 = min(int(b), int(kLutTileSize) - 2);
  float bFrac = b - float(slice0);
  float3 c0 = sampleLutSlice(lutTex, rg, slice0);
  float3 c1 = sampleLutSlice(lutTex, rg, slice0 + 1);
  float3 lutLinear = srgbToLinear(mix(c0, c1, bFrac));
  return mix(rgb, lutLinear, intensity);
}

// ============================================================================
// Old-camera (low-res blur + chromatic aberration + desaturation)
// ============================================================================
//
// The blur is a 7-tap symmetric 1D Gaussian (W(x) = exp(-2x²/9)) applied
// separably — horizontal half in a pre-pass, vertical half here. Each half
// is collapsed from 7 raw taps to 4 bilinear taps by pairing adjacent texels
// and sampling at a weighted fractional offset, so total cost is 4 + 4 = 8
// weighted samples instead of the old 7×7 = 49.
//
//   pair (-3,-2): wsum 0.5464, offset -2.2477
//   pair (-1, 0): wsum 1.8007, offset -0.4447
//   pair ( 1, 2): wsum 1.2118, offset  1.3392
//   single ( 3): w 0.1353, offset 3.0000
//
// Weights below are pre-normalised (Σ = 1) so the inner loop just multiplies
// and adds — no final divide. The effective filter is still a perfectly
// symmetric Gaussian; only the sampling pattern is asymmetric.

constant int kOldCamBilinearTaps = 4;
constant float kOldCamBilinearOffsets[4] = {
    -2.247670180, -0.444671006, 1.339245006, 3.000000000,
};
constant float kOldCamBilinearWeights[4] = {
     0.147912196,  0.487437944, 0.328025442, 0.036624418,
};

// Horizontal half of the separable Gaussian. Shared by the three pre-pass
// fragment entry points below. `texelStepX` is the per-tap UV stride
// (already scaled by the desired blur radius); `kOldCamBilinearOffsets`
// then walks the four bilinear sample positions along that stride.
template <typename SampleFn>
static inline float3 oldCamHorizontalBlur(
    float2 uv, float texelStepX, SampleFn sampleColor) {
  float3 sum = float3(0.0);
  for (int k = 0; k < kOldCamBilinearTaps; ++k) {
    float2 sampleAt = clamp(
        uv + float2(kOldCamBilinearOffsets[k] * texelStepX, 0.0), 0.0, 1.0);
    sum += sampleColor(sampleAt) * kOldCamBilinearWeights[k];
  }
  return sum;
}

// Vertical half of the separable Gaussian + chromatic-aberration +
// desaturation. The pre-pass has already written horizontally-blurred linear
// RGB into `samplePreBlurred`; here we walk it vertically with the same
// 4-tap bilinear kernel. CA still reads from the un-blurred source
// (`sampleColor`) — the colour fringes must come from the raw image, not
// the smoothed version. Caller guarantees at least one of
// `resolution`/`colorShift` is > 0.
//
// `uvScale` matches the main vertex shader's center-anchored UV crop and is
// also applied by the pre-pass vertex shader, so the intermediate texture's
// [0,1] UV span maps to the cropped region of the source. Converting source
// UV → pre-pass UV is therefore `(s - 0.5) / uvScale + 0.5`, and a step in
// source-UV space scales to `step / uvScale` in pre-pass space.
template <typename SampleFn, typename PreBlurredFn>
static inline float3 applyOldCamera(
    float2 sampleUv,
    float2 uvScale,
    float2 texelSize,
    float biggerSide,
    float resolution,
    float colorShift,
    SampleFn sampleColor,
    PreBlurredFn samplePreBlurred) {
  float blurRadius = resolution * biggerSide * 0.02;

  float3 lrColor;
  if (blurRadius > 0.0) {
    float stepY = (blurRadius / 3.0) * texelSize.y;
    // Convert the source-UV center and the per-tap source-UV step into the
    // pre-pass texture's UV space (which spans only the cropped region).
    float2 sampleUvPre = (sampleUv - 0.5) / uvScale + 0.5;
    float stepYPre = stepY / uvScale.y;
    lrColor = float3(0.0);
    for (int k = 0; k < kOldCamBilinearTaps; ++k) {
      float2 sampleAt = clamp(
          sampleUvPre + float2(0.0, kOldCamBilinearOffsets[k] * stepYPre), 0.0, 1.0);
      lrColor += samplePreBlurred(sampleAt) * kOldCamBilinearWeights[k];
    }
  } else {
    lrColor = sampleColor(sampleUv);
  }

  // Chromatic aberration: 2 extra samples along the radial axis.
  if (colorShift > 0.0) {
    float caOffset = colorShift * biggerSide * 0.05 * texelSize.x;
    lrColor = applyRadialCA(
        lrColor, sampleUv, caOffset, colorShift * 0.2, sampleColor);
  }

  // Luma-pulled desaturation tied to the blur strength.
  if (resolution > 0.0) {
    float lrLuma = luminance(lrColor);
    lrColor = mix(lrColor, float3(lrLuma), resolution * 0.2);
  }

  return clamp(lrColor, 0.0, 1.0);
}

// ============================================================================
// Mist (Orton-style soft glow from the shared frame blur)
// ============================================================================
//
// The wide blur feeding the mist is the renderer's frame-blur texture (the
// quarter-res MPS Gaussian shared with the diffusion effect — see the
// frame-blur entry point below). This replaced an in-shader 17-tap ring blur:
// a true Gaussian with no ring ghosting on point lights, at one bilinear tap
// in the main pass. The blur radius is fixed (strength scales only the blend
// weights, as with bloom); it matches the old ring radius at full strength.

// Composes the mist look from the original colour and a wide Gaussian blur.
//   1. Brightened "Orton" base from squared blur.
//   2. Screen blend toward the bright blur — glow on highlights. The blend is
//      masked by the pixel's own luminance so shadows/blacks aren't lifted,
//      which previously made the photo look faded / opaque at high intensity.
//   3. Soft diffusion: mix sharp toward blur.
static inline float3 composeMist(float3 color, float3 blur, float mist) {
  float3 brightBlur = blur * blur;
  float3 screenBlend = 1.0 - (1.0 - color) * (1.0 - brightBlur);
  float lum = luminance(color);
  color = mix(color, screenBlend, mist * 0.75 * lum);
  color = mix(color, blur, mist * 0.25);
  return clamp(color, 0.0, 1.0);
}

// ============================================================================
// Bloom (Gaussian highlight glow)
// ============================================================================
//
// Multi-pass: `bloomBrightPass` keeps only above-threshold highlights, the
// renderer blurs them with an `MPSImageGaussianBlur` into a smooth round halo,
// and the main pass adds that halo back (additive, like film over-exposure).
// The bright-pass shares the pre-pass vertex, so its quarter-res texture spans
// the same uvScale crop; the main pass maps source UV → bloom UV via
// `(uv - 0.5) / uvScale + 0.5`.

// Linear-light highlight cutoff; higher blooms only the brightest pixels.
constant float kBloomThreshold = 0.75;
// Gain on the blurred halo at `bloom == 1` (additive, so it clips fast).
constant float kBloomGain = 1.5;

// Decode the source and keep only the above-threshold highlights, weighted by
// their excess luminance. The wide blur is added later by the renderer's MPS
// Gaussian pass.
template <typename SampleFn>
static inline float4 bloomBrightPass(float2 uv, SampleFn sampleColor) {
  float3 c = sampleColor(uv);
  float w = saturate((luminance(c) - kBloomThreshold) / (1.0 - kBloomThreshold));
  return float4(c * w, 1.0);
}

// Reads a renderer-blurred auxiliary texture (bloom halo, diffusion blur) —
// the wide Gaussian spread already lives in the texture, so a single bilinear
// tap suffices.
static inline float3 sampleBlurredAux(
    texture2d<float, access::sample> tex, float2 uv) {
  constexpr sampler s(mag_filter::linear, min_filter::linear,
                      address::clamp_to_edge);
  return tex.sample(s, uv).rgb;
}

// ============================================================================
// Diffusion (soft-focus mix toward the shared frame blur)
// ============================================================================
//
// Multi-pass like bloom: `camera_frame_blur_downsample_fragment` decodes the
// full frame to linear RGB at quarter resolution, the renderer blurs it with
// an `MPSImageGaussianBlur`, and the main pass mixes toward the result (the
// same blurred texture also feeds the mist effect). The downsample shares
// the pre-pass vertex, so the texture spans the same uvScale crop; the main
// pass maps source UV → blur UV via `(uv - 0.5) / uvScale + 0.5`.

// Blur weight at `diffusion == 1`. Kept below 1 so full strength reads as
// strongly soft rather than defocused.
constant float kDiffusionMaxMix = 0.7;

// ============================================================================
// Final sRGB-space perturbations: grain + dither
// ============================================================================
//
// Both effects are authored in perceptual (sRGB) space:
//   * Real sensor grain is added by the readout electronics *after* the tone
//     curve, so on a display it looks equally strong in shadows, midtones,
//     and highlights. Adding the same amplitude in linear light would be
//     3–4× more visible in shadows than in skies — the "grain only shows
//     on dark pixels" symptom.
//   * Dither breaks up the posterized contours produced by the final 8-bit
//     quantization in the framebuffer (which is in sRGB-encoded space). One
//     LSB == 1/255 in that space.
//
// Combining them into one encode/decode pair saves one sRGB roundtrip
// (~4 `pow()` per fragment in the common preview path).

// PCG-style integer hash. Bit-mixes a 32-bit input to a 32-bit output with
// uniform distribution; fast on modern GPUs (a few integer ops).
static inline uint pcgHash(uint v) {
  v = v * 747796405u + 2891336453u;
  uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
  return (w >> 22u) ^ w;
}

// Triangular PDF noise on [-1, 1] from the packed fragment coordinate.
// Sum of two i.i.d. uniforms ⇒ triangular distribution (the canonical TPDF
// dither). The 24-bit mask is the largest fp32-exact uniform spacing.
static inline float ditherTriangular(float2 fragCoord) {
  uint2 p = uint2(fragCoord);
  uint h1 = pcgHash(p.x + p.y * 0x9E3779B9u);
  uint h2 = pcgHash(p.y + p.x * 0x85EBCA6Bu);
  float u1 = float(h1 & 0xFFFFFFu) * (1.0 / 16777216.0);
  float u2 = float(h2 & 0xFFFFFFu) * (1.0 / 16777216.0);
  return u1 + u2 - 1.0;
}

// Applies grain + dither in one sRGB encode/decode pair. Grain is skipped
// when `grainOpacity == 0`; dither always runs.
static inline float3 applySrgbPerturbations(
    float3 rgb,
    float grainOpacity,
    float grainBehavior,
    float2 grainUv,
    texture2d<float, access::sample> grainTex,
    float2 grainUVScale,
    float2 grainOffset,
    float2 fragCoord) {
  float3 srgb = linearToSrgb(rgb);

  if (grainOpacity > 0.0) {
    constexpr sampler repeatSampler(
        mag_filter::linear, min_filter::linear,
        address::repeat);
    float2 gUv = fract(grainUv * grainUVScale + grainOffset);
    if (grainBehavior > 0.5) {
      // Dark-only: additive grain scaled by inverse sRGB luminance so it
      // fades out on highlights and is most visible in shadows.
      float3 grain = grainTex.sample(repeatSampler, gUv).rgb - 0.5;
      float luma = luminance(srgb);
      float mask = pow(1.0 - luma, 3.25);
      srgb += grain * grainOpacity * mask;
    } else {
      // Overlay (uniform): additive grain visible across all tones.
      float3 grain = grainTex.sample(repeatSampler, gUv).rgb - 0.5;
      srgb += grain * grainOpacity;
    }
  }

  srgb += ditherTriangular(fragCoord) / 255.0;
  return srgbToLinear(saturate(srgb));
}

// ============================================================================
// Post-process pipeline
// ============================================================================
//
// One templated body behind `camera_fragment`; the per-format sampling is
// folded into `SourceSampleFn` when the pipeline is specialised, and every
// step here uses that functor for sampling.
//
// Pipeline order: lens/sensor sim → atmospheric → colour grade → darken →
// final perturbations → vignette.
// LUT must run AFTER the multi-tap effects (old-cam, prism) because those
// re-sample the raw source per tap and would discard any earlier LUT-graded
// value — and after mist/diffusion/bloom, whose renderer-blurred textures
// are likewise derived from the ungraded source. Vignette runs last so it
// darkens grain and every other effect.

template <typename SampleFn>
static inline float4 renderCamera(
    VertexOut in,
    constant CameraUniforms& uniforms,
    texture2d<float, access::sample> grainTex,
    texture2d<float, access::sample> lutTex,
    texture2d<float, access::sample> preBlurredTex,
    texture2d<float, access::sample> bloomTex,
    texture2d<float, access::sample> frameBlurTex,
    float2 sourceSize,
    SampleFn sampleColor) {
  CropContext ctx = computeCropContext(
      in.uv, uniforms.uvScale,
      uniforms.captureScale, uniforms.darkenOutside,
      uniforms.captureCornerRadius);

  float fisheyeMask = 1.0;
  float fisheyeRim = 0.0;
  if (uniforms.cheapFisheye > 0.5 && ctx.insideScaled) {
    fisheyeMask = applyCheapFisheye(ctx.sampleUv, fisheyeRim, ctx.localUv,
                                    uniforms.uvScale, uniforms.captureScale,
                                    uniforms.outputAspect);
    if (fisheyeMask <= 0.0) {
      return float4(0.0, 0.0, 0.0, 1.0);
    }
  }

  float3 rgb = sampleColor(ctx.sampleUv);

  if (ctx.insideScaled) {
    float2 texelSize = 1.0 / sourceSize;
    float biggerSide = max(sourceSize.x, sourceSize.y);
    // Source UV → aux blur-texture UV, shared by mist, diffusion, and bloom
    // (their renderer-blurred textures all span the uvScale-cropped source
    // region). No clamp needed at the sample sites: the sampler is
    // clamp_to_edge.
    float2 auxBlurUv = (ctx.sampleUv - 0.5) / uniforms.uvScale + 0.5;

    if (uniforms.resolution > 0.0 || uniforms.colorShift > 0.0) {
      constexpr sampler preBlurredSampler(
          mag_filter::linear, min_filter::linear, address::clamp_to_edge);
      rgb = applyOldCamera(
          ctx.sampleUv, uniforms.uvScale, texelSize, biggerSide,
          uniforms.resolution, uniforms.colorShift,
          sampleColor,
          RgbSampleFn{preBlurredTex, preBlurredSampler});
    }
    if (uniforms.mist > 0.0) {
      rgb = composeMist(rgb, sampleBlurredAux(frameBlurTex, auxBlurUv),
                        uniforms.mist);
    }
    if (uniforms.diffusion > 0.0) {
      // Soft-focus: mix toward the renderer-blurred full frame. Runs before
      // bloom so the additive halo stays luminous on top of the softened
      // base.
      rgb = mix(rgb, sampleBlurredAux(frameBlurTex, auxBlurUv),
                uniforms.diffusion * kDiffusionMaxMix);
    }
    if (uniforms.bloom > 0.0) {
      float3 glow = sampleBlurredAux(bloomTex, auxBlurUv);
      rgb = clamp(rgb + glow * (uniforms.bloom * kBloomGain), 0.0, 1.0);
    }
    if (uniforms.cheapFisheye > 0.5) {
      rgb = applyFisheyeRimCA(rgb, ctx.sampleUv, fisheyeRim, sampleColor);
    }
    if (uniforms.prism > 0.0) {
      rgb = applyPrism(rgb, ctx.sampleUv, ctx.localUv,
                       uniforms.uvScale, uniforms.captureScale,
                       sourceSize, biggerSide,
                       uniforms.prism, sampleColor);
    }
    if (uniforms.lutIntensity > 0.0) {
      rgb = applyLut(rgb, lutTex, uniforms.lutIntensity);
    }
  }

  rgb = applyDarkening(rgb, ctx.insideScaled, uniforms.darkenOutside);

  // Grain runs only inside the scaled rect (matches original behaviour);
  // dither always runs (one global encode/decode pair).
  float effectiveGrainOpacity = ctx.insideScaled ? uniforms.grainOpacity : 0.0;
  float2 grainUv = uniforms.grainSwapUV > 0.5 ? ctx.localUv.yx : ctx.localUv;
  rgb = applySrgbPerturbations(
      rgb, effectiveGrainOpacity, uniforms.grainBehavior, grainUv,
      grainTex, uniforms.grainUVScale, uniforms.grainOffset,
      in.position.xy);

  if (ctx.insideScaled) {
    rgb = applyVignette(rgb, ctx.localUv, uniforms.vignetteIntensity, uniforms.outputAspect);
  }

  rgb *= fisheyeMask;

  return float4(rgb, 1.0);
}

// ============================================================================
// Fragment entry points
// ============================================================================
//
// One entry point per pass; the source format is specialised via
// `kSourceFormat` (see SourceSampleFn). Texture slots are the shared
// `CameraShaderTextureIndex` constants, fixed across formats.

fragment float4 camera_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> sourceTexture [[texture(CameraShaderTextureSource)]],
    texture2d<float> cbcrTexture [[texture(CameraShaderTextureCbCr)]],
    texture2d<float, access::sample> grainTexture [[texture(CameraShaderTextureGrain)]],
    texture2d<float, access::sample> lutTexture [[texture(CameraShaderTextureLut)]],
    texture2d<float, access::sample> preBlurredTexture
        [[texture(CameraShaderTexturePreBlurred)]],
    texture2d<float, access::sample> bloomTexture [[texture(CameraShaderTextureBloom)]],
    texture2d<float, access::sample> frameBlurTexture
        [[texture(CameraShaderTextureFrameBlur)]],
    constant CameraUniforms& uniforms [[buffer(0)]]) {
  constexpr sampler s(mag_filter::linear, min_filter::linear);
  float2 sourceSize = float2(sourceTexture.get_width(), sourceTexture.get_height());
  return renderCamera(in, uniforms, grainTexture, lutTexture, preBlurredTexture,
                      bloomTexture, frameBlurTexture, sourceSize,
                      SourceSampleFn{sourceTexture, cbcrTexture, s});
}

// ============================================================================
// Pre-pass entry points (horizontal half of the separable Gaussian)
// ============================================================================
//
// One pre-pass invocation per main render when `uniforms.resolution > 0`.
// Renders at source resolution (no uvScale crop) and writes linear-light
// RGBA16F into an intermediate texture that the main pass then reads. The
// main pass's blur step is the vertical 4-tap half of the same Gaussian.

// Uses the same center-anchored uvScale crop as the main vertex shader, so the
// pre-pass only blurs the region the main pass will actually sample. On a 9:16
// crop of a 16:9 sensor this avoids ~1.8× wasted blur work. The intermediate
// texture's [0,1] UV span then maps to the cropped region; the main pass
// converts source UV → pre-pass UV via `(s - 0.5)/uvScale + 0.5`.
vertex VertexOut camera_prepass_vertex(
    uint vid [[vertex_id]],
    constant CameraUniforms& uniforms [[buffer(0)]]) {
  return fullscreenTriangle(vid, uniforms.uvScale);
}

// Shared body for the horizontal pre-pass entry point below. The blur
// radius/step mirror the vertical half computed in `applyOldCamera`.
template <typename SampleFn>
static inline float4 prepassHorizontal(
    float2 uv, float2 sourceSize, float resolution, SampleFn sampleColor) {
  float biggerSide = max(sourceSize.x, sourceSize.y);
  float blurRadius = resolution * biggerSide * 0.02;
  float stepX = (blurRadius / 3.0) * (1.0 / sourceSize.x);
  return float4(oldCamHorizontalBlur(uv, stepX, sampleColor), 1.0);
}

fragment float4 camera_prepass_h_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> sourceTexture [[texture(CameraShaderTextureSource)]],
    texture2d<float> cbcrTexture [[texture(CameraShaderTextureCbCr)]],
    constant CameraUniforms& uniforms [[buffer(0)]]) {
  constexpr sampler s(mag_filter::linear, min_filter::linear);
  float2 sourceSize = float2(sourceTexture.get_width(), sourceTexture.get_height());
  return prepassHorizontal(in.uv, sourceSize, uniforms.resolution,
                           SourceSampleFn{sourceTexture, cbcrTexture, s});
}

// ============================================================================
// Bloom bright-pass entry point
// ============================================================================
//
// Run when `uniforms.bloom > 0`, sharing `camera_prepass_vertex` so the output
// spans the uvScale-cropped source region. Writes the thresholded highlights
// at quarter resolution; the renderer then blurs them with an MPS Gaussian
// into the halo the main pass samples.

// The fragment stage needs no uniforms (the threshold is a compile-time
// constant); only the shared pre-pass vertex reads `uvScale` at buffer(0).
fragment float4 camera_bloom_bright_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> sourceTexture [[texture(CameraShaderTextureSource)]],
    texture2d<float> cbcrTexture [[texture(CameraShaderTextureCbCr)]]) {
  constexpr sampler s(mag_filter::linear, min_filter::linear);
  return bloomBrightPass(in.uv, SourceSampleFn{sourceTexture, cbcrTexture, s});
}

// ============================================================================
// Frame-blur downsample entry point (mist + diffusion)
// ============================================================================
//
// Run when `uniforms.mist > 0` or `uniforms.diffusion > 0`, sharing
// `camera_prepass_vertex` so the output spans the uvScale-cropped source
// region. Writes the decoded frame as linear RGB at quarter resolution into
// an RGBA16F target (8-bit linear would band in shadows); the renderer then
// blurs it with an MPS Gaussian into the soft full-frame copy that mist
// blends with and diffusion mixes toward.

// The fragment stage needs no uniforms; only the shared pre-pass vertex reads
// `uvScale` at buffer(0).
fragment float4 camera_frame_blur_downsample_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> sourceTexture [[texture(CameraShaderTextureSource)]],
    texture2d<float> cbcrTexture [[texture(CameraShaderTextureCbCr)]]) {
  constexpr sampler s(mag_filter::linear, min_filter::linear);
  return float4(SourceSampleFn{sourceTexture, cbcrTexture, s}(in.uv), 1.0);
}
