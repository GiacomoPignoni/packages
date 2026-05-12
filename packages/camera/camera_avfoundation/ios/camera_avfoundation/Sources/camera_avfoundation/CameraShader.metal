// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <metal_stdlib>
using namespace metal;

// Parameters passed from Flutter to the shader.
// Add fields here as new controls are exposed through the Dart API.
// Mirrored by `CameraUniforms` in VideoFrameRenderer.swift — keep both in sync.
struct CameraUniforms {
  float vignetteIntensity;  // 0 = no vignette, 1 = full strength
  float2 uvScale;           // <1 narrows the sampled rect (center-crop)
  float captureScale;       // 0.1–1.0; 1.0 = no scale-down
  float darkenOutside;      // 0.0 disables (capture passes); ~0.4 enables (preview)
  float outputAspect;       // width / height of rendered output — for vignette compensation
};

struct VertexOut {
  float4 position [[position]];
  float2 uv;
};

vertex VertexOut camera_vertex(
    uint vid [[vertex_id]],
    constant CameraUniforms& uniforms [[buffer(0)]]) {
  // Fullscreen triangle: covers the whole NDC quad with a single primitive,
  // sparing the rasterizer the diagonal seam of a two-triangle quad.
  float2 positions[3] = {float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0)};
  float2 uvs[3] = {float2(0.0, 2.0), float2(0.0, 0.0), float2(2.0, 0.0)};
  VertexOut out;
  out.position = float4(positions[vid], 0.0, 1.0);
  // Center-anchored UV transform: shrink (or expand) around (0.5, 0.5) so the
  // destination texture samples a sub-rect of the source for cropping.
  out.uv = (uvs[vid] - 0.5) * uniforms.uvScale + 0.5;
  return out;
}

// Vignette in linear-light space (we render to an sRGB texture so the GPU
// gamma-encodes on write). `uv` is normalized [0,1] within the scaled rect so
// the vignette tracks the captured area, not the full crop.
//
// `aspectRatio` = width/height of the *destination* rect in pixels. Without
// aspect compensation the distance calculation is in UV space, which is square
// ([0,1]²), so on a tall crop (e.g. 9:16) the vignette is circular in UV but
// elliptical in pixel space — the long-axis corners darken sooner than the
// short-axis corners. Multiplying the horizontal component by the aspect ratio
// restores the circular shape in pixel space.
static inline float3 applyVignette(
    float3 rgb, float2 uv, float intensity, float aspectRatio) {
  float2 offset = (uv - 0.5) * 2.0;        // [-1, 1] in UV space
  offset.x *= aspectRatio;                 // scale to pixel-aspect space
  float distSq = dot(offset, offset);
  float vignette = 1.0 - intensity * smoothstep(0.25, 1.96, distSq);
  return rgb * vignette;
}

// Returns:
//   sampleUv         — UV to sample in source space (already pre-cropped via
//                      uvScale in the vertex stage).
//   localUv          — fragment position normalized to [0,1] across the
//                      scaled inner rect; used by the vignette.
//   insideScaled     — whether this fragment falls inside the scaled rect.
struct CropContext {
  float2 sampleUv;
  float2 localUv;
  bool insideScaled;
};
static inline CropContext computeCropContext(
    float2 uv,
    float2 uvScale,
    float captureScale,
    float darkenOutside) {
  // Guard against zero/near-zero captureScale to prevent divide-by-zero NaN.
  float cs = max(captureScale, 1e-4);
  float2 cropCenter = float2(0.5);
  // d in [-1, 1] across the full aspect-ratio crop.
  float2 cropHalfExtent = uvScale * 0.5;
  float2 d = (uv - cropCenter) / cropHalfExtent;

  CropContext ctx;
  // Capture passes (darkenOutside == 0): destination *is* the scaled rect,
  // sample only the inner area, and `localUv` covers [0,1] across the
  // destination. Every fragment is "inside" so the vignette runs corner-to-
  // corner of the saved file — same physical region as in the preview.
  //
  // Preview passes (darkenOutside > 0): destination is the full aspect crop,
  // sample at the original uv, and `localUv` is normalized to the *inner*
  // rect so the vignette tracks the captured area, going out of [0,1] for
  // the dimmed border (we skip the vignette there via `insideScaled`).
  if (darkenOutside <= 0.0) {
    ctx.sampleUv = (uv - cropCenter) * cs + cropCenter;
    ctx.localUv = d * 0.5 + 0.5;
    ctx.insideScaled = true;
  } else {
    ctx.sampleUv = uv;
    ctx.localUv = (d / cs) * 0.5 + 0.5;
    ctx.insideScaled = max(abs(d.x), abs(d.y)) <= cs;
  }
  return ctx;
}

static inline float3 applyDarkening(float3 rgb, bool insideScaled, float darkenOutside) {
  return insideScaled ? rgb : rgb * (1.0 - darkenOutside);
}

fragment float4 camera_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    constant CameraUniforms& uniforms [[buffer(0)]]) {
  constexpr sampler s(mag_filter::linear, min_filter::linear);
  CropContext ctx = computeCropContext(
      in.uv, uniforms.uvScale,
      uniforms.captureScale, uniforms.darkenOutside);
  float4 color = cameraTexture.sample(s, ctx.sampleUv);
  // Vignette runs in scaled-rect-local UV — same physical region as in the
  // preview, baked into the saved file. Darkening of the area outside the
  // scaled rect is preview-only (the saved file only contains the inner
  // rect, so there is no "outside" to darken).
  if (ctx.insideScaled) {
    color.rgb = applyVignette(color.rgb, ctx.localUv, uniforms.vignetteIntensity, uniforms.outputAspect);
  }
  color.rgb = applyDarkening(color.rgb, ctx.insideScaled, uniforms.darkenOutside);
  return color;
}

// Cheap gamma-decode: BT.709 / sRGB are close enough at the precision we're
// rendering that a single pow approximates the inverse-EOTF. We linearize
// before vignetting so the math matches the BGRA path (which samples
// through an sRGB texture view and gets linear values for free).
static inline float3 srgbToLinearApprox(float3 srgb) {
  return pow(srgb, 2.2);
}

// BT.709 full-range Y'CbCr → RGB (used for 420f source buffers).
// CbCr is centered at 0.5; subtract once and apply the matrix. The result
// is gamma-encoded RGB; we linearize, vignette, then let the sRGB
// destination view encode on write.
fragment float4 camera_fragment_yuv_full(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> cbcrTexture [[texture(1)]],
    constant CameraUniforms& uniforms [[buffer(0)]]) {
  constexpr sampler s(mag_filter::linear, min_filter::linear);
  CropContext ctx = computeCropContext(
      in.uv, uniforms.uvScale,
      uniforms.captureScale, uniforms.darkenOutside);
  float y = yTexture.sample(s, ctx.sampleUv).r;
  float2 cbcr = cbcrTexture.sample(s, ctx.sampleUv).rg - float2(0.5, 0.5);
  float3 rgb;
  rgb.r = y + 1.5748 * cbcr.y;
  rgb.g = y - 0.1873 * cbcr.x - 0.4681 * cbcr.y;
  rgb.b = y + 1.8556 * cbcr.x;
  rgb = srgbToLinearApprox(saturate(rgb));
  // Vignette runs in scaled-rect-local UV — same physical region as in the
  // preview, baked into the saved file. Darkening of the area outside the
  // scaled rect is preview-only (the saved file only contains the inner
  // rect, so there is no "outside" to darken).
  if (ctx.insideScaled) {
    rgb = applyVignette(rgb, ctx.localUv, uniforms.vignetteIntensity, uniforms.outputAspect);
  }
  rgb = applyDarkening(rgb, ctx.insideScaled, uniforms.darkenOutside);
  return float4(rgb, 1.0);
}

// BT.709 video-range Y'CbCr → RGB (used for 420v source buffers).
// Y is in [16/255, 235/255] and CbCr in [16/255, 240/255].
fragment float4 camera_fragment_yuv_video(
    VertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],
    texture2d<float> cbcrTexture [[texture(1)]],
    constant CameraUniforms& uniforms [[buffer(0)]]) {
  constexpr sampler s(mag_filter::linear, min_filter::linear);
  CropContext ctx = computeCropContext(
      in.uv, uniforms.uvScale,
      uniforms.captureScale, uniforms.darkenOutside);
  float y = (yTexture.sample(s, ctx.sampleUv).r - 16.0 / 255.0) * (255.0 / 219.0);
  float2 cbcr = (cbcrTexture.sample(s, ctx.sampleUv).rg - float2(128.0 / 255.0)) * (255.0 / 224.0);
  float3 rgb;
  rgb.r = y + 1.5748 * cbcr.y;
  rgb.g = y - 0.1873 * cbcr.x - 0.4681 * cbcr.y;
  rgb.b = y + 1.8556 * cbcr.x;
  rgb = srgbToLinearApprox(saturate(rgb));
  // Vignette runs in scaled-rect-local UV — same physical region as in the
  // preview, baked into the saved file. Darkening of the area outside the
  // scaled rect is preview-only (the saved file only contains the inner
  // rect, so there is no "outside" to darken).
  if (ctx.insideScaled) {
    rgb = applyVignette(rgb, ctx.localUv, uniforms.vignetteIntensity, uniforms.outputAspect);
  }
  rgb = applyDarkening(rgb, ctx.insideScaled, uniforms.darkenOutside);
  return float4(rgb, 1.0);
}
