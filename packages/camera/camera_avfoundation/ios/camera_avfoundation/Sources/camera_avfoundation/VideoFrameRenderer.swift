// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Metal

// Mirror of the CameraUniforms struct in CameraShader.metal.
// Keep both in sync when adding new fields.
struct CameraUniforms {
  var vignetteIntensity: Float = 0
  // Center-anchored UV transform: shrink (uvScale < 1) to crop the sampled
  // sub-rect of the source. Default is identity (no crop).
  var uvScale: SIMD2<Float> = SIMD2<Float>(1, 1)
  // Inner-rect "capture scale" applied on top of the aspect-ratio crop.
  // 1.0 = no extra narrowing. Capture passes use this to shrink the sampled
  // area; preview passes use it together with `darkenOutside` to draw the
  // full crop with the area outside the scaled rect dimmed.
  var captureScale: Float = 1.0
  // 0.0 = no darkening (capture passes); ~0.4 = dim the area outside the
  // scaled rect (preview passes).
  var darkenOutside: Float = 0.0
  // Aspect ratio (width / height) of the rendered output in pixels. Passed
  // to applyVignette so that the circular distance calculation is compensated
  // for non-square outputs. Set once at init time from the renderer's fixed
  // output dimensions.
  var outputAspect: Float = 1.0
}

/// Source pixel format the renderer can ingest.
enum CameraSourceFormat {
  case bgra
  case yuvFullRange    // 420f
  case yuvVideoRange   // 420v

  init?(pixelFormat: OSType) {
    switch pixelFormat {
    case kCVPixelFormatType_32BGRA:
      self = .bgra
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      self = .yuvFullRange
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
      self = .yuvVideoRange
    default:
      return nil
    }
  }
}

final class VideoFrameRenderer {
  // Sized for: 2 in-flight on GPU + 1 in preview texture + 3 in AVAssetWriter
  // + 2 headroom = 8.
  private static let maxPoolBuffers = 8

  // Hard cap on the recording pool. Under a stalled AVAssetWriter the pool
  // can otherwise grow without bound — at 4K each buffer is ~30 MB, so a
  // dozen stalled frames would consume ~360 MB. Cap matches maxPoolBuffers.
  private static let maxRecordingPoolBuffers = 8

  // Eagerly keep this many destination buffers warm so the first second of
  // recording doesn't spike on alloc. Real working set is ~4–5.
  private static let minPoolBuffers = 4

  // Number of GPU render operations that may be queued at once on the
  // preview path. 3 lets the pipeline keep one frame queued while the next
  // is submitted and a third is being captured — enough headroom that a
  // brief GPU hiccup doesn't force the preview to drop a frame.
  private static let maxInFlightPreviewFrames = 3
  // Independent budget for the recording path. Preview and recording run
  // from the same sample-buffer callback, so a shared semaphore can starve
  // the preview when the recording path is busy — and vice-versa. Keeping
  // them independent means a stalled encoder cannot drop preview frames,
  // and a slow preview render cannot stall recording.
  private static let maxInFlightRecordingFrames = 3

  // Darkening multiplier applied outside the captureScale rectangle in
  // preview-only renders. Capture passes (photo, recording) bypass darkening
  // to keep saved files clean. Hardcoded — no API knob today.
  // Outside pixels are multiplied by `(1 - previewDarkenOutside)`, so 0.7
  // means the dimmed area renders at 30% brightness — visibly darker than
  // a casual gradient but still legible for framing.
  static let previewDarkenOutside: Float = 0.7

  /// Rounds `v` to the nearest even pixel value, with a floor of 2.
  /// H.264/HEVC encoders refuse odd dimensions on most configurations.
  static func evenRound(_ v: Float) -> Int {
    let r = Int(v.rounded())
    return max(2, r - (r % 2))
  }

  // Heavy Metal setup is cached across renderers so that recreating one
  // (e.g. on pixel-format change) is essentially free.
  private struct MetalSetup {
    let device: MTLDevice
    let previewCommandQueue: MTLCommandQueue
    let photoCommandQueue: MTLCommandQueue
    let bgraPipelineState: MTLRenderPipelineState
    let yuvFullRangePipelineState: MTLRenderPipelineState
    let yuvVideoRangePipelineState: MTLRenderPipelineState
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
    photoQueue.label = "io.flutter.camera.photoMetalQueue"
    previewQueue.label = "io.flutter.camera.previewMetalQueue"

    // Load the pre-compiled Metal library from the plugin bundle.
    // SPM places it in the module framework bundle; CocoaPods drops it into
    // the app's default metallib.
    let library: MTLLibrary
    let pluginBundle = Bundle(for: VideoFrameRenderer.self)
    if let url = pluginBundle.url(forResource: "default", withExtension: "metallib"),
      let lib = try? device.makeLibrary(URL: url)
    {
      library = lib
    } else if let defaultLib = device.makeDefaultLibrary() {
      library = defaultLib
    } else {
      NSLog("VideoFrameRenderer: Metal library not found in bundle or default library")
      return nil
    }

    guard let vertexFunction = library.makeFunction(name: "camera_vertex"),
      let bgraFragment = library.makeFunction(name: "camera_fragment"),
      let yuvFullFragment = library.makeFunction(name: "camera_fragment_yuv_full"),
      let yuvVideoFragment = library.makeFunction(name: "camera_fragment_yuv_video")
    else {
      NSLog("VideoFrameRenderer: shader functions not found in library")
      return nil
    }

    func makePipeline(_ fragment: MTLFunction, label: String) -> MTLRenderPipelineState? {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.label = label
      descriptor.vertexFunction = vertexFunction
      descriptor.fragmentFunction = fragment
      // sRGB-encoded write so the vignette/blend math happens in linear light
      // and the destination IOSurface ends up display-ready.
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
      do {
        return try device.makeRenderPipelineState(descriptor: descriptor)
      } catch {
        NSLog("VideoFrameRenderer: pipeline state creation failed for \(label): \(error)")
        return nil
      }
    }

    guard let bgraPipeline = makePipeline(bgraFragment, label: "camera_bgra"),
      let yuvFullPipeline = makePipeline(yuvFullFragment, label: "camera_yuv_full"),
      let yuvVideoPipeline = makePipeline(yuvVideoFragment, label: "camera_yuv_video")
    else {
      return nil
    }

    let setup = MetalSetup(
      device: device,
      previewCommandQueue: previewQueue,
      photoCommandQueue: photoQueue,
      bgraPipelineState: bgraPipeline,
      yuvFullRangePipelineState: yuvFullPipeline,
      yuvVideoRangePipelineState: yuvVideoPipeline)
    cachedSetup = setup
    return setup
  }

  /// Eagerly compile the Metal pipelines so the first sample-buffer callback
  /// doesn't pay for it. Safe to call repeatedly; subsequent calls are no-ops.
  static func warmUp() {
    _ = sharedSetup()
  }

  private let device: MTLDevice
  private let previewCommandQueue: MTLCommandQueue
  private let photoCommandQueue: MTLCommandQueue
  private let bgraPipelineState: MTLRenderPipelineState
  private let yuvFullRangePipelineState: MTLRenderPipelineState
  private let yuvVideoRangePipelineState: MTLRenderPipelineState
  private let textureCache: CVMetalTextureCache
  private let pool: CVPixelBufferPool
  private let poolAuxAttributes: CFDictionary
  private let width: Int
  private let height: Int
  /// Target aspect ratio (width/height). `nil` means "no crop" (use source
  /// dimensions). Used by `renderImage` to compute photo crops from the
  /// *photo's* dimensions, since photo and video sample buffers often have
  /// different aspect ratios on iOS.
  private let targetRatio: Double?
  /// Tracked source dimensions. The vertex-stage uvScale uniform was computed
  /// against these; if the source size changes (camera switch during
  /// recording, where we keep the renderer because the AssetWriter is locked
  /// to its output dims), `updateSourceDimensions` recomputes the uvScale so
  /// the saved video keeps the requested aspect ratio.
  private(set) var sourceWidth: Int
  private(set) var sourceHeight: Int
  /// Tracked source pixel format. Used by DefaultCamera to detect a format
  /// change (e.g. 420v → 420f across a camera switch) so it can rebuild the
  /// renderer when not recording, or at minimum track the change for
  /// diagnostic purposes when recording.
  private(set) var sourcePixelFormat: OSType

  /// Cached CIContext for HEIF/JPEG encoding on the photo path.
  /// CIContext is thread-safe and amortizes a lot of GPU setup.
  private lazy var ciContext: CIContext = {
    return CIContext(mtlDevice: device, options: [
      .cacheIntermediates: false,
      .priorityRequestLow: true,
    ])
  }()

  private var uniforms = CameraUniforms()
  private let uniformsLock = NSLock()

  /// Limits how many command buffers can be queued on the preview GPU
  /// simultaneously. When all slots are taken `render(blocking: false)`
  /// returns nil and the caller drops the frame for the preview.
  private let previewInFlightSemaphore: DispatchSemaphore
  /// Limits how many command buffers can be queued for the recording path.
  /// Separate from the preview semaphore so the two pipelines cannot starve
  /// each other — at peak the renderer can have `maxInFlightPreviewFrames +
  /// maxInFlightRecordingFrames` operations queued on the GPU.
  private let recordingInFlightSemaphore: DispatchSemaphore

  /// Counter used to amortize `CVMetalTextureCacheFlush` across many frames.
  /// Flushing every frame discards IOSurface→texture mappings the next
  /// frame would otherwise reuse; flushing periodically is enough to keep
  /// stale entries from accumulating after resolution changes.
  private var framesSinceFlush: Int = 0
  private static let flushEveryNFrames: Int = 60

  /// Lazily-built second pool sized to the *captureScale*-narrowed
  /// dimensions. Used by the recording path so the AVAssetWriter receives
  /// a buffer that already excludes the darkened preview border.
  private var recordingPool: CVPixelBufferPool?
  private var recordingPoolWidth: Int = 0
  private var recordingPoolHeight: Int = 0
  /// Aux attributes for recording-pool allocations. Contains the high-water
  /// threshold so a stalled writer cannot grow the pool without bound.
  private var recordingPoolAuxAttributes: CFDictionary?
  private let recordingPoolLock = NSLock()

  var outputWidth: Int { width }
  var outputHeight: Int { height }

  init?(
    width: Int, height: Int, targetRatio: Double? = nil,
    sourceWidth: Int = 0, sourceHeight: Int = 0,
    sourcePixelFormat: OSType = 0
  ) {
    guard width > 0, height > 0 else {
      NSLog("VideoFrameRenderer: invalid dimensions \(width)x\(height)")
      return nil
    }
    guard let setup = VideoFrameRenderer.sharedSetup() else {
      return nil
    }

    var cache: CVMetalTextureCache?
    let cacheStatus = CVMetalTextureCacheCreate(
      kCFAllocatorDefault, nil, setup.device, nil, &cache)
    guard cacheStatus == kCVReturnSuccess, let textureCache = cache else {
      NSLog("VideoFrameRenderer: texture cache creation failed: \(cacheStatus)")
      return nil
    }

    let poolAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
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
    self.bgraPipelineState = setup.bgraPipelineState
    self.yuvFullRangePipelineState = setup.yuvFullRangePipelineState
    self.yuvVideoRangePipelineState = setup.yuvVideoRangePipelineState
    self.textureCache = textureCache
    self.pool = createdPool
    self.poolAuxAttributes = [
      kCVPixelBufferPoolAllocationThresholdKey as String: VideoFrameRenderer.maxPoolBuffers
    ] as CFDictionary
    self.width = width
    self.height = height
    // Bake the output aspect ratio into the default uniforms so applyVignette
    // can compensate the circular distance calculation for non-square outputs.
    uniforms.outputAspect = height > 0 ? Float(width) / Float(height) : 1.0
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

    NSLog("VideoFrameRenderer: ready at \(width)x\(height)")
  }

  /// Recomputes the uvScale uniform for a new source size while keeping the
  /// renderer's output dimensions fixed. Used when the source dimensions
  /// change under us (e.g. `setDescriptionWhileRecording` switches sensors)
  /// and we have to keep the renderer because the AVAssetWriter is locked to
  /// its current output size. Without this the cached uvScale would still
  /// reflect the *previous* source's ratio and the saved video would have a
  /// drifted aspect.
  ///
  /// Recomputes uvScale to center-crop the new source to the renderer's
  /// *output ratio* (not the original source's pixel count). The result is
  /// always a valid center-crop of the new source matching the locked output
  /// aspect — rather than literally `output / newSource`, which could under-
  /// crop and leave the renderer's output filled by a smaller-than-needed
  /// region of the source.
  func updateSourceDimensions(width: Int, height: Int) {
    guard width > 0, height > 0 else { return }
    sourceWidth = width
    sourceHeight = height
    let outputRatio = Double(self.width) / Double(self.height)
    let sourceRatio = Double(width) / Double(height)
    let uvScaleX: Float
    let uvScaleY: Float
    if outputRatio > sourceRatio {
      // Output is wider than new source — sample full width, crop top/bottom.
      uvScaleX = 1.0
      uvScaleY = Float(sourceRatio / outputRatio)
    } else if outputRatio < sourceRatio {
      // Output is taller — sample full height, crop left/right.
      uvScaleX = Float(outputRatio / sourceRatio)
      uvScaleY = 1.0
    } else {
      uvScaleX = 1.0
      uvScaleY = 1.0
    }
    updateUniforms { $0.uvScale = SIMD2<Float>(uvScaleX, uvScaleY) }
  }

  /// Records that the source pixel format changed (e.g. after a camera
  /// switch during recording). `submitRender` already selects the correct
  /// fragment pipeline per-frame from the buffer's actual format; this just
  /// keeps `sourcePixelFormat` in sync so callers can detect the change.
  func updateSourcePixelFormat(_ format: OSType) {
    sourcePixelFormat = format
  }

  /// Update shader uniforms. Thread-safe; values are snapshotted into each
  /// command buffer at submit time so an in-flight frame never sees a torn
  /// write.
  func updateUniforms(_ update: (inout CameraUniforms) -> Void) {
    uniformsLock.lock()
    update(&uniforms)
    uniformsLock.unlock()
  }

  private func snapshotUniforms() -> CameraUniforms {
    uniformsLock.lock()
    defer { uniformsLock.unlock() }
    return uniforms
  }

  /// Returns true if `source`'s pixel format is one the shader can ingest.
  static func canHandle(pixelFormat: OSType) -> Bool {
    return CameraSourceFormat(pixelFormat: pixelFormat) != nil
  }

  /// Returns true when no shader work is needed for the preview path:
  /// uniforms are identity, no aspect-ratio crop, no recording (which
  /// always needs the rendered buffer for AVAssetWriter), and source is
  /// already BGRA at the renderer's output dimensions. The caller can
  /// publish the source buffer directly to the Flutter texture, saving a
  /// full-frame GPU pass per frame.
  func canBypassPreview(
    sourcePixelFormat: OSType,
    sourceWidth: Int,
    sourceHeight: Int
  ) -> Bool {
    guard sourcePixelFormat == kCVPixelFormatType_32BGRA else { return false }
    guard sourceWidth == width, sourceHeight == height else { return false }
    let snapshot = snapshotUniforms()
    return snapshot.vignetteIntensity == 0
      && snapshot.captureScale >= 1.0
      && snapshot.uvScale.x >= 1.0 && snapshot.uvScale.y >= 1.0
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
      // Target is wider than source — crop top/bottom.
      outHeight = evenRound(Float((Double(sourceWidth) / targetRatio)))
    } else if targetRatio < sourceRatio {
      // Target is taller — crop left/right.
      outWidth = evenRound(Float((Double(sourceHeight) * targetRatio)))
    } else {
      outWidth = evenRound(Float(outWidth))
      outHeight = evenRound(Float(outHeight))
    }

    let uvScaleX = Float(outWidth) / Float(sourceWidth)
    let uvScaleY = Float(outHeight) / Float(sourceHeight)
    return (outWidth, outHeight, SIMD2<Float>(uvScaleX, uvScaleY))
  }

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
        destWidth: width, destHeight: height,
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

    // Photos and the video preview can arrive at different aspect ratios on
    // iOS (12MP 4:3 photo vs 16:9 video preview). Recompute the crop fresh
    // from the photo's own dimensions and the stored target ratio so the
    // saved file actually matches the requested aspect ratio.
    //
    // Why the ratio is inverted here: `targetRatio` is the user-facing
    // *display* aspect (width/height in portrait, e.g. 0.8 for 4:5). Video
    // sample buffers arrive already rotated to portrait by the connection's
    // videoOrientation, so the preview path can use it as-is. Photo sample
    // buffers, however, are delivered in *sensor* (landscape) orientation
    // regardless of videoOrientation — the rotation hint is carried by EXIF
    // metadata that viewers apply at display time. Crop math here therefore
    // needs the sensor-space ratio, which is the reciprocal of the display
    // ratio.
    let sensorTargetRatio = targetRatio.map { $0 > 0 ? 1.0 / $0 : $0 }
    let crop = VideoFrameRenderer.croppedDimensions(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      targetRatio: sensorTargetRatio)

    // Apply capture scale: shrink the destination dims while keeping the
    // aspect ratio. The shader narrows the sampled UV by the same factor.
    let captureScale = snapshotUniforms().captureScale
    let scaledWidth = VideoFrameRenderer.evenRound(Float(crop.width) * captureScale)
    let scaledHeight = VideoFrameRenderer.evenRound(Float(crop.height) * captureScale)

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
          darkenOutside: 0.0))
    else {
      return nil
    }

    let waitSem = DispatchSemaphore(value: 0)
    commandBuffer.addCompletedHandler { _ in waitSem.signal() }
    commandBuffer.commit()
    waitSem.wait()
    // Photo is one-shot: the source IOSurface won't be reused, so force a
    // flush to release the cache entry immediately rather than waiting for
    // the periodic preview-path flush.
    CVMetalTextureCacheFlush(textureCache, 0)
    return dest
  }

  /// Output dimensions of buffers produced by `renderForRecording(_:)` for
  /// the current `captureScale`. Used by `DefaultCamera` to configure the
  /// AVAssetWriter so encoded video matches the saved-file dimensions.
  var recordingOutputWidth: Int {
    return VideoFrameRenderer.evenRound(Float(width) * snapshotUniforms().captureScale)
  }
  var recordingOutputHeight: Int {
    return VideoFrameRenderer.evenRound(Float(height) * snapshotUniforms().captureScale)
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
  }

  /// Renders into a pooled buffer at the *captureScale*-narrowed dimensions
  /// with no darkening — for AVAssetWriter input during recording. Blocks
  /// on the in-flight semaphore (recording must not drop frames).
  ///
  /// When `captureScale == 1.0` the output matches the preview pool and we
  /// could in principle reuse it, but to keep the recording path simple and
  /// independent of preview lifecycle we always render through this path
  /// while recording.
  func renderForRecording(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let snapshot = snapshotUniforms()
    let scaledW = VideoFrameRenderer.evenRound(Float(width) * snapshot.captureScale)
    let scaledH = VideoFrameRenderer.evenRound(Float(height) * snapshot.captureScale)

    let poolAndAttrs = ensureRecordingPoolAndAuxAttrs(width: scaledW, height: scaledH)
    guard let (recordingPool, auxAttrs) = poolAndAttrs else {
      return nil
    }

    recordingInFlightSemaphore.wait()

    var destinationBuffer: CVPixelBuffer?
    // Allocate with aux attributes so the pool's high-water threshold is
    // enforced — a stalled writer cannot accumulate unbounded 4K IOSurfaces.
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      kCFAllocatorDefault, recordingPool, auxAttrs, &destinationBuffer)
    guard status == kCVReturnSuccess, let destination = destinationBuffer else {
      recordingInFlightSemaphore.signal()
      if status != kCVReturnWouldExceedAllocationThreshold {
        NSLog(
          "VideoFrameRenderer: recording buffer allocation failed: \(status) (pool dims \(scaledW)x\(scaledH))"
        )
      }
      return nil
    }

    guard
      let commandBuffer = submitRender(
        from: source, to: destination,
        destWidth: scaledW, destHeight: scaledH,
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

  /// Returns the (pool, auxAttrs) pair sized for the given dimensions,
  /// creating it on first use. Returns both atomically under the lock so
  /// callers never see a pool without its matching aux attributes.
  private func ensureRecordingPoolAndAuxAttrs(width: Int, height: Int)
    -> (CVPixelBufferPool, CFDictionary)?
  {
    recordingPoolLock.lock()
    defer { recordingPoolLock.unlock() }
    if let pool = recordingPool,
      let auxAttrs = recordingPoolAuxAttributes,
      recordingPoolWidth == width, recordingPoolHeight == height
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
    // Apply the same high-water cap as the preview pool so a stalled writer
    // cannot accumulate unbounded IOSurfaces. kCVPixelBufferPoolAllocationThresholdKey
    // in the *aux* dict (passed to CVPixelBufferPoolCreatePixelBufferWithAuxAttributes)
    // limits outstanding live buffers; we keep the pool's own attrs clean to
    // avoid the -6689 failure observed when they contained a size key.
    let poolAttrs: [String: Any] = [
      kCVPixelBufferPoolAllocationThresholdKey as String: VideoFrameRenderer.maxRecordingPoolBuffers
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let createdPool = pool else {
      NSLog("VideoFrameRenderer: recording pool creation failed: \(status)")
      return nil
    }
    let auxAttributes = poolAttrs as CFDictionary

    recordingPool = createdPool
    recordingPoolAuxAttributes = auxAttributes
    recordingPoolWidth = width
    recordingPoolHeight = height

    // Pre-allocate buffers so the first frames of the recording don't pay
    // for IOSurface allocation. At 4K each buffer is ~30 MB, so we prime
    // `minPoolBuffers` rather than the full high-water cap.
    VideoFrameRenderer.primePool(
      createdPool,
      auxAttributes: auxAttributes,
      count: VideoFrameRenderer.minPoolBuffers)

    return (createdPool, auxAttributes)
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
    guard let renderedBuffer = renderImage(sourceBuffer) else {
      return nil
    }
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
    var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    if var meta = metadata as? [String: Any], !meta.isEmpty {
      // Strip pixel-dimension keys that reflect the *original* sensor size
      // before crop/scale. Leaving them in causes EXIF to report wrong
      // dimensions for the saved file (e.g. 4032×3024 for a 16:9 crop).
      meta.removeValue(forKey: kCGImagePropertyPixelWidth as String)
      meta.removeValue(forKey: kCGImagePropertyPixelHeight as String)
      ciImage = ciImage.settingProperties(meta)
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    if CFEqual(destinationUTType, "public.heic" as CFString)
      || CFEqual(destinationUTType, "public.heif" as CFString)
    {
      return ciContext.heifRepresentation(
        of: ciImage, format: .BGRA8, colorSpace: colorSpace, options: [:])
    }
    return ciContext.jpegRepresentation(
      of: ciImage, colorSpace: colorSpace, options: [:])
  }

  /// Per-call uniform overrides. Lets the photo and recording-capture paths
  /// run with their own UV transform / darkening without disturbing the
  /// shared cached uniforms used by in-flight preview frames.
  struct UniformOverrides {
    var uvScale: SIMD2<Float>? = nil
    var captureScale: Float? = nil
    var darkenOutside: Float? = nil
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
    let sourcePixelFormat = CVPixelBufferGetPixelFormatType(source)
    guard let format = CameraSourceFormat(pixelFormat: sourcePixelFormat) else {
      NSLog(
        "VideoFrameRenderer: unsupported source pixel format \(String(format: "0x%08X", sourcePixelFormat))"
      )
      return nil
    }

    // Source texture(s). For YUV biplanar sources we sample the Y plane and
    // the interleaved CbCr plane separately and convert in the fragment
    // shader. For BGRA we sample directly. The destination is always BGRA.
    var sourceCVTextures: [CVMetalTexture] = []
    var sourceTextures: [MTLTexture] = []

    switch format {
    case .bgra:
      let sourceWidth = CVPixelBufferGetWidth(source)
      let sourceHeight = CVPixelBufferGetHeight(source)
      guard
        let (cv, mtl) = makeTexture(
          from: source, plane: 0, width: sourceWidth, height: sourceHeight,
          pixelFormat: .bgra8Unorm_srgb, usage: [.shaderRead])
      else {
        NSLog("VideoFrameRenderer: BGRA source texture creation failed")
        return nil
      }
      sourceCVTextures.append(cv)
      sourceTextures.append(mtl)

    case .yuvFullRange, .yuvVideoRange:
      let yWidth = CVPixelBufferGetWidthOfPlane(source, 0)
      let yHeight = CVPixelBufferGetHeightOfPlane(source, 0)
      let cWidth = CVPixelBufferGetWidthOfPlane(source, 1)
      let cHeight = CVPixelBufferGetHeightOfPlane(source, 1)
      guard
        let (yCV, yMTL) = makeTexture(
          from: source, plane: 0, width: yWidth, height: yHeight,
          pixelFormat: .r8Unorm, usage: [.shaderRead]),
        let (cCV, cMTL) = makeTexture(
          from: source, plane: 1, width: cWidth, height: cHeight,
          pixelFormat: .rg8Unorm, usage: [.shaderRead])
      else {
        NSLog("VideoFrameRenderer: YUV source texture creation failed")
        return nil
      }
      sourceCVTextures.append(yCV)
      sourceCVTextures.append(cCV)
      sourceTextures.append(yMTL)
      sourceTextures.append(cMTL)
    }

    guard
      let (destCV, destinationTexture) = makeTexture(
        from: destination, plane: 0, width: destWidth, height: destHeight,
        pixelFormat: .bgra8Unorm_srgb, usage: [.renderTarget, .shaderRead])
    else {
      NSLog("VideoFrameRenderer: destination texture creation failed")
      return nil
    }

    let passDescriptor = MTLRenderPassDescriptor()
    passDescriptor.colorAttachments[0].texture = destinationTexture
    passDescriptor.colorAttachments[0].loadAction = .dontCare
    passDescriptor.colorAttachments[0].storeAction = .store

    guard let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
    else {
      NSLog("VideoFrameRenderer: command buffer / encoder creation failed")
      return nil
    }

    let pipelineState: MTLRenderPipelineState
    switch format {
    case .bgra: pipelineState = bgraPipelineState
    case .yuvFullRange: pipelineState = yuvFullRangePipelineState
    case .yuvVideoRange: pipelineState = yuvVideoRangePipelineState
    }

    encoder.setRenderPipelineState(pipelineState)
    for (index, texture) in sourceTextures.enumerated() {
      encoder.setFragmentTexture(texture, index: index)
    }

    // Inline uniforms — Metal copies the bytes into its own per-draw storage
    // so each in-flight frame gets its own snapshot. No shared MTLBuffer to
    // race over. Bound to both stages: vertex applies the UV crop transform,
    // fragment uses the visual-effect fields.
    var snapshot = snapshotUniforms()
    if let override = overrides.uvScale {
      snapshot.uvScale = override
    }
    if let override = overrides.captureScale {
      snapshot.captureScale = override
    }
    if let override = overrides.darkenOutside {
      snapshot.darkenOutside = override
    }
    encoder.setVertexBytes(
      &snapshot, length: MemoryLayout<CameraUniforms>.stride, index: 0)
    encoder.setFragmentBytes(
      &snapshot, length: MemoryLayout<CameraUniforms>.stride, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()

    // CVMetalTexture wrappers must outlive the GPU work — the bare
    // MTLTexture does not retain the IOSurface lock. If the wrappers are
    // released while the GPU is still reading from the backing IOSurface
    // the Metal completion queue crashes with EXC_BAD_ACCESS in
    // CF_IS_OBJC.
    //
    // We can't just write `_ = cvTexturesToHold` inside the closure: the
    // optimizer can prove that has no side effects and elide the entire
    // capture. `withExtendedLifetime` is the documented way to tell the
    // compiler "this value must remain alive until this point". Inside
    // the closure body, the call itself is enough to keep `cvTextures`
    // strongly referenced until the completion handler runs.
    let cvTextures = sourceCVTextures + [destCV]
    commandBuffer.addCompletedHandler { _ in
      withExtendedLifetime(cvTextures) {}
    }
    return commandBuffer
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
    // `warm` deallocs here, returning the buffers to the pool ready for use.
    _ = warm
  }

  /// Drops cached IOSurface→texture mappings whose source buffers have been
  /// released. Called periodically (every `flushEveryNFrames`) — flushing
  /// every frame would discard mappings the next frame would reuse.
  private func flushTextureCacheIfNeeded() {
    framesSinceFlush += 1
    if framesSinceFlush >= VideoFrameRenderer.flushEveryNFrames {
      framesSinceFlush = 0
      CVMetalTextureCacheFlush(textureCache, 0)
    }
  }

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
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo: UInt32 =
      CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard
      let context = CGContext(
        data: baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: colorSpace, bitmapInfo: bitmapInfo)
    else {
      return nil
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixelBuffer
  }

  private func makeTexture(
    from buffer: CVPixelBuffer,
    plane: Int,
    width: Int,
    height: Int,
    pixelFormat: MTLPixelFormat,
    usage: MTLTextureUsage
  ) -> (CVMetalTexture, MTLTexture)? {
    let textureAttributes: [String: Any] = [
      kCVMetalTextureUsage as String: NSNumber(value: usage.rawValue)
    ]
    var cvTexture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,
      textureCache,
      buffer,
      textureAttributes as CFDictionary,
      pixelFormat,
      width,
      height,
      plane,
      &cvTexture)
    guard status == kCVReturnSuccess, let cvTexture = cvTexture,
      let mtlTexture = CVMetalTextureGetTexture(cvTexture)
    else {
      return nil
    }
    return (cvTexture, mtlTexture)
  }
}
