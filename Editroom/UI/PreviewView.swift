import SwiftUI
import AppKit
import AVFoundation

/// Displays decoded frames straight from the player's video output. The last frame stays up while
/// a new composition is swapped in, so edits never flash black.
final class PreviewSurface: NSView {
    private let model: EditorModel
    private var link: CADisplayLink?
    private var current: CVPixelBuffer?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        // A viewer that has just appeared (full screen, say) starts on the frame already showing.
        if current == nil, let last = model.engine.lastFrame {
            current = last
            layer?.contents = CVPixelBufferGetIOSurface(last)?.takeUnretainedValue()
        }
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step(_ sender: CADisplayLink) {
        if let buffer = model.engine.pullFrame() {
            current = buffer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
            CATransaction.commit()
        } else if model.engine.isEmpty, current != nil {
            current = nil
            layer?.contents = nil
        }
        model.tick()
    }
}

struct PreviewSurfaceView: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> PreviewSurface { PreviewSurface(model: model) }
    func updateNSView(_ nsView: PreviewSurface, context: Context) {}
}

struct PreviewView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clock: Clock
    @ObservedObject var source: SourcePreviewState
    @State private var moveStart: (x: Double, y: Double)?
    /// Viewer magnification; nil fits the frame to the space available.
    @State private var zoom: Double?
    /// Active interactive handle on the selected clip's canvas bounding box.
    @State private var canvasDrag: CanvasDragState?
    /// Magnetic guide lines flashed while dragging/rotating on the canvas.
    @State private var guides = SnapGuides()
    /// Live HUD badge shown while dragging/scaling/cropping/rotating on the canvas.
    @State private var hudText: String?

    private struct SnapGuides: Equatable {
        var centerX = false
        var centerY = false
        var leftEdge = false
        var rightEdge = false
        var topEdge = false
        var bottomEdge = false
    }

    fileprivate enum CanvasHandle: Equatable {
        case body
        case topLeft, topRight, bottomLeft, bottomRight
        case cropLeft, cropRight, cropTop, cropBottom
        case rotate
    }

    private struct CanvasDragState {
        let clipID: UUID
        let handle: CanvasHandle
        let initial: ClipTransform
        let baseRect: CGRect
        let initialAffine: CGAffineTransform
        let startPoint: CGPoint
        let startAngle: Double
    }

    @State private var hoveredHandle: CanvasHandle?
    @State private var lastSnapScale100 = false
    @State private var lastSnapAngle: Double?
    @State private var gestureBaseScale: Double?
    @State private var gestureBaseRotation: Double?

    init(model: EditorModel) {
        self.model = model
        self.clock = model.clock
        self.source = model.sourcePreview
    }

    /// The one visual clip in the selection, which dragging in the viewer moves/crops/scales/rotates.
    private var target: Clip? {
        let visual = model.selection.compactMap { model.project.clip($0) }.filter { $0.kind != .audio }
        return visual.count == 1 ? visual[0] : nil
    }

    /// Whether the selected target clip is actually visible and unlocked at the current playhead time.
    private var activeTarget: Clip? {
        guard let c = target else { return nil }
        let t = Double(clock.frame) / max(1, model.project.fps)
        guard t >= c.start - 1e-4 && t < c.end - 1e-4 else { return nil }
        if let track = model.project.videoTracks.first(where: { $0.id == c.trackID }), track.hidden || track.locked { return nil }
        return c
    }

    private func baseRect(for clip: Clip, in canvas: CGSize) -> CGRect {
        if clip.kind == .solid { return CGRect(origin: .zero, size: canvas) }
        if let aid = clip.assetID, let asset = model.project.asset(aid), asset.width > 0, asset.height > 0 {
            return ClipTransform.fittedBaseRect(sourceSize: CGSize(width: asset.width, height: asset.height), canvasSize: canvas)
        }
        return CGRect(origin: .zero, size: canvas)
    }

    /// Hit-tests topmost visible unlocked visual clip at a point in viewer coordinates (`yUp: false`).
    private func hitTestClip(at point: CGPoint, in canvas: CGSize) -> Clip? {
        let t = Double(clock.frame) / max(1, model.project.fps)
        for track in model.project.videoTracks.reversed() where !track.hidden && !track.locked {
            let clips = model.project.clips.filter { $0.trackID == track.id && $0.kind != .audio && t >= $0.start && t < $0.end }
            for c in clips {
                if c.kind == .text {
                    let cx = CGFloat(c.text.x) * canvas.width
                    let cy = CGFloat(c.text.y) * canvas.height
                    let hit = CGRect(x: cx - canvas.width * 0.35, y: cy - 40, width: canvas.width * 0.7, height: 80)
                    if hit.contains(point) { return c }
                } else if c.isTransformable {
                    let tf = c.transform ?? ClipTransform()
                    guard tf.opacity > 0.001 else { continue }
                    let br = baseRect(for: c, in: canvas)
                    let cr = tf.croppedRect(in: br, yUp: false)
                    let inv = tf.affine(canvasSize: canvas, yUp: false).inverted()
                    let localPt = point.applying(inv)
                    if cr.insetBy(dx: -6, dy: -6).contains(localPt) { return c }
                }
            }
        }
        return nil
    }

    private func setTransform(_ id: UUID, _ body: @escaping (inout ClipTransform) -> Void) {
        model.liveVisual(autoCommit: false) { p in
            guard let i = p.index(of: id) else { return }
            var t = p.clips[i].transform ?? ClipTransform()
            body(&t)
            t.clampAll()
            p.clips[i].transform = t.isIdentity ? nil : t
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Clicking anywhere outside the video frame (margins/backdrop) clears the selection.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !model.selection.isEmpty { model.selection = [] }
                    }

                GeometryReader { geo in
                    let aspect = model.project.aspect
                    let fit = min(geo.size.width, geo.size.height * aspect)
                    // 100% is one frame pixel per screen pixel.
                    let scale = NSScreen.main?.backingScaleFactor ?? 2
                    let w = zoom.map { CGFloat(Double(model.project.width) * $0) / scale } ?? fit
                    let h = w / aspect
                    let viewer = picture(w: w, h: h).background(MagicAnchor(key: "viewer"))
                    if w <= geo.size.width + 0.5 && h <= geo.size.height + 0.5 {
                        ZStack {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if !model.selection.isEmpty { model.selection = [] }
                                }
                            viewer.position(x: geo.size.width / 2, y: geo.size.height / 2)
                        }
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            ZStack {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if !model.selection.isEmpty { model.selection = [] }
                                    }
                                viewer
                            }
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                        }
                        .scrollIndicators(.visible)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            .overlay(
                PreviewTrackpadBridge(
                    onMagnify: { mag, phase in handleTrackpadPinch(magnification: mag, phase: phase) },
                    onRotate: { deg, phase in handleTrackpadRotate(deltaDegrees: deg, phase: phase) },
                    onSmartMagnify: { handleTrackpadSmartMagnify() }
                )
            )

            // CapCut-style quick canvas bar when a visual transformable clip is selected.
            if let clip = activeTarget, clip.isTransformable, !model.viewerOnly {
                CanvasQuickBar(clip: clip, model: model)
                    .padding(.top, 6)
                    .padding(.horizontal, 16)
            }

            // The bar takes the whole space under the picture, so its controls sit in the middle of it.
            TransportBar(model: model, clock: model.clock, meters: model.meters, zoom: $zoom)
        }
        .background(model.viewerOnly ? Color.black : Theme.bg)
    }

    @ViewBuilder private func picture(w: CGFloat, h: CGFloat) -> some View {
        let canvasSize = CGSize(width: max(1, w), height: max(1, h))
        let clip = activeTarget
        ZStack(alignment: .topLeading) {
            PreviewSurfaceView(model: model)
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.ink.opacity(0.06)))

            // Magnetic alignment guide lines (shown while moving/aligning on canvas).
            if guides != SnapGuides() {
                Canvas { ctx, size in
                    let lineColor = Color(hex: 0x38BDF8).opacity(0.9)
                    let style = StrokeStyle(lineWidth: 1, dash: [4, 3])
                    if guides.centerX {
                        var p = Path(); p.move(to: CGPoint(x: size.width / 2, y: 0)); p.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                        ctx.stroke(p, with: .color(lineColor), style: style)
                    }
                    if guides.centerY {
                        var p = Path(); p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        ctx.stroke(p, with: .color(lineColor), style: style)
                    }
                    if guides.leftEdge {
                        var p = Path(); p.move(to: CGPoint(x: 1, y: 0)); p.addLine(to: CGPoint(x: 1, y: size.height))
                        ctx.stroke(p, with: .color(Color(hex: 0xF5C542)), lineWidth: 1.5)
                    }
                    if guides.rightEdge {
                        var p = Path(); p.move(to: CGPoint(x: size.width - 1, y: 0)); p.addLine(to: CGPoint(x: size.width - 1, y: size.height))
                        ctx.stroke(p, with: .color(Color(hex: 0xF5C542)), lineWidth: 1.5)
                    }
                    if guides.topEdge {
                        var p = Path(); p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: size.width, y: 1))
                        ctx.stroke(p, with: .color(Color(hex: 0xF5C542)), lineWidth: 1.5)
                    }
                    if guides.bottomEdge {
                        var p = Path(); p.move(to: CGPoint(x: 0, y: size.height - 1)); p.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                        ctx.stroke(p, with: .color(Color(hex: 0xF5C542)), lineWidth: 1.5)
                    }
                }
                .frame(width: w, height: h)
                .allowsHitTesting(false)
            }

            // CapCut-style direct-manipulation bounding box + 4 crop edges + 4 scale corners + rotation handle.
            if let c = clip, c.isTransformable, !model.isPlaying, source.current == nil, !model.viewerOnly {
                directManipulationOverlay(for: c, canvasSize: canvasSize)
            }

            // Live numeric HUD pill while dragging/scaling/cropping/rotating, or transient action toast.
            if let hud = hudText ?? model.statusToast {
                Text(hud)
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .overlay(Capsule().strokeBorder(Color(hex: 0x38BDF8).opacity(0.65), lineWidth: 1))
                    .position(x: w / 2, y: 22)
                    .allowsHitTesting(false)
            }

            // Nothing on the timeline yet: say how to start, and take a click as "import". Not while
            // a Media item is hovered: its frame is drawn underneath, by the player, once skimming rests.
            if model.project.clips.isEmpty, source.current == nil {
                EmptyViewerPrompt(hasMedia: !model.project.assets.isEmpty) { model.showImportPanel() }
                    .frame(width: w, height: h)
            }
            // A library item being hover-scrubbed shows here, labelled so it isn't mistaken for the edit.
            if let s = source.current {
                SourceFrame(current: s).frame(width: w, height: h)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .coordinateSpace(name: "viewer")
        .contentShape(Rectangle())
        .onTapGesture { loc in
            guard !model.project.clips.isEmpty, source.current == nil else { return }
            if let hit = hitTestClip(at: loc, in: canvasSize) {
                model.selection = [hit.id]
            } else {
                model.selection = []
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("viewer"))
                .onChanged { v in
                    // Auto-select clip under drag start if nothing (or a different clip) is selected.
                    if canvasDrag == nil, moveStart == nil, let hit = hitTestClip(at: v.startLocation, in: canvasSize) {
                        if !model.selection.contains(hit.id) {
                            model.selection = [hit.id]
                        }
                    }
                    guard let c = activeTarget else { return }
                    if c.kind == .text {
                        if moveStart == nil { moveStart = (c.text.x, c.text.y) }
                        guard let s = moveStart else { return }
                        var nx = min(1, max(0, s.x + Double(v.translation.width / canvasSize.width)))
                        var ny = min(1, max(0, s.y + Double(v.translation.height / canvasSize.height)))
                        var g = SnapGuides()
                        if abs((nx - 0.5) * Double(canvasSize.width)) < 6 { nx = 0.5; g.centerX = true }
                        if abs((ny - 0.5) * Double(canvasSize.height)) < 6 { ny = 0.5; g.centerY = true }
                        guides = g
                        hudText = String(format: "Title %.0f%%, %.0f%%", nx * 100, ny * 100)
                        model.liveVisual(autoCommit: false) { p in
                            if let i = p.index(of: c.id) {
                                p.clips[i].text.x = nx
                                p.clips[i].text.y = ny
                            }
                        }
                    } else if c.isTransformable {
                        handleTransformDrag(clip: c, handle: .body, value: v, canvasSize: canvasSize)
                    }
                }
                .onEnded { _ in
                    endCanvasDrag()
                }
        )
        .onChange(of: model.isPlaying) { _, playing in if playing { cancelCanvasDragIfActive() } }
        .onChange(of: model.selection) { _, _ in cancelCanvasDragIfActive() }
        .onChange(of: model.viewerOnly) { _, _ in cancelCanvasDragIfActive() }
        .onDisappear { cancelCanvasDragIfActive() }
    }

    private func cancelCanvasDragIfActive() {
        guard canvasDrag != nil || moveStart != nil || hudText != nil || guides != SnapGuides() else { return }
        endCanvasDrag()
    }

    @ViewBuilder
    private func directManipulationOverlay(for clip: Clip, canvasSize: CGSize) -> some View {
        let tf = clip.transform ?? ClipTransform()
        let br = baseRect(for: clip, in: canvasSize)
        let cr = tf.croppedRect(in: br, yUp: false)
        let m = tf.affine(canvasSize: canvasSize, yUp: false)

        let tl = CGPoint(x: cr.minX, y: cr.minY).applying(m)
        let tr = CGPoint(x: cr.maxX, y: cr.minY).applying(m)
        let brPt = CGPoint(x: cr.maxX, y: cr.maxY).applying(m)
        let bl = CGPoint(x: cr.minX, y: cr.maxY).applying(m)

        let topMid = CGPoint(x: (tl.x + tr.x) / 2, y: (tl.y + tr.y) / 2)
        let botMid = CGPoint(x: (bl.x + brPt.x) / 2, y: (bl.y + brPt.y) / 2)
        let leftMid = CGPoint(x: (tl.x + bl.x) / 2, y: (tl.y + bl.y) / 2)
        let rightMid = CGPoint(x: (tr.x + brPt.x) / 2, y: (tr.y + brPt.y) / 2)

        // Unit normal pointing "up" from the top edge for the rotation lollipop handle.
        // When the top edge is near the canvas top (e.g. default scale == 1), fold the handle inside
        // so it never clips into window chrome or ScrollView bounds.
        let topVec = CGPoint(x: tr.x - tl.x, y: tr.y - tl.y)
        let topLen = max(1, hypot(topVec.x, topVec.y))
        let upNormal = CGPoint(x: topVec.y / topLen, y: -topVec.x / topLen)
        let rawRot = CGPoint(x: topMid.x + upNormal.x * 26, y: topMid.y + upNormal.y * 26)
        let rotHandle: CGPoint = (rawRot.y < 14 || rawRot.x < 14 || rawRot.x > canvasSize.width - 14 || rawRot.y > canvasSize.height - 14)
            ? CGPoint(x: min(max(16, topMid.x - upNormal.x * 22), canvasSize.width - 16),
                      y: min(max(16, topMid.y - upNormal.y * 22), canvasSize.height - 16))
            : rawRot
        let isCropping: Bool = {
            if let h = canvasDrag?.handle {
                switch h { case .cropLeft, .cropRight, .cropTop, .cropBottom: return true; default: return false }
            }
            return false
        }()

        ZStack(alignment: .topLeading) {
            // Outline of full uncropped source frame while cropping (or when cropped) + crisp cropped box.
            Canvas { ctx, _ in
                if tf.hasCrop || isCropping {
                    let btl = CGPoint(x: br.minX, y: br.minY).applying(m)
                    let btr = CGPoint(x: br.maxX, y: br.minY).applying(m)
                    let bbr = CGPoint(x: br.maxX, y: br.maxY).applying(m)
                    let bbl = CGPoint(x: br.minX, y: br.maxY).applying(m)
                    var ghost = Path()
                    ghost.move(to: btl); ghost.addLine(to: btr); ghost.addLine(to: bbr); ghost.addLine(to: bbl); ghost.closeSubpath()
                    ctx.stroke(ghost, with: .color(Color.white.opacity(isCropping ? 0.45 : 0.2)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                var box = Path()
                box.move(to: tl); box.addLine(to: tr); box.addLine(to: brPt); box.addLine(to: bl); box.closeSubpath()
                ctx.stroke(box, with: .color(Color(hex: 0x38BDF8)), lineWidth: 1.5)

                var stem = Path()
                stem.move(to: topMid); stem.addLine(to: rotHandle)
                ctx.stroke(stem, with: .color(Color(hex: 0x38BDF8).opacity(0.9)), lineWidth: 1.2)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .allowsHitTesting(false)

            // 4 Edge Crop Handles (CapCut/Figma-style pills: drag inward/outward to crop directly!).
            edgeHandle(clip: clip, handle: .cropTop, at: topMid, angleDeg: tf.rotation, horizontal: true, canvasSize: canvasSize)
            edgeHandle(clip: clip, handle: .cropBottom, at: botMid, angleDeg: tf.rotation, horizontal: true, canvasSize: canvasSize)
            edgeHandle(clip: clip, handle: .cropLeft, at: leftMid, angleDeg: tf.rotation, horizontal: false, canvasSize: canvasSize)
            edgeHandle(clip: clip, handle: .cropRight, at: rightMid, angleDeg: tf.rotation, horizontal: false, canvasSize: canvasSize)

            // 4 Corner Scale Handles.
            cornerHandle(clip: clip, handle: .topLeft, at: tl, rotationDeg: tf.rotation, canvasSize: canvasSize)
            cornerHandle(clip: clip, handle: .topRight, at: tr, rotationDeg: tf.rotation, canvasSize: canvasSize)
            cornerHandle(clip: clip, handle: .bottomLeft, at: bl, rotationDeg: tf.rotation, canvasSize: canvasSize)
            cornerHandle(clip: clip, handle: .bottomRight, at: brPt, rotationDeg: tf.rotation, canvasSize: canvasSize)

            // Top Rotation Handle.
            let rotHot = hoveredHandle == .rotate || canvasDrag?.handle == .rotate
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color(hex: 0x38BDF8), lineWidth: 1.5))
                .overlay(Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.black))
                .frame(width: 18, height: 18)
                .scaleEffect(rotHot ? 1.18 : 1)
                .animation(.easeOut(duration: 0.1), value: rotHot)
                .shadow(color: .black.opacity(0.45), radius: 2)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .position(rotHandle)
                .onHover { hovering in
                    updateHandleHover(.rotate, hovering: hovering, rotationDeg: tf.rotation)
                }
                .onTapGesture {}
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("viewer"))
                        .onChanged { v in
                            CanvasCursors.rotate.set()
                            handleTransformDrag(clip: clip, handle: .rotate, value: v, canvasSize: canvasSize)
                        }
                        .onEnded { _ in endCanvasDrag() }
                )
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private func updateHandleHover(_ handle: CanvasHandle, hovering: Bool, rotationDeg: Double) {
        if hovering {
            hoveredHandle = handle
            CanvasCursors.cursor(for: handle, rotationDeg: rotationDeg).set()
        } else if hoveredHandle == handle {
            hoveredHandle = nil
            if canvasDrag == nil { NSCursor.arrow.set() }
        }
    }

    private func cornerHandle(clip: Clip, handle: CanvasHandle, at point: CGPoint, rotationDeg: Double, canvasSize: CGSize) -> some View {
        let hot = hoveredHandle == handle || canvasDrag?.handle == handle
        return Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color(hex: 0x38BDF8), lineWidth: 1.5))
            .frame(width: 12, height: 12)
            .scaleEffect(hot ? 1.25 : 1)
            .animation(.easeOut(duration: 0.1), value: hot)
            .shadow(color: .black.opacity(0.45), radius: 2)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .position(point)
            .help("Drag corner to resize")
            .onHover { hovering in
                updateHandleHover(handle, hovering: hovering, rotationDeg: rotationDeg)
            }
            .onTapGesture {}
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("viewer"))
                    .onChanged { v in
                        CanvasCursors.cursor(for: handle, rotationDeg: rotationDeg).set()
                        handleTransformDrag(clip: clip, handle: handle, value: v, canvasSize: canvasSize)
                    }
                    .onEnded { _ in endCanvasDrag() }
            )
    }

    private func edgeHandle(clip: Clip, handle: CanvasHandle, at point: CGPoint, angleDeg: Double, horizontal: Bool, canvasSize: CGSize) -> some View {
        let hot = hoveredHandle == handle || canvasDrag?.handle == handle
        return Capsule()
            .fill(Color(hex: 0xF5C542))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.7), lineWidth: 1))
            .frame(width: horizontal ? 24 : 6, height: horizontal ? 6 : 24)
            .rotationEffect(.degrees(angleDeg))
            .scaleEffect(hot ? 1.2 : 1)
            .animation(.easeOut(duration: 0.1), value: hot)
            .shadow(color: .black.opacity(0.45), radius: 2)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .position(point)
            .help("Drag edge to crop")
            .onHover { hovering in
                updateHandleHover(handle, hovering: hovering, rotationDeg: angleDeg)
            }
            .onTapGesture {}
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("viewer"))
                    .onChanged { v in
                        CanvasCursors.cursor(for: handle, rotationDeg: angleDeg).set()
                        handleTransformDrag(clip: clip, handle: handle, value: v, canvasSize: canvasSize)
                    }
                    .onEnded { _ in endCanvasDrag() }
            )
    }

    private func endCanvasDrag() {
        canvasDrag = nil
        moveStart = nil
        guides = SnapGuides()
        hudText = nil
        lastSnapScale100 = false
        lastSnapAngle = nil
        if let h = hoveredHandle, let c = activeTarget {
            CanvasCursors.cursor(for: h, rotationDeg: c.transform?.rotation ?? 0).set()
        } else {
            NSCursor.arrow.set()
        }
        model.commitLive()
    }

    // MARK: Native Mac Trackpad Gestures on Preview Canvas

    private func handleTrackpadPinch(magnification: Double, phase: NSEvent.Phase) {
        if let clip = activeTarget, clip.isTransformable, !model.isPlaying, source.current == nil {
            if phase == .began || gestureBaseScale == nil {
                gestureBaseScale = (clip.transform ?? ClipTransform()).scale
                lastSnapScale100 = abs((gestureBaseScale ?? 1) - 1.0) < 0.005
            }
            if phase == .ended || phase == .cancelled {
                gestureBaseScale = nil
                hudText = nil
                lastSnapScale100 = false
                model.commitLive()
                return
            }
            let cur = (clip.transform ?? ClipTransform()).scale
            var ns = (cur * (1 + magnification)).clamped(to: ClipTransform.scaleRange)
            let snapped = abs(ns - 1.0) < 0.02
            if snapped { ns = 1.0 }
            if snapped && !lastSnapScale100 { AppleHaptics.align() }
            lastSnapScale100 = snapped
            ns = (ns * 1000).rounded() / 1000
            hudText = String(format: "Scale %.0f%%", ns * 100)
            setTransform(clip.id) { $0.scale = ns }
        } else {
            // No clip selected: pinch smoothly zooms the viewer.
            guard phase != .ended, phase != .cancelled else { return }
            let base = zoom ?? 1.0
            let next = (base * (1 + magnification)).clamped(to: 0.25...3.0)
            let near100 = abs(next - 1.0) < 0.03
            if near100 && !lastSnapScale100 { AppleHaptics.align() }
            lastSnapScale100 = near100
            zoom = near100 ? 1.0 : next
        }
    }

    private func handleTrackpadRotate(deltaDegrees: Double, phase: NSEvent.Phase) {
        guard let clip = activeTarget, clip.isTransformable, !model.isPlaying, source.current == nil else { return }
        if phase == .began || gestureBaseRotation == nil {
            gestureBaseRotation = (clip.transform ?? ClipTransform()).rotation
            lastSnapAngle = nil
        }
        if phase == .ended || phase == .cancelled {
            gestureBaseRotation = nil
            hudText = nil
            lastSnapAngle = nil
            model.commitLive()
            return
        }
        // AppKit NSEvent.rotation is positive counter-clockwise; ClipTransform.rotation is clockwise.
        var deg = (gestureBaseRotation ?? 0) - deltaDegrees
        gestureBaseRotation = deg
        while deg > 180 { deg -= 360 }
        while deg < -180 { deg += 360 }
        var snappedAngle: Double?
        for snap in [-180.0, -135.0, -90.0, -45.0, 0.0, 45.0, 90.0, 135.0, 180.0] {
            if abs(deg - snap) < 3.5 { deg = snap; snappedAngle = snap; break }
        }
        if let sa = snappedAngle, sa != lastSnapAngle { AppleHaptics.align() }
        lastSnapAngle = snappedAngle
        deg = (deg * 10).rounded() / 10
        hudText = String(format: "Rotate %.1f°", deg)
        setTransform(clip.id) { $0.rotation = deg }
    }

    private func handleTrackpadSmartMagnify() {
        zoom = (zoom == nil) ? 1.0 : nil
        AppleHaptics.align()
    }

    private func handleTransformDrag(clip: Clip, handle: CanvasHandle, value: DragGesture.Value, canvasSize: CGSize) {
        if canvasDrag == nil || canvasDrag?.clipID != clip.id || canvasDrag?.handle != handle {
            let initial = clip.transform ?? ClipTransform()
            let br = baseRect(for: clip, in: canvasSize)
            let m = initial.affine(canvasSize: canvasSize, yUp: false)
            let center = CGPoint(x: canvasSize.width / 2 + initial.x * canvasSize.width,
                                 y: canvasSize.height / 2 + initial.y * canvasSize.height)
            let startAng = atan2(Double(value.startLocation.y - center.y), Double(value.startLocation.x - center.x))
            canvasDrag = CanvasDragState(clipID: clip.id, handle: handle, initial: initial,
                                         baseRect: br, initialAffine: m, startPoint: value.startLocation, startAngle: startAng)
        }
        guard let st = canvasDrag else { return }
        let w = Double(canvasSize.width), h = Double(canvasSize.height)
        let projW = Double(model.project.width), projH = Double(model.project.height)

        switch handle {
        case .body:
            var nx = st.initial.x + Double(value.translation.width) / w
            var ny = st.initial.y + Double(value.translation.height) / h
            var g = SnapGuides()
            let snapPx = 6.0
            if abs(nx * w) < snapPx { nx = 0; g.centerX = true }
            if abs(ny * h) < snapPx { ny = 0; g.centerY = true }
            // Edge snap when unrotated.
            if abs(st.initial.rotation) < 0.1 {
                var probe = st.initial; probe.x = nx; probe.y = ny
                let cr = probe.croppedRect(in: st.baseRect, yUp: false)
                let rect = cr.applying(probe.affine(canvasSize: canvasSize, yUp: false))
                if abs(rect.minX) < snapPx { nx -= Double(rect.minX) / w; g.leftEdge = true }
                else if abs(rect.maxX - canvasSize.width) < snapPx { nx -= Double(rect.maxX - canvasSize.width) / w; g.rightEdge = true }
                if abs(rect.minY) < snapPx { ny -= Double(rect.minY) / h; g.topEdge = true }
                else if abs(rect.maxY - canvasSize.height) < snapPx { ny -= Double(rect.maxY - canvasSize.height) / h; g.bottomEdge = true }
            }
            if (g.centerX && !guides.centerX) || (g.centerY && !guides.centerY)
                || (g.leftEdge && !guides.leftEdge) || (g.rightEdge && !guides.rightEdge)
                || (g.topEdge && !guides.topEdge) || (g.bottomEdge && !guides.bottomEdge) {
                AppleHaptics.align()
            }
            guides = g
            let pxX = (nx * projW).rounded(), pxY = (ny * projH).rounded()
            hudText = String(format: "Pos %.0f, %.0f", pxX, pxY)
            setTransform(clip.id) {
                $0.x = pxX / projW
                $0.y = pxY / projH
            }

        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let center = CGPoint(x: canvasSize.width / 2 + st.initial.x * canvasSize.width,
                                 y: canvasSize.height / 2 + st.initial.y * canvasSize.height)
            let d0 = max(10, hypot(st.startPoint.x - center.x, st.startPoint.y - center.y))
            let d1 = max(5, hypot(value.location.x - center.x, value.location.y - center.y))
            var ns = (st.initial.scale * Double(d1 / d0)).clamped(to: ClipTransform.scaleRange)
            let snapped100 = abs(ns - 1.0) < 0.025
            if snapped100 { ns = 1.0 }
            if snapped100 && !lastSnapScale100 { AppleHaptics.align() }
            lastSnapScale100 = snapped100
            ns = (ns * 1000).rounded() / 1000
            guides = SnapGuides()
            hudText = String(format: "Scale %.0f%%", ns * 100)
            setTransform(clip.id) { $0.scale = ns }

        case .rotate:
            let center = CGPoint(x: canvasSize.width / 2 + st.initial.x * canvasSize.width,
                                 y: canvasSize.height / 2 + st.initial.y * canvasSize.height)
            let ang = atan2(Double(value.location.y - center.y), Double(value.location.x - center.x))
            var deg = st.initial.rotation + (ang - st.startAngle) * 180.0 / .pi
            while deg > 180 { deg -= 360 }
            while deg < -180 { deg += 360 }
            var snappedAngle: Double?
            for snap in [-180.0, -135.0, -90.0, -45.0, 0.0, 45.0, 90.0, 135.0, 180.0] {
                if abs(deg - snap) < 4.0 { deg = snap; snappedAngle = snap; break }
            }
            if let sa = snappedAngle, sa != lastSnapAngle { AppleHaptics.align() }
            lastSnapAngle = snappedAngle
            deg = (deg * 10).rounded() / 10
            guides = SnapGuides()
            hudText = String(format: "Rotate %.1f°", deg)
            setTransform(clip.id) { $0.rotation = deg }

        case .cropLeft, .cropRight, .cropTop, .cropBottom:
            // Project drag into clip's un-transformed local space (works accurately even when rotated & scaled!).
            let inv = st.initialAffine.inverted()
            let p0 = st.startPoint.applying(inv)
            let p1 = value.location.applying(inv)
            let dx = Double(p1.x - p0.x) / max(1, Double(st.baseRect.width))
            let dy = Double(p1.y - p0.y) / max(1, Double(st.baseRect.height))
            var l = st.initial.cropLeft, r = st.initial.cropRight
            var t = st.initial.cropTop, b = st.initial.cropBottom
            switch handle {
            case .cropLeft: l = (st.initial.cropLeft + dx).clamped(to: 0...(max(0, 0.95 - r)))
            case .cropRight: r = (st.initial.cropRight - dx).clamped(to: 0...(max(0, 0.95 - l)))
            case .cropTop: t = (st.initial.cropTop + dy).clamped(to: 0...(max(0, 0.95 - b)))
            case .cropBottom: b = (st.initial.cropBottom - dy).clamped(to: 0...(max(0, 0.95 - t)))
            default: break
            }
            l = (l * 1000).rounded() / 1000
            r = (r * 1000).rounded() / 1000
            t = (t * 1000).rounded() / 1000
            b = (b * 1000).rounded() / 1000
            guides = SnapGuides()
            hudText = String(format: "Crop L:%.0f%% R:%.0f%% T:%.0f%% B:%.0f%%", l * 100, r * 100, t * 100, b * 100)
            setTransform(clip.id) {
                $0.cropLeft = l
                $0.cropRight = r
                $0.cropTop = t
                $0.cropBottom = b
            }
        }
    }
}

/// Compact CapCut-style quick action bar beneath the viewer when a visual clip is selected.
private struct CanvasQuickBar: View {
    let clip: Clip
    @ObservedObject var model: EditorModel

    private var tf: ClipTransform { clip.transform ?? ClipTransform() }

    private func apply(_ body: @escaping (inout ClipTransform) -> Void) {
        model.mutate { p in
            guard let i = p.index(of: clip.id) else { return }
            var t = p.clips[i].transform ?? ClipTransform()
            body(&t)
            t.clampAll()
            p.clips[i].transform = t.isIdentity ? nil : t
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "crop")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0xF5C542))
            Text("Drag edges to crop · corners to scale")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            Spacer(minLength: 8)
            if clip.kind == .video || clip.kind == .image {
                let isPersonOrSubject = clip.bgRemoval != nil && clip.bgRemoval?.mode != .aiCard
                let isCard = clip.bgRemoval?.mode == .aiCard
                quickBtn(symbol: "person.and.background.dotted", label: "Remove BG", active: isPersonOrSubject) {
                    model.mutate { p in
                        guard let i = p.index(of: clip.id) else { return }
                        if isPersonOrSubject {
                            p.clips[i].bgRemoval = nil
                        } else {
                            p.clips[i].bgRemoval = BackgroundRemoval(mode: p.clips[i].kind == .video ? .aiPerson : .aiSubject)
                        }
                    }
                    AppleHaptics.click()
                }
                quickBtn(symbol: "doc.text.viewfinder", label: "Keep Card", active: isCard) {
                    model.mutate { p in
                        guard let i = p.index(of: clip.id) else { return }
                        if isCard {
                            p.clips[i].bgRemoval = nil
                        } else {
                            p.clips[i].bgRemoval = BackgroundRemoval(mode: .aiCard, tolerance: 0.5, softness: 0.04)
                        }
                    }
                    AppleHaptics.click()
                }
                let polished = clip.style != nil
                quickBtn(symbol: "sparkles.rectangle.stack", label: "Polish", active: polished) {
                    model.mutate { p in
                        guard let i = p.index(of: clip.id) else { return }
                        p.clips[i].style = polished ? nil : .cardPolish
                    }
                    AppleHaptics.click()
                }
                quickBtn(symbol: "faceid", label: "Face Track", active: false) {
                    Task { await model.autoReframeFaces(clipIDs: [clip.id]) }
                }
            }
            quickBtn(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Flip H", active: tf.flipH) {
                apply { $0.flipH.toggle() }
            }
            quickBtn(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", label: "Flip V", active: tf.flipV) {
                apply { $0.flipV.toggle() }
            }
            quickBtn(symbol: "circle.dashed", label: tf.maskShape == .circle ? "Circle" : "Round", active: tf.hasMask) {
                apply {
                    if !$0.hasMask {
                        $0.maskShape = .roundedRect
                        $0.cornerRadius = 0.12
                    } else if $0.maskShape == .roundedRect {
                        $0.maskShape = .circle
                    } else {
                        $0.maskShape = .none
                        $0.cornerRadius = 0
                        $0.maskFeather = 0
                    }
                }
            }
            if tf.hasCrop {
                quickBtn(symbol: "crop", label: "Reset Crop", active: false) {
                    apply { $0.cropLeft = 0; $0.cropRight = 0; $0.cropTop = 0; $0.cropBottom = 0 }
                }
            }
            if !tf.isIdentity {
                quickBtn(symbol: "arrow.counterclockwise", label: "Reset", active: false) {
                    model.mutate { p in
                        if let i = p.index(of: clip.id) { p.clips[i].transform = nil }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink.opacity(0.08)))
    }

    private func quickBtn(symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(active ? Color.black : Theme.textDim)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(active ? Color(hex: 0xF5C542) : Theme.raised))
        }
        .buttonStyle(.plain)
    }
}

struct TransportBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clock: Clock
    /// Redraws the times when Show time as changes.
    @ObservedObject private var themes = ThemeStore.shared
    let meters: MeterState
    @Binding var zoom: Double?

    private static let zooms: [(String, Double?)] = [("Fit", nil), ("25%", 0.25), ("50%", 0.5), ("100%", 1), ("200%", 2)]

    var body: some View {
        let fps = model.project.fps
        HStack(alignment: .center, spacing: 10) {
            // Left: current timecode + total duration (never overlaps transport buttons on narrow windows).
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TimecodeField(time: Double(clock.frame) / fps, fps: fps) { model.seek(to: $0) }
                Text("/ " + Timecode.string(model.project.duration, fps: fps))
                    .font(Theme.mono(11, .regular))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Center: playback controls.
            HStack(alignment: .center, spacing: 4) {
                IconButton(symbol: "backward.end.fill", size: 30, help: "Previous Edit (↑ or ⇧←)") { model.jumpToEdit(forward: false) }
                IconButton(symbol: "backward.frame.fill", size: 30, help: "Back One Frame (←)") { model.step(frames: -1) }
                PlayButton(playing: model.isPlaying) { model.togglePlay() }
                    .padding(.horizontal, 8)
                IconButton(symbol: "forward.frame.fill", size: 30, help: "Forward One Frame (→)") { model.step(frames: 1) }
                IconButton(symbol: "forward.end.fill", size: 30, help: "Next Edit (↓ or ⇧→)") { model.jumpToEdit(forward: true) }
            }
            .fixedSize()

            // Right: loop, meters, zoom, fullscreen.
            HStack(alignment: .center, spacing: 8) {
                IconButton(symbol: "repeat", active: model.loop, size: 28, help: "Loop Playback (L)") { model.loop.toggle() }
                HStack(spacing: 2) {
                    LevelMeter(meters: meters, side: .left).frame(width: 4)
                    LevelMeter(meters: meters, side: .right).frame(width: 4)
                }
                .frame(height: 24)
                .padding(.horizontal, 4)
                .help("Output level, left and right")
                Menu {
                    ForEach(Self.zooms, id: \.0) { item in
                        Button(item.0) { zoom = item.1 }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.zooms.first { $0.1 == zoom }?.0 ?? "Fit")
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
                    }
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Viewer zoom")
                IconButton(symbol: "camera", size: 28, help: "Export Current Frame as PNG") {
                    Task { await model.snapshotCurrentFrame() }
                }
                IconButton(symbol: model.viewerOnly ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           size: 28, help: model.viewerOnly ? "Exit Full Screen (F or Esc)" : "Full Screen Viewer (F)") {
                    model.toggleViewerFullScreen()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
    }
}

/// A library item's frame filling the viewer, with its name and source time in the corner.
private struct SourceFrame: View {
    let current: SourcePreviewState.Current
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        let a = current.asset
        let fps = a.fps > 1 ? a.fps : 30
        ZStack(alignment: .topLeading) {
            // Until its first frame is decoded, the viewer's own picture stays showing underneath
            // rather than going black.
            if let img = current.image {
                Color.black
                Image(decorative: img, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                // Trimming a clip's edge: just the time (the clip is the one being dragged).
                if current.note == nil { Text(a.name).font(.system(size: 11.5, weight: .semibold)) }
                Text(Timecode.string(current.time, fps: fps)).font(Theme.mono(11.5, .regular))
                    .foregroundStyle(Color(hex: current.note == nil ? 0x9A9A96 : 0xF2F2F0))
            }
            // On the picture, so light type in every theme.
            .foregroundStyle(Color(hex: 0xF2F2F0))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.65)))
            .padding(10)
        }
        // The whole viewer, label in its top-left corner, also when the picture is drawn underneath by the
        // player (scrub frames) rather than here.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// What the viewer shows on an empty timeline: a dashed drop area with a film frame and an arrow.
private struct EmptyViewerPrompt: View {
    let hasMedia: Bool
    let onImport: () -> Void
    @State private var hovering = false

    /// The viewer is black in every theme, so on Light this uses Dark's colours, not Light's dark ones.
    private var p: Palette { Theme.current.isLight ? AppTheme.dark.palette : Theme.p }

    var body: some View {
        let text = Color(hex: p.text), faint = Color(hex: p.textFaint)
        GeometryReader { g in
            VStack(spacing: 16) {
                Canvas { ctx, size in
                    let s = size.width / 74
                    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * s, y: y * s, width: w * s, height: h * s) }
                    var frame = Path(roundedRect: r(1, 9, 58, 40), cornerRadius: 5 * s)
                    for y: CGFloat in [17, 41] { frame.move(to: CGPoint(x: 1 * s, y: y * s)); frame.addLine(to: CGPoint(x: 59 * s, y: y * s)) }
                    for x: CGFloat in [9, 19, 29, 39, 49] {
                        frame.move(to: CGPoint(x: x * s, y: 9 * s)); frame.addLine(to: CGPoint(x: x * s, y: 17 * s))
                        frame.move(to: CGPoint(x: x * s, y: 41 * s)); frame.addLine(to: CGPoint(x: x * s, y: 49 * s))
                    }
                    let style = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                    ctx.stroke(frame, with: .color(faint), style: style)
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: 66 * s, y: 4 * s)); arrow.addLine(to: CGPoint(x: 66 * s, y: 24 * s))
                    arrow.move(to: CGPoint(x: 59 * s, y: 17 * s)); arrow.addLine(to: CGPoint(x: 66 * s, y: 24 * s)); arrow.addLine(to: CGPoint(x: 73 * s, y: 17 * s))
                    ctx.stroke(arrow, with: .color(text), style: style)
                }
                .frame(width: 96, height: 70)
                Text(hasMedia ? "Drag media from the library to the timeline" : "Drop video, audio or images anywhere")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(text)
                Text(hasMedia ? "or double-click it to add it at the playhead"
                              : "or press ⌘I to import  ·  MP4, MOV, MKV, WebM, WAV, MP3, JPG, PNG")
                    .font(.system(size: 11.5))
                    .foregroundStyle(faint)
            }
            .frame(width: g.size.width * 0.62, height: g.size.height * 0.58)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(hovering ? Color(hex: p.ink).opacity(0.3) : Color(hex: p.outline))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onTapGesture { if !hasMedia { onImport() } }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// The current time. Click it to type a time to jump to: Return or clicking away goes there, Esc cancels.
private struct TimecodeField: View {
    let time: Double
    let fps: Double
    let onJump: (Double) -> Void
    @ObservedObject private var themes = ThemeStore.shared
    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused, editing { commit() }
                    }
            } else {
                Text(Timecode.string(time, fps: fps))
            }
        }
        .font(Theme.mono(16, .medium))
        .kerning(0.3)
        .foregroundStyle(Theme.text)
        .fixedSize()
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(editing || hovering ? Theme.field : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.text.opacity(editing ? 0.85 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture {
            guard !editing else { return }
            text = Timecode.string(time, fps: fps)
            editing = true
            focused = true
        }
        .padding(.leading, -7)
        .help("Click to type a time")
    }

    private func commit() {
        if let t = Timecode.parse(text, fps: fps) { onJump(t) }
        editing = false
    }
}

private struct PlayButton: View {
    let playing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.onText)
                .offset(x: playing ? 0 : 1.5)
                .frame(width: 46, height: 46)
                .background(Circle().fill(hovering ? Theme.ink : Theme.text))
                // A dark ring sets it off from the bar.
                .padding(5)
                .background(Circle().fill(Theme.transport).overlay(Circle().strokeBorder(Theme.ink.opacity(0.05))))
                .scaleEffect(hovering ? 1.05 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Play / Pause (Space)")
    }
}

/// Crisp native-style double-headed diagonal, vertical, horizontal, and rotation cursors
/// for direct manipulation on the preview canvas (automatically rotated with the clip).
@MainActor
private enum CanvasCursors {
    private static var cache: [Int: NSCursor] = [:]

    static func cursor(for handle: PreviewView.CanvasHandle, rotationDeg: Double) -> NSCursor {
        switch handle {
        case .body:
            return .openHand
        case .rotate:
            return rotate
        case .topLeft, .bottomRight:
            return resize(angleDeg: 135 - rotationDeg)
        case .topRight, .bottomLeft:
            return resize(angleDeg: 45 - rotationDeg)
        case .cropTop, .cropBottom:
            return resize(angleDeg: 90 - rotationDeg)
        case .cropLeft, .cropRight:
            return resize(angleDeg: -rotationDeg)
        }
    }

    /// Double-headed arrow cursor at any angle (quantized to 15° steps and cached).
    /// `0°` = horizontal ↔, `45°` = diagonal ↗↙, `90°` = vertical ↕, `135°` = diagonal ↖↘.
    static func resize(angleDeg: Double) -> NSCursor {
        let norm = ((angleDeg.truncatingRemainder(dividingBy: 180)) + 180).truncatingRemainder(dividingBy: 180)
        let bucket = (Int((norm / 15).rounded()) * 15) % 180
        if let hit = cache[bucket] { return hit }

        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: CGFloat(bucket) * .pi / 180)

            // Double-headed arrow along the X axis (-9...+9), black fill with crisp white outline.
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -9.0, y: 0))
            p.addLine(to: CGPoint(x: -4.2, y: 4.5))
            p.addLine(to: CGPoint(x: -4.2, y: 1.5))
            p.addLine(to: CGPoint(x: 4.2, y: 1.5))
            p.addLine(to: CGPoint(x: 4.2, y: 4.5))
            p.addLine(to: CGPoint(x: 9.0, y: 0))
            p.addLine(to: CGPoint(x: 4.2, y: -4.5))
            p.addLine(to: CGPoint(x: 4.2, y: -1.5))
            p.addLine(to: CGPoint(x: -4.2, y: -1.5))
            p.addLine(to: CGPoint(x: -4.2, y: -4.5))
            p.closeSubpath()

            ctx.setShadow(offset: CGSize(width: 0, height: -0.8), blur: 1.5, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addPath(p)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.4)
            ctx.setLineJoin(.round)
            ctx.strokePath()

            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(p)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()

            ctx.restoreGState()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
        cache[bucket] = cursor
        return cursor
    }

    static let rotate: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
            guard let sym = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg),
                  let whiteCfg = Optional(NSImage.SymbolConfiguration(pointSize: 15, weight: .black)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))),
                  let halo = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
                    .withSymbolConfiguration(whiteCfg) else { return false }
            let hs = halo.size
            halo.draw(in: NSRect(x: rect.midX - hs.width / 2, y: rect.midY - hs.height / 2, width: hs.width, height: hs.height))
            let s = sym.size
            sym.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
}

/// Transparent AppKit gesture bridge that forwards native Mac Multi-Touch trackpad gestures
/// (pinch `.magnify`, two-finger twist `.rotate`, two-finger double-tap `.smartMagnify`)
/// whenever the pointer is over the Preview Canvas, without interfering with clicks or drags.
private struct PreviewTrackpadBridge: NSViewRepresentable {
    var onMagnify: (Double, NSEvent.Phase) -> Void
    var onRotate: (Double, NSEvent.Phase) -> Void
    var onSmartMagnify: () -> Void

    func makeNSView(context: Context) -> TrackpadMonitorView {
        let v = TrackpadMonitorView()
        v.onMagnify = onMagnify
        v.onRotate = onRotate
        v.onSmartMagnify = onSmartMagnify
        return v
    }

    func updateNSView(_ nsView: TrackpadMonitorView, context: Context) {
        nsView.onMagnify = onMagnify
        nsView.onRotate = onRotate
        nsView.onSmartMagnify = onSmartMagnify
    }

    final class TrackpadMonitorView: NSView {
        var onMagnify: ((Double, NSEvent.Phase) -> Void)?
        var onRotate: ((Double, NSEvent.Phase) -> Void)?
        var onSmartMagnify: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .rotate, .smartMagnify]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let win = self.window, event.window === win else { return event }
                    let local = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(local) else { return event }
                    switch event.type {
                    case .magnify:
                        self.onMagnify?(Double(event.magnification), event.phase)
                        return nil
                    case .rotate:
                        self.onRotate?(Double(event.rotation), event.phase)
                        return nil
                    case .smartMagnify:
                        self.onSmartMagnify?()
                        return nil
                    default:
                        return event
                    }
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { removeMonitor() }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
