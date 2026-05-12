// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Metal
import MetalKit
import MetalPerformanceShaders

// `CameraUniforms`, `CameraShaderSourceFormat`, and the texture bind slots
// come from CameraShaderTypes.h, the single header the Metal shaders compile
// too — the cross-language ABI lives there, not in this file. Under CocoaPods
// the header reaches Swift via the framework umbrella instead of a module.
#if SWIFT_PACKAGE
  import camera_avfoundation_shader_types
#endif

// =============================================================================
// MARK: - Shared types
// =============================================================================

extension CameraUniforms {
  /// Default render state: identity crop, square aspect, no effects. The
  /// imported C struct's `init()` zero-fills, so the non-zero defaults are
  /// applied here.
  static func makeDefault() -> CameraUniforms {
    var uniforms = CameraUniforms()
    uniforms.uvScale = SIMD2<Float>(1, 1)
    uniforms.captureScale = 1
    uniforms.outputAspect = 1
    uniforms.grainUVScale = SIMD2<Float>(1, 1)
    return uniforms
  }

  /// The one mapping point from the pigeon effects message onto shader
  /// uniforms. Every caller that pushes `PlatformEffectsValues` into a
  /// renderer goes through here, so a new effect can't reach one path (live
  /// update) and miss another (renderer rebuild).
  mutating func apply(_ values: PlatformEffectsValues) {
    vignetteIntensity = Float(values.vignetteIntensity)
    grainOpacity = Float(values.grainOpacity)
    grainBehavior = values.grainBehavior == .darkOnly ? 1 : 0
    lutIntensity = Float(values.lutIntensity)
    resolution = Float(values.resolution)
    colorShift = Float(values.colorShift)
    mist = Float(values.mist)
    prism = Float(values.prism)
    bloom = Float(values.bloom)
    diffusion = Float(values.diffusion)
    cheapFisheye = values.cheapFisheye ? 1 : 0
  }
}

/// Source pixel format the renderer can ingest. The raw value is only an
/// index into the per-format pipeline array; the value bound to the shader's
/// `kSourceFormat` function constant is `shaderFormat`, from the shared
/// header.
enum CameraSourceFormat: Int, CaseIterable {
  case bgra
  case yuvFullRange  // 420f
  case yuvVideoRange  // 420v

  init?(pixelFormat: OSType) {
    switch pixelFormat {
    case kCVPixelFormatType_32BGRA: self = .bgra
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: self = .yuvFullRange
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: self = .yuvVideoRange
    default: return nil
    }
  }

  var shaderFormat: CameraShaderSourceFormat {
    switch self {
    case .bgra: return CameraShaderSourceFormatBGRA
    case .yuvFullRange: return CameraShaderSourceFormatYuvFullRange
    case .yuvVideoRange: return CameraShaderSourceFormatYuvVideoRange
    }
  }
}

extension MTLRenderCommandEncoder {
  /// Binds a fragment texture at one of the shared shader slots.
  func setFragmentTexture(_ texture: MTLTexture?, slot: CameraShaderTextureIndex) {
    setFragmentTexture(texture, index: Int(slot.rawValue))
  }
}

// =============================================================================
// MARK: - VideoFrameRenderer
// =============================================================================

final class VideoFrameRenderer {

  // ---------------------------------------------------------------------------
  // MARK: - Constants
  // ---------------------------------------------------------------------------

  /// Sized for: 2 in-flight on GPU + 1 in preview texture + 3 in AVAssetWriter
  /// + 2 headroom = 8.
  private static let maxPoolBuffers = 8

  /// Hard cap on the recording pool. Under a stalled AVAssetWriter the pool
  /// can otherwise grow without bound — at 4K each buffer is ~30 MB, so a
  /// dozen stalled frames would consume ~360 MB. Matches `maxPoolBuffers`.
  private static let maxRecordingPoolBuffers = 8

  /// Eagerly keep this many destination buffers warm so the first second of
  /// recording doesn't spike on alloc. Real working set is ~4–5.
  private static let minPoolBuffers = 4

  /// Number of GPU render operations that may be queued at once on the
  /// preview path. 3 lets the pipeline keep one frame queued while the next
  /// is submitted and a third is being captured.
  private static let maxInFlightPreviewFrames = 3

  /// Independent budget for the recording path. Preview and recording run
  /// from the same sample-buffer callback, so a shared semaphore can starve
  /// the preview when the recording path is busy (and vice-versa).
  private static let maxInFlightRecordingFrames = 3

  /// Darkening multiplier applied outside the captureScale rectangle in
  /// preview-only renders. Capture passes (photo, recording) bypass darkening
  /// to keep saved files clean. Outside pixels are multiplied by
  /// `(1 - previewDarkenOutside)` — 0.7 means the dimmed area renders at
  /// 30% brightness.
  static let previewDarkenOutside: Float = 0.7

  /// Flush the IOSurface→texture cache every N frames. Flushing every frame
  /// discards mappings the next frame would otherwise reuse.
  private static let flushEveryNFrames: Int = 60

  /// Rounds `v` to the nearest even pixel value, with a floor of 2.
  /// H.264/HEVC encoders refuse odd dimensions on most configurations.
  static func evenRound(_ v: Float) -> Int {
    let r = Int(v.rounded())
    return max(2, r - (r % 2))
  }

  // ---------------------------------------------------------------------------
  // MARK: - Shared Metal setup
  // ---------------------------------------------------------------------------

  /// The render pipelines for one source format — each shader entry point
  /// exists once and is specialised per format via the `kSourceFormat`
  /// function constant at pipeline-creation time.
  ///   main                — full effect pipeline into the sRGB destination.
  ///   prePass             — horizontal half of the separable old-camera Gaussian.
  ///   bloomBright         — bloom highlight threshold at quarter resolution.
  ///   frameBlurDownsample — full-frame decode at quarter resolution for the
  ///                         shared mist/diffusion blur.
  private struct FormatPipelines {
    let main: MTLRenderPipelineState
    let prePass: MTLRenderPipelineState
    let bloomBright: MTLRenderPipelineState
    let frameBlurDownsample: MTLRenderPipelineState
  }

  /// Heavy Metal setup is cached across renderers so that recreating one
  /// (e.g. on pixel-format change) is essentially free.
  private struct MetalSetup {
    let device: MTLDevice
    let previewCommandQueue: MTLCommandQueue
    let photoCommandQueue: MTLCommandQueue
    /// Indexed by `CameraSourceFormat.rawValue`.
    let pipelines: [FormatPipelines]
  }

  private static var cachedSetup: MetalSetup?
  private static let setupLock = NSLock()

  private static func sharedSetup() -> MetalSetup? {
    setupLock.lock()
    defer { setupLock.unlock() }
    if let setup = cachedSetup { return setup }

    guard let device = MTLCreateSystemDefaultDevice() else {
      NSLog("VideoFrameRenderer: no Metal device available")
      return nil
    }
    guard let previewQueue = device.makeCommandQueue(),
      let photoQueue = device.makeCommandQueue()
    else {
      NSLog("VideoFrameRenderer: failed to create command queues")
      return nil
    }
    previewQueue.label = "io.flutter.camera.previewMetalQueue"
    photoQueue.label = "io.flutter.camera.photoMetalQueue"

    // Load the pre-compiled Metal library. The build system compiles
    // `CameraShader.metal` into a `default.metallib`, but where it ends up
    // depends on how the plugin is integrated:
    //   - SwiftPM: inside the target's resource bundle (`Bundle.module`).
    //   - CocoaPods: in the pod's framework bundle (`Bundle(for:)`), or, when
    //     statically linked, merged into the app's default metallib.
    // Search the candidate bundles in order, then fall back to the default lib.
    var candidateBundles: [Bundle] = []
    #if SWIFT_PACKAGE
      candidateBundles.append(Bundle.module)
    #endif
    candidateBundles.append(Bundle(for: VideoFrameRenderer.self))

    let library: MTLLibrary
    if let bundleLibrary = candidateBundles.lazy.compactMap({ bundle -> MTLLibrary? in
      guard let url = bundle.url(forResource: "default", withExtension: "metallib") else {
        return nil
      }
      return try? device.makeLibrary(URL: url)
    }).first {
      library = bundleLibrary
    } else if let defaultLib = device.makeDefaultLibrary() {
      library = defaultLib
    } else {
      NSLog("VideoFrameRenderer: Metal library not found in bundle or default library")
      return nil
    }

    guard let vertexFunction = library.makeFunction(name: "camera_vertex"),
      let prePassVertex = library.makeFunction(name: "camera_prepass_vertex")
    else {
      NSLog("VideoFrameRenderer: shader functions not found in library")
      return nil
    }

    // Each fragment entry point exists once in the shader and is specialised
    // per source format via the `kSourceFormat` function constant. The dead
    // format branches are stripped at compile time, so the three variants
    // match hand-written per-format functions.
    func makeFragment(_ name: String, format: CameraSourceFormat) -> MTLFunction? {
      let constants = MTLFunctionConstantValues()
      var raw = Int32(format.shaderFormat.rawValue)
      constants.setConstantValue(&raw, type: .int, index: 0)
      do {
        return try library.makeFunction(name: name, constantValues: constants)
      } catch {
        NSLog("VideoFrameRenderer: specialising \(name) for \(format) failed: \(error)")
        return nil
      }
    }

    func makePipeline(
      vertex: MTLFunction, fragment: MTLFunction,
      pixelFormat: MTLPixelFormat, label: String
    ) -> MTLRenderPipelineState? {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.label = label
      descriptor.vertexFunction = vertex
      descriptor.fragmentFunction = fragment
      descriptor.colorAttachments[0].pixelFormat = pixelFormat
      do {
        return try device.makeRenderPipelineState(descriptor: descriptor)
      } catch {
        NSLog("VideoFrameRenderer: pipeline state creation failed for \(label): \(error)")
        return nil
      }
    }

    // Target formats per pass:
    //   main      — sRGB-encoded write so the effect math happens in linear
    //               light and the destination IOSurface ends up display-ready.
    //   pre-pass  — RGBA16F linear-light intermediate (no sRGB encoding; the
    //               main pass keeps the math in linear light).
    //   bloom      — RGBA8: the bright-pass output is LDR [0,1] and heavily
    //                blurred afterwards, so 8 bits suffice.
    //   frame blur — RGBA16F: the downsampled frame spans the whole tonal
    //                range in linear light; 8-bit linear would band in shadows.
    var pipelines: [FormatPipelines] = []
    for format in CameraSourceFormat.allCases {
      guard
        let mainFragment = makeFragment("camera_fragment", format: format),
        let prePassFragment = makeFragment("camera_prepass_h_fragment", format: format),
        let bloomFragment = makeFragment("camera_bloom_bright_fragment", format: format),
        let frameBlurFragment = makeFragment(
          "camera_frame_blur_downsample_fragment", format: format),
        let main = makePipeline(
          vertex: vertexFunction, fragment: mainFragment,
          pixelFormat: .bgra8Unorm_srgb, label: "camera_\(format)"),
        let prePass = makePipeline(
          vertex: prePassVertex, fragment: prePassFragment,
          pixelFormat: .rgba16Float, label: "camera_prepass_h_\(format)"),
        let bloomBright = makePipeline(
          vertex: prePassVertex, fragment: bloomFragment,
          pixelFormat: .rgba8Unorm, label: "camera_bloom_bright_\(format)"),
        let frameBlurDownsample = makePipeline(
          vertex: prePassVertex, fragment: frameBlurFragment,
          pixelFormat: .rgba16Float, label: "camera_frame_blur_downsample_\(format)")
      else {
        return nil
      }
      pipelines.append(
        FormatPipelines(
          main: main, prePass: prePass, bloomBright: bloomBright,
          frameBlurDownsample: frameBlurDownsample))
    }

    let setup = MetalSetup(
      device: device,
      previewCommandQueue: previewQueue,
      photoCommandQueue: photoQueue,
      pipelines: pipelines)
    cachedSetup = setup
    return setup
  }

  /// Eagerly compile the Metal pipelines so the first sample-buffer callback
  /// doesn't pay for it. Safe to call repeatedly; subsequent calls are no-ops.
  static func warmUp() {
    _ = sharedSetup()
  }

  /// Shared sRGB color space used for HEIF/JPEG encoding. Constructed once;
  /// `CGColorSpace(name:)` is non-trivial.
  private static let sRGBColorSpace: CGColorSpace =
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  // ---------------------------------------------------------------------------
  // MARK: - Stored properties
  // ---------------------------------------------------------------------------

  // Metal handles (immutable for the lifetime of the renderer).
  private let device: MTLDevice
  private let previewCommandQueue: MTLCommandQueue
  private let photoCommandQueue: MTLCommandQueue
  /// Per-format pipelines, indexed by `CameraSourceFormat.rawValue`.
  private let pipelines: [FormatPipelines]
  private let textureCache: CVMetalTextureCache

  // Cached intermediate textures for the separable old-camera blur. Allocated
  // lazily at source dimensions on the first frame where `resolution > 0`,
  // re-created when source dimensions change. Stored as `.private` so the
  // GPU is the only consumer — Metal's automatic hazard tracking serialises
  // the per-frame write/read between pre-pass and main pass within a single
  // command queue.
  //
  // One texture per command queue: Metal's automatic hazard tracking only
  // orders work *within* a queue, so the preview and photo queues each need
  // their own intermediate. This also avoids reallocation thrash when
  // alternating between preview (e.g. 1080p) and photo capture (e.g. full
  // sensor resolution) — each path keeps its own correctly-sized texture.
  private var prePassTexturePreview: MTLTexture?
  private var prePassTexturePhoto: MTLTexture?
  private let prePassTextureLock = NSLock()

  // Cached auxiliary blur working sets — one per (kind, command queue), where
  // a "kind" is a renderer-blurred texture the main pass samples: the bloom
  // halo and the shared mist/diffusion frame blur. Each set works the same
  // way: a pass renders into `input` at quarter source resolution, an
  // `MPSImageGaussianBlur` writes the wide blur into `blurred`, and the main
  // pass samples `blurred`. The ping-pong pair (rather than an in-place blur)
  // keeps stable texture identity and avoids the per-frame scratch alloc MPS
  // needs for a convolution. One kernel per queue: preview and photo run on
  // independent queues and an MPS kernel must not be encoded from two threads
  // at once (as with `recordingLanczos`/`photoLanczos`).
  //
  // Lifecycle: allocated lazily on the first frame the kind is needed,
  // re-created when the working size changes, and released only after the
  // effect has stayed off for `auxBlurReleaseAfterOffFrames` consecutive
  // frames — an effect value sliding through zero must not free and rebuild
  // textures plus an MPS kernel on every crossing. The photo queue is also
  // freed deterministically at the end of each `renderImage` (see
  // `releasePhotoAuxBlurResources`), since its sets are quarter-photo-res and
  // photos are one-shot.
  //
  // Slot state is intentionally lock-free: all renders for a given command
  // queue are submitted from one thread at a time — the same invariant that
  // lets the slot's MPS kernel encode without a lock — so each slot is only
  // ever touched by its queue's render thread.
  private struct AuxBlurResources {
    let input: MTLTexture
    let blurred: MTLTexture
    let blur: MPSImageGaussianBlur
  }

  private enum AuxBlurKind: Int, CaseIterable {
    /// Bloom bright-pass output → halo. RGBA8: the thresholded highlights are
    /// LDR [0,1] and heavily blurred afterwards, so 8 bits suffice (residual
    /// quantisation is hidden by the final dither).
    case bloom
    /// Full-frame decode → soft copy for mist + diffusion. RGBA16F: the
    /// content spans the whole tonal range in linear light, where 8-bit
    /// linear would band in shadows.
    case frameBlur

    var pixelFormat: MTLPixelFormat {
      self == .bloom ? .rgba8Unorm : .rgba16Float
    }

    /// Gaussian sigma for the working size. Scales with the bigger working
    /// side so the radius is resolution-independent across the preview and
    /// full-resolution photo paths. The frame blur is slightly tighter than
    /// bloom's halo so diffusion reads as soft detail rather than defocus; it
    /// also matches the radius of mist's previous in-shader ring blur at full
    /// strength (0.015 × source bigger side).
    func sigma(width: Int, height: Int) -> Float {
      let side = Float(max(width, height))
      return self == .bloom ? max(2.0, 0.02 * side) : max(1.5, 0.015 * side)
    }

    var label: String {
      self == .bloom ? "CameraBloom" : "CameraFrameBlur"
    }
  }

  /// Per-(kind, queue) cache slot. The boxes live for the renderer's
  /// lifetime; only `resources`/`offFrames` mutate, and only from the owning
  /// queue's render thread.
  private final class AuxBlurSlot {
    var resources: AuxBlurResources?
    var offFrames = 0
  }
  /// Indexed by `auxBlurSlotIndex`.
  private let auxBlurSlots = (0..<(AuxBlurKind.allCases.count * 2)).map { _ in AuxBlurSlot() }
  private func auxBlurSlot(_ kind: AuxBlurKind, isPhotoQueue: Bool) -> AuxBlurSlot {
    auxBlurSlots[kind.rawValue * 2 + (isPhotoQueue ? 1 : 0)]
  }
  /// ~2–4 s of preview at 30–60 fps: long enough to ride out a slider passing
  /// through zero, short enough not to hoard textures for an abandoned effect.
  private static let auxBlurReleaseAfterOffFrames = 120

  /// Cached texture-attribute dictionaries passed to
  /// `CVMetalTextureCacheCreateTextureFromImage`. Built once at init so the
  /// hot path never bridges a fresh `[String: Any]` to `CFDictionary`.
  private let shaderReadAttrs: CFDictionary
  private let renderTargetAttrs: CFDictionary
  private static let mpsWriteAttrs: CFDictionary = [
    kCVMetalTextureUsage as String: NSNumber(value: MTLTextureUsage.shaderWrite.rawValue)
  ] as CFDictionary

  // Uniforms — GUARDED BY uniformsLock.
  // `framesSinceFlush` piggybacks on this lock so the preview and recording
  // paths can both increment it safely.
  private let uniformsLock = NSLock()
  private var uniforms = CameraUniforms.makeDefault()
  private var framesSinceFlush: Int = 0

  // -------------------------------------------------------------------------
  // Grain / noise overlay state. All four GUARDED BY grainTextureLock.
  // Tests reach in via the `#if DEBUG` accessors below — the runtime API
  // stays `private` so production callers can't grab these without going
  // through the proper load / clear / snapshot methods.
  // -------------------------------------------------------------------------

  private let grainTextureLock = NSLock()
  /// The grain noise texture loaded from the user-supplied image path.
  /// Nil when no grain path has been set or loading failed.
  private var grainTexture: MTLTexture?
  /// The path most recently passed to `loadGrainTexture(path:)`. Callbacks
  /// that arrive for an older path are discarded.
  private var pendingGrainTexturePath: String?
  /// Linear fraction of the shorter output dimension used to size grain tiles.
  /// 0.1 → tile = 10% of shorter side (fine grain, default).
  private var grainSize: Float = 0.1

  #if DEBUG
    /// Test-only snapshot of `grainTexture`. Takes the lock internally so
    /// callers can't observe the field mid-write.
    var grainTextureForTesting: MTLTexture? {
      grainTextureLock.lock(); defer { grainTextureLock.unlock() }
      return grainTexture
    }
    /// Test-only snapshot of `pendingGrainTexturePath`.
    var pendingGrainTexturePathForTesting: String? {
      grainTextureLock.lock(); defer { grainTextureLock.unlock() }
      return pendingGrainTexturePath
    }
    /// Test-only snapshot of `grainSize`.
    var grainSizeForTesting: Float {
      grainTextureLock.lock(); defer { grainTextureLock.unlock() }
      return grainSize
    }
  #endif

  /// 24-fps timer that randomises `grainOffset` so the grain animates
  /// independently of the screen's display frame rate.
  /// GUARDED BY grainTextureLock — concurrent load completions (or a load
  /// completion racing a `clearGrainTexture`) used to read & write this
  /// field unlocked, which leaked timer references that kept firing forever.
  private var grainAnimationTimer: DispatchSourceTimer?
  private let grainTimerQueue = DispatchQueue(
    label: "io.flutter.camera.grainTimer", qos: .userInteractive)

  /// Path of the grain texture currently being decoded on `grainLoadQueue`,
  /// GUARDED BY grainTextureLock. Used to dedupe redundant `loadGrainTexture`
  /// calls — without this, a rapid `setEffectsValues(B → A → B → A → …)`
  /// sequence stacks up N concurrent PNG decodes, which is both expensive
  /// (each decode is ~10 ms of CPU) and racy (each completion called
  /// `startGrainAnimation`, leaking timers).
  private var grainLoadInFlightPath: String?

  /// Wraps an `MTLTexture` so it can be stored in an `NSCache` (whose
  /// `ObjectType` must be a class, while `MTLTexture` is a protocol).
  private final class GrainTextureBox {
    let texture: MTLTexture
    init(_ texture: MTLTexture) { self.texture = texture }
  }

  /// In-memory cache of decoded grain textures, keyed by absolute file path.
  /// Mirrors `lutTextureCache`: class-level so it survives renderer rebuilds
  /// and is shared across cameras. `NSCache` auto-evicts under memory
  /// pressure, so the worst case after eviction is one re-decode.
  private static let grainTextureCache = NSCache<NSString, GrainTextureBox>()

  /// Dedicated serial queue for grain disk-IO + decode + texture upload.
  /// Serial (like `lutLoadQueue`) so rapid filter switches don't fan out
  /// into parallel decodes. The previous `DispatchQueue.global` (concurrent)
  /// allowed multiple completions to race in `startGrainAnimation` and leak
  /// animation timers under rapid switching.
  private static let grainLoadQueue = DispatchQueue(
    label: "io.flutter.camera.grainLoadQueue", qos: .utility)

  // LUT color-filter state — all private, GUARDED BY lutTextureLock.
  private let lutTextureLock = NSLock()
  private var lutTexture: MTLTexture?
  private var pendingLutTexturePath: String?
  /// Mirror of `grainLoadInFlightPath` for the LUT loader: dedupes parallel
  /// decodes for the same path. Without it, `A → B → A → B` switches queue
  /// up four decode jobs on `lutLoadQueue`, three of which run pointlessly
  /// before discovering their path is stale.
  private var lutLoadInFlightPath: String?

  #if DEBUG
    /// Test-only snapshot of `lutTexture`. Takes the lock internally so
    /// callers can't observe the field mid-write.
    var lutTextureForTesting: MTLTexture? {
      lutTextureLock.lock(); defer { lutTextureLock.unlock() }
      return lutTexture
    }
    /// Test-only snapshot of `pendingLutTexturePath`.
    var pendingLutTexturePathForTesting: String? {
      lutTextureLock.lock(); defer { lutTextureLock.unlock() }
      return pendingLutTexturePath
    }
  #endif

  /// Wraps an `MTLTexture` so it can be stored in an `NSCache` (whose
  /// `ObjectType` must be a class, while `MTLTexture` is a protocol).
  private final class LutTextureBox {
    let texture: MTLTexture
    init(_ texture: MTLTexture) { self.texture = texture }
  }

  /// In-memory cache of decoded LUT textures, keyed by absolute file path.
  /// Class-level so it survives renderer rebuilds (aspect-ratio changes) and
  /// is shared across cameras. `NSCache` auto-evicts under memory pressure,
  /// so the worst case after eviction is one re-decode — no correctness risk.
  /// Thread-safe by contract.
  private static let lutTextureCache = NSCache<NSString, LutTextureBox>()

  /// Dedicated serial queue for LUT disk-IO + PNG decode + texture upload.
  /// Serial so rapid filter switches don't fan out into parallel decodes, and
  /// `.utility` so a long decode cannot starve the main thread (the previous
  /// `.userInitiated` global queue had high enough priority to compete on
  /// older devices). Stale-path callbacks are still discarded via the
  /// `pendingLutTexturePath` check.
  private static let lutLoadQueue = DispatchQueue(
    label: "io.flutter.camera.lutLoadQueue", qos: .utility)

  // Pools.
  private let pool: CVPixelBufferPool
  private let poolAuxAttributes: CFDictionary
  private let recordingPoolLock = NSLock()
  private var recordingPool: CVPixelBufferPool?
  private var recordingPoolAuxAttributes: CFDictionary?
  private var recordingPoolWidth: Int = 0
  private var recordingPoolHeight: Int = 0
  // Intermediate pool for the small render when captureScale < 1 and upscaling is active.
  private var scaledRenderPool: CVPixelBufferPool?
  private var scaledRenderPoolAuxAttributes: CFDictionary?
  private var scaledRenderPoolWidth: Int = 0
  private var scaledRenderPoolHeight: Int = 0

  /// Limits how many command buffers can be queued on the preview GPU
  /// simultaneously. When all slots are taken `render(blocking: false)`
  /// returns nil and the caller drops the frame for the preview.
  private let previewInFlightSemaphore: DispatchSemaphore
  /// Independent budget for the recording path. At peak the renderer can have
  /// `maxInFlightPreviewFrames + maxInFlightRecordingFrames` operations
  /// queued on the GPU.
  private let recordingInFlightSemaphore: DispatchSemaphore

  // Output dims + tracked source.
  private let width: Int
  private let height: Int
  /// Target aspect ratio (width/height) in *sensor-landscape* space
  /// (`>= 1`), or `nil` for "no crop". Used by `photoCropPlan` to compute
  /// photo crops from the sensor-orientation photo buffer. See
  /// `photoCropPlan` for the rationale; the conversion from the user's
  /// orientation-agnostic shape happens in
  /// `DefaultCamera.sensorSpaceAspectRatio()`.
  private let targetRatio: Double?
  /// Tracked source dimensions. The vertex-stage uvScale uniform was computed
  /// against these; if the source size changes (camera switch during
  /// recording), `updateSourceDimensions` recomputes the uvScale so the saved
  /// video keeps the requested aspect ratio.
  private(set) var sourceWidth: Int
  private(set) var sourceHeight: Int
  /// Tracked source pixel format. Used by `DefaultCamera` to detect a format
  /// change (e.g. 420v → 420f across a camera switch) so it can rebuild the
  /// renderer when not recording.
  private(set) var sourcePixelFormat: OSType

  /// Cached CIContext for HEIF/JPEG encoding on the photo path.
  /// CIContext is thread-safe and amortizes a lot of GPU setup.
  private lazy var ciContext: CIContext = {
    return CIContext(mtlDevice: device, options: [
      .cacheIntermediates: false,
      .priorityRequestLow: true,
    ])
  }()

  /// Cached MPS Lanczos kernels. MPS kernels are not lightweight — allocating
  /// one per frame is wasteful. Two instances because `scaleTransform` is
  /// stateful and the recording / photo paths run on independent delegate
  /// queues; sharing one kernel would race on that property.
  private lazy var recordingLanczos = MPSImageLanczosScale(device: device)
  private lazy var photoLanczos = MPSImageLanczosScale(device: device)

  /// Preview-path output dimensions. The on-screen preview never needs to be
  /// rendered at the full sensor resolution — the shader fragment cost scales
  /// with the *output* pixel count, so downsampling the preview pass is by far
  /// the biggest win we can get on heavy effects (49-tap blur, mist, etc.).
  /// Recording and photo paths continue to render at full `width × height`.
  /// When `previewMaxShorterSide` is nil (or larger than the source's shorter
  /// side) these collapse back to `width × height`.
  let previewWidth: Int
  let previewHeight: Int

  /// What Flutter sees: the preview texture's actual pixel dimensions. The
  /// AspectRatio widget on the Dart side only cares about the ratio, which is
  /// preserved when we cap the preview, so the on-screen layout is unchanged.
  var outputWidth: Int { previewWidth }
  var outputHeight: Int { previewHeight }

  /// Computes preview dimensions for a `width × height` aspect-cropped output,
  /// capping the shorter side at `maxShorterSide`. Aspect is preserved and
  /// dimensions are rounded to even pixels.
  static func previewCappedDimensions(
    width: Int, height: Int, maxShorterSide: Int?
  ) -> (width: Int, height: Int) {
    guard let cap = maxShorterSide, cap > 0 else { return (width, height) }
    let shorter = min(width, height)
    if shorter <= cap { return (width, height) }
    let scale = Double(cap) / Double(shorter)
    let w = max(2, evenRound(Float(Double(width) * scale)))
    let h = max(2, evenRound(Float(Double(height) * scale)))
    return (w, h)
  }

  // ---------------------------------------------------------------------------
  // MARK: - Lifecycle
  // ---------------------------------------------------------------------------

  init?(
    width: Int, height: Int, targetRatio: Double? = nil,
    sourceWidth: Int = 0, sourceHeight: Int = 0,
    sourcePixelFormat: OSType = 0,
    previewMaxShorterSide: Int? = nil
  ) {
    guard width > 0, height > 0 else {
      NSLog("VideoFrameRenderer: invalid dimensions \(width)x\(height)")
      return nil
    }
    guard let setup = VideoFrameRenderer.sharedSetup() else {
      return nil
    }

    let previewDims = VideoFrameRenderer.previewCappedDimensions(
      width: width, height: height, maxShorterSide: previewMaxShorterSide)

    var cache: CVMetalTextureCache?
    let cacheStatus = CVMetalTextureCacheCreate(
      kCFAllocatorDefault, nil, setup.device, nil, &cache)
    guard cacheStatus == kCVReturnSuccess, let textureCache = cache else {
      NSLog("VideoFrameRenderer: texture cache creation failed: \(cacheStatus)")
      return nil
    }

    // Preview pool is sized for `previewDims` — the actual render target of
    // the on-screen preview path. Recording uses its own pool sized at the
    // full `width × height`, so capping here doesn't reduce recording quality.
    let poolAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: previewDims.width,
      kCVPixelBufferHeightKey as String: previewDims.height,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let poolMaxAttributes: [String: Any] = [
      kCVPixelBufferPoolMinimumBufferCountKey as String: VideoFrameRenderer.minPoolBuffers
    ]
    var pool: CVPixelBufferPool?
    let poolStatus = CVPixelBufferPoolCreate(
      kCFAllocatorDefault, poolMaxAttributes as CFDictionary,
      poolAttributes as CFDictionary, &pool)
    guard poolStatus == kCVReturnSuccess, let createdPool = pool else {
      NSLog("VideoFrameRenderer: pixel buffer pool creation failed: \(poolStatus)")
      return nil
    }

    self.device = setup.device
    self.previewCommandQueue = setup.previewCommandQueue
    self.photoCommandQueue = setup.photoCommandQueue
    self.pipelines = setup.pipelines
    self.textureCache = textureCache
    self.pool = createdPool
    self.poolAuxAttributes = [
      kCVPixelBufferPoolAllocationThresholdKey as String: VideoFrameRenderer.maxPoolBuffers
    ] as CFDictionary

    let shaderReadUsage = MTLTextureUsage.shaderRead
    let renderTargetUsage: MTLTextureUsage = [.renderTarget, .shaderRead]
    self.shaderReadAttrs = [
      kCVMetalTextureUsage as String: NSNumber(value: shaderReadUsage.rawValue)
    ] as CFDictionary
    self.renderTargetAttrs = [
      kCVMetalTextureUsage as String: NSNumber(value: renderTargetUsage.rawValue)
    ] as CFDictionary

    self.width = width
    self.height = height
    self.previewWidth = previewDims.width
    self.previewHeight = previewDims.height
    // Default outputAspect to the renderer's portrait dimensions. Each render
    // pass overrides it from the actual destination size in `submitRender`,
    // which is what aspect-correcting effects (vignette, fisheye) need —
    // photo path renders to a sensor-orientation (landscape) buffer with the
    // reciprocal aspect.
    uniforms.outputAspect = Float(width) / Float(height)
    self.targetRatio = targetRatio
    self.sourceWidth = sourceWidth
    self.sourceHeight = sourceHeight
    self.sourcePixelFormat = sourcePixelFormat
    self.previewInFlightSemaphore = DispatchSemaphore(
      value: VideoFrameRenderer.maxInFlightPreviewFrames)
    self.recordingInFlightSemaphore = DispatchSemaphore(
      value: VideoFrameRenderer.maxInFlightRecordingFrames)

    // Pre-allocate the warm pool so the first frames don't pay for malloc.
    VideoFrameRenderer.primePool(
      createdPool,
      auxAttributes: self.poolAuxAttributes,
      count: VideoFrameRenderer.minPoolBuffers)

    NSLog(
      "VideoFrameRenderer: ready at \(width)x\(height) (preview "
        + "\(previewDims.width)x\(previewDims.height))")
  }

  // ---------------------------------------------------------------------------
  // MARK: - Source dimension / format tracking
  // ---------------------------------------------------------------------------

  /// Recomputes the uvScale uniform for a new source size while keeping the
  /// renderer's output dimensions fixed. Used when the source dimensions
  /// change under us (e.g. `setDescriptionWhileRecording` switches sensors)
  /// and we have to keep the renderer because the AVAssetWriter is locked to
  /// its current output size.
  ///
  /// Recomputes uvScale to center-crop the new source to the renderer's
  /// *output ratio* (not the original source's pixel count). The result is
  /// always a valid center-crop of the new source matching the locked output
  /// aspect.
  func updateSourceDimensions(width: Int, height: Int) {
    guard width > 0, height > 0 else { return }
    sourceWidth = width
    sourceHeight = height
    let outputRatio = Double(self.width) / Double(self.height)
    let sourceRatio = Double(width) / Double(height)
    let uvScaleX: Float
    let uvScaleY: Float
    if outputRatio > sourceRatio {
      // Output wider than new source — sample full width, crop top/bottom.
      uvScaleX = 1.0
      uvScaleY = Float(sourceRatio / outputRatio)
    } else if outputRatio < sourceRatio {
      // Output taller — sample full height, crop left/right.
      uvScaleX = Float(outputRatio / sourceRatio)
      uvScaleY = 1.0
    } else {
      uvScaleX = 1.0
      uvScaleY = 1.0
    }
    updateUniforms { $0.uvScale = SIMD2<Float>(uvScaleX, uvScaleY) }
  }

  /// Records that the source pixel format changed (e.g. after a camera
  /// switch during recording). `submitRender` selects the correct fragment
  /// pipeline per-frame from the buffer's actual format; this just keeps
  /// `sourcePixelFormat` in sync so callers can detect the change.
  func updateSourcePixelFormat(_ format: OSType) {
    sourcePixelFormat = format
  }

  // ---------------------------------------------------------------------------
  // MARK: - Uniforms
  // ---------------------------------------------------------------------------

  /// Update shader uniforms. Thread-safe; values are snapshotted into each
  /// command buffer at submit time so an in-flight frame never sees a torn
  /// write.
  func updateUniforms(_ update: (inout CameraUniforms) -> Void) {
    uniformsLock.lock()
    update(&uniforms)
    uniformsLock.unlock()
  }

  func snapshotUniforms() -> CameraUniforms {
    uniformsLock.lock()
    defer { uniformsLock.unlock() }
    return uniforms
  }

  /// Returns true if `source`'s pixel format is one the shader can ingest.
  static func canHandle(pixelFormat: OSType) -> Bool {
    return CameraSourceFormat(pixelFormat: pixelFormat) != nil
  }

  /// Returns true when no shader work is needed for the preview path:
  /// uniforms are identity, no aspect-ratio crop, no recording (which always
  /// needs the rendered buffer for AVAssetWriter), and source is already
  /// BGRA at the renderer's output dimensions. The caller can publish the
  /// source buffer directly to the Flutter texture, saving a full-frame GPU
  /// pass per frame.
  func canBypassPreview(
    sourcePixelFormat: OSType,
    sourceWidth: Int,
    sourceHeight: Int
  ) -> Bool {
    guard sourcePixelFormat == kCVPixelFormatType_32BGRA else { return false }
    // Bypass means publishing the source buffer directly to Flutter; that's
    // only valid when the source already matches the *preview* output size.
    guard sourceWidth == previewWidth, sourceHeight == previewHeight else { return false }
    let snapshot = snapshotUniforms()
    return snapshot.vignetteIntensity == 0
      && snapshot.captureScale >= 1.0
      && snapshot.uvScale.x >= 1.0 && snapshot.uvScale.y >= 1.0
      && snapshot.grainOpacity == 0
      && snapshot.lutIntensity == 0
      && snapshot.resolution == 0
      && snapshot.colorShift == 0
      && snapshot.mist == 0
      && snapshot.prism == 0
      && snapshot.bloom == 0
      && snapshot.diffusion == 0
  }

  // ---------------------------------------------------------------------------
  // MARK: - Geometry helpers
  // ---------------------------------------------------------------------------

  /// Computes the grain UV scale for given output dimensions and grain size.
  /// Extracted as a static helper so the math can be unit-tested independently
  /// of the full render pipeline.
  ///
  /// `grainSize` is a linear fraction of the shorter output dimension:
  ///   0.1 → tile = 10% of shorter side (fine grain, default)
  ///   1.0 → one tile fills the shorter dimension
  ///   >1.0 → tile larger than frame (very coarse grain)
  static func grainUVScale(grainSize: Float, outputWidth: Int, outputHeight: Int) -> SIMD2<Float> {
    let gs = max(grainSize, 0.001)  // guard against divide-by-zero
    let dw = Float(outputWidth)
    let dh = Float(outputHeight)
    let cellPx = max(gs * min(dw, dh), 1.0)
    return SIMD2<Float>(dw / cellPx, dh / cellPx)
  }

  /// Computed output dimensions and UV scale for a center-crop of
  /// `(sourceWidth, sourceHeight)` to the target aspect ratio (width/height).
  ///
  /// Returns the source size unchanged with `uvScale = (1, 1)` when
  /// `targetRatio` is `nil` or non-positive (treated as "no crop / original
  /// ratio").
  ///
  /// Output dimensions are rounded to even pixels — H.264/HEVC encoders refuse
  /// odd dimensions on most configurations.
  static func croppedDimensions(
    sourceWidth: Int,
    sourceHeight: Int,
    targetRatio: Double?
  ) -> (width: Int, height: Int, uvScale: SIMD2<Float>) {
    guard sourceWidth > 0, sourceHeight > 0,
      let targetRatio = targetRatio, targetRatio > 0, targetRatio.isFinite
    else {
      // No crop requested (or invalid inputs): still round to even so that
      // H.264/HEVC encoders don't choke on an odd source dimension.
      return (evenRound(Float(sourceWidth)), evenRound(Float(sourceHeight)), SIMD2<Float>(1, 1))
    }

    let sourceRatio = Double(sourceWidth) / Double(sourceHeight)
    var outWidth = sourceWidth
    var outHeight = sourceHeight

    if targetRatio > sourceRatio {
      // Target wider than source — crop top/bottom.
      outHeight = evenRound(Float(Double(sourceWidth) / targetRatio))
    } else if targetRatio < sourceRatio {
      // Target taller — crop left/right.
      outWidth = evenRound(Float(Double(sourceHeight) * targetRatio))
    } else {
      outWidth = evenRound(Float(outWidth))
      outHeight = evenRound(Float(outHeight))
    }

    let uvScaleX = Float(outWidth) / Float(sourceWidth)
    let uvScaleY = Float(outHeight) / Float(sourceHeight)
    return (outWidth, outHeight, SIMD2<Float>(uvScaleX, uvScaleY))
  }

  /// Returns the aspect-ratio crop and capture-scale resample geometry that
  /// the photo path applies to a sensor-orientation pixel buffer of the given
  /// dimensions. Shared by `renderImage` and `renderOriginalImageData` so the
  /// two cannot drift.
  ///
  /// `targetRatio` is the *sensor-landscape* aspect (width/height with
  /// width >= height, e.g. 1.25 for 5:4 sensor → 4:5 portrait after EXIF
  /// rotation). Photo sample buffers are always delivered in sensor
  /// (landscape) orientation regardless of the connection's
  /// `videoOrientation` — the rotation back to device orientation is carried
  /// by EXIF metadata that viewers apply at display time. Storing the ratio
  /// in sensor space here means the photo crop is independent of the
  /// orientation at capture time: a portrait device gets a portrait result
  /// (sensor crop rotated 90° by EXIF), and a landscape device gets a
  /// landscape result (sensor crop displayed as-is) — both from the same
  /// stored value. The caller (`DefaultCamera.buildRendererIfPossible`)
  /// converts the user's orientation-agnostic shape into sensor space via
  /// `sensorSpaceAspectRatio()`.
  ///
  /// `needsResample` is gated on `captureScale < 1` so a `1.0` scale never
  /// triggers an upscale pass — an odd crop dimension could otherwise round
  /// up via `evenRound` and make `scaledWidth == crop.width` at exactly 1.0.
  private func photoCropPlan(
    sourceWidth: Int, sourceHeight: Int
  ) -> (
    crop: (width: Int, height: Int, uvScale: SIMD2<Float>),
    scaledWidth: Int,
    scaledHeight: Int,
    needsResample: Bool,
    captureScale: Float
  ) {
    let crop = VideoFrameRenderer.croppedDimensions(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      targetRatio: targetRatio)
    let captureScale = snapshotUniforms().captureScale
    let scaledWidth = VideoFrameRenderer.evenRound(Float(crop.width) * captureScale)
    let scaledHeight = VideoFrameRenderer.evenRound(Float(crop.height) * captureScale)
    let needsResample =
      captureScale < 1.0 && (scaledWidth < crop.width || scaledHeight < crop.height)
    return (crop, scaledWidth, scaledHeight, needsResample, captureScale)
  }

  /// True iff `renderOriginalImageData` would actually modify the source —
  /// i.e. an aspect-ratio crop is configured, or `captureScale < 1` is
  /// triggering a resample. Lets the photo-output processor skip the entire
  /// CIImage roundtrip and return `AVCapturePhoto.fileDataRepresentation()`
  /// directly in the common case.
  func photoOriginalRequiresProcessing(sourceWidth: Int, sourceHeight: Int) -> Bool {
    let plan = photoCropPlan(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    return plan.crop.width != sourceWidth
      || plan.crop.height != sourceHeight
      || plan.needsResample
  }

  /// Output dimensions of buffers produced by `renderForRecording(_:)` for
  /// the current `captureScale`.
  var recordingOutputWidth: Int { recordingOutputDimensions().width }
  var recordingOutputHeight: Int { recordingOutputDimensions().height }

  private func recordingOutputDimensions() -> (width: Int, height: Int) {
    // Always return the full aspect-ratio-cropped dimensions. When
    // captureScale < 1, renderForRecording renders to a smaller intermediate
    // buffer and Lanczos-upscales back to (width, height) before handing the
    // frame to AVAssetWriter — so the writer always receives full-resolution
    // buffers regardless of the current captureScale.
    (width, height)
  }

  // ---------------------------------------------------------------------------
  // MARK: - Public render entry points
  // ---------------------------------------------------------------------------

  /// Renders `source` through the shader pipeline.
  ///
  /// - Parameter blocking: when true (recording mode) waits for an in-flight
  ///   slot so no frame is dropped from the GPU pipeline. When false the call
  ///   returns nil immediately if the pipeline is full and the caller should
  ///   fall back to the source buffer.
  ///
  /// The returned buffer is still being written by the GPU when this method
  /// returns. That is safe because:
  ///   - Flutter's Metal preview reads it via a CVMetalTexture — the driver
  ///     serialises the read-after-write through IOSurface fences.
  ///   - AVAssetWriter's VideoToolbox encoder is also GPU-based and respects
  ///     the same IOSurface fences.
  ///
  /// Do **not** call `CVPixelBufferLockBaseAddress` on the returned buffer
  /// for CPU access — use `renderImage(_:)` instead, which waits for the GPU.
  func render(_ source: CVPixelBuffer, blocking: Bool) -> CVPixelBuffer? {
    if blocking {
      previewInFlightSemaphore.wait()
    } else {
      guard previewInFlightSemaphore.wait(timeout: .now()) != .timedOut else {
        return nil
      }
    }

    var destinationBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      kCFAllocatorDefault, pool, poolAuxAttributes, &destinationBuffer)
    guard status == kCVReturnSuccess, let destination = destinationBuffer else {
      previewInFlightSemaphore.signal()
      if status != kCVReturnWouldExceedAllocationThreshold {
        NSLog("VideoFrameRenderer: destination buffer allocation failed: \(status)")
      }
      return nil
    }

    guard
      let commandBuffer = submitRender(
        from: source, to: destination,
        destWidth: previewWidth, destHeight: previewHeight,
        commandQueue: previewCommandQueue,
        overrides: UniformOverrides(
          darkenOutside: VideoFrameRenderer.previewDarkenOutside))
    else {
      previewInFlightSemaphore.signal()
      return nil
    }

    commandBuffer.addCompletedHandler { [previewInFlightSemaphore] _ in
      previewInFlightSemaphore.signal()
    }
    commandBuffer.commit()
    flushTextureCacheIfNeeded()
    return destination
  }

  /// Renders into a freshly allocated buffer cropped to the renderer's
  /// configured target aspect ratio **and** the current capture scale,
  /// preserving the source photo's full resolution along each axis.
  /// **Waits for the GPU to finish.** Uses a separate command queue so it
  /// doesn't stall the live preview.
  func renderImage(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let sourceWidth = CVPixelBufferGetWidth(source)
    let sourceHeight = CVPixelBufferGetHeight(source)

    let plan = photoCropPlan(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    let crop = plan.crop
    let captureScale = plan.captureScale
    let scaledWidth = plan.scaledWidth
    let scaledHeight = plan.scaledHeight

    let attrs: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    var destination: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, scaledWidth, scaledHeight, kCVPixelFormatType_32BGRA,
      attrs as CFDictionary, &destination)
    guard status == kCVReturnSuccess, let dest = destination else {
      NSLog("VideoFrameRenderer: one-off destination buffer allocation failed: \(status)")
      return nil
    }

    guard
      let commandBuffer = submitRender(
        from: source, to: dest, destWidth: scaledWidth, destHeight: scaledHeight,
        commandQueue: photoCommandQueue,
        overrides: UniformOverrides(
          uvScale: crop.uvScale,
          captureScale: captureScale,
          darkenOutside: 0.0,
          swapGrainAxes: true))
    else {
      return nil
    }

    // When captureScale < 1 the render produced a smaller buffer. Lanczos-upscale
    // it back to the full crop dimensions in the same command buffer so the saved
    // photo always has the maximum resolution for the configured aspect ratio.
    let needsUpscale = plan.needsResample
    var finalBuffer: CVPixelBuffer = dest

    if needsUpscale {
      // Photo path: allocate the upscale destination directly rather than via a
      // pool. Photos are one-shot and infrequent, so pool churn would dominate
      // the (small) allocation cost.
      let upscaleAttrs: [String: Any] = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
      var upscaleDest: CVPixelBuffer?
      let upscaleStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, crop.width, crop.height, kCVPixelFormatType_32BGRA,
        upscaleAttrs as CFDictionary, &upscaleDest)
      if upscaleStatus == kCVReturnSuccess, let upscaleBuffer = upscaleDest,
        encodeLanczosUpscale(
          using: photoLanczos, in: commandBuffer, from: dest, to: upscaleBuffer)
      {
        finalBuffer = upscaleBuffer
      } else {
        NSLog("VideoFrameRenderer: photo Lanczos upscale failed, returning scaled-down buffer")
      }
    }

    let waitSem = DispatchSemaphore(value: 0)
    commandBuffer.addCompletedHandler { _ in waitSem.signal() }
    commandBuffer.commit()
    waitSem.wait()
    // Photo is one-shot: the source IOSurface won't be reused, so force a
    // flush to release the cache entry immediately rather than waiting for
    // the periodic preview-path flush. Same reasoning for the aux blur sets —
    // at quarter photo resolution they are tens of MB, too much to pin
    // between captures.
    CVMetalTextureCacheFlush(textureCache, 0)
    releasePhotoAuxBlurResources()
    return finalBuffer
  }

  /// Renders the camera buffer through the shader and encodes the result as
  /// JPEG or HEIF. `destinationUTType` should be e.g. `"public.jpeg"` /
  /// `"public.heic"`. `metadata` is forwarded to the encoder so EXIF /
  /// orientation tags are preserved.
  func renderImageData(
    sourceBuffer: CVPixelBuffer,
    destinationUTType: CFString,
    metadata: CFDictionary?
  ) -> Data? {
    guard let renderedBuffer = renderImage(sourceBuffer) else { return nil }
    return encode(
      pixelBuffer: renderedBuffer, destinationUTType: destinationUTType, metadata: metadata)
  }

  /// Compatibility wrapper for callers that only have a CGImage (e.g. when
  /// the photo output delivered a compressed file rather than a raw buffer).
  /// Prefer `renderImageData(sourceBuffer:...)` — it skips the decode pass.
  func renderImageData(
    cgImage: CGImage,
    destinationUTType: CFString,
    metadata: CFDictionary?
  ) -> Data? {
    guard let sourceBuffer = VideoFrameRenderer.makePixelBuffer(from: cgImage) else {
      NSLog("VideoFrameRenderer: failed to wrap CGImage as CVPixelBuffer")
      return nil
    }
    return renderImageData(
      sourceBuffer: sourceBuffer,
      destinationUTType: destinationUTType,
      metadata: metadata)
  }

  /// Encodes the source buffer to JPEG/HEIF with the **same crop and
  /// `captureScale` resampling** as `renderImageData(sourceBuffer:...)`, but
  /// **without** applying the custom `CameraShader.metal` effects (vignette,
  /// grain, LUT, color shift, mist, etc.). Used by the "take picture with
  /// original" path to produce an un-effected sibling of the rendered photo
  /// whose dimensions and resampling character match the processed file.
  ///
  /// Implementation: Core Image graph
  ///   `CIImage(cvPixelBuffer:) → cropped → CILanczosScaleTransform (down)
  ///    → CILanczosScaleTransform (up) → cropped to exact size → encode`
  /// executed by the cached `CIContext`. The custom Metal shader is never
  /// bound.
  func renderOriginalImageData(
    sourceBuffer: CVPixelBuffer,
    destinationUTType: CFString,
    metadata: CFDictionary?
  ) -> Data? {
    let sourceWidth = CVPixelBufferGetWidth(sourceBuffer)
    let sourceHeight = CVPixelBufferGetHeight(sourceBuffer)

    let plan = photoCropPlan(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    let crop = plan.crop

    var image = CIImage(cvPixelBuffer: sourceBuffer)

    // Center-crop to (crop.width, crop.height) and translate to origin so the
    // downstream encode uses an extent of exactly the cropped size.
    if crop.width != sourceWidth || crop.height != sourceHeight {
      let cropOriginX = (sourceWidth - crop.width) / 2
      let cropOriginY = (sourceHeight - crop.height) / 2
      let cropRect = CGRect(
        x: cropOriginX, y: cropOriginY, width: crop.width, height: crop.height)
      image = image.cropped(to: cropRect).transformed(
        by: CGAffineTransform(
          translationX: -CGFloat(cropOriginX),
          y: -CGFloat(cropOriginY)))
    }

    // Mirror the shader path's "downsample then Lanczos-upscale" so the
    // saved file shares the same dimensions and resampling character. Both
    // passes must succeed atomically — applying the upscale to a still-full-
    // size image would produce an oversized output.
    if plan.needsResample {
      // Use the X-dim scale ratio for both passes; aspectRatio = 1 keeps the
      // Y dimension proportional. The final `cropped(to:)` snaps any
      // Lanczos-induced extent overshoot back to the exact target.
      let downScale = Double(plan.scaledWidth) / Double(crop.width)
      let upScale = Double(crop.width) / Double(plan.scaledWidth)

      if let downsampled = VideoFrameRenderer.lanczosScale(image, scale: downScale),
        let upsampled = VideoFrameRenderer.lanczosScale(downsampled, scale: upScale)
      {
        image = upsampled.cropped(
          to: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
      } else {
        NSLog(
          "VideoFrameRenderer: original-path Lanczos resample failed — keeping unscaled image"
        )
      }
    }

    return encode(
      ciImage: image, destinationUTType: destinationUTType, metadata: metadata)
  }

  /// CGImage compatibility wrapper for `renderOriginalImageData`. Used by the
  /// compressed-delivery photo path (no `pixelBuffer` available).
  func renderOriginalImageData(
    cgImage: CGImage,
    destinationUTType: CFString,
    metadata: CFDictionary?
  ) -> Data? {
    guard let sourceBuffer = VideoFrameRenderer.makePixelBuffer(from: cgImage) else {
      NSLog(
        "VideoFrameRenderer: failed to wrap CGImage as CVPixelBuffer for original path")
      return nil
    }
    return renderOriginalImageData(
      sourceBuffer: sourceBuffer,
      destinationUTType: destinationUTType,
      metadata: metadata)
  }

  /// Applies CILanczosScaleTransform with `aspectRatio = 1`. Returns nil if
  /// the filter can't be instantiated or has no output. Pulled out so the
  /// original-photo path can chain two calls without duplicating boilerplate.
  private static func lanczosScale(_ input: CIImage, scale: Double) -> CIImage? {
    guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(NSNumber(value: scale), forKey: kCIInputScaleKey)
    filter.setValue(NSNumber(value: 1.0), forKey: kCIInputAspectRatioKey)
    return filter.outputImage
  }

  /// Renders into a pooled buffer at full `(width, height)` — for AVAssetWriter
  /// input during recording. When `captureScale < 1`, renders to a smaller
  /// intermediate buffer and Lanczos-upscales to `(width, height)` in the same
  /// command buffer. Blocks on the in-flight semaphore (recording must not drop
  /// frames).
  ///
  /// **Invariant — do not break:** the returned buffer must only flow into
  /// the AVAssetWriter pixel-buffer adaptor and be released as the encoder
  /// drains it. The recording pool is hard-capped at
  /// `maxRecordingPoolBuffers` (8). If a future caller publishes this buffer
  /// to the Flutter preview texture, or otherwise retains it beyond the
  /// writer's reach, the pool will saturate at the cap and this method will
  /// start returning nil — silently dropping every frame for the rest of the
  /// recording. Preview consumers must go through `render(_:blocking:)`
  /// which has its own pool.
  func renderForRecording(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let snapshot = snapshotUniforms()
    let scaledW = VideoFrameRenderer.evenRound(Float(width) * snapshot.captureScale)
    let scaledH = VideoFrameRenderer.evenRound(Float(height) * snapshot.captureScale)
    // Gate on `captureScale < 1` so a `1.0` scale never triggers an upscale
    // pass — `evenRound` could otherwise round an odd dimension up and make
    // `scaledW == width` numerically true at exactly 1.0. Also avoids the
    // wasteful intermediate-pool path for near-1 scales (e.g. 0.999) where
    // the visual difference is imperceptible.
    let needsUpscale =
      snapshot.captureScale < 1.0 && (scaledW < width || scaledH < height)

    // Output pool is always at full (width × height) so AVAssetWriter receives
    // consistent dimensions regardless of captureScale.
    guard let (recordingPool, auxAttrs) =
      ensureRecordingPoolAndAuxAttrs(width: width, height: height)
    else {
      return nil
    }

    recordingInFlightSemaphore.wait()

    // When upscaling is needed, acquire the small intermediate buffer first.
    // Allocating the (much larger) full-resolution destination only to discard
    // it on a scaled-pool miss would waste a ~30 MB IOSurface on the failure
    // path under writer stalls.
    var intermediateBuffer: CVPixelBuffer?
    if needsUpscale {
      guard let (scaledPool, scaledAux) = ensureScaledRenderPool(width: scaledW, height: scaledH)
      else {
        recordingInFlightSemaphore.signal()
        return nil
      }
      var tempBuffer: CVPixelBuffer?
      let tempStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault, scaledPool, scaledAux, &tempBuffer)
      guard tempStatus == kCVReturnSuccess, let temp = tempBuffer else {
        recordingInFlightSemaphore.signal()
        return nil
      }
      intermediateBuffer = temp
    }

    var destinationBuffer: CVPixelBuffer?
    // Allocate with aux attributes so the pool's high-water threshold is
    // enforced — a stalled writer cannot accumulate unbounded 4K IOSurfaces.
    let destStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      kCFAllocatorDefault, recordingPool, auxAttrs, &destinationBuffer)
    guard destStatus == kCVReturnSuccess, let destination = destinationBuffer else {
      recordingInFlightSemaphore.signal()
      if destStatus != kCVReturnWouldExceedAllocationThreshold {
        NSLog(
          "VideoFrameRenderer: recording buffer allocation failed: \(destStatus)"
            + " (pool dims \(width)x\(height))")
      }
      return nil
    }

    if let temp = intermediateBuffer {
      // Render to the small intermediate buffer, then Lanczos-upscale into the
      // full-resolution destination — both in one command buffer.
      guard
        let commandBuffer = submitRender(
          from: source, to: temp,
          destWidth: scaledW, destHeight: scaledH,
          commandQueue: previewCommandQueue,
          overrides: UniformOverrides(
            captureScale: snapshot.captureScale,
            darkenOutside: 0.0))
      else {
        recordingInFlightSemaphore.signal()
        return nil
      }

      guard
        encodeLanczosUpscale(
          using: recordingLanczos, in: commandBuffer, from: temp, to: destination)
      else {
        recordingInFlightSemaphore.signal()
        return nil
      }

      // `temp` is already kept alive by the Lanczos `srcCV` retention inside
      // `encodeLanczosUpscale`, so we don't need a separate capture here.
      commandBuffer.addCompletedHandler { [recordingInFlightSemaphore] _ in
        recordingInFlightSemaphore.signal()
      }
      commandBuffer.commit()
      flushTextureCacheIfNeeded()
      return destination
    }

    // captureScale == 1.0: render directly to the full-resolution pool buffer.
    guard
      let commandBuffer = submitRender(
        from: source, to: destination,
        destWidth: width, destHeight: height,
        commandQueue: previewCommandQueue,
        overrides: UniformOverrides(
          captureScale: snapshot.captureScale,
          darkenOutside: 0.0))
    else {
      recordingInFlightSemaphore.signal()
      return nil
    }

    commandBuffer.addCompletedHandler { [recordingInFlightSemaphore] _ in
      recordingInFlightSemaphore.signal()
    }
    commandBuffer.commit()
    flushTextureCacheIfNeeded()
    return destination
  }

  /// Drops the lazily-created recording pool. Called when `captureScale`
  /// changes so the next recording frame rebuilds the pool at the new
  /// scaled dimensions. Safe to call when no pool exists.
  func invalidateRecordingPool() {
    recordingPoolLock.lock()
    defer { recordingPoolLock.unlock() }
    recordingPool = nil
    recordingPoolWidth = 0
    recordingPoolHeight = 0
    recordingPoolAuxAttributes = nil
    // Also drop the intermediate pool used when captureScale < 1: its
    // dimensions change with captureScale, so it must be recreated too.
    scaledRenderPool = nil
    scaledRenderPoolWidth = 0
    scaledRenderPoolHeight = 0
    scaledRenderPoolAuxAttributes = nil
  }

  // ---------------------------------------------------------------------------
  // MARK: - Render pass core
  // ---------------------------------------------------------------------------

  /// Per-call uniform overrides. Lets the photo and recording-capture paths
  /// run with their own UV transform / darkening without disturbing the
  /// shared cached uniforms used by in-flight preview frames.
  struct UniformOverrides {
    var uvScale: SIMD2<Float>? = nil
    var captureScale: Float? = nil
    var darkenOutside: Float? = nil
    /// Set true when the pixel buffer is in sensor (landscape) orientation
    /// and a 90° EXIF rotation will be applied by the viewer (i.e. the photo
    /// path). Swapping the X/Y components of grainUVScale compensates for
    /// the axis transposition so the grain looks identical in the displayed
    /// photo and the live preview.
    var swapGrainAxes: Bool = false
  }

  /// Bundle of textures bound for a single render pass. Inline-storage
  /// alternative to building `[CVMetalTexture]` / `[MTLTexture]` arrays per
  /// frame; YUV biplanar sources need exactly 2 planes, BGRA needs 1.
  private struct SourceTextureSet {
    let cv0: CVMetalTexture
    let mtl0: MTLTexture
    let cv1: CVMetalTexture?
    let mtl1: MTLTexture?
    let destCV: CVMetalTexture
    let destMTL: MTLTexture

    /// CbCr plane, or — for BGRA, which has none — the source itself as the
    /// mandatory dummy at that slot (Metal validation requires *some* texture
    /// at every declared slot; the BGRA-specialised shader variants never
    /// sample it).
    var chromaOrDummy: MTLTexture { mtl1 ?? mtl0 }
  }

  /// Snapshot of all mutable state a single render pass needs. Built once
  /// per call so the hot path takes each of `uniformsLock`,
  /// `grainTextureLock`, and `lutTextureLock` exactly once.
  private struct RenderSnapshot {
    var uniforms: CameraUniforms
    var grainTexture: MTLTexture?
    var grainSize: Float
    var lutTexture: MTLTexture?
  }

  private func snapshotRenderState() -> RenderSnapshot {
    uniformsLock.lock()
    let u = uniforms
    uniformsLock.unlock()

    grainTextureLock.lock()
    let gt = grainTexture
    let gs = grainSize
    grainTextureLock.unlock()

    lutTextureLock.lock()
    let lt = lutTexture
    lutTextureLock.unlock()

    return RenderSnapshot(uniforms: u, grainTexture: gt, grainSize: gs, lutTexture: lt)
  }

  /// Encodes the render pass and returns the uncommitted command buffer.
  /// The caller owns commit + completion handlers. Source `CVMetalTexture`
  /// wrappers are retained for the lifetime of the GPU work via the command
  /// buffer's completion handler — required by the IOSurface contract.
  private func submitRender(
    from source: CVPixelBuffer,
    to destination: CVPixelBuffer,
    destWidth: Int,
    destHeight: Int,
    commandQueue: MTLCommandQueue,
    overrides: UniformOverrides = UniformOverrides()
  ) -> MTLCommandBuffer? {
    let sourcePixelFormatValue = CVPixelBufferGetPixelFormatType(source)
    guard let format = CameraSourceFormat(pixelFormat: sourcePixelFormatValue) else {
      NSLog(
        "VideoFrameRenderer: unsupported source pixel format "
          + String(format: "0x%08X", sourcePixelFormatValue))
      return nil
    }

    // Build the source/destination texture set and pick the matching pipeline.
    guard let (sourceSet, pipelineState) = makeRenderTextures(
      source: source, destination: destination,
      destWidth: destWidth, destHeight: destHeight, format: format)
    else {
      return nil
    }

    var snapshot = snapshotRenderState()

    // Per-call overrides for the photo / recording paths. Applied before we
    // decide whether to dispatch the pre-pass so an override that flips
    // `resolution` (none today, but reserved) is honoured here too.
    if let v = overrides.uvScale { snapshot.uniforms.uvScale = v }
    if let v = overrides.captureScale { snapshot.uniforms.captureScale = v }
    if let v = overrides.darkenOutside { snapshot.uniforms.darkenOutside = v }

    // Aspect of the actual destination buffer. Preview and recording write
    // portrait-oriented buffers; the photo path writes a sensor-orientation
    // (landscape) buffer that the viewer rotates via EXIF. Effects that
    // compensate for non-square pixel space (vignette circle, fisheye disk)
    // need the on-buffer aspect to stay round, so derive it here instead of
    // relying on the cached default.
    snapshot.uniforms.outputAspect = Float(destWidth) / Float(destHeight)

    // Source plane dimensions: BGRA reports the full buffer; YUV reports the
    // Y plane (which is at full source resolution). Used to size the
    // pre-pass intermediate.
    let sourceW: Int
    let sourceH: Int
    switch format {
    case .bgra:
      sourceW = CVPixelBufferGetWidth(source)
      sourceH = CVPixelBufferGetHeight(source)
    case .yuvFullRange, .yuvVideoRange:
      sourceW = CVPixelBufferGetWidthOfPlane(source, 0)
      sourceH = CVPixelBufferGetHeightOfPlane(source, 0)
    }

    // Decide whether to run the separable-blur pre-pass. The shader's blur
    // step only activates when `resolution > 0`, so the pre-pass output is
    // only consumed in that case — anything else and we skip the cost.
    let needsPrePass = snapshot.uniforms.resolution > 0
    let isPhotoQueue = commandQueue === photoCommandQueue
    let prePassTexture: MTLTexture? =
      needsPrePass
      ? ensurePrePassTexture(width: sourceW, height: sourceH, isPhotoQueue: isPhotoQueue)
      : nil

    // Aux blur working sets, both rendered at quarter source resolution — the
    // results are heavy low-passes, so working small loses nothing visually
    // while shrinking both the fill cost and the Gaussian sigma (which scales
    // with the working size) ~4x each versus half resolution. The bloom
    // bright-pass runs only when `bloom > 0`; the frame blur feeds both mist
    // and diffusion, so it runs when either is on. Lifecycle (lazy alloc,
    // deferred release) is handled inside `auxBlurResources`.
    let auxW = max(1, sourceW / 4)
    let auxH = max(1, sourceH / 4)
    let bloomResources = auxBlurResources(
      .bloom, active: snapshot.uniforms.bloom > 0,
      width: auxW, height: auxH, isPhotoQueue: isPhotoQueue)
    let frameBlurResources = auxBlurResources(
      .frameBlur, active: snapshot.uniforms.mist > 0 || snapshot.uniforms.diffusion > 0,
      width: auxW, height: auxH, isPhotoQueue: isPhotoQueue)

    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      NSLog("VideoFrameRenderer: command buffer creation failed")
      return nil
    }

    // Encode the horizontal-blur pre-pass into the same command buffer as the
    // main pass. Metal's automatic hazard tracking serialises the main pass's
    // read against this write — no explicit fence needed.
    if let prePassTexture = prePassTexture {
      let prePassDescriptor = MTLRenderPassDescriptor()
      prePassDescriptor.colorAttachments[0].texture = prePassTexture
      prePassDescriptor.colorAttachments[0].loadAction = .dontCare
      prePassDescriptor.colorAttachments[0].storeAction = .store

      guard let prePassEncoder = commandBuffer.makeRenderCommandEncoder(
        descriptor: prePassDescriptor)
      else {
        NSLog("VideoFrameRenderer: pre-pass encoder creation failed")
        return nil
      }
      prePassEncoder.setRenderPipelineState(pipelines[format.rawValue].prePass)
      prePassEncoder.setFragmentTexture(sourceSet.mtl0, slot: CameraShaderTextureSource)
      prePassEncoder.setFragmentTexture(sourceSet.chromaOrDummy, slot: CameraShaderTextureCbCr)
      var prePassUniforms = snapshot.uniforms
      // Bind uniforms to *both* stages: the vertex shader needs `uvScale` so
      // it can apply the same center-anchored crop the main vertex applies,
      // limiting the pre-pass blur to the region the main pass will sample.
      prePassEncoder.setVertexBytes(
        &prePassUniforms, length: MemoryLayout<CameraUniforms>.stride, index: 0)
      prePassEncoder.setFragmentBytes(
        &prePassUniforms, length: MemoryLayout<CameraUniforms>.stride, index: 0)
      prePassEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      prePassEncoder.endEncoding()
    }

    // Aux blur passes (bloom bright-pass; frame-blur downsample for
    // mist/diffusion): render the kind's input texture, then an MPS Gaussian
    // into its blurred texture. Encoded ahead of the main pass in the same
    // command buffer, so Metal's hazard tracking serialises the main pass's
    // read after the blur write — no explicit barrier needed.
    if let bloom = bloomResources {
      guard encodeAuxBlurPass(
        commandBuffer: commandBuffer, pipeline: pipelines[format.rawValue].bloomBright,
        resources: bloom, sourceSet: sourceSet, uniforms: snapshot.uniforms,
        label: "bloom bright-pass")
      else { return nil }
    }
    if let frameBlur = frameBlurResources {
      guard encodeAuxBlurPass(
        commandBuffer: commandBuffer, pipeline: pipelines[format.rawValue].frameBlurDownsample,
        resources: frameBlur, sourceSet: sourceSet, uniforms: snapshot.uniforms,
        label: "frame-blur downsample")
      else { return nil }
    }

    let passDescriptor = MTLRenderPassDescriptor()
    passDescriptor.colorAttachments[0].texture = sourceSet.destMTL
    passDescriptor.colorAttachments[0].loadAction = .dontCare
    passDescriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
    else {
      NSLog("VideoFrameRenderer: main encoder creation failed")
      return nil
    }

    encoder.setRenderPipelineState(pipelineState)
    // Texture slots are the shared `CameraShaderTextureIndex` constants,
    // fixed across source formats.
    encoder.setFragmentTexture(sourceSet.mtl0, slot: CameraShaderTextureSource)
    encoder.setFragmentTexture(sourceSet.chromaOrDummy, slot: CameraShaderTextureCbCr)

    // Bind grain texture (if loaded). The shader receives it even when
    // `grainOpacity == 0`; the early-out `if (opacity > 0)` in the shader
    // prevents any sampling in that case.
    //
    // If no texture is bound we zero out grainOpacity so the shader's
    // early-out skips an unbound slot — same for the LUT below.
    if let gt = snapshot.grainTexture {
      encoder.setFragmentTexture(gt, slot: CameraShaderTextureGrain)
    } else {
      snapshot.uniforms.grainOpacity = 0
    }
    if let lt = snapshot.lutTexture {
      encoder.setFragmentTexture(lt, slot: CameraShaderTextureLut)
    } else {
      snapshot.uniforms.lutIntensity = 0
    }

    // Pre-blurred intermediate (or the source as a harmless fallback when no
    // pre-pass ran). Metal validation requires *some* texture at every slot
    // declared by the shader, even on code paths that never sample it; the
    // shader's `if (blurRadius > 0)` branch guards the actual sampling.
    encoder.setFragmentTexture(
      prePassTexture ?? sourceSet.mtl0, slot: CameraShaderTexturePreBlurred)

    // Blurred bloom halo. As with grain/LUT, bind the source as a harmless
    // fallback and zero `bloom` when absent so the shader's `if (bloom > 0)`
    // guard skips sampling the fallback.
    if let bt = bloomResources?.blurred {
      encoder.setFragmentTexture(bt, slot: CameraShaderTextureBloom)
    } else {
      snapshot.uniforms.bloom = 0
      encoder.setFragmentTexture(sourceSet.mtl0, slot: CameraShaderTextureBloom)
    }

    // Blurred frame copy — same fallback contract as the bloom halo. Both
    // consumers must be zeroed when the texture is absent, or the shader
    // would blend the un-blurred fallback into the image.
    if let ft = frameBlurResources?.blurred {
      encoder.setFragmentTexture(ft, slot: CameraShaderTextureFrameBlur)
    } else {
      snapshot.uniforms.mist = 0
      snapshot.uniforms.diffusion = 0
      encoder.setFragmentTexture(sourceSet.mtl0, slot: CameraShaderTextureFrameBlur)
    }

    // Resolution-independent, aspect-correct grain UV scale, then optional
    // photo-path axis swap and texture-aspect pre-multiply.
    //
    // Using actual pixel dimensions (not UV [0,1]) keeps tiles square in
    // output pixels — no horizontal stretching on landscape outputs — and
    // makes the apparent grain size identical across preview, 1080p video,
    // and full-resolution photos. Texture aspect is pre-multiplied into
    // grainUVScale.y so the Metal shader doesn't need per-fragment
    // get_width()/get_height() calls. The aspect correction is applied
    // *after* the axis swap so it always corrects the .y component of
    // whatever UV is passed to applyGrain.
    if snapshot.uniforms.grainOpacity > 0, let gt = snapshot.grainTexture {
      var scale = VideoFrameRenderer.grainUVScale(
        grainSize: snapshot.grainSize, outputWidth: destWidth, outputHeight: destHeight)
      if overrides.swapGrainAxes {
        scale = SIMD2<Float>(scale.y, scale.x)
      }
      scale.y *= Float(gt.width) / Float(gt.height)
      snapshot.uniforms.grainUVScale = scale
      snapshot.uniforms.grainSwapUV = overrides.swapGrainAxes ? 1.0 : 0.0
    }

    // Inline uniforms — Metal copies the bytes into its own per-draw storage
    // so each in-flight frame gets its own snapshot. No shared MTLBuffer to
    // race over. Bound to both stages: vertex applies the UV crop transform,
    // fragment uses the visual-effect fields.
    var uniformsForGPU = snapshot.uniforms
    encoder.setVertexBytes(
      &uniformsForGPU, length: MemoryLayout<CameraUniforms>.stride, index: 0)
    encoder.setFragmentBytes(
      &uniformsForGPU, length: MemoryLayout<CameraUniforms>.stride, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()

    // CVMetalTexture wrappers must outlive the GPU work — the bare
    // MTLTexture does not retain the IOSurface lock. If the wrappers are
    // released while the GPU is still reading from the backing IOSurface
    // the Metal completion queue crashes with EXC_BAD_ACCESS in CF_IS_OBJC.
    //
    // `withExtendedLifetime` is the documented way to tell the compiler
    // "this value must remain alive until this point" — a bare `_ = …`
    // could be elided by the optimizer.
    commandBuffer.addCompletedHandler { _ in
      withExtendedLifetime(sourceSet) {}
    }
    return commandBuffer
  }

  /// Builds source + destination textures for a single render pass and
  /// selects the matching fragment pipeline. The two used to be split across
  /// separate `switch format` blocks; folding them keeps the format dispatch
  /// in one place.
  private func makeRenderTextures(
    source: CVPixelBuffer,
    destination: CVPixelBuffer,
    destWidth: Int,
    destHeight: Int,
    format: CameraSourceFormat
  ) -> (SourceTextureSet, MTLRenderPipelineState)? {
    let cv0: CVMetalTexture
    let mtl0: MTLTexture
    let cv1: CVMetalTexture?
    let mtl1: MTLTexture?

    switch format {
    case .bgra:
      let w = CVPixelBufferGetWidth(source)
      let h = CVPixelBufferGetHeight(source)
      guard let (cv, mtl) = makeTexture(
        from: source, plane: 0, width: w, height: h,
        pixelFormat: .bgra8Unorm_srgb, isRenderTarget: false)
      else {
        NSLog("VideoFrameRenderer: BGRA source texture creation failed")
        return nil
      }
      cv0 = cv; mtl0 = mtl; cv1 = nil; mtl1 = nil

    case .yuvFullRange, .yuvVideoRange:
      // YUV biplanar: sample Y plane and the interleaved CbCr plane
      // separately and convert in the fragment shader.
      let yW = CVPixelBufferGetWidthOfPlane(source, 0)
      let yH = CVPixelBufferGetHeightOfPlane(source, 0)
      let cW = CVPixelBufferGetWidthOfPlane(source, 1)
      let cH = CVPixelBufferGetHeightOfPlane(source, 1)
      guard let (yCV, yMTL) = makeTexture(
        from: source, plane: 0, width: yW, height: yH,
        pixelFormat: .r8Unorm, isRenderTarget: false),
        let (cCV, cMTL) = makeTexture(
          from: source, plane: 1, width: cW, height: cH,
          pixelFormat: .rg8Unorm, isRenderTarget: false)
      else {
        NSLog("VideoFrameRenderer: YUV source texture creation failed")
        return nil
      }
      cv0 = yCV; mtl0 = yMTL; cv1 = cCV; mtl1 = cMTL
    }

    guard let (destCV, destMTL) = makeTexture(
      from: destination, plane: 0, width: destWidth, height: destHeight,
      pixelFormat: .bgra8Unorm_srgb, isRenderTarget: true)
    else {
      NSLog("VideoFrameRenderer: destination texture creation failed")
      return nil
    }

    let set = SourceTextureSet(
      cv0: cv0, mtl0: mtl0, cv1: cv1, mtl1: mtl1,
      destCV: destCV, destMTL: destMTL)
    return (set, pipelines[format.rawValue].main)
  }

  private func makeTexture(
    from buffer: CVPixelBuffer,
    plane: Int,
    width: Int,
    height: Int,
    pixelFormat: MTLPixelFormat,
    isRenderTarget: Bool
  ) -> (CVMetalTexture, MTLTexture)? {
    let attrs = isRenderTarget ? renderTargetAttrs : shaderReadAttrs
    var cvTexture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, buffer, attrs,
      pixelFormat, width, height, plane, &cvTexture)
    guard status == kCVReturnSuccess, let cvTexture = cvTexture,
      let mtlTexture = CVMetalTextureGetTexture(cvTexture)
    else {
      return nil
    }
    return (cvTexture, mtlTexture)
  }

  // ---------------------------------------------------------------------------
  // MARK: - Lanczos upscale
  // ---------------------------------------------------------------------------

  /// Encodes a GPU Lanczos upscale from `source` into `destination` in an
  /// already-open (uncommitted) `commandBuffer`. Both buffers must be BGRA.
  ///
  /// Both passes (the preceding Metal render and this fragment-shader-based
  /// MPS pass) share one command buffer so the driver schedules them
  /// back-to-back without a CPU round-trip or an extra synchronisation point.
  /// Read-after-write synchronisation between the render-pass write to `source`
  /// and the MPS read of `source` relies on Metal's automatic hazard tracking
  /// for IOSurface-backed textures created via `CVMetalTextureCache`, which is
  /// resource-level (not view-level) and so handles the case where the render
  /// pass writes via one MTLTexture view and MPS reads via another.
  ///
  /// `kernel` is the cached MPS instance for this render path — the recording
  /// and photo paths each have their own (`scaleTransform` is mutable state
  /// and the paths run on independent delegate queues).
  ///
  /// Texture wrappers are kept alive via the command buffer's completion
  /// handler — the caller must commit the buffer after this returns.
  private func encodeLanczosUpscale(
    using kernel: MPSImageLanczosScale,
    in commandBuffer: MTLCommandBuffer,
    from source: CVPixelBuffer,
    to destination: CVPixelBuffer
  ) -> Bool {
    let srcW = CVPixelBufferGetWidth(source)
    let srcH = CVPixelBufferGetHeight(source)
    let dstW = CVPixelBufferGetWidth(destination)
    let dstH = CVPixelBufferGetHeight(destination)

    // Use .bgra8Unorm (not _sRGB) — MPS performs geometric resampling of the
    // raw byte values. The sRGB encoding of the pixel data is preserved
    // byte-for-byte; only the spatial interpolation kernel is applied.
    var srcCV: CVMetalTexture?
    var dstCV: CVMetalTexture?
    let srcStatus = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, source, nil,
      .bgra8Unorm, srcW, srcH, 0, &srcCV)
    let dstStatus = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, destination,
      VideoFrameRenderer.mpsWriteAttrs, .bgra8Unorm, dstW, dstH, 0, &dstCV)

    guard let srcTex = srcCV.flatMap(CVMetalTextureGetTexture),
      let dstTex = dstCV.flatMap(CVMetalTextureGetTexture)
    else {
      NSLog(
        "VideoFrameRenderer: Lanczos upscale texture creation failed"
          + " (src=\(srcStatus), dst=\(dstStatus))")
      return false
    }

    var transform = MPSScaleTransform(
      scaleX: Double(dstW) / Double(srcW),
      scaleY: Double(dstH) / Double(srcH),
      translateX: 0, translateY: 0)
    // The pointer must remain valid through `encode`; per `withUnsafePointer`'s
    // contract it is only guaranteed inside the closure, so do the encode there.
    // Clear `scaleTransform` before leaving the closure so the kernel doesn't
    // keep a dangling stack pointer that a future caller might inadvertently
    // read by calling `encode` without re-setting the transform.
    withUnsafePointer(to: &transform) { ptr in
      kernel.scaleTransform = ptr
      kernel.encode(
        commandBuffer: commandBuffer,
        sourceTexture: srcTex,
        destinationTexture: dstTex)
      kernel.scaleTransform = nil
    }

    // Keep CVMetalTexture wrappers alive until the GPU command completes.
    // `withExtendedLifetime`, not a bare `_ =` — the optimizer may elide a
    // bare read (see the equivalent handler in `submitRender`).
    commandBuffer.addCompletedHandler { _ in
      withExtendedLifetime(srcCV) {}
      withExtendedLifetime(dstCV) {}
    }
    return true
  }

  // ---------------------------------------------------------------------------
  // MARK: - Separable-blur intermediate
  // ---------------------------------------------------------------------------

  /// Lazily allocates (or re-allocates on size change) the RGBA16F
  /// intermediate that holds the horizontal half of the separable
  /// old-camera blur. Stored at source resolution because the main pass
  /// drives its vertical blur in source UV space.
  ///
  /// One texture per command queue: Metal's automatic hazard tracking
  /// serialises the pre-pass write against the main pass's read on the
  /// same queue, but it does *not* order work across queues. Preview and
  /// photo paths run on independent queues, so each owns its own cached
  /// intermediate to avoid both a cross-queue data race and reallocation
  /// thrash when sizes alternate between the two paths.
  private func ensurePrePassTexture(
    width: Int, height: Int, isPhotoQueue: Bool
  ) -> MTLTexture? {
    prePassTextureLock.lock()
    defer { prePassTextureLock.unlock() }
    let cached = isPhotoQueue ? prePassTexturePhoto : prePassTexturePreview
    if let tex = cached, tex.width == width, tex.height == height {
      return tex
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .private
    let tex = device.makeTexture(descriptor: desc)
    tex?.label = isPhotoQueue ? "CameraOldCamPrePassPhoto" : "CameraOldCamPrePassPreview"
    if isPhotoQueue {
      prePassTexturePhoto = tex
    } else {
      prePassTexturePreview = tex
    }
    return tex
  }

  /// Encodes one aux-blur build: render `pipeline` into `resources.input`
  /// (sharing the pre-pass vertex, so the output spans the same uvScale crop
  /// the main pass samples), then the kind's MPS Gaussian into
  /// `resources.blurred`. Returns false if encoder creation fails.
  private func encodeAuxBlurPass(
    commandBuffer: MTLCommandBuffer,
    pipeline: MTLRenderPipelineState,
    resources: AuxBlurResources,
    sourceSet: SourceTextureSet,
    uniforms: CameraUniforms,
    label: String
  ) -> Bool {
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = resources.input
    descriptor.colorAttachments[0].loadAction = .dontCare
    descriptor.colorAttachments[0].storeAction = .store

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      NSLog("VideoFrameRenderer: \(label) encoder creation failed")
      return false
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(sourceSet.mtl0, slot: CameraShaderTextureSource)
    encoder.setFragmentTexture(sourceSet.chromaOrDummy, slot: CameraShaderTextureCbCr)
    // Only the vertex stage takes uniforms (it needs `uvScale` for the same
    // center-anchored crop as the pre-pass); the fragment stages of both aux
    // passes are uniform-free.
    var vertexUniforms = uniforms
    encoder.setVertexBytes(
      &vertexUniforms, length: MemoryLayout<CameraUniforms>.stride, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()

    resources.blur.encode(
      commandBuffer: commandBuffer,
      sourceTexture: resources.input,
      destinationTexture: resources.blurred)
    return true
  }

  /// Returns the working set for one aux-blur kind on one command queue when
  /// `active`, (re)creating it when the working size changes (the kernel's
  /// sigma is baked in at init). When inactive, counts idle frames and drops
  /// the set only after `auxBlurReleaseAfterOffFrames` — see the lifecycle
  /// comment on `auxBlurSlots`. In-flight command buffers retain any textures
  /// they reference until they complete, so dropping the last reference here
  /// is safe even right after a frame that used the set.
  private func auxBlurResources(
    _ kind: AuxBlurKind, active: Bool, width: Int, height: Int, isPhotoQueue: Bool
  ) -> AuxBlurResources? {
    let slot = auxBlurSlot(kind, isPhotoQueue: isPhotoQueue)
    guard active else {
      if slot.resources != nil {
        slot.offFrames += 1
        if slot.offFrames >= Self.auxBlurReleaseAfterOffFrames {
          slot.resources = nil
        }
      }
      return nil
    }
    slot.offFrames = 0

    if let cached = slot.resources,
      cached.input.width == width, cached.input.height == height {
      return cached
    }

    // Both textures are quarter-res `.private` in the kind's pixel format;
    // only the usage differs — `input` is rendered then read by MPS,
    // `blurred` is written by MPS then sampled by the main pass.
    func makeTexture(usage: MTLTextureUsage, label: String) -> MTLTexture? {
      let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: kind.pixelFormat, width: width, height: height, mipmapped: false)
      desc.usage = usage
      desc.storageMode = .private
      let tex = device.makeTexture(descriptor: desc)
      tex?.label = label
      return tex
    }
    let suffix = isPhotoQueue ? "Photo" : "Preview"
    guard
      let input = makeTexture(
        usage: [.renderTarget, .shaderRead], label: "\(kind.label)Input\(suffix)"),
      let blurred = makeTexture(
        usage: [.shaderRead, .shaderWrite], label: "\(kind.label)\(suffix)")
    else {
      return nil
    }

    let blur = MPSImageGaussianBlur(
      device: device, sigma: kind.sigma(width: width, height: height))
    blur.edgeMode = .clamp

    let resources = AuxBlurResources(input: input, blurred: blurred, blur: blur)
    slot.resources = resources
    return resources
  }

  /// Frees the photo queue's aux working sets. Called at the end of each
  /// `renderImage`: photos are one-shot and already block on the GPU, so
  /// per-photo realloc is noise next to a full-res render — while keeping the
  /// sets between captures would pin tens of MB of quarter-photo-res
  /// textures for an idle path. Must be called from the photo render thread
  /// (the slots' owning thread).
  private func releasePhotoAuxBlurResources() {
    for kind in AuxBlurKind.allCases {
      let slot = auxBlurSlot(kind, isPhotoQueue: true)
      slot.resources = nil
      slot.offFrames = 0
    }
  }

  // ---------------------------------------------------------------------------
  // MARK: - Pool management
  // ---------------------------------------------------------------------------

  /// Returns the (pool, auxAttrs) pair sized for the given dimensions,
  /// creating it on first use. Returns both atomically under the lock so
  /// callers never see a pool without its matching aux attributes.
  private func ensureRecordingPoolAndAuxAttrs(
    width: Int, height: Int
  ) -> (CVPixelBufferPool, CFDictionary)? {
    ensurePool(
      cachedPool: &recordingPool,
      cachedAux: &recordingPoolAuxAttributes,
      cachedWidth: &recordingPoolWidth,
      cachedHeight: &recordingPoolHeight,
      width: width, height: height,
      label: "recording")
  }

  /// Returns the (pool, auxAttrs) pair for intermediate scaled-render buffers
  /// used when `captureScale < 1` and upscaling is active. Same lock as the
  /// recording pool — both are invalidated together by `invalidateRecordingPool`.
  private func ensureScaledRenderPool(
    width: Int, height: Int
  ) -> (CVPixelBufferPool, CFDictionary)? {
    ensurePool(
      cachedPool: &scaledRenderPool,
      cachedAux: &scaledRenderPoolAuxAttributes,
      cachedWidth: &scaledRenderPoolWidth,
      cachedHeight: &scaledRenderPoolHeight,
      width: width, height: height,
      label: "scaled render")
  }

  /// Shared pool builder used by both `ensureRecordingPoolAndAuxAttrs` and
  /// `ensureScaledRenderPool`. The cache state for each pool lives on the
  /// renderer as four separate stored properties; this helper threads them
  /// in via `inout` so a single body covers both cases.
  ///
  /// The pool's own attrs stay clean (no allocation threshold key) — the cap
  /// goes in the *aux* dict passed to
  /// `CVPixelBufferPoolCreatePixelBufferWithAuxAttributes`. Putting the size
  /// keys in the pool attrs and the threshold in the aux dict avoids the
  /// CVReturn -6689 we used to hit when threshold was in the pool attrs.
  ///
  /// Both pools share `recordingPoolLock` so the recording and scaled-render
  /// pools can be invalidated together without races against
  /// `renderForRecording`.
  private func ensurePool(
    cachedPool: inout CVPixelBufferPool?,
    cachedAux: inout CFDictionary?,
    cachedWidth: inout Int,
    cachedHeight: inout Int,
    width: Int, height: Int,
    label: String
  ) -> (CVPixelBufferPool, CFDictionary)? {
    recordingPoolLock.lock()
    defer { recordingPoolLock.unlock() }
    if let pool = cachedPool,
      let auxAttrs = cachedAux,
      cachedWidth == width, cachedHeight == height
    {
      return (pool, auxAttrs)
    }

    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let poolAttrs: [String: Any] = [
      kCVPixelBufferPoolAllocationThresholdKey as String: VideoFrameRenderer.maxRecordingPoolBuffers
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let createdPool = pool else {
      NSLog("VideoFrameRenderer: \(label) pool creation failed: \(status)")
      return nil
    }
    let auxAttributes = poolAttrs as CFDictionary

    cachedPool = createdPool
    cachedAux = auxAttributes
    cachedWidth = width
    cachedHeight = height

    // Pre-allocate `minPoolBuffers` so the first frames of a session don't pay
    // for IOSurface allocation. At 4K each buffer is ~30 MB, so we prime
    // the lower bound rather than the full high-water cap.
    VideoFrameRenderer.primePool(
      createdPool,
      auxAttributes: auxAttributes,
      count: VideoFrameRenderer.minPoolBuffers)

    return (createdPool, auxAttributes)
  }

  /// Pre-allocates `count` destination buffers in the given pool so the first
  /// frames of a session don't pay for IOSurface allocation. The buffers are
  /// released as the local array goes out of scope, returning them to the
  /// pool ready for use.
  private static func primePool(
    _ pool: CVPixelBufferPool,
    auxAttributes: CFDictionary?,
    count: Int
  ) {
    var warm: [CVPixelBuffer] = []
    warm.reserveCapacity(count)
    for _ in 0..<count {
      var buffer: CVPixelBuffer?
      let status: CVReturn
      if let auxAttributes = auxAttributes {
        status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
          kCFAllocatorDefault, pool, auxAttributes, &buffer)
      } else {
        status = CVPixelBufferPoolCreatePixelBuffer(
          kCFAllocatorDefault, pool, &buffer)
      }
      guard status == kCVReturnSuccess, let buffer = buffer else { break }
      warm.append(buffer)
    }
    // `warm` deinits here, returning the buffers to the pool ready for use.
  }

  /// Drops cached IOSurface→texture mappings whose source buffers have been
  /// released. Called periodically — flushing every frame would discard
  /// mappings the next frame would reuse. Thread-safe; the preview and
  /// recording paths both increment the counter.
  private func flushTextureCacheIfNeeded() {
    uniformsLock.lock()
    framesSinceFlush += 1
    let shouldFlush = framesSinceFlush >= VideoFrameRenderer.flushEveryNFrames
    if shouldFlush { framesSinceFlush = 0 }
    uniformsLock.unlock()

    if shouldFlush {
      CVMetalTextureCacheFlush(textureCache, 0)
    }
  }

  // ---------------------------------------------------------------------------
  // MARK: - Image encoding
  // ---------------------------------------------------------------------------

  /// Encodes a BGRA `CVPixelBuffer` to JPEG or HEIF. Goes straight from the
  /// rendered IOSurface through `CIContext`'s Metal-backed encoder — no
  /// CGImage round-trip, no VRAM read-back, no extra heap allocation.
  /// EXIF / orientation metadata is merged into the output via CIImage
  /// properties.
  private func encode(
    pixelBuffer: CVPixelBuffer,
    destinationUTType: CFString,
    metadata: CFDictionary?
  ) -> Data? {
    return encode(
      ciImage: CIImage(cvPixelBuffer: pixelBuffer),
      destinationUTType: destinationUTType,
      metadata: metadata)
  }

  /// Encodes an arbitrary `CIImage` to JPEG or HEIF through the cached
  /// `CIContext`. Shared between the shader path (which feeds a rendered
  /// `CVPixelBuffer`) and the un-effected original path (which feeds a
  /// crop+Lanczos `CIImage` chain). EXIF / orientation metadata is merged
  /// into the output via CIImage properties.
  private func encode(
    ciImage: CIImage,
    destinationUTType: CFString,
    metadata: CFDictionary?
  ) -> Data? {
    var image = ciImage
    if var meta = metadata as? [String: Any], !meta.isEmpty {
      // Strip pixel-dimension keys that reflect the *original* sensor size
      // before crop/scale. Leaving them in causes EXIF to report wrong
      // dimensions for the saved file (e.g. 4032×3024 for a 16:9 crop).
      meta.removeValue(forKey: kCGImagePropertyPixelWidth as String)
      meta.removeValue(forKey: kCGImagePropertyPixelHeight as String)
      image = image.settingProperties(meta)
    }
    let colorSpace = VideoFrameRenderer.sRGBColorSpace

    if CFEqual(destinationUTType, "public.heic" as CFString)
      || CFEqual(destinationUTType, "public.heif" as CFString)
    {
      return ciContext.heifRepresentation(
        of: image, format: .BGRA8, colorSpace: colorSpace, options: [:])
    }
    return ciContext.jpegRepresentation(
      of: image, colorSpace: colorSpace, options: [:])
  }

  /// Wraps a `CGImage` as a BGRA `CVPixelBuffer`. Used by the
  /// `renderImageData(cgImage:…)` compatibility wrapper.
  private static func makePixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
    let width = cgImage.width
    let height = cgImage.height
    let attrs: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      attrs as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    // Use the same sRGB color space as the rest of the encode pipeline so the
    // CGImage-fallback path doesn't drift into the device-dependent DeviceRGB
    // space that the shader/encode passes never see.
    let bitmapInfo: UInt32 =
      CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(
      data: baseAddress, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
      space: VideoFrameRenderer.sRGBColorSpace, bitmapInfo: bitmapInfo)
    else {
      return nil
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixelBuffer
  }

  // ---------------------------------------------------------------------------
  // MARK: - Grain texture
  // ---------------------------------------------------------------------------

  /// Updates the grain tile size (0–1, resolution-independent).
  /// Safe to call from any thread.
  func updateGrainSize(_ size: Float) {
    grainTextureLock.lock()
    grainSize = size
    grainTextureLock.unlock()
  }

  /// Loads the grain texture from `path` on a background thread so the
  /// main thread and the preview pipeline are never blocked. If loading
  /// succeeds the existing texture is replaced and the animation timer
  /// (re)starts. On failure the previous texture is retained.
  ///
  /// Decoded textures are memoised in `grainTextureCache`, so re-selecting
  /// a previously-loaded grain image is O(1) and never touches the disk.
  /// On a cache miss the decode is dispatched to the serial `grainLoadQueue`
  /// (not the concurrent global queue) so two rapid switches to the same
  /// path can't stack up parallel decodes. A path that is already being
  /// decoded is deduped via `grainLoadInFlightPath`.
  func loadGrainTexture(path: String) {
    // Cache-hit fast path: switch to the already-decoded texture without
    // any disk IO, decode, or queue hop. Common when toggling between a
    // handful of grain images (or a single grain on/off).
    if let cached = VideoFrameRenderer.grainTextureCache.object(forKey: path as NSString) {
      grainTextureLock.lock()
      pendingGrainTexturePath = path
      grainTexture = cached.texture
      startGrainAnimationLocked()
      grainTextureLock.unlock()
      return
    }

    grainTextureLock.lock()
    pendingGrainTexturePath = path
    if grainLoadInFlightPath == path {
      // A load for this exact path is already running on `grainLoadQueue`;
      // let it complete instead of dispatching a redundant decode.
      grainTextureLock.unlock()
      return
    }
    grainLoadInFlightPath = path
    grainTextureLock.unlock()

    VideoFrameRenderer.grainLoadQueue.async { [weak self] in
      guard let self = self else { return }
      defer {
        // Always clear the in-flight marker for this path on the way out so
        // a subsequent `loadGrainTexture(path)` after we return can dispatch
        // again (e.g. on a cache miss).
        self.grainTextureLock.lock()
        if self.grainLoadInFlightPath == path {
          self.grainLoadInFlightPath = nil
        }
        self.grainTextureLock.unlock()
      }

      // Bail early if a newer load/clear superseded us before we got the
      // queue slot — saves the decode + upload work entirely.
      self.grainTextureLock.lock()
      let stillCurrent = self.pendingGrainTexturePath == path
      self.grainTextureLock.unlock()
      if !stillCurrent { return }

      // Re-check the cache under the serial queue: a concurrent load for
      // the same path (cache-hit fast path of a later call) may have just
      // populated it while we were waiting.
      if let cached = VideoFrameRenderer.grainTextureCache.object(forKey: path as NSString) {
        self.grainTextureLock.lock()
        if self.pendingGrainTexturePath == path {
          self.grainTexture = cached.texture
          self.startGrainAnimationLocked()
        }
        self.grainTextureLock.unlock()
        return
      }

      // Step 1: decode via ImageIO so we get detailed status and support
      // every PNG variant (grayscale, indexed, 16-bit, etc.) that
      // MTKTextureLoader rejects with the opaque "Image decoding failed"
      // error.
      let cfURL = URL(fileURLWithPath: path) as CFURL
      guard let source = CGImageSourceCreateWithURL(cfURL, nil) else {
        NSLog("VideoFrameRenderer: cannot open grain image at '\(path)'")
        return
      }
      let sourceStatus = CGImageSourceGetStatus(source)
      guard sourceStatus == .statusComplete else {
        let typeHint = (CGImageSourceGetType(source) as String?) ?? "unknown"
        NSLog(
          "VideoFrameRenderer: grain image source is not complete at '\(path)'"
            + " (CGImageSourceStatus=\(sourceStatus.rawValue), type=\(typeHint))")
        return
      }
      guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        let typeHint = (CGImageSourceGetType(source) as String?) ?? "unknown"
        NSLog(
          "VideoFrameRenderer: failed to decode grain CGImage at '\(path)'"
            + " (type=\(typeHint), frames=\(CGImageSourceGetCount(source)))")
        return
      }
      let width = cgImage.width
      let height = cgImage.height
      guard width > 0, height > 0 else {
        NSLog(
          "VideoFrameRenderer: grain image has zero dimensions"
            + " (\(width)×\(height)) at '\(path)'")
        return
      }

      // Step 2: normalise to RGBA8 by drawing into a CGBitmapContext. The
      // backing buffer is allocated without zero-init; `.copy` blend mode
      // makes `CGContext.draw` overwrite every output byte unconditionally
      // (the default `.normal` mode would composite source-over and leak
      // uninitialized memory through any transparent pixels in the source).
      let bytesPerRow = width * 4
      let totalBytes = height * bytesPerRow
      let pixelData = UnsafeMutableRawPointer.allocate(
        byteCount: totalBytes, alignment: 1)
      defer { pixelData.deallocate() }

      guard let ctx = CGContext(
        data: pixelData,
        width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else {
        NSLog(
          "VideoFrameRenderer: failed to create CGContext for grain texture at"
            + " '\(path)' (size \(width)×\(height))")
        return
      }
      ctx.setBlendMode(.copy)
      ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

      // Step 3: upload to a Metal texture as RGBA8Unorm (linear).
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: width, height: height, mipmapped: false)
      descriptor.usage = .shaderRead
      descriptor.storageMode = .shared
      guard let texture = self.device.makeTexture(descriptor: descriptor) else {
        NSLog(
          "VideoFrameRenderer: failed to create Metal texture for grain at"
            + " '\(path)' (size \(width)×\(height))")
        return
      }
      texture.replace(
        region: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0,
        withBytes: pixelData,
        bytesPerRow: bytesPerRow)

      // Cost estimate (in bytes) lets NSCache make sensible eviction
      // decisions under memory pressure: rgba8Unorm = 4 B/texel.
      let costBytes = width * height * 4
      VideoFrameRenderer.grainTextureCache.setObject(
        GrainTextureBox(texture), forKey: path as NSString, cost: costBytes)

      // Activate the texture + start the animation timer atomically under
      // grainTextureLock. Holding the lock across the timer swap closes the
      // race that previously leaked timers when two completions (or a
      // completion + clearGrainTexture) ran concurrently.
      self.grainTextureLock.lock()
      if self.pendingGrainTexturePath == path {
        self.grainTexture = texture
        self.startGrainAnimationLocked()
      }
      self.grainTextureLock.unlock()
    }
  }

  /// Removes the grain texture and stops the animation timer. The grain
  /// effect disappears on the next rendered frame.
  ///
  /// `pendingGrainTexturePath` is nilled (symmetric with `clearLutTexture`)
  /// so any in-flight load on `grainLoadQueue` bails at its
  /// `pendingGrainTexturePath == path` check instead of resurrecting the
  /// texture and starting an unwanted animation timer.
  func clearGrainTexture() {
    updateUniforms { $0.grainOpacity = 0 }
    grainTextureLock.lock()
    pendingGrainTexturePath = nil
    grainTexture = nil
    stopGrainAnimationLocked()
    grainTextureLock.unlock()
  }

  /// Cancels the grain animation timer without dropping the grain texture.
  /// For renderers that will never render again but may briefly outlive
  /// their last frame — parked in `previousVideoFrameRenderer` awaiting
  /// texture adoption, or retained by an in-flight photo delegate across
  /// `close()` — so the 24-fps timer doesn't keep firing for the rest of
  /// that lifetime. A later `loadGrainTexture` / `adoptTextures` restarts
  /// the timer.
  func stopGrainAnimation() {
    grainTextureLock.lock()
    stopGrainAnimationLocked()
    grainTextureLock.unlock()
  }

  /// Starts (or restarts) the 24-fps timer that randomises `grainOffset`.
  /// Caller must hold `grainTextureLock`. Holding the lock across the
  /// cancel/recreate keeps a concurrent stop or another start from leaking
  /// a timer reference (the previous unlocked version would race two
  /// `grainAnimationTimer = timer` stores and orphan one of the timers).
  private func startGrainAnimationLocked() {
    grainAnimationTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: grainTimerQueue)
    // Fire at 24 fps; 5 ms leeway keeps CPU wake-ups cheap.
    timer.schedule(deadline: .now(), repeating: 1.0 / 24.0, leeway: .milliseconds(5))
    timer.setEventHandler { [weak self] in
      self?.updateUniforms {
        $0.grainOffset = SIMD2<Float>(Float.random(in: 0..<1), Float.random(in: 0..<1))
      }
    }
    grainAnimationTimer = timer
    timer.resume()
  }

  /// Cancels the animation timer. Caller must hold `grainTextureLock`.
  private func stopGrainAnimationLocked() {
    grainAnimationTimer?.cancel()
    grainAnimationTimer = nil
  }

  // ---------------------------------------------------------------------------
  // MARK: - LUT texture
  // ---------------------------------------------------------------------------

  /// Loads the LUT texture from a 512×512 PNG atlas at `path` on a
  /// background queue. The decoded `MTLTexture` is memoised in a class-level
  /// `NSCache` keyed by path — re-selecting a previously-loaded LUT is
  /// O(1) and never touches the disk or the decoder. On a cache miss the
  /// file is decoded on the CPU, then uploaded as a 512×512 `.rgba8Unorm`
  /// 2D texture. Stale-path callbacks (a newer `loadLutTexture` or
  /// `clearLutTexture` issued before this completion) are discarded.
  func loadLutTexture(path: String) {
    // Cache-hit fast path: switch to the already-decoded texture without
    // any disk IO, decoding, or queue hop. Common when toggling between a
    // handful of LUTs.
    if let cached = VideoFrameRenderer.lutTextureCache.object(forKey: path as NSString) {
      lutTextureLock.lock()
      pendingLutTexturePath = path
      lutTexture = cached.texture
      lutTextureLock.unlock()
      return
    }

    lutTextureLock.lock()
    pendingLutTexturePath = path
    if lutLoadInFlightPath == path {
      // A decode for this exact path is already running on `lutLoadQueue`;
      // let it complete instead of dispatching a redundant decode.
      lutTextureLock.unlock()
      return
    }
    lutLoadInFlightPath = path
    lutTextureLock.unlock()

    VideoFrameRenderer.lutLoadQueue.async { [weak self] in
      guard let self = self else { return }
      defer {
        // Always clear the in-flight marker for this path on the way out so
        // a subsequent `loadLutTexture(path)` after we return can dispatch
        // again (e.g. on a cache miss).
        self.lutTextureLock.lock()
        if self.lutLoadInFlightPath == path {
          self.lutLoadInFlightPath = nil
        }
        self.lutTextureLock.unlock()
      }

      // Re-check the cache under the serial queue: a concurrent load for
      // the same path may have just populated it while we were waiting.
      if let cached = VideoFrameRenderer.lutTextureCache.object(forKey: path as NSString) {
        self.lutTextureLock.lock()
        if self.pendingLutTexturePath == path {
          self.lutTexture = cached.texture
        }
        self.lutTextureLock.unlock()
        return
      }

      // Bail early if a newer load/clear superseded us before we even
      // started decoding — saves the decode work entirely.
      self.lutTextureLock.lock()
      let stillCurrent = self.pendingLutTexturePath == path
      self.lutTextureLock.unlock()
      if !stillCurrent { return }

      let pixels: [UInt8]
      do {
        pixels = try VideoFrameRenderer.decodeLutPng(path: path)
      } catch {
        NSLog("VideoFrameRenderer: failed to load LUT PNG — \(error)")
        return
      }
      let side = VideoFrameRenderer.lutImageDimension
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,  // not `_srgb`: the shader decodes sRGB explicitly
        width: side, height: side, mipmapped: false)
      descriptor.usage = .shaderRead
      descriptor.storageMode = .shared
      guard let texture = self.device.makeTexture(descriptor: descriptor) else {
        NSLog("VideoFrameRenderer: failed to create LUT texture (\(side)×\(side))")
        return
      }
      pixels.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        texture.replace(
          region: MTLRegionMake2D(0, 0, side, side),
          mipmapLevel: 0,
          withBytes: base,
          bytesPerRow: side * 4)
      }

      // Cost estimate (in bytes) lets NSCache make sensible eviction
      // decisions under memory pressure: rgba8Unorm = 4 B/texel (1 MiB/LUT).
      let costBytes = side * side * 4
      VideoFrameRenderer.lutTextureCache.setObject(
        LutTextureBox(texture), forKey: path as NSString, cost: costBytes)

      self.lutTextureLock.lock()
      if self.pendingLutTexturePath == path {
        self.lutTexture = texture
      }
      self.lutTextureLock.unlock()
    }
  }

  /// Removes the LUT texture. The LUT effect disappears on the next rendered
  /// frame; `lutIntensity` is zeroed so the shader's early-out skips sampling
  /// the unbound texture slot.
  func clearLutTexture() {
    updateUniforms { $0.lutIntensity = 0 }
    lutTextureLock.lock()
    pendingLutTexturePath = nil
    lutTexture = nil
    lutTextureLock.unlock()
  }

  /// The required width and height, in pixels, of a LUT PNG atlas
  /// (an 8×8 grid of 64×64 tiles = one 64×64×64 colour cube).
  static let lutImageDimension = 512

  /// Errors that `decodeLutPng` can throw, each carrying enough context to
  /// understand exactly why the file was rejected.
  enum LutPngError: Error, CustomStringConvertible {
    case cannotOpenFile(path: String)
    case imageSourceIncomplete(path: String, status: Int32, typeHint: String)
    case cannotDecodeImage(path: String, typeHint: String)
    case wrongDimensions(path: String, width: Int, height: Int)
    case cannotCreateContext(path: String)

    var description: String {
      switch self {
      case .cannotOpenFile(let path):
        return "Cannot open LUT image at '\(path)'"
      case .imageSourceIncomplete(let path, let status, let typeHint):
        return "LUT image source is not complete at '\(path)'"
          + " (CGImageSourceStatus=\(status), type=\(typeHint))"
      case .cannotDecodeImage(let path, let typeHint):
        return "Failed to decode LUT image at '\(path)' (type=\(typeHint))"
      case .wrongDimensions(let path, let width, let height):
        return "LUT image at '\(path)' is \(width)×\(height); expected exactly "
          + "\(VideoFrameRenderer.lutImageDimension)×\(VideoFrameRenderer.lutImageDimension)"
          + " (an 8×8 grid of 64×64 tiles)"
      case .cannotCreateContext(let path):
        return "Failed to create CGContext while decoding LUT image at '\(path)'"
      }
    }
  }

  /// Decodes a 512×512 PNG LUT atlas at `path` into tightly-packed RGBA8
  /// bytes (512 × 512 × 4, row 0 = image top row, sRGB-encoded values).
  ///
  /// The atlas layout is an 8×8 row-major grid (left→right, top→bottom) of
  /// 64×64 tiles: within a tile x = red and y = green (top to bottom); the
  /// tile index is the blue slice. `CGContext.draw` renders the image
  /// upright, so buffer row 0 is the PNG's top row — the same orientation
  /// the shader samples at v = 0, no flip needed.
  static func decodeLutPng(path: String) throws -> [UInt8] {
    let cfURL = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(cfURL, nil) else {
      throw LutPngError.cannotOpenFile(path: path)
    }
    let sourceStatus = CGImageSourceGetStatus(source)
    guard sourceStatus == .statusComplete else {
      throw LutPngError.imageSourceIncomplete(
        path: path, status: sourceStatus.rawValue,
        typeHint: (CGImageSourceGetType(source) as String?) ?? "unknown")
    }
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw LutPngError.cannotDecodeImage(
        path: path,
        typeHint: (CGImageSourceGetType(source) as String?) ?? "unknown")
    }
    let side = lutImageDimension
    guard cgImage.width == side, cgImage.height == side else {
      throw LutPngError.wrongDimensions(
        path: path, width: cgImage.width, height: cgImage.height)
    }

    // A LUT atlas is *data*, not imagery: a Display-P3 / ICC-tagged export
    // must pass through byte-identical, so re-tag (not convert) RGB sources
    // to the destination colorspace before drawing. Non-RGB models
    // (grayscale, indexed) fall through to a normal converting draw.
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var drawImage = cgImage
    if cgImage.colorSpace?.model == .rgb,
      let retagged = cgImage.copy(colorSpace: colorSpace)
    {
      drawImage = retagged
    }

    // RGBX (`noneSkipLast`) so alpha premultiplication can never touch the
    // colour bytes — LUT PNGs are opaque by contract, and a stray alpha
    // channel is flattened instead of darkening RGB. `.copy` blend mode
    // makes `CGContext.draw` overwrite every output byte unconditionally.
    let bytesPerRow = side * 4
    var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let ctx = CGContext(
          data: buffer.baseAddress,
          width: side, height: side,
          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      ctx.setBlendMode(.copy)
      ctx.draw(drawImage, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { throw LutPngError.cannotCreateContext(path: path) }
    return pixels
  }

  // ---------------------------------------------------------------------------
  // MARK: - Texture adoption
  // ---------------------------------------------------------------------------

  /// Synchronously copies the already-decoded LUT and grain textures from
  /// `other` into this renderer. Used when the renderer is rebuilt for an
  /// aspect-ratio change so the live preview keeps applying the same LUT /
  /// grain on its very first frame, instead of flashing un-filtered while
  /// the async `loadLutTexture` / `loadGrainTexture` callbacks decode the
  /// files again. The Metal textures are dimension-independent GPU objects,
  /// so reusing them across renderers is safe.
  func adoptTextures(from other: VideoFrameRenderer) {
    other.lutTextureLock.lock()
    let lutTex = other.lutTexture
    let lutPath = other.pendingLutTexturePath
    other.lutTextureLock.unlock()
    if lutTex != nil {
      lutTextureLock.lock()
      lutTexture = lutTex
      pendingLutTexturePath = lutPath
      lutTextureLock.unlock()
    }

    other.grainTextureLock.lock()
    let grainTex = other.grainTexture
    let grainPath = other.pendingGrainTexturePath
    let grainSz = other.grainSize
    other.grainTextureLock.unlock()
    if grainTex != nil {
      grainTextureLock.lock()
      grainTexture = grainTex
      pendingGrainTexturePath = grainPath
      grainSize = grainSz
      startGrainAnimationLocked()
      grainTextureLock.unlock()
    }
  }
}

