import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import Metal
import Vision

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
        BackgroundMatteEngine.clearCache()
    }
}

/// Hardware-accelerated Apple Silicon Neural Engine (Vision) + Metal GPU background removal engine.
/// Caches raw Vision mattes per `(clipID, frame, mode, size)` so adjusting Tolerance, Softness,
/// Edge Shift, or Invert re-runs purely on the GPU in <3ms without re-invoking Vision.
final class BackgroundMatteEngine: @unchecked Sendable {
    private struct MatteKey: Hashable {
        let clipID: UUID
        let frameBucket: Int
        let mode: BackgroundRemovalMode
        let width: Int
        let height: Int
    }

    private struct ChromaKey: Hashable {
        let r: Int, g: Int, b: Int
        let tolerance: Int
        let softness: Int
        let invert: Bool
    }

    private struct CardQuad {
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomRight: CGPoint
        let bottomLeft: CGPoint
    }

    private static let lock = NSLock()
    private static var matteCache: [MatteKey: CIImage] = [:]
    private static var matteOrder: [MatteKey] = []
    private static var cardCache: [MatteKey: CardQuad] = [:]
    private static var cardOrder: [MatteKey] = []
    private static var chromaCache: [ChromaKey: Data] = [:]
    private static let maxMattes = 90

    static func clearCache() {
        lock.lock()
        matteCache.removeAll()
        matteOrder.removeAll()
        cardCache.removeAll()
        cardOrder.removeAll()
        lock.unlock()
    }

    static func apply(_ bg: BackgroundRemoval, to image: CIImage, clipID: UUID, at t: Double, isStill: Bool) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else { return image }

        if bg.mode == .aiCard {
            return applyCardIsolation(bg, to: image, extent: extent, clipID: clipID, at: t, isStill: isStill)
        }

        if bg.mode == .chromaKey {
            let cube = chromaCube(color: bg.keyColor, tolerance: bg.tolerance, softness: bg.softness, invert: bg.invert)
            let keyed = image.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": 32,
                "inputCubeData": cube,
            ]).cropped(to: extent)
            if abs(bg.edgeShift) < 0.01 { return keyed }
            // Apply edge shrink/expand to the keyed alpha when requested.
            var alphaMask = keyed.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]).cropped(to: extent)
            if bg.edgeShift < -0.01 {
                alphaMask = alphaMask.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: abs(bg.edgeShift) * 6.0]).cropped(to: extent)
            } else {
                alphaMask = alphaMask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: bg.edgeShift * 6.0]).cropped(to: extent)
            }
            let clear = CIImage(color: .clear).cropped(to: extent)
            return image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: alphaMask,
            ]).cropped(to: extent)
        }

        // AI Neural Segmentation (Vision Framework on Apple Silicon Neural Engine).
        let key = MatteKey(clipID: clipID,
                           frameBucket: isStill ? 0 : Int((t * 60.0).rounded()),
                           mode: bg.mode,
                           width: Int(extent.width.rounded()),
                           height: Int(extent.height.rounded()))
        let rawMatte: CIImage?
        lock.lock()
        let cached = matteCache[key]
        lock.unlock()

        if let cached {
            rawMatte = cached
        } else {
            let computed = computeVisionMatte(for: image, mode: bg.mode)
            if let computed {
                lock.lock()
                matteCache[key] = computed
                matteOrder.append(key)
                if matteOrder.count > maxMattes {
                    let drop = matteOrder.removeFirst()
                    matteCache.removeValue(forKey: drop)
                }
                lock.unlock()
            }
            rawMatte = computed
        }

        guard let raw = rawMatte, raw.extent.width > 0, raw.extent.height > 0 else { return image }

        // Map raw Vision matte cleanly onto `image.extent`.
        let sx = extent.width / raw.extent.width
        let sy = extent.height / raw.extent.height
        var matte = raw.transformed(by: CGAffineTransform(scaleX: sx, y: sy)
            .concatenating(CGAffineTransform(translationX: extent.minX - raw.extent.minX * sx,
                                             y: extent.minY - raw.extent.minY * sy)))
            .cropped(to: extent)

        // 1. Edge shrink / expand (kills background spill halo when negative).
        if bg.edgeShift < -0.01 {
            let r = CGFloat(abs(bg.edgeShift) * 6.0)
            let pad = ceil(r) + 2
            let black = CIImage(color: .black).cropped(to: extent.insetBy(dx: -pad, dy: -pad))
            matte = matte.composited(over: black)
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r])
                .cropped(to: extent)
        } else if bg.edgeShift > 0.01 {
            let r = CGFloat(bg.edgeShift * 6.0)
            matte = matte.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r])
                .cropped(to: extent)
        }

        // 2. Tolerance control: shifts neural alpha decision boundary in real time on the GPU.
        // tolerance 0.0 -> strict (0.88), tolerance 0.5 -> balanced (0.49), tolerance 1.0 -> permissive (0.10).
        let threshold = 0.88 - bg.tolerance.clamped(to: 0...1) * 0.78
        let slope = 7.5 - bg.softness.clamped(to: 0...1) * 5.0
        let bias = 0.5 - threshold * slope
        matte = matte
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: slope, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: slope, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: slope, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            .cropped(to: extent)

        // 3. Softness / feathering without edge seam.
        if bg.softness > 0.01 {
            let radius = CGFloat(bg.softness.clamped(to: 0...1) * 7.0)
            let pad = ceil(radius * 3)
            let black = CIImage(color: .black).cropped(to: extent.insetBy(dx: -pad, dy: -pad))
            matte = matte.composited(over: black)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
        }

        // 4. Optional invert.
        if bg.invert {
            matte = matte.applyingFilter("CIColorInvert").cropped(to: extent)
        }

        let bgImg: CIImage
        if bg.blurBackground > 0.01 {
            let blurR = CGFloat(bg.blurBackground.clamped(to: 0...1) * 28.0)
            bgImg = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurR])
                .cropped(to: extent)
        } else {
            bgImg = CIImage(color: .clear).cropped(to: extent)
        }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bgImg,
            kCIInputMaskImageKey: matte,
        ]).cropped(to: extent)
    }

    /// Isolates a news card, article, screenshot or document rectangle using Apple Vision
    /// (`VNDetectDocumentSegmentationRequest` + `VNDetectRectanglesRequest` fallback), erasing
    /// the surrounding studio/presenter background while letting Tolerance/Edge/Softness refine live.
    private static func applyCardIsolation(_ bg: BackgroundRemoval, to image: CIImage, extent: CGRect,
                                           clipID: UUID, at t: Double, isStill: Bool) -> CIImage {
        // News cards in live streams stay steady across frames, so 4Hz bucketing keeps detection smooth & flicker-free.
        let key = MatteKey(clipID: clipID,
                           frameBucket: isStill ? 0 : Int((t * 4.0).rounded()),
                           mode: .aiCard,
                           width: Int(extent.width.rounded()),
                           height: Int(extent.height.rounded()))
        lock.lock()
        let cachedQuad = cardCache[key]
        lock.unlock()

        let quad: CardQuad?
        if let cachedQuad {
            quad = cachedQuad
        } else {
            let detected = detectCardQuad(in: image)
            if let detected {
                lock.lock()
                cardCache[key] = detected
                cardOrder.append(key)
                if cardOrder.count > maxMattes {
                    let drop = cardOrder.removeFirst()
                    cardCache.removeValue(forKey: drop)
                }
                lock.unlock()
            }
            quad = detected
        }

        guard let q = quad else { return image }

        let w = Int(ceil(extent.width)), h = Int(ceil(extent.height))
        guard w > 1, h > 1 else { return image }

        // Vision coordinates are normalized with bottom-left origin (same y-up convention as Core Image).
        func toPixel(_ pt: CGPoint) -> CGPoint {
            CGPoint(x: pt.x * CGFloat(w), y: pt.y * CGFloat(h))
        }
        var pts = [toPixel(q.topLeft), toPixel(q.topRight), toPixel(q.bottomRight), toPixel(q.bottomLeft)]
        let cx = pts.map(\.x).reduce(0, +) / 4
        let cy = pts.map(\.y).reduce(0, +) / 4

        // Tolerance (0...1, default 0.5) expands/contracts card bounds by ±8%; Edge Shift adds fine ±16px trim.
        let tolScale = 1.0 + CGFloat((bg.tolerance.clamped(to: 0...1) - 0.5) * 0.16)
        let edgePx = CGFloat(bg.edgeShift.clamped(to: -1...1) * 16.0)
        pts = pts.map { pt in
            let vx = pt.x - cx, vy = pt.y - cy
            let len = max(1, hypot(vx, vy))
            let nx = cx + vx * tolScale + (vx / len) * edgePx
            let ny = cy + vy * tolScale + (vy / len) * edgePx
            return CGPoint(x: nx, y: ny)
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return image }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        let path = CGMutablePath()
        path.move(to: pts[0])
        path.addLine(to: pts[1])
        path.addLine(to: pts[2])
        path.addLine(to: pts[3])
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()

        guard let cg = ctx.makeImage() else { return image }
        var matte = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)

        if bg.softness > 0.01 {
            let radius = CGFloat(bg.softness.clamped(to: 0...1) * 10.0)
            let pad = ceil(radius * 3)
            let black = CIImage(color: .black).cropped(to: extent.insetBy(dx: -pad, dy: -pad))
            matte = matte.composited(over: black)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
        }
        if bg.invert {
            matte = matte.applyingFilter("CIColorInvert").cropped(to: extent)
        }

        let bgImg: CIImage
        if bg.blurBackground > 0.01 {
            let blurR = CGFloat(bg.blurBackground.clamped(to: 0...1) * 28.0)
            bgImg = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurR])
                .cropped(to: extent)
        } else {
            bgImg = CIImage(color: .clear).cropped(to: extent)
        }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bgImg,
            kCIInputMaskImageKey: matte,
        ]).cropped(to: extent)
    }

    private static func detectCardQuad(in image: CIImage) -> CardQuad? {
        let e = image.extent
        let normalized = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let maxSide = max(e.width, e.height)
        let visionInput: CIImage
        if maxSide > 1024 {
            let s = 1024 / maxSide
            visionInput = normalized.transformed(by: CGAffineTransform(scaleX: s, y: s))
        } else {
            visionInput = normalized
        }

        let handler = VNImageRequestHandler(ciImage: visionInput, options: [.ciContext: TimelineCompositor.context])

        // 1. Primary: Apple Neural Engine Document/Card Segmentation (captures colored headers + white body as 1 card).
        let docReq = VNDetectDocumentSegmentationRequest()
        if (try? handler.perform([docReq])) != nil,
           let best = docReq.results?.first(where: { r in
               let area = r.boundingBox.width * r.boundingBox.height
               return area >= 0.04 && area <= 0.94 && r.confidence >= 0.5
           }) {
            return CardQuad(topLeft: best.topLeft, topRight: best.topRight,
                            bottomRight: best.bottomRight, bottomLeft: best.bottomLeft)
        }

        // 2. Fallback: Vision Rectangle Detector (picks largest crisp non-full-frame card).
        let rectReq = VNDetectRectanglesRequest()
        rectReq.maximumObservations = 6
        rectReq.minimumSize = 0.14
        rectReq.minimumConfidence = 0.45
        rectReq.minimumAspectRatio = 0.25
        rectReq.maximumAspectRatio = 1.0
        if (try? handler.perform([rectReq])) != nil,
           let best = (rectReq.results ?? [])
            .filter({ r in
                let area = r.boundingBox.width * r.boundingBox.height
                return area >= 0.04 && area <= 0.94
            })
            .max(by: { ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height) }) {
            return CardQuad(topLeft: best.topLeft, topRight: best.topRight,
                            bottomRight: best.bottomRight, bottomLeft: best.bottomLeft)
        }

        return nil
    }

    /// Runs Apple Vision segmentation on the Neural Engine and returns a normalized grayscale `CIImage` matte.
    private static func computeVisionMatte(for image: CIImage, mode: BackgroundRemovalMode) -> CIImage? {
        let e = image.extent
        let normalized = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        // Cap Vision input at 1024px long side so 4K video stays fast on the Neural Engine while keeping crisp mattes.
        let maxSide = max(e.width, e.height)
        let visionInput: CIImage
        if maxSide > 1024 {
            let s = 1024 / maxSide
            visionInput = normalized.transformed(by: CGAffineTransform(scaleX: s, y: s))
        } else {
            visionInput = normalized
        }

        let handler = VNImageRequestHandler(ciImage: visionInput, options: [.ciContext: TimelineCompositor.context])

        if mode == .aiSubject {
            let req = VNGenerateForegroundInstanceMaskRequest()
            if (try? handler.perform([req])) != nil,
               let obs = req.results?.first,
               !obs.allInstances.isEmpty,
               let maskBuf = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
                return CIImage(cvPixelBuffer: maskBuf)
            }
            // Fall through to person segmentation if no discrete subject instance was found.
        }

        let personReq = VNGeneratePersonSegmentationRequest()
        personReq.qualityLevel = .accurate
        personReq.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? handler.perform([personReq])) != nil,
              let obs = personReq.results?.first else { return nil }
        return CIImage(cvPixelBuffer: obs.pixelBuffer)
    }

    /// Cached 32x32x32 3D color-distance LUT for GPU Color / Chroma Key.
    private static func chromaCube(color: RGBA, tolerance: Double, softness: Double, invert: Bool) -> Data {
        let key = ChromaKey(r: Int((color.r * 255).rounded()),
                            g: Int((color.g * 255).rounded()),
                            b: Int((color.b * 255).rounded()),
                            tolerance: Int((tolerance * 200).rounded()),
                            softness: Int((softness * 200).rounded()),
                            invert: invert)
        lock.lock()
        if let hit = chromaCache[key] { lock.unlock(); return hit }
        lock.unlock()

        let dim = 32
        var data = [Float](repeating: 0, count: dim * dim * dim * 4)
        let kr = Float(color.r), kg = Float(color.g), kb = Float(color.b)
        let thresh = Float(0.04 + tolerance.clamped(to: 0...1) * 0.72)
        let feather = Float(max(0.015, softness.clamped(to: 0...1) * 0.35))

        var idx = 0
        for b in 0..<dim {
            let bf = Float(b) / Float(dim - 1)
            for g in 0..<dim {
                let gf = Float(g) / Float(dim - 1)
                for r in 0..<dim {
                    let rf = Float(r) / Float(dim - 1)
                    let dr = rf - kr, dg = gf - kg, db = bf - kb
                    let dist = sqrt(dr * dr + dg * dg + db * db)
                    var a = min(1, max(0, (dist - thresh) / feather))
                    a = a * a * (3 - 2 * a)
                    if invert { a = 1 - a }
                    data[idx] = rf * a
                    data[idx + 1] = gf * a
                    data[idx + 2] = bf * a
                    data[idx + 3] = a
                    idx += 4
                }
            }
        }
        let result = data.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        if chromaCache.count > 64 { chromaCache.removeAll() }
        chromaCache[key] = result
        lock.unlock()
        return result
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
    let bgRemoval: BackgroundRemoval?
    let style: ClipStyle?
    let animation: ClipAnimation?
    let keyframes: [ClipKeyframe]?
    let highlight: ClipHighlight?
    let privacyBlur: PrivacyBlur?
    let lowerThird: LowerThird?
    /// A video layer's place in its file, for scrubbing from made-ahead frames (nil: not from them).
    let scrub: ScrubSource?

    init(clip: Clip, source: Source, cube: Data? = nil, color: SourceColor = .standard, plan: TransitionPlan = TransitionPlan(),
         scrub: ScrubSource? = nil) {
        self.clipID = clip.id
        self.scrub = scrub
        self.cube = cube
        self.color = color
        transform = clip.transform.flatMap { $0.isIdentity ? nil : $0 }
        bgRemoval = clip.bgRemoval
        style = clip.style.flatMap { $0.isDefault ? nil : $0 }
        animation = clip.animation.flatMap { $0.isDefault ? nil : $0 }
        keyframes = clip.keyframes.flatMap { $0.isEmpty ? nil : $0 }
        highlight = clip.highlight
        privacyBlur = clip.privacyBlur
        lowerThird = clip.lowerThird
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
            let tf = layer.transform
            let isStill: Bool = { if case .image = layer.source { return true }; return false }()
            // 1. Flip H/V about the fitted clip's centre.
            if let tf, tf.flipH || tf.flipV {
                let bcx = baseRect.midX, bcy = baseRect.midY
                let flip = CGAffineTransform(translationX: -bcx, y: -bcy)
                    .concatenating(CGAffineTransform(scaleX: tf.flipH ? -1 : 1, y: tf.flipV ? -1 : 1))
                    .concatenating(CGAffineTransform(translationX: bcx, y: bcy))
                image = image.transformed(by: flip)
            }
            // 2. Real 4-side crop in fitted clip space.
            let cropRect = tf?.croppedRect(in: baseRect, yUp: true) ?? baseRect
            if let tf, tf.hasCrop {
                image = image.cropped(to: cropRect)
            }
            // 3. AI Background Removal / Portrait Blur / Card Cutout / Chroma Key.
            if let bg = layer.bgRemoval {
                image = BackgroundMatteEngine.apply(bg, to: image, clipID: layer.clipID, at: t, isStill: isStill)
            }
            // 3b. Privacy Blur / Pixelate Censorship Zone inside cropped rect.
            if let pb = layer.privacyBlur {
                image = applyPrivacyBlur(pb, to: image, in: cropRect)
            }
            // 3c. Animated News Headline Highlighter (wipes smoothly left-to-right).
            let localT = max(0, t - layer.fadeStart)
            let clipDur = max(0.05, layer.fadeEnd - layer.fadeStart)
            if let hl = layer.highlight {
                image = applyHighlighter(hl, to: image, in: cropRect, localTime: localT)
            }
            // 4. Geometric Mask (rounded corners / ellipse / circle + feather) inside cropped rect.
            if let tf, tf.hasMask, let mask = makeMask(rect: cropRect, shape: tf.maskShape,
                                                       cornerRadius: tf.cornerRadius, feather: tf.maskFeather) {
                let clear = CIImage(color: .clear).cropped(to: cropRect)
                image = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: clear,
                    kCIInputMaskImageKey: mask,
                ]).cropped(to: cropRect)
            }
            // 4b. Card Polish: corner rounding, border stroke, and cinematic drop shadow.
            if let st = layer.style {
                image = applyClipStyle(st, to: image, in: cropRect, canvas: size)
            }
            // 5. Keyframes + Motion Animation + Transform Affine (Preview == Export).
            var effectiveTF = tf ?? ClipTransform()
            var motionOpacity = 1.0
            if let keys = layer.keyframes, let kf = ClipKeyframe.interpolate(keys, at: localT) {
                effectiveTF.x = kf.x
                effectiveTF.y = kf.y
                effectiveTF.scale = kf.scale
                effectiveTF.rotation = kf.rotation
                motionOpacity *= kf.opacity.clamped(to: 0...1)
            }
            if let anim = layer.animation {
                let m = anim.evaluate(localTime: localT, duration: clipDur)
                effectiveTF.x += m.dx
                effectiveTF.y += m.dy
                effectiveTF.scale = (effectiveTF.scale * m.scaleMul).clamped(to: ClipTransform.scaleRange)
                effectiveTF.rotation += m.rotDelta
                motionOpacity *= m.opacityMul
            }
            if abs(effectiveTF.scale - 1) > 1e-6 || abs(effectiveTF.rotation) > 1e-6
                || abs(effectiveTF.x) > 1e-6 || abs(effectiveTF.y) > 1e-6 {
                image = image.transformed(by: effectiveTF.affine(canvasSize: size, yUp: true))
            }
            if let cube = layer.cube {
                image = image.applyingFilter("CIColorCube", parameters: [
                    "inputCubeDimension": GradeCube.dimension,
                    "inputCubeData": cube,
                ])
            }
            let finalOpacity = opacity * motionOpacity
            if finalOpacity <= 0.001 { continue }
            if finalOpacity < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: finalOpacity),
                ])
            }
            out = image.composited(over: out)
            // 6. Optional Animated Broadcast Lower Third rendered crisply on top of this clip.
            if let lt = layer.lowerThird, let ltImg = renderLowerThird(lt, canvas: size, localTime: localT, duration: clipDur) {
                out = ltImg.composited(over: out)
            }
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

    // MARK: Modern Visual Effects (Privacy Blur, Animated Highlighter, Card Polish, Lower Third)

    private static func applyPrivacyBlur(_ pb: PrivacyBlur, to image: CIImage, in rect: CGRect) -> CIImage {
        let zw = rect.width * CGFloat(pb.width), zh = rect.height * CGFloat(pb.height)
        let zx = rect.minX + rect.width * CGFloat(pb.x) - zw / 2
        let zy = rect.minY + rect.height * CGFloat(1 - pb.y) - zh / 2
        let zone = CGRect(x: zx, y: zy, width: zw, height: zh).intersection(rect)
        guard zone.width > 2, zone.height > 2 else { return image }
        let blurred: CIImage
        if pb.pixelate {
            let scale = max(6, CGFloat(pb.strength) * min(rect.width, rect.height) * 0.045)
            blurred = image.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale])
                .cropped(to: zone)
        } else {
            let radius = max(6, CGFloat(pb.strength) * 32.0)
            blurred = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: zone)
        }
        return blurred.composited(over: image).cropped(to: rect)
    }

    private static func applyHighlighter(_ hl: ClipHighlight, to image: CIImage, in rect: CGRect, localTime: Double) -> CIImage {
        guard localTime >= hl.startOffset else { return image }
        let raw = ((localTime - hl.startOffset) / max(0.05, hl.wipeDuration)).clamped(to: 0...1)
        let progress = 1 - pow(1 - raw, 3) // ease-out stroke
        let fullW = rect.width * CGFloat(hl.width)
        let barW = fullW * CGFloat(progress)
        let barH = rect.height * CGFloat(hl.height)
        guard barW > 1, barH > 1 else { return image }
        let leftX = rect.minX + rect.width * CGFloat(hl.x) - fullW / 2
        let botY = rect.minY + rect.height * CGFloat(1 - hl.y) - barH / 2
        let barRect = CGRect(x: leftX, y: botY, width: barW, height: barH).intersection(rect)
        guard !barRect.isEmpty else { return image }
        let bar = CIImage(color: CIColor(red: hl.color.r, green: hl.color.g, blue: hl.color.b, alpha: hl.color.a))
            .cropped(to: barRect)
        // Multiply-style vibrant translucent marker stroke over white news cards & video alike.
        return bar.composited(over: image).cropped(to: rect)
    }

    private static func applyClipStyle(_ st: ClipStyle, to image: CIImage, in rect: CGRect, canvas: CGSize) -> CIImage {
        var out = image
        let shortSide = min(rect.width, rect.height)
        // 1. Optional corner rounding (independent of geometric mask, great on cropped cards).
        if st.cornerRadius > 1e-4, let mask = makeMask(rect: rect, shape: .roundedRect, cornerRadius: st.cornerRadius, feather: 0) {
            let clear = CIImage(color: .clear).cropped(to: rect)
            out = out.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: mask,
            ]).cropped(to: rect)
        }
        // 2. Crisp border outline around the card/clip edge.
        if st.borderWidth > 0.25 {
            let bw = CGFloat(st.borderWidth) * min(canvas.width, canvas.height) / 1080
            let w = Int(ceil(rect.width)), h = Int(ceil(rect.height))
            if w > 4, h > 4,
               let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                let insetRect = CGRect(x: bw / 2, y: bw / 2, width: max(1, CGFloat(w) - bw), height: max(1, CGFloat(h) - bw))
                let cr = shortSide * CGFloat(st.cornerRadius.clamped(to: 0...0.5))
                ctx.addPath(CGPath(roundedRect: insetRect, cornerWidth: cr, cornerHeight: cr, transform: nil))
                ctx.setStrokeColor(CGColor(srgbRed: st.borderColor.r, green: st.borderColor.g, blue: st.borderColor.b, alpha: st.borderColor.a))
                ctx.setLineWidth(bw)
                ctx.strokePath()
                if let cg = ctx.makeImage() {
                    let borderImg = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                    out = borderImg.composited(over: out)
                }
            }
        }
        // 3. Cinematic drop shadow derived from the clip's own alpha (works even on AI Card & AI Person cutouts!).
        if st.shadowOpacity > 0.01 {
            let scale = min(canvas.width, canvas.height) / 1080
            let radius = CGFloat(st.shadowRadius) * scale
            let dy = -CGFloat(st.shadowOffsetY) * scale // Core Image is y-up, so positive offsetY drops downward.
            let pad = ceil(radius * 2.5 + abs(dy) + 8)
            let shadowBounds = rect.insetBy(dx: -pad, dy: -pad)
            let blackAlpha = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: st.shadowOpacity),
            ])
            let clearPad = CIImage(color: .clear).cropped(to: shadowBounds)
            let shadow = blackAlpha.composited(over: clearPad)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .transformed(by: CGAffineTransform(translationX: 0, y: dy))
                .cropped(to: shadowBounds)
            out = out.composited(over: shadow)
        }
        return out
    }

    private static func renderLowerThird(_ lt: LowerThird, canvas: CGSize, localTime: Double, duration: Double) -> CIImage? {
        guard !lt.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let scale = min(canvas.width, canvas.height) / 1080
        let inU = (localTime / 0.35).clamped(to: 0...1)
        let outU = ((duration - localTime) / 0.30).clamped(to: 0...1)
        let u = min(inU, outU)
        let ease = 1 - pow(1 - u, 3)
        if ease <= 0.01 { return nil }

        let titleFont = NSFont.systemFont(ofSize: 38 * scale, weight: .heavy)
        let subFont = NSFont.systemFont(ofSize: 22 * scale, weight: .semibold)
        let titleAttr: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor.white]
        let subAttr: [NSAttributedString.Key: Any] = [.font: subFont, .foregroundColor: NSColor.white.withAlphaComponent(0.84)]
        let tSize = (lt.title as NSString).size(withAttributes: titleAttr)
        let sSize = lt.subtitle.isEmpty ? .zero : (lt.subtitle as NSString).size(withAttributes: subAttr)

        let padX = 22 * scale, padY = 14 * scale, barW = 8 * scale
        let boxW = min(canvas.width * 0.88, ceil(max(tSize.width, sSize.width) + padX * 2 + barW + 10 * scale))
        let boxH = ceil(tSize.height + (lt.subtitle.isEmpty ? 0 : sSize.height + 4 * scale) + padY * 2)
        let iw = Int(boxW), ih = Int(boxH)
        guard iw > 4, ih > 4,
              let ctx = CGContext(data: nil, width: iw, height: ih, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        let boxRect = CGRect(x: 0, y: 0, width: boxW, height: boxH)
        let rounded = CGPath(roundedRect: boxRect, cornerWidth: 10 * scale, cornerHeight: 10 * scale, transform: nil)
        ctx.addPath(rounded)
        ctx.clip()
        ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 0.90))
        ctx.fill(boxRect)

        ctx.setFillColor(CGColor(srgbRed: lt.accentColor.r, green: lt.accentColor.g, blue: lt.accentColor.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: barW, height: boxH))

        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let textX = barW + padX * 0.8
        if lt.subtitle.isEmpty {
            (lt.title as NSString).draw(at: CGPoint(x: textX, y: (boxH - tSize.height) / 2), withAttributes: titleAttr)
        } else {
            (lt.subtitle as NSString).draw(at: CGPoint(x: textX, y: padY), withAttributes: subAttr)
            (lt.title as NSString).draw(at: CGPoint(x: textX, y: padY + sSize.height + 4 * scale), withAttributes: titleAttr)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return nil }
        let marginX = canvas.width * 0.06
        let slideX = -CGFloat(1 - ease) * (boxW * 0.35)
        let posY = (1 - CGFloat(lt.y)) * canvas.height - boxH / 2
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(translationX: marginX + slideX, y: max(16 * scale, min(canvas.height - boxH - 16 * scale, posY))))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: ease)])
    }
}
