import AVFoundation
import CoreGraphics
import CoreImage
import Metal

/// Thread-safe cache of the most recently decoded raw source frames at a timeline time,
/// allowing instant (<5ms) GPU re-compositing during interactive drag/crop/transform/grade edits
/// without rebuilding AVMutableComposition or seeking AVPlayer.
final class LiveFrameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedTime: Double = -1
    private var frames: [UUID: CIImage] = [:]

    func store(time: Double, frames newFrames: [UUID: CIImage]) {
        guard !newFrames.isEmpty else { return }
        lock.lock()
        cachedTime = time
        frames = newFrames
        lock.unlock()
    }

    func lookup(time: Double, tolerance: Double = 0.02) -> [UUID: CIImage]? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty, abs(cachedTime - time) <= tolerance else { return nil }
        return frames
    }

    func clear() {
        lock.lock()
        cachedTime = -1
        frames.removeAll()
        lock.unlock()
    }
}

/// Where a video layer's picture comes from in its file, for showing it from the scrub frames.
struct ScrubSource {
    let asset: UUID
    let clock: SourceClock
    /// Played backwards: the file's length, which the time is counted back from.
    var reversedLength: Double? = nil

    func time(at t: Double) -> Double {
        let s = clock.source(at: t - 1e-4)
        return reversedLength.map { $0 - s } ?? s
    }
}

/// One visual element on the timeline, already resolved for a specific render size.
struct RenderLayer {
    enum Source {
        case track(CMPersistentTrackID, CGImagePropertyOrientation)
        case image(CIImage)
        case color(CIColor)
        /// Played backwards: at timeline time t the frame is the one just before file time
        /// `length - clock.source(at: t)`, kept no bigger than `limit` pixels.
        case reversed(ReverseFrames, CGImagePropertyOrientation, limit: Int, clock: SourceClock, length: Double)
        /// Played forwards, read straight from the file (HDR and Log): at timeline time t the frame
        /// is the one showing at file time `clock.source(at: t)`.
        case decoded(ReverseFrames, CGImagePropertyOrientation, limit: Int, clock: SourceClock)
    }

    let clipID: UUID
    /// When the layer is drawn: the clip, plus any extra a transition shows before or after it.
    let start: Double
    let end: Double
    /// The clip itself, which its own fades are measured from.
    let fadeStart: Double
    let fadeEnd: Double
    let reveal: TransitionEdge?
    let conceal: TransitionEdge?
    let fadeIn: Double
    let fadeOut: Double
    let inCurve: FadeCurve
    let outCurve: FadeCurve
    let source: Source
    /// Baked colour cube for this clip's grade, if it has one.
    let cube: Data?
    /// How the source file's picture is encoded; HDR and Log are converted to Rec.709 first.
    let color: SourceColor
    let transform: ClipTransform?
    /// A video layer's place in its file, for scrubbing from made-ahead frames (nil: not from them).
    let scrub: ScrubSource?

    init(clip: Clip, source: Source, cube: Data? = nil, color: SourceColor = .standard, plan: TransitionPlan = TransitionPlan(),
         scrub: ScrubSource? = nil) {
        self.clipID = clip.id
        self.scrub = scrub
        self.cube = cube
        self.color = color
        transform = clip.transform.flatMap { $0.isIdentity ? nil : $0 }
        start = clip.start - plan.leadIn
        end = clip.end + plan.tailOut
        fadeStart = clip.start
        fadeEnd = clip.end
        reveal = plan.reveal
        conceal = plan.conceal
        fadeIn = clip.fadeIn
        fadeOut = clip.fadeOut
        inCurve = clip.inCurve
        outCurve = clip.outCurve
        self.source = source
    }

    func opacity(at t: Double) -> Double {
        var o = 1.0
        // The clip's own fades; in the extra a transition shows, they hold their value at that end.
        let ft = min(max(t, fadeStart), fadeEnd)
        if fadeIn > 0 { o = min(o, inCurve.apply((ft - fadeStart) / fadeIn)) }
        if fadeOut > 0 { o = min(o, outCurve.apply((fadeEnd - ft) / fadeOut)) }
        if let r = reveal, r.kind != .wipe { o *= r.progress(t) }
        if let c = conceal { o *= 1 - c.progress(t) }
        return max(0, min(1, o))
    }

    /// For a wipe in progress, how much of the picture (from the left) is showing.
    func wipe(at t: Double) -> Double? {
        guard let r = reveal, r.kind == .wipe, t < r.end else { return nil }
        let p = r.progress(t)
        return p * p * (3 - 2 * p)
    }
}

/// A single instruction spans the whole timeline; the compositor resolves what is visible per frame.
final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    /// Bottom-most first.
    let layers: [RenderLayer]

    /// The sequence is laid out at this size, and the output is the window at `offset` within it
    /// (the same as the output, unless exporting to a different shape).
    let canvas: CGSize
    let offset: CGPoint
    /// Captions, drawn over everything in the output's own frame.
    let captions: [CaptionLayer]
    /// True only for live player renders so exports and get_frame never pollute LiveFrameCache.
    let cacheLiveFrames: Bool

    init(timeRange: CMTimeRange, layers: [RenderLayer], trackIDs: [CMPersistentTrackID], canvas: CGSize, offset: CGPoint = .zero,
         captions: [CaptionLayer] = [], cacheLiveFrames: Bool = false) {
        self.timeRange = timeRange
        self.canvas = canvas
        self.offset = offset
        self.layers = layers
        self.captions = captions
        self.cacheLiveFrames = cacheLiveFrames
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
    }
}

final class TimelineCompositor: NSObject, AVVideoCompositing {
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    private let queue = DispatchQueue(label: "editroom.compositor", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

    // Take frames in the decoder's own YUV formats (8- and 10-bit), so a 4K frame isn't converted to
    // RGB on the way in; Core Image converts on the GPU as part of compositing.
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ],
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        let gen = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = gen != self.generation
            self.lock.unlock()
            if stale {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? TimelineInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Editroom", code: 1))
                return
            }
            let image = Self.compose(instruction, request: request)
            let size = request.renderContext.size
            Self.context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
            // Every layer is Rec.709 by now. Saying so stops the encoder or display from "converting"
            // a frame again because it inherited an HDR source's tags.
            CVBufferRemoveAllAttachments(output)
            CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            request.finish(withComposedVideoFrame: output)
        }
    }

    static let liveFrameCache = LiveFrameCache()

    private static func compose(_ instruction: TimelineInstruction, request: AVAsynchronousVideoCompositionRequest) -> CIImage {
        let t = request.compositionTime.seconds + 1e-4
        let shouldCache = instruction.cacheLiveFrames
        var captured: [UUID: CIImage] = [:]
        let result = compose(instruction, at: t, output: request.renderContext.size) { _, layer in
            let buffer: CVPixelBuffer?
            switch layer.source {
            case .track(let id, _): buffer = request.sourceFrame(byTrackID: id)
            case .reversed(let frames, _, let limit, let clock, let length): buffer = frames.frame(before: length - clock.source(at: t - 1e-4), limit: limit)
            case .decoded(let frames, _, let limit, let clock): buffer = frames.frame(at: clock.source(at: t - 1e-4), limit: limit)
            default: buffer = nil
            }
            if let buffer {
                let img = CIImage(cvPixelBuffer: buffer)
                if shouldCache { captured[layer.clipID] = img }
                return img
            }
            return nil
        }
        if shouldCache, !captured.isEmpty {
            liveFrameCache.store(time: request.compositionTime.seconds, frames: captured)
        }
        return result
    }

    /// Generates an alpha mask image for a cropped rectangle (`yUp` Core Image coordinates).
    private static func makeMask(rect: CGRect, shape: MaskShape, cornerRadius: Double, feather: Double) -> CIImage? {
        let w = Int(ceil(rect.width)), h = Int(ceil(rect.height))
        guard w > 0, h > 0 else { return nil }
        let effectiveShape: MaskShape = (shape == .none && cornerRadius > 1e-5) ? .roundedRect : shape
        let shortSide = min(rect.width, rect.height)
        let featherPx = CGFloat(feather.clamped(to: ClipTransform.featherRange)) * shortSide
        // Keep sigma <= 0.4 * inset so the Gaussian tail decays below 0.5% before reaching rect's edge
        // (eliminating any hard rectangular cutoff seam).
        let blurRadius = featherPx > 0.5 ? featherPx * 0.4 : 0
        let inset = featherPx > 0.5 ? min(shortSide * 0.45, max(featherPx, blurRadius * 2.5)) : 0

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)

        let drawBounds = CGRect(x: inset, y: inset, width: max(1, CGFloat(w) - inset * 2), height: max(1, CGFloat(h) - inset * 2))
        switch effectiveShape {
        case .none:
            ctx.fill(drawBounds)
        case .roundedRect:
            let r = min(drawBounds.width, drawBounds.height) * CGFloat(cornerRadius.clamped(to: ClipTransform.radiusRange))
            let path = CGPath(roundedRect: drawBounds, cornerWidth: r, cornerHeight: r, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        case .ellipse:
            ctx.fillEllipse(in: drawBounds)
        case .circle:
            let side = min(drawBounds.width, drawBounds.height)
            let square = CGRect(x: (CGFloat(w) - side) / 2, y: (CGFloat(h) - side) / 2, width: side, height: side)
            ctx.fillEllipse(in: square)
        }

        guard let cg = ctx.makeImage() else { return nil }
        var mask = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        if blurRadius > 0.25 {
            // Composite over black padding (never clampedToExtent, which smears non-zero border pixels).
            let pad = ceil(blurRadius * 3)
            let paddedRect = rect.insetBy(dx: -pad, dy: -pad)
            let black = CIImage(color: .black).cropped(to: paddedRect)
            mask = mask.composited(over: black)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                .cropped(to: rect)
        }
        return mask
    }

    /// The frame at timeline time `t`: every layer showing then, bottom first. `picture` gives a video
    /// layer's own frame, as it comes from the file (the player's decoded frame, or a scrub frame).
    static func compose(_ instruction: TimelineInstruction, at t: Double, output: CGSize,
                        picture: (Int, RenderLayer) -> CIImage?) -> CIImage {
        let size = instruction.canvas
        let frame = CGRect(origin: .zero, size: size)
        var out = CIImage(color: .black).cropped(to: frame)

        for (index, layer) in instruction.layers.enumerated() where t >= layer.start && t < layer.end {
            let clipOpacity = layer.transform?.opacity ?? 1.0
            let opacity = layer.opacity(at: t) * clipOpacity
            if opacity <= 0.001 { continue }
            var image: CIImage
            let baseRect: CGRect
            switch layer.source {
            case .track(_, let orientation), .reversed(_, let orientation, _, _, _), .decoded(_, let orientation, _, _):
                guard var src = picture(index, layer) else { continue }
                if orientation != .up { src = src.oriented(orientation) }
                let e = src.extent
                guard e.width > 0, e.height > 0 else { continue }
                let s = min(size.width / e.width, size.height / e.height)
                let tx = (size.width - e.width * s) / 2 - e.minX * s
                let ty = (size.height - e.height * s) / 2 - e.minY * s
                image = src.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty))
                baseRect = CGRect(x: (size.width - e.width * s) / 2, y: (size.height - e.height * s) / 2,
                                  width: e.width * s, height: e.height * s)
                // After scaling, so a 4K source is converted at the output's size.
                image = layer.color.toRec709(image)
            case .image(let img):
                image = img
                baseRect = img.extent.isInfinite ? frame : img.extent
            case .color(let color):
                image = CIImage(color: color).cropped(to: frame)
                baseRect = frame
            }
            if let w = layer.wipe(at: t) {
                image = image.cropped(to: CGRect(x: 0, y: 0, width: size.width * w, height: size.height))
            }
            if let tf = layer.transform {
                // 1. Flip H/V about the fitted clip's centre.
                if tf.flipH || tf.flipV {
                    let bcx = baseRect.midX, bcy = baseRect.midY
                    let flip = CGAffineTransform(translationX: -bcx, y: -bcy)
                        .concatenating(CGAffineTransform(scaleX: tf.flipH ? -1 : 1, y: tf.flipV ? -1 : 1))
                        .concatenating(CGAffineTransform(translationX: bcx, y: bcy))
                    image = image.transformed(by: flip)
                }
                // 2. Real 4-side crop in fitted clip space.
                let cropRect = tf.croppedRect(in: baseRect, yUp: true)
                if tf.hasCrop {
                    image = image.cropped(to: cropRect)
                }
                // 3. Mask (rounded corners / ellipse / circle + feather) inside cropped rect.
                if tf.hasMask, let mask = makeMask(rect: cropRect, shape: tf.maskShape,
                                                   cornerRadius: tf.cornerRadius, feather: tf.maskFeather) {
                    let clear = CIImage(color: .clear).cropped(to: cropRect)
                    image = image.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: clear,
                        kCIInputMaskImageKey: mask,
                    ]).cropped(to: cropRect)
                }
                // 4. Scale, rotate and offset using the shared transform matrix (Preview == Export == HitTest).
                if abs(tf.scale - 1) > 1e-6 || abs(tf.rotation) > 1e-6 || abs(tf.x) > 1e-6 || abs(tf.y) > 1e-6 {
                    image = image.transformed(by: tf.affine(canvasSize: size, yUp: true))
                }
            }
            if let cube = layer.cube {
                image = image.applyingFilter("CIColorCube", parameters: [
                    "inputCubeDimension": GradeCube.dimension,
                    "inputCubeData": cube,
                ])
            }
            if opacity < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
                ])
            }
            out = image.composited(over: out)
        }
        if instruction.offset != .zero || output != size {
            out = out.transformed(by: CGAffineTransform(translationX: -instruction.offset.x, y: -instruction.offset.y))
        }
        out = out.cropped(to: CGRect(origin: .zero, size: output))
        for caption in instruction.captions where t >= caption.start && t < caption.end {
            if let image = caption.image(output: output) { out = image.composited(over: out) }
        }
        return out.cropped(to: CGRect(origin: .zero, size: output))
    }
}
