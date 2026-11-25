import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InspectorView: View {
    static let width: CGFloat = 320

    @ObservedObject var model: EditorModel
    @State private var speedOrigin: [Clip]?
    @State private var rampOrigin: [Clip]?
    /// Where the playhead was before a ramp dot's drag moved it to the dot; put back when the drag ends.
    @State private var rampPlayhead: Double?

    private var selected: [Clip] {
        model.project.clips.filter { model.selection.contains($0.id) }
    }

    var body: some View {
        let clips = selected
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Group {
                    if !clips.isEmpty, clips.allSatisfy({ $0.kind == .solid }) {
                        SolidIcon().frame(width: 15, height: 11)
                    } else {
                        Image(systemName: headerSymbol(clips)).font(.system(size: 12, weight: .medium))
                    }
                }
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 18)
                Text(title(clips))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if clips.isEmpty, showsCaptions {
                        captionSection
                    } else if clips.isEmpty {
                        sequenceSection
                    } else {
                        clipSections(clips)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 18)
            }
        }
        .background(Theme.panel)
    }

    private func primary(_ clips: [Clip]) -> Clip? {
        clips.first { $0.kind != .audio } ?? clips.first
    }

    /// Captions picked, or the caption track's header clicked.
    private var showsCaptions: Bool {
        model.project.captions != nil && (model.captionsFocused || !model.captionSelection.isEmpty)
    }

    private func title(_ clips: [Clip]) -> String {
        if clips.isEmpty, showsCaptions {
            let n = model.captionSelection.count
            return n > 1 ? "\(n) captions" : n == 1 ? "Caption" : "Captions"
        }
        if clips.isEmpty { return "Sequence" }
        let groups = Set(clips.map { $0.linkID ?? $0.id })
        if groups.count == 1, let c = primary(clips) { return model.project.name(of: c) }
        return "\(clips.count) clips"
    }

    private func headerSymbol(_ clips: [Clip]) -> String {
        if clips.isEmpty, showsCaptions { return "captions.bubble" }
        guard let c = primary(clips) else { return "rectangle.on.rectangle" }
        if Set(clips.map { $0.linkID ?? $0.id }).count > 1 { return "square.stack" }
        switch c.kind {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .text: return "textformat"
        case .solid: return "square.fill"
        }
    }

    // MARK: Captions

    /// The picked caption's words, to retype, and the style every caption shares.
    @ViewBuilder private var captionSection: some View {
        let blocks = model.captionBlocks
        let picked = blocks.filter { model.captionSelection.contains($0.id) }
        if let track = model.project.captions {
            if picked.count == 1, let b = picked.first {
                InspectorSection("Caption") {
                    CaptionTextField(model: model, block: b)
                    Text("Fixed here, a word stays fixed wherever this clip is used. Delete leaves the caption's words out.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            InspectorSection("Style") {
                // 1-click viral/broadcast caption presets
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(CaptionPreset.allCases, id: \.self) { preset in
                            Chip(label: preset.label, active: false) {
                                model.setCaptionStyle { $0.apply(preset: preset) }
                                AppleHaptics.click()
                            }
                        }
                    }
                }
                ParamRow(icon: .symbol("textformat.size"), label: "Size", value: track.style.size, range: CaptionStyle.sizeRange,
                         format: { "\(Int($0.rounded()))" },
                         onEditing: { if !$0 { model.commitLive() } },
                         onChange: { v in model.setCaptionStyle(live: true) { $0.size = v.rounded() } })
                ParamRow(icon: .symbol("arrow.up.and.down"), label: "Position", value: track.style.y * 100, range: 10...95,
                         format: { "\(Int($0.rounded()))%" },
                         onEditing: { if !$0 { model.commitLive() } },
                         onChange: { v in model.setCaptionStyle(live: true) { $0.y = (v / 100 * 1000).rounded() / 1000 } })
                captionColorRow("Text", icon: "textformat", on: nil, color: track.style.textColor) { s, c in s.textColor = c }
                captionColorRow("Word highlight", icon: "highlighter", on: track.style.highlight, color: track.style.highlightColor,
                                toggle: { $0.highlight.toggle() }) { s, c in s.highlightColor = c }
                captionColorRow("Outline", icon: "a.square", on: track.style.outline, color: track.style.outlineColor,
                                toggle: { $0.outline.toggle() }) { s, c in s.outlineColor = c }
                captionColorRow("Box pill", icon: "rectangle.fill", on: track.style.boxColor != nil,
                                color: track.style.boxColor ?? RGBA(r: 0, g: 0, b: 0, a: 0.78),
                                toggle: { $0.boxColor = $0.boxColor == nil ? RGBA(r: 0, g: 0, b: 0, a: 0.78) : nil }) { s, c in
                    s.boxColor = RGBA(r: c.r, g: c.g, b: c.b, a: 0.82)
                }
                HStack(spacing: 8) {
                    Chip(label: "ALL CAPS", active: track.style.uppercase) {
                        model.setCaptionStyle { $0.uppercase.toggle() }
                    }
                    Chip(label: "Shadow", active: track.style.shadow) {
                        model.setCaptionStyle { $0.shadow.toggle() }
                    }
                    Spacer()
                }
                if model.captionsWaiting {
                    Text("Listening for what's said in the captioned clips…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
    }

    /// A caption colour: its well, and for a part that can be off (highlight, outline) a chip to turn it on.
    private func captionColorRow(_ label: String, icon: String, on: Bool?, color: RGBA, toggle: ((inout CaptionStyle) -> Void)? = nil,
                                 set: @escaping (inout CaptionStyle, RGBA) -> Void) -> some View {
        // Laid out like the slider rows above: icon, name, then the controls on the right.
        HStack(spacing: 8) {
            RowIconView(icon: .symbol(icon))
                .foregroundStyle(on == false ? Theme.textFaint : Theme.textDim)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(on == false ? Theme.textFaint : Theme.text)
            Spacer()
            // Highlight and outline: an eye beside the colour, to show or hide them.
            if let on, let toggle {
                CaptionEye(on: on) { model.setCaptionStyle(toggle) }
            }
            ColorField(color: color) { c in model.setCaptionStyle(live: true, settles: true) { set(&$0, c) } }
                .frame(width: 44)
                .opacity(on == false ? 0.4 : 1)
        }
    }

    // MARK: Sequence

    private static let sizes: [(String, Int, Int)] = [
        ("4K  3840 × 2160", 3840, 2160),
        ("1440p  2560 × 1440", 2560, 1440),
        ("1080p  1920 × 1080", 1920, 1080),
        ("720p  1280 × 720", 1280, 720),
        ("Vertical  1080 × 1920", 1080, 1920),
        ("Vertical 4K  2160 × 3840", 2160, 3840),
        ("Square  1080 × 1080", 1080, 1080),
    ]

    @ViewBuilder private var sequenceSection: some View {
        let p = model.project
        InspectorSection("Frame") {
            MenuField(label: "\(p.width) × \(p.height)") {
                ForEach(Self.sizes, id: \.0) { item in
                    Button(item.0) { model.setSequence(width: item.1, height: item.2) }
                }
            }
            FrameSizeFields(width: p.width, height: p.height) { w, h in
                model.setSequence(width: w, height: h)
            }
        }
        InspectorSection("Frame rate") {
            MenuField(label: Self.fpsLabel(p.fps)) {
                ForEach(EditorModel.frameRates, id: \.self) { rate in
                    Button(Self.fpsLabel(rate)) { model.setFPS(rate) }
                }
            }
            if !p.settingsLocked && !p.assets.contains(where: { $0.kind == .video }) {
                Text("Matches the first video you import.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        if !p.clips.isEmpty {
            InspectorSection("Smart Macros") {
                HStack(spacing: 6) {
                    Chip(label: "News Reel 9:16", active: false) {
                        Task { await model.applyNewsReelMacro() }
                    }
                    Chip(label: "Cut Silences", active: false) {
                        _ = model.removeSilences(clipIDs: [])
                    }
                    Spacer()
                }
                Text("News Reel 9:16 switches to vertical, face-tracks V1, isolates & polishes V2 cards, enhances A1 voice, and cuts silences.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func fpsLabel(_ fps: Double) -> String {
        (abs(fps - fps.rounded()) < 0.001 ? String(Int(fps)) : String(format: "%.2f", fps)) + " fps"
    }

    // MARK: Clips

    @ViewBuilder private func clipSections(_ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let visual = clips.filter { $0.kind != .audio }
        let audio = clips.filter { $0.kind == .audio }
        let sourced = clips.filter { $0.playsSource }
        let offSpeed = sourced.first.map { abs($0.speed - 1) > 0.001 } ?? false
        let offGain = audio.first.map { abs($0.gainDB) > 0.001 } ?? false

        // What a title or a solid is comes first: its words, or its colour.
        if clips.count == 1, let c = clips.first {
            if c.kind == .text { textSection(c) }
            if c.kind == .solid {
                // Named for the clip, like Text; Fill is its colour, as a row like the others.
                InspectorSection("Solid") {
                    HStack(spacing: 8) {
                        RowIconView(icon: .symbol("paintbrush"))
                            .foregroundStyle(Theme.textDim)
                            .frame(width: 18)
                        Text("Fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        ColorPicker("", selection: Binding(get: { c.color.color }, set: { color in
                            model.liveVisual(autoCommit: true) { p in
                                if let i = p.index(of: c.id) { p.clips[i].color = RGBA(color) }
                            }
                        }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }
        }

        if sourced.first != nil || audio.first != nil {
            let ramped = sourced.first?.isRamped ?? false
            // Like the other sections: Reset puts the whole section back (speed, ramp and volume).
            InspectorSection("Playback", action: offSpeed || ramped || offGain ? ("Reset", { model.resetPlayback(volume: Set(audio.map(\.id))) }) : nil,
                             marked: offSpeed || ramped || offGain) {
                if let first = audio.first {
                    let audioIDs = Set(audio.map(\.id))
                    let enhanced = audio.allSatisfy { $0.voiceEnhance == true }
                    ParamRow(icon: .symbol("speaker.wave.2"), label: "Volume",
                             value: first.gainDB, range: -60...12, format: formatDB,
                             onEditing: { if !$0 { model.commitLive() } },
                             onChange: { v in
                                 model.live(autoCommit: false) { p in
                                     for i in p.clips.indices where audioIDs.contains(p.clips[i].id) { p.clips[i].gainDB = (v * 10).rounded() / 10 }
                                 }
                             })
                    HStack(spacing: 6) {
                        Chip(label: enhanced ? "Voice Enhance ON" : "Voice Enhance", active: enhanced) {
                            model.mutate { p in
                                for i in p.clips.indices where audioIDs.contains(p.clips[i].id) {
                                    p.clips[i].voiceEnhance = enhanced ? nil : true
                                }
                            }
                            AppleHaptics.click()
                        }
                        Chip(label: "Cut Silences", active: false) {
                            _ = model.removeSilences(clipIDs: audioIDs)
                        }
                        Spacer()
                    }
                }
                if let first = sourced.first {
                    ParamRow(icon: .symbol("clock.arrow.circlepath"), label: "Speed",
                             value: first.speed * 100, range: 10...5000, logarithmic: true,
                             format: { "\(Int($0.rounded()))%" },
                             onEditing: { began in
                                 if began {
                                     speedOrigin = model.project.clips
                                 } else {
                                     speedOrigin = nil
                                     model.commitLive()
                                 }
                             },
                             onChange: { applySpeed($0 / 100, ids: ids) },
                             inside: AnyView(RampButton(on: ramped) { toggleRamp(first, ids: ids) }))
                    // The ramp, while the clip has one (kept up mid-drag, even if a dot is pulled back out).
                    if ramped || rampOrigin != nil {
                        SpeedRampGraph(clip: first, fps: model.project.fps, onEditing: { began in
                            if began {
                                rampOrigin = model.project.clips
                            } else {
                                rampOrigin = nil
                                model.commitLive()
                                if let back = rampPlayhead {
                                    rampPlayhead = nil
                                    model.seek(to: back)
                                }
                            }
                        }, onChange: { shape, focus in
                            guard let origin = rampOrigin else { return }
                            let sticky = model.sticky
                            model.live(autoCommit: false) { p in
                                p.clips = origin
                                p.setRamp(ids: p.linked(ids), speed: shape.mid, points: (shape.p1, shape.p2, shape.p3, shape.p4),
                                          start: shape.start, end: shape.end, sticky: sticky)
                            }
                            // The playhead and viewer follow the dot being dragged, to show the frame it's on
                            // (never while playing, which would stop playback).
                            if let focus, !model.isPlaying, let c = model.project.clips.first(where: { $0.id == first.id }) {
                                if rampPlayhead == nil { rampPlayhead = model.playhead }
                                model.scrub(to: SpeedRampGraph.time(of: focus, in: c))
                            }
                        }, onSet: { shape in
                            let sticky = model.sticky
                            model.mutate { p in
                                p.setRamp(ids: p.linked(ids), speed: shape.mid, points: (shape.p1, shape.p2, shape.p3, shape.p4),
                                          start: shape.start, end: shape.end, sticky: sticky)
                            }
                        })
                        .transition(.opacity)
                    }
                }
            }
        }

        let movable = visual.filter(\.isTransformable)
        if !movable.isEmpty {
            transformSection(movable)
            cropMaskSection(movable)
        } else if visual.count == 1, visual[0].kind == .text {
            textTransformSection(visual[0])
        }
        let cuttable = visual.filter { $0.kind == .video || $0.kind == .image }
        if !cuttable.isEmpty {
            backgroundRemovalSection(cuttable)
        }
        if !movable.isEmpty {
            styleAndMotionSection(movable)
            newsAndEffectsSection(movable)
        }
        if visual.count == 1 { transitionSection(visual[0]) }
        if !visual.isEmpty { fadeSection(audio.isEmpty ? "Fade" : "Video fade", visual) }
        if !audio.isEmpty { fadeSection(visual.isEmpty ? "Fade" : "Audio fade", audio) }
        if !visual.isEmpty { colorSection(visual) }

    }

    /// The ramp button: on, a starter ramp (100%, easing into the speed in the middle of the clip,
    /// back to 100%; a dip to 50% if the speed is 100%); off, the ramp goes and the speed stays.
    private func toggleRamp(_ clip: Clip, ids: Set<UUID>) {
        let group = model.project.linked(ids)
        let sticky = model.sticky
        if clip.isRamped {
            model.mutate { p in p.retime(ids: group, sticky: sticky) { $0.ramp = nil } }
        } else {
            let mid = abs(clip.speed - 1) < 0.001 ? 0.5 : clip.speed
            // In the shape last picked on the graph: easing in and back out, or just in (2-point).
            let points = SpeedRampGraph.twoPoint ? (0.3, 0.6, 1.0, 1.0) : (0.3, 0.4, 0.6, 0.7)
            model.mutate { p in p.setRamp(ids: group, speed: mid, points: points, start: 1, end: 1, sticky: sticky) }
        }
    }

    private func applySpeed(_ speed: Double, ids: Set<UUID>) {
        guard let origin = speedOrigin else {
            model.setSpeed(speed)
            return
        }
        // Always derive from the clips as they were when the drag began, so rounding never accumulates.
        model.live(autoCommit: false) { p in
            p.clips = origin
            p.setSpeed(ids: p.linked(ids), speed: speed, sticky: model.sticky)
        }
    }

    @ViewBuilder private func transformSection(_ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let tf = clips[0].transform ?? ClipTransform()
        let w = Double(model.project.width), h = Double(model.project.height)
        let live: (@escaping (inout ClipTransform) -> Void) -> Void = { body in
            model.liveVisual(autoCommit: false) { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var t = p.clips[i].transform ?? ClipTransform()
                    body(&t)
                    t.clampAll()
                    p.clips[i].transform = t.isIdentity ? nil : t
                }
            }
        }
        let done: (Bool) -> Void = { if !$0 { model.commitLive() } }
        let hasBasicTransform = abs(tf.scale - 1) > 1e-5 || abs(tf.x) > 1e-5 || abs(tf.y) > 1e-5
            || abs(tf.rotation) > 1e-5 || abs(tf.opacity - 1) > 1e-5 || tf.flipH || tf.flipV
        InspectorSection("Transform", action: hasBasicTransform ? ("Reset", {
            model.mutate { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var t = p.clips[i].transform ?? ClipTransform()
                    t.scale = 1; t.x = 0; t.y = 0; t.rotation = 0; t.opacity = 1; t.flipH = false; t.flipV = false
                    p.clips[i].transform = t.isIdentity ? nil : t
                }
            }
        }) : nil, collapsedByDefault: false, marked: hasBasicTransform) {
            ParamRow(icon: .symbol("arrow.up.left.and.arrow.down.right"), label: "Scale", value: tf.scale * 100,
                     range: 5...1000, logarithmic: true, step: 1, format: Self.percentTenths, onEditing: done,
                     onChange: { v in live { $0.scale = ((v * 10).rounded() / 1000).clamped(to: ClipTransform.scaleRange) } })
            ParamRow(icon: .symbol("arrow.left.and.right"), label: "X", value: tf.x * w, range: -w...w,
                     step: 1, format: Self.tenths, onEditing: done,
                     onChange: { v in live { $0.x = (v * 10).rounded() / 10 / w } })
            ParamRow(icon: .symbol("arrow.up.and.down"), label: "Y", value: tf.y * h, range: -h...h,
                     step: 1, format: Self.tenths, onEditing: done,
                     onChange: { v in live { $0.y = (v * 10).rounded() / 10 / h } })
            ParamRow(icon: .symbol("rotate.right"), label: "Rotate", value: tf.rotation, range: -180...180,
                     step: 1, format: { Self.tenths($0) + "°" }, onEditing: done,
                     onChange: { v in live { $0.rotation = (v * 10).rounded() / 10 } })
            ParamRow(icon: .symbol("circle.lefthalf.filled"), label: "Opacity", value: tf.opacity * 100, range: 0...100,
                     step: 1, format: Self.percentTenths, onEditing: done,
                     onChange: { v in live { $0.opacity = (v / 100).clamped(to: ClipTransform.opacityRange) } })
            HStack(spacing: 8) {
                Chip(label: "Flip H", active: tf.flipH) {
                    model.mutate { p in
                        for i in p.clips.indices where ids.contains(p.clips[i].id) {
                            var t = p.clips[i].transform ?? ClipTransform()
                            t.flipH.toggle()
                            p.clips[i].transform = t.isIdentity ? nil : t
                        }
                    }
                }
                Chip(label: "Flip V", active: tf.flipV) {
                    model.mutate { p in
                        for i in p.clips.indices where ids.contains(p.clips[i].id) {
                            var t = p.clips[i].transform ?? ClipTransform()
                            t.flipV.toggle()
                            p.clips[i].transform = t.isIdentity ? nil : t
                        }
                    }
                }
                Spacer()
            }
        }
    }

    @ViewBuilder private func cropMaskSection(_ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let tf = clips[0].transform ?? ClipTransform()
        let live: (@escaping (inout ClipTransform) -> Void) -> Void = { body in
            model.liveVisual(autoCommit: false) { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var t = p.clips[i].transform ?? ClipTransform()
                    body(&t)
                    t.clampAll()
                    p.clips[i].transform = t.isIdentity ? nil : t
                }
            }
        }
        let done: (Bool) -> Void = { if !$0 { model.commitLive() } }
        let active = tf.hasCrop || tf.hasMask
        InspectorSection("Crop & Mask", action: active ? ("Reset", {
            model.mutate { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var t = p.clips[i].transform ?? ClipTransform()
                    t.cropLeft = 0; t.cropRight = 0; t.cropTop = 0; t.cropBottom = 0
                    t.maskShape = .none; t.cornerRadius = 0; t.maskFeather = 0
                    p.clips[i].transform = t.isIdentity ? nil : t
                }
            }
        }) : nil, collapsedByDefault: !active, marked: active) {
            ParamRow(icon: .symbol("arrow.right.to.line"), label: "Left", value: tf.cropLeft * 100,
                     range: 0...95, step: 1, format: Self.percentTenths, onEditing: done,
                     onChange: { v in live { $0.cropLeft = (v / 100).clamped(to: 0...max(0, 0.95 - $0.cropRight)) } })
            ParamRow(icon: .symbol("arrow.left.to.line"), label: "Right", value: tf.cropRight * 100,
                     range: 0...95, step: 1, format: Self.percentTenths, onEditing: done,
                     onChange: { v in live { $0.cropRight = (v / 100).clamped(to: 0...max(0, 0.95 - $0.cropLeft)) } })
            ParamRow(icon: .symbol("arrow.down.to.line"), label: "Top", value: tf.cropTop * 100,
                     range: 0...95, step: 1, format: Self.percentTenths, onEditing: done,
                     onChange: { v in live { $0.cropTop = (v / 100).clamped(to: 0...max(0, 0.95 - $0.cropBottom)) } })
            ParamRow(icon: .symbol("arrow.up.to.line"), label: "Bottom", value: tf.cropBottom * 100,
                     range: 0...95, step: 1, format: Self.percentTenths, onEditing: done,
                     onChange: { v in live { $0.cropBottom = (v / 100).clamped(to: 0...max(0, 0.95 - $0.cropTop)) } })
            HStack(spacing: 8) {
                Image(systemName: "square.on.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 18)
                Text("Mask")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text)
                    .frame(width: 52, alignment: .leading)
                MenuField(label: tf.maskShape.label, height: 26) {
                    ForEach(MaskShape.allCases, id: \.self) { shape in
                        Button(shape.label) {
                            model.mutate { p in
                                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                    var t = p.clips[i].transform ?? ClipTransform()
                                    t.maskShape = shape
                                    if shape == .roundedRect && t.cornerRadius < 0.01 { t.cornerRadius = 0.1 }
                                    if shape == .none { t.cornerRadius = 0; t.maskFeather = 0 }
                                    p.clips[i].transform = t.isIdentity ? nil : t
                                }
                            }
                        }
                    }
                }
            }
            if tf.maskShape == .roundedRect || tf.cornerRadius > 0 {
                ParamRow(icon: .symbol("square.dashed"), label: "Radius", value: tf.cornerRadius * 100,
                         range: 0...50, step: 1, format: Self.percentTenths, onEditing: done,
                         onChange: { v in live { $0.cornerRadius = (v / 100).clamped(to: ClipTransform.radiusRange); if $0.cornerRadius > 0 && $0.maskShape == .none { $0.maskShape = .roundedRect } } })
            }
            if tf.hasMask {
                ParamRow(icon: .symbol("aqi.medium"), label: "Feather", value: tf.maskFeather * 100,
                         range: 0...25, step: 0.5, format: Self.percentTenths, onEditing: done,
                         onChange: { v in live { $0.maskFeather = (v / 100).clamped(to: ClipTransform.featherRange) } })
            }
        }
    }

    @ViewBuilder private func backgroundRemovalSection(_ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let current = clips[0].bgRemoval
        let active = current != nil
        let bg = current ?? BackgroundRemoval(mode: clips[0].kind == .video ? .aiPerson : .aiSubject)
        let live: (@escaping (inout BackgroundRemoval) -> Void) -> Void = { body in
            model.liveVisual(autoCommit: false) { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var b = p.clips[i].bgRemoval ?? BackgroundRemoval(mode: p.clips[i].kind == .video ? .aiPerson : .aiSubject)
                    body(&b)
                    b.clampAll()
                    p.clips[i].bgRemoval = b
                }
            }
        }
        let done: (Bool) -> Void = { if !$0 { model.commitLive() } }
        InspectorSection("Background Removal", action: active ? ("Off", {
            model.mutate { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].bgRemoval = nil }
            }
        }) : nil, collapsedByDefault: !active, marked: active) {
            HStack(spacing: 8) {
                Image(systemName: "person.and.background.dotted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(active ? Color(hex: 0x38BDF8) : Theme.textDim)
                    .frame(width: 18)
                Text("Remove BG")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { active },
                    set: { on in
                        model.mutate { p in
                            for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                p.clips[i].bgRemoval = on ? BackgroundRemoval(mode: p.clips[i].kind == .video ? .aiPerson : .aiSubject) : nil
                            }
                        }
                        AppleHaptics.click()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(Color(hex: 0x38BDF8))
            }
            if active {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 18)
                    Text("Engine")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text)
                        .frame(width: 52, alignment: .leading)
                    MenuField(label: bg.mode.label, height: 26) {
                        ForEach(BackgroundRemovalMode.allCases, id: \.self) { mode in
                            Button(mode.label) {
                                model.mutate { p in
                                    for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                        var b = p.clips[i].bgRemoval ?? BackgroundRemoval()
                                        b.mode = mode
                                        p.clips[i].bgRemoval = b
                                    }
                                }
                            }
                        }
                    }
                }
                if bg.mode == .chromaKey {
                    HStack(spacing: 8) {
                        Image(systemName: "eyedropper")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textDim)
                            .frame(width: 18)
                        Text("Key Color")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach([
                                ("Green", RGBA(r: 0, g: 0.694, b: 0.251, a: 1)),
                                ("Blue", RGBA(r: 0, g: 0.278, b: 0.733, a: 1)),
                                ("White", RGBA(r: 1, g: 1, b: 1, a: 1)),
                                ("Black", RGBA(r: 0, g: 0, b: 0, a: 1)),
                            ], id: \.0) { swatch in
                                Circle()
                                    .fill(swatch.1.color)
                                    .overlay(Circle().strokeBorder(Theme.ink.opacity(0.35), lineWidth: 1))
                                    .frame(width: 14, height: 14)
                                    .onTapGesture {
                                        model.liveVisual(autoCommit: true) { p in
                                            for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                                p.clips[i].bgRemoval?.keyColor = swatch.1
                                            }
                                        }
                                    }
                                    .help(swatch.0)
                            }
                            ColorPicker("", selection: Binding(
                                get: { bg.keyColor.color },
                                set: { col in
                                    model.liveVisual(autoCommit: true) { p in
                                        for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                            p.clips[i].bgRemoval?.keyColor = RGBA(col)
                                        }
                                    }
                                }
                            ), supportsOpacity: false)
                            .labelsHidden()
                        }
                    }
                }
                ParamRow(icon: .symbol("slider.horizontal.3"), label: "Tolerance", value: bg.tolerance * 100,
                         range: 0...100, step: 1, format: Self.percentTenths, onEditing: done,
                         onChange: { v in live { $0.tolerance = v / 100 } })
                ParamRow(icon: .symbol("aqi.medium"), label: "Softness", value: bg.softness * 100,
                         range: 0...100, step: 1, format: Self.percentTenths, onEditing: done,
                         onChange: { v in live { $0.softness = v / 100 } })
                ParamRow(icon: .symbol("arrow.left.and.right"), label: "Edge", value: bg.edgeShift * 100,
                         range: -100...100, step: 1, format: { "\(Int($0.rounded()))%" }, onEditing: done,
                         onChange: { v in live { $0.edgeShift = v / 100 } })
                ParamRow(icon: .symbol("camera.aperture"), label: "BG Blur", value: bg.blurBackground * 100,
                         range: 0...100, step: 1, format: Self.percentTenths, onEditing: done,
                         onChange: { v in live { $0.blurBackground = v / 100 } })
                HStack(spacing: 8) {
                    Chip(label: "Invert Mask", active: bg.invert) {
                        model.mutate { p in
                            for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                p.clips[i].bgRemoval?.invert.toggle()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func styleAndMotionSection(_ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let st = clips[0].style ?? ClipStyle()
        let anim = clips[0].animation ?? ClipAnimation()
        let keys = clips[0].keyframes ?? []
        let hasStyle = !st.isIdentity
        let hasMotion = !anim.isIdentity || !keys.isEmpty
        let active = hasStyle || hasMotion
        let liveStyle: (@escaping (inout ClipStyle) -> Void) -> Void = { body in
            model.liveVisual(autoCommit: false) { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var s = p.clips[i].style ?? ClipStyle()
                    body(&s)
                    s.clampAll()
                    p.clips[i].style = s.isIdentity ? nil : s
                }
            }
        }
        let setAnim: (@escaping (inout ClipAnimation) -> Void) -> Void = { body in
            model.mutate { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var a = p.clips[i].animation ?? ClipAnimation()
                    body(&a)
                    p.clips[i].animation = a.isIdentity ? nil : a
                }
            }
        }
        let done: (Bool) -> Void = { if !$0 { model.commitLive() } }

        InspectorSection("Style & Motion", action: active ? ("Reset", {
            model.mutate { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    p.clips[i].style = nil
                    p.clips[i].animation = nil
                    p.clips[i].keyframes = nil
                }
            }
        }) : nil, collapsedByDefault: !active, marked: active) {
            HStack(spacing: 6) {
                Chip(label: "Card Polish", active: hasStyle) {
                    model.mutate { p in
                        for i in p.clips.indices where ids.contains(p.clips[i].id) {
                            p.clips[i].style = hasStyle ? nil : .cardPolish
                        }
                    }
                    AppleHaptics.click()
                }
                if clips.count == 1, clips[0].kind == .video || clips[0].kind == .image {
                    Chip(label: "Face Track", active: false) {
                        Task { await model.autoReframeFaces(clipIDs: ids) }
                    }
                }
                Spacer()
            }
            ParamRow(icon: .symbol("shadow"), label: "Shadow", value: st.shadowOpacity * 100, range: 0...100, step: 1,
                     format: Self.percentTenths, onEditing: done,
                     onChange: { v in liveStyle { $0.shadowOpacity = v / 100; if $0.shadowOpacity > 0.01 && $0.shadowRadius < 2 { $0.shadowRadius = 24; $0.shadowOffsetY = 12 } } })
            ParamRow(icon: .symbol("square"), label: "Border", value: st.borderWidth, range: 0...24, step: 0.5,
                     format: { "\(Self.tenths($0))px" }, onEditing: done,
                     onChange: { v in liveStyle { $0.borderWidth = v } })
            ParamRow(icon: .symbol("app.dashed"), label: "Corners", value: st.cornerRadius * 100, range: 0...35, step: 1,
                     format: Self.percentTenths, onEditing: done,
                     onChange: { v in liveStyle { $0.cornerRadius = v / 100 } })

            HStack(spacing: 8) {
                Image(systemName: "arrow.down.right.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textDim).frame(width: 18)
                Text("In").font(.system(size: 11.5)).foregroundStyle(Theme.text).frame(width: 52, alignment: .leading)
                MenuField(label: anim.inPreset.label, height: 26) {
                    ForEach(MotionPreset.inOutCases, id: \.self) { m in
                        Button(m.label) { setAnim { $0.inPreset = m } }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textDim).frame(width: 18)
                Text("Out").font(.system(size: 11.5)).foregroundStyle(Theme.text).frame(width: 52, alignment: .leading)
                MenuField(label: anim.outPreset.label, height: 26) {
                    ForEach(MotionPreset.inOutCases, id: \.self) { m in
                        Button(m.label) { setAnim { $0.outPreset = m } }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "repeat").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textDim).frame(width: 18)
                Text("Loop").font(.system(size: 11.5)).foregroundStyle(Theme.text).frame(width: 52, alignment: .leading)
                MenuField(label: anim.loopPreset.label, height: 26) {
                    ForEach(MotionPreset.loopCases, id: \.self) { m in
                        Button(m.label) { setAnim { $0.loopPreset = m } }
                    }
                }
            }
            if anim.inPreset != .none || anim.outPreset != .none {
                ParamRow(icon: .symbol("timer"), label: "Speed", value: anim.inDuration, range: 0.1...2.0, step: 0.05,
                         format: { String(format: "%.2fs", $0) }, onEditing: done,
                         onChange: { v in
                             model.liveVisual(autoCommit: false) { p in
                                 for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                     var a = p.clips[i].animation ?? ClipAnimation()
                                     a.inDuration = v; a.outDuration = v
                                     p.clips[i].animation = a.isIdentity ? nil : a
                                 }
                             }
                         })
            }

            if clips.count == 1, let c = clips.first {
                HStack(spacing: 6) {
                    Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(keys.isEmpty ? Theme.textDim : Color(hex: 0x38BDF8)).frame(width: 18)
                    Text(keys.isEmpty ? "Keyframes" : "\(keys.count) Keyframe\(keys.count == 1 ? "" : "s")")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text)
                    Spacer()
                    Chip(label: "+ Key", active: false) {
                        let localT = max(0, min(c.duration, model.playhead - c.start))
                        let tf = c.transform ?? ClipTransform()
                        let kf = ClipKeyframe(time: localT, x: tf.x, y: tf.y, scale: tf.scale, rotation: tf.rotation, opacity: tf.opacity)
                        model.mutate { p in
                            guard let i = p.index(of: c.id) else { return }
                            var arr = p.clips[i].keyframes ?? []
                            arr.removeAll { abs($0.time - localT) < 0.05 }
                            arr.append(kf)
                            arr.sort { $0.time < $1.time }
                            p.clips[i].keyframes = arr
                        }
                        AppleHaptics.align()
                    }
                    if !keys.isEmpty {
                        Chip(label: "Clear", active: false) {
                            model.mutate { p in
                                if let i = p.index(of: c.id) { p.clips[i].keyframes = nil }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func newsAndEffectsSection(_ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let hl = clips[0].highlight
        let pb = clips[0].privacyBlur
        let lt = clips[0].lowerThird
        let active = hl != nil || pb != nil || lt != nil
        let done: (Bool) -> Void = { if !$0 { model.commitLive() } }

        InspectorSection("News & Effects", action: active ? ("Clear", {
            model.mutate { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    p.clips[i].highlight = nil
                    p.clips[i].privacyBlur = nil
                    p.clips[i].lowerThird = nil
                }
            }
        }) : nil, collapsedByDefault: !active, marked: active) {
            // 1. Animated Headline Highlighter
            HStack(spacing: 8) {
                Image(systemName: "highlighter").font(.system(size: 11, weight: .medium)).foregroundStyle(hl != nil ? Color(hex: 0xF5C542) : Theme.textDim).frame(width: 18)
                Text("Highlighter").font(.system(size: 11.5)).foregroundStyle(Theme.text)
                Spacer()
                Toggle("", isOn: Binding(get: { hl != nil }, set: { on in
                    model.mutate { p in
                        for i in p.clips.indices where ids.contains(p.clips[i].id) {
                            p.clips[i].highlight = on ? ClipHighlight() : nil
                        }
                    }
                })).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Color(hex: 0xF5C542))
            }
            if let h = hl {
                let liveHL: (@escaping (inout ClipHighlight) -> Void) -> Void = { body in
                    model.liveVisual(autoCommit: false) { p in
                        for i in p.clips.indices where ids.contains(p.clips[i].id) {
                            var x = p.clips[i].highlight ?? ClipHighlight()
                            body(&x); x.clampAll()
                            p.clips[i].highlight = x
                        }
                    }
                }
                ParamRow(icon: .symbol("arrow.up.and.down"), label: "Line Y", value: h.y * 100, range: 5...95, step: 1,
                         format: Self.percentTenths, onEditing: done, onChange: { v in liveHL { $0.y = v / 100 } })
                ParamRow(icon: .symbol("arrow.left.and.right"), label: "Width", value: h.width * 100, range: 10...100, step: 1,
                         format: Self.percentTenths, onEditing: done, onChange: { v in liveHL { $0.width = v / 100 } })
                ParamRow(icon: .symbol("rectangle.expand.vertical"), label: "Height", value: h.height * 100, range: 2...35, step: 0.5,
                         format: Self.percentTenths, onEditing: done, onChange: { v in liveHL { $0.height = v / 100 } })
                HStack(spacing: 6) {
                    Spacer()
                    ForEach([
                        ("Yellow", RGBA(r: 0.99, g: 0.88, b: 0.20, a: 0.48)),
                        ("Green", RGBA(r: 0.29, g: 0.87, b: 0.50, a: 0.45)),
                        ("Cyan", RGBA(r: 0.22, g: 0.74, b: 0.97, a: 0.45)),
                        ("Coral", RGBA(r: 0.98, g: 0.44, b: 0.52, a: 0.45)),
                    ], id: \.0) { sw in
                        Circle().fill(sw.1.color.opacity(0.95)).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Theme.ink.opacity(0.3), lineWidth: 1))
                            .onTapGesture {
                                model.liveVisual(autoCommit: true) { p in
                                    for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].highlight?.color = sw.1 }
                                }
                            }
                    }
                }
            }

            // 2. Privacy Blur / Pixelate
            HStack(spacing: 8) {
                Image(systemName: "eye.slash").font(.system(size: 11, weight: .medium)).foregroundStyle(pb != nil ? Color(hex: 0x38BDF8) : Theme.textDim).frame(width: 18)
                Text("Privacy Blur").font(.system(size: 11.5)).foregroundStyle(Theme.text)
                Spacer()
                Toggle("", isOn: Binding(get: { pb != nil }, set: { on in
                    model.mutate { p in
                        for i in p.clips.indices where ids.contains(p.clips[i].id) {
                            p.clips[i].privacyBlur = on ? PrivacyBlur() : nil
                        }
                    }
                })).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Color(hex: 0x38BDF8))
            }
            if let b = pb {
                let livePB: (@escaping (inout PrivacyBlur) -> Void) -> Void = { body in
                    model.liveVisual(autoCommit: false) { p in
                        for i in p.clips.indices where ids.contains(p.clips[i].id) {
                            var x = p.clips[i].privacyBlur ?? PrivacyBlur()
                            body(&x); x.clampAll()
                            p.clips[i].privacyBlur = x
                        }
                    }
                }
                HStack(spacing: 6) {
                    Chip(label: "Blur", active: !b.pixelate) { model.mutate { p in for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].privacyBlur?.pixelate = false } } }
                    Chip(label: "Pixelate", active: b.pixelate) { model.mutate { p in for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].privacyBlur?.pixelate = true } } }
                    Spacer()
                }
                ParamRow(icon: .symbol("arrow.left.and.right"), label: "X", value: b.x * 100, range: 0...100, step: 1, format: Self.percentTenths, onEditing: done, onChange: { v in livePB { $0.x = v / 100 } })
                ParamRow(icon: .symbol("arrow.up.and.down"), label: "Y", value: b.y * 100, range: 0...100, step: 1, format: Self.percentTenths, onEditing: done, onChange: { v in livePB { $0.y = v / 100 } })
                ParamRow(icon: .symbol("arrow.left.and.right.square"), label: "Width", value: b.width * 100, range: 5...100, step: 1, format: Self.percentTenths, onEditing: done, onChange: { v in livePB { $0.width = v / 100 } })
                ParamRow(icon: .symbol("arrow.up.and.down.square"), label: "Height", value: b.height * 100, range: 5...100, step: 1, format: Self.percentTenths, onEditing: done, onChange: { v in livePB { $0.height = v / 100 } })
                ParamRow(icon: .symbol("aqi.medium"), label: "Strength", value: b.strength * 100, range: 15...100, step: 1, format: Self.percentTenths, onEditing: done, onChange: { v in livePB { $0.strength = v / 100 } })
            }

            // 3. Broadcast Lower Third (Tarja)
            HStack(spacing: 8) {
                Image(systemName: "rectangle.bottomthird.inset.filled").font(.system(size: 11, weight: .medium)).foregroundStyle(lt != nil ? Color(hex: 0x38BDF8) : Theme.textDim).frame(width: 18)
                Text("Lower Third").font(.system(size: 11.5)).foregroundStyle(Theme.text)
                Spacer()
                Toggle("", isOn: Binding(get: { lt != nil }, set: { on in
                    model.mutate { p in
                        for i in p.clips.indices where ids.contains(p.clips[i].id) {
                            p.clips[i].lowerThird = on ? LowerThird(title: "Breaking News", subtitle: "Live Analysis") : nil
                        }
                    }
                })).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Color(hex: 0x38BDF8))
            }
            if let l = lt {
                TextField("Title", text: Binding(get: { l.title }, set: { s in
                    model.liveVisual(autoCommit: true) { p in
                        for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].lowerThird?.title = s }
                    }
                }))
                .textFieldStyle(.plain).font(.system(size: 11.5, weight: .semibold)).padding(6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
                TextField("Subtitle", text: Binding(get: { l.subtitle }, set: { s in
                    model.liveVisual(autoCommit: true) { p in
                        for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].lowerThird?.subtitle = s }
                    }
                }))
                .textFieldStyle(.plain).font(.system(size: 11)).padding(6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
                ParamRow(icon: .symbol("arrow.up.and.down"), label: "Y", value: l.y * 100, range: 10...95, step: 1,
                         format: Self.percentTenths, onEditing: done,
                         onChange: { v in
                             model.liveVisual(autoCommit: false) { p in
                                 for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].lowerThird?.y = v / 100 }
                             }
                         })
                HStack(spacing: 6) {
                    Text("Accent").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    Spacer()
                    ForEach([
                        ("Gold", RGBA(r: 0.96, g: 0.77, b: 0.26, a: 1)),
                        ("Cyan", RGBA(r: 0.22, g: 0.74, b: 0.97, a: 1)),
                        ("Red", RGBA(r: 0.93, g: 0.26, b: 0.26, a: 1)),
                        ("Green", RGBA(r: 0.13, g: 0.77, b: 0.37, a: 1)),
                    ], id: \.0) { sw in
                        Circle().fill(sw.1.color).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Theme.ink.opacity(0.3), lineWidth: 1))
                            .onTapGesture {
                                model.liveVisual(autoCommit: true) { p in
                                    for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].lowerThird?.accentColor = sw.1 }
                                }
                            }
                    }
                }
            }
        }
    }

    /// A number to a tenth ("12.5"), whole numbers without the ".0" ("12").
    static func tenths(_ v: Double) -> String {
        let t = (v * 10).rounded() / 10
        return t == t.rounded() ? "\(Int(t))" : String(format: "%.1f", t)
    }

    /// A percentage to a tenth ("95.3%"), whole numbers without the ".0" ("100%").
    static func percentTenths(_ v: Double) -> String { tenths(v) + "%" }

    /// Transitions on the cuts either side of a clip: In blends from the clip before, Out into the clip after.
    @ViewBuilder private func transitionSection(_ c: Clip) -> some View {
        let p = model.project
        let before = p.previous(touching: c)
        let after = p.next(touching: c)
        if before != nil || after != nil {
            let incoming = before != nil ? c : nil
            let outgoing = after
            let marked = incoming?.transitionIn != nil || outgoing?.transitionIn != nil
            InspectorSection("Transitions", collapsedByDefault: true, marked: marked) {
                if let clip = incoming, let a = before { transitionRows("In", into: clip, from: a) }
                if let clip = outgoing { transitionRows("Out", into: clip, from: c) }
            }
        }
    }

    @ViewBuilder private func transitionRows(_ label: String, into clip: Clip, from a: Clip) -> some View {
        let t = clip.transitionIn
        HStack(spacing: 8) {
            Image(systemName: label == "In" ? "arrow.right.to.line" : "arrow.right.to.line.compact")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
                .frame(width: 52, alignment: .leading)
            MenuField(label: t?.kind.label ?? "None", height: 26) {
                Button("None") { model.setTransition(into: clip.id, nil) }
                Divider()
                ForEach(TransitionKind.allCases, id: \.self) { kind in
                    Button(kind.label) {
                        var n = t ?? Transition()
                        n.kind = kind
                        model.setTransition(into: clip.id, n)
                    }
                }
            }
        }
        .frame(height: 28)
        if let t {
            let span = model.project.transitionSpan(from: a, into: clip)
            let actual = span.map { $0.end - $0.start } ?? 0
            ParamRow(icon: .symbol("timer"), label: "Length", value: t.duration, range: 0.1...5,
                     format: { String(format: "%.2fs", $0) },
                     onEditing: { if !$0 { model.commitLive() } },
                     onChange: { v in
                         model.live(autoCommit: false) { p in
                             if let i = p.index(of: clip.id) { p.clips[i].transitionIn?.duration = (v * 100).rounded() / 100 }
                         }
                     })
            if actual < t.duration - 0.01 {
                Text(actual > 0 ? String(format: "Shortened to %.2fs: no more media beyond the cut.", actual)
                                : "Needs media beyond the cut to blend; try Dip to Black.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.leading, 26)
            }
        }
    }

    @ViewBuilder private func fadeSection(_ title: String, _ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let first = clips[0]
        let maxFade = max(0.1, min(first.duration, 10))
        InspectorSection(title, collapsedByDefault: true, marked: first.fadeIn > 0 || first.fadeOut > 0) {
            ParamRow(icon: .fadeIn, label: "Fade In",
                     value: first.fadeIn, range: 0...maxFade, format: { String(format: "%.2fs", $0) },
                     onEditing: { if !$0 { model.commitLive() } },
                     onChange: { v in
                         model.live(autoCommit: false) { p in
                             for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                 p.clips[i].fadeIn = min(p.snapFrame(v), p.clips[i].duration - p.clips[i].fadeOut)
                             }
                         }
                     },
                     trailing: AnyView(CurveMenu(selection: first.inCurve, rising: true, active: first.fadeIn > 0) { curve in
                         model.mutate { p in
                             for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].fadeInCurve = curve }
                         }
                     }))
            ParamRow(icon: .fadeOut, label: "Fade Out",
                     value: first.fadeOut, range: 0...maxFade, format: { String(format: "%.2fs", $0) },
                     onEditing: { if !$0 { model.commitLive() } },
                     onChange: { v in
                         model.live(autoCommit: false) { p in
                             for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                 p.clips[i].fadeOut = min(p.snapFrame(v), p.clips[i].duration - p.clips[i].fadeIn)
                             }
                         }
                     },
                     trailing: AnyView(CurveMenu(selection: first.outCurve, rising: false, active: first.fadeOut > 0) { curve in
                         model.mutate { p in
                             for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].fadeOutCurve = curve }
                         }
                     }))
        }
    }

    @ViewBuilder private func colorSection(_ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let grade = clips[0].grade ?? ColorGrade()
        let live: (@escaping (inout ColorGrade) -> Void) -> Void = { body in
            model.liveVisual(autoCommit: false) { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var g = p.clips[i].grade ?? ColorGrade()
                    body(&g)
                    p.clips[i].grade = g.isNeutral ? nil : g
                }
            }
        }
        let once: (@escaping (inout ColorGrade) -> Void) -> Void = { body in
            model.mutate { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var g = p.clips[i].grade ?? ColorGrade()
                    body(&g)
                    p.clips[i].grade = g.isNeutral ? nil : g
                }
            }
        }
        let done: (Bool) -> Void = { editing in
            if !editing { model.commitLive() }
        }
        InspectorSection("Grade", action: grade.isNeutral ? nil : ("Reset", { once { $0 = ColorGrade() } }),
                         collapsedByDefault: true, marked: !grade.isNeutral) {
            HStack(alignment: .top, spacing: 0) {
                ColorWheel(title: "Shadows", point: grade.shadows, onChange: { pt in live { $0.shadows = pt } }, onEnd: { model.commitLive() })
                ColorWheel(title: "Midtones", point: grade.midtones, onChange: { pt in live { $0.midtones = pt } }, onEnd: { model.commitLive() })
                ColorWheel(title: "Highlights", point: grade.highlights, onChange: { pt in live { $0.highlights = pt } }, onEnd: { model.commitLive() })
            }
            .padding(.vertical, 4)
            ParamRow(icon: .symbol("sun.max"), label: "Exposure", value: grade.exposure, range: -2...2,
                     format: { String(format: "%+.2f", $0) }, onEditing: done,
                     onChange: { v in live { $0.exposure = (v * 100).rounded() / 100 } })
            ParamRow(icon: .symbol("circle.lefthalf.filled"), label: "Contrast", value: grade.contrast, range: -50...50,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in live { $0.contrast = v.rounded() } })
            ParamRow(icon: .symbol("drop"), label: "Saturate", value: grade.saturation, range: -100...100,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in live { $0.saturation = v.rounded() } })
            ParamRow(icon: .symbol("thermometer.medium"), label: "Temp", value: grade.temperature, range: -50...50,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in live { $0.temperature = v.rounded() } })
            ParamRow(icon: .symbol("eyedropper"), label: "Tint", value: grade.tint, range: -50...50,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in live { $0.tint = v.rounded() } })
            HStack(spacing: 8) {
                Image(systemName: "camera.filters").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 18)
                Text("Look")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text)
                    .frame(width: 52, alignment: .leading)
                MenuField(label: grade.lookLabel, height: 26) {
                    Button("None") { once { $0.look = nil } }
                    Divider()
                    ForEach(BuiltInLook.all, id: \.name) { item in
                        Button(item.name) { once { $0.look = item.name } }
                    }
                    Divider()
                    Button("Load .cube…") {
                        if let path = chooseCube() { once { $0.look = path } }
                    }
                }
            }
            .frame(height: 28)
            if grade.look != nil {
                ParamRow(icon: .symbol("circle.dotted"), label: "Intensity", value: grade.lookIntensity * 100, range: 0...100,
                         format: { "\(Int($0.rounded()))%" }, onEditing: done,
                         onChange: { v in live { $0.lookIntensity = v.rounded() / 100 } })
            }
        }
    }

    private func chooseCube() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.prompt = "Load"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard GradeBaker.cubeFile(url.path) != nil else {
            model.importError = "“\(url.lastPathComponent)” isn't a 3D .cube LUT this app can read."
            return nil
        }
        return url.path
    }

    @ViewBuilder private func textSection(_ c: Clip) -> some View {
        let update: (@escaping (inout TextStyle) -> Void) -> Void = { body in
            model.live { p in
                if let i = p.index(of: c.id) { body(&p.clips[i].text) }
            }
        }
        InspectorSection("Text") {
            TextEditor(text: Binding(get: { c.text.string }, set: { s in update { $0.string = s } }))
                .font(.system(size: 11.5))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 68)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            FontPicker(selection: c.text.fontName) { family in update { $0.fontName = family } }
            HStack(spacing: 8) {
                Chip(label: "Bold", active: c.text.bold) { update { $0.bold.toggle() } }
                ColorField(color: c.text.color) { color in update { $0.color = color } }
            }
            ParamRow(icon: .symbol("textformat.size"), label: "Size", value: c.text.size, range: 12...600, logarithmic: true,
                     format: { "\(Int($0.rounded()))" },
                     onEditing: { if !$0 { model.commitLive() } },
                     onChange: { v in update { $0.size = v.rounded() } })
        }
    }

    /// Position for a text clip, in frame pixels from the centre like other clips. No scale: the
    /// font size does that and keeps the text sharp.
    @ViewBuilder private func textTransformSection(_ c: Clip) -> some View {
        let w = Double(model.project.width), h = Double(model.project.height)
        let centred = abs(c.text.x - 0.5) < 1e-6 && abs(c.text.y - 0.5) < 1e-6
        let update: (@escaping (inout TextStyle) -> Void) -> Void = { body in
            model.liveVisual(autoCommit: false) { p in
                if let i = p.index(of: c.id) { body(&p.clips[i].text) }
            }
        }
        let done: (Bool) -> Void = { if !$0 { model.commitLive() } }
        InspectorSection("Transform", action: centred ? nil : ("Reset", {
            model.mutate { p in
                if let i = p.index(of: c.id) {
                    p.clips[i].text.x = 0.5
                    p.clips[i].text.y = 0.5
                }
            }
        }), collapsedByDefault: true, marked: !centred) {
            ParamRow(icon: .symbol("arrow.left.and.right"), label: "X", value: (c.text.x - 0.5) * w, range: -w / 2...w / 2,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in update { $0.x = 0.5 + v.rounded() / w } })
            ParamRow(icon: .symbol("arrow.up.and.down"), label: "Y", value: (c.text.y - 0.5) * h, range: -h / 2...h / 2,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in update { $0.y = 0.5 + v.rounded() / h } })
        }
    }
}

// MARK: - Building blocks

/// A titled group of rows. Click the header to fold it away; the choice is remembered per section.
private struct InspectorSection<Content: View>: View {
    let title: String
    let action: (String, () -> Void)?
    /// Shows a dot beside the title while folded, so a changed section isn't hidden silently.
    let marked: Bool
    @ViewBuilder let content: Content
    // Plain state (saved to defaults by hand) so opening and closing can animate.
    @State private var collapsed: Bool
    private let key: String
    @State private var hovering = false

    init(_ title: String, action: (String, () -> Void)? = nil, collapsedByDefault: Bool = false, marked: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.marked = marked
        self.content = content()
        key = "inspector.collapsed.\(title)"
        _collapsed = State(initialValue: UserDefaults.standard.object(forKey: "inspector.collapsed.\(title)") as? Bool ?? collapsedByDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.08)) { collapsed.toggle() }
                    UserDefaults.standard.set(collapsed, forKey: key)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7.5, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .frame(width: 8)
                        Text(title.uppercased())
                            .font(Theme.label())
                            .kerning(1.6)
                        if marked && collapsed {
                            Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(hovering ? Theme.textDim : Theme.textFaint)
                    .frame(height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                if let action, !collapsed {
                    TextLink(title: action.0, action: action.1)
                }
            }
            if !collapsed {
                content.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct TextLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? Theme.accent : Theme.textDim)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Slim slider: accent fill, white knob.
struct ThinSlider: View {
    /// Normalised 0...1.
    let value: Double
    let onEditing: (Bool) -> Void
    let onChange: (Double) -> Void
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 13
            let travel = max(1, geo.size.width - knob)
            let x = CGFloat(min(1, max(0, value))) * travel
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.12)).frame(height: 2)
                Capsule().fill(Theme.text).frame(width: x + knob / 2, height: 2)
                Circle()
                    .fill(Theme.text)
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 3).padding(-3))
                    .scaleEffect(dragging || hovering ? 1.12 : 1)
                    .offset(x: x)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            onEditing(true)
                        }
                        onChange(Double(min(1, max(0, (v.location.x - knob / 2) / travel))))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditing(false)
                    }
            )
        }
        .frame(height: 20)
    }
}

private enum RowIcon {
    case symbol(String)
    case fadeIn
    case fadeOut
}

private struct RowIconView: View {
    let icon: RowIcon

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 11, weight: .medium))
        case .fadeIn:
            HStack(spacing: 1) {
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                Capsule().frame(width: 1.5, height: 10)
            }
        case .fadeOut:
            HStack(spacing: 1) {
                Capsule().frame(width: 1.5, height: 10)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
            }
        }
    }
}

/// One parameter: icon, name, slider, typed value, and an optional trailing control.
private struct ParamRow: View {
    let icon: RowIcon
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var logarithmic = false
    /// What ↑/↓ change it by (ten times with Shift); nil goes by what the field shows.
    var step: Double?
    let format: (Double) -> String
    let onEditing: (Bool) -> Void
    let onChange: (Double) -> Void
    var trailing: AnyView?
    /// A small button inside the value field, on its right (the speed ramp).
    var inside: AnyView?

    @State private var text = ""
    @State private var cancelled = false
    @FocusState private var focused: Bool

    private var normalised: Double {
        let v = min(max(value, range.lowerBound), range.upperBound)
        if logarithmic { return (log(v) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound)) }
        return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func denormalise(_ n: Double) -> Double {
        if logarithmic { return exp(log(range.lowerBound) + n * (log(range.upperBound) - log(range.lowerBound))) }
        return range.lowerBound + n * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        HStack(spacing: 8) {
            RowIconView(icon: icon)
                .foregroundStyle(Theme.textDim)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
                .frame(width: 52, alignment: .leading)
            ThinSlider(value: normalised, onEditing: onEditing) { onChange(denormalise($0)) }
            // Always a text field, so Tab moves to the next row's value like any form. Return or leaving the
            // field applies what was typed; Esc puts the value back.
            HStack(spacing: 4) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit { focused = false }
                    .onExitCommand {
                        cancelled = true
                        focused = false
                    }
                    .onChange(of: focused) { _, isFocused in
                        if isFocused {
                            cancelled = false
                        } else {
                            if !cancelled { commit() }
                            text = format(value)
                        }
                    }
                    .onChange(of: value) { _, v in
                        if !focused { text = format(v) }
                    }
                    .onAppear { text = format(value) }
                    .arrowSteps(focused) { up, big in nudge(up: up, big: big) }
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text)
                    .padding(.leading, 6)
                    .padding(.trailing, inside == nil ? 6 : 0)
                    .frame(maxHeight: .infinity)
                    // The whole number part is the click target, not just the digits.
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { focused = true })
                if let inside { inside.padding(.trailing, 4) }
            }
            .frame(width: 68, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.text.opacity(focused ? 0.85 : 0)))
            if let trailing { trailing }
        }
        .frame(height: 28)
    }

    /// ↑/↓ while typing: the value up or down a step, by what the field shows (1 for whole numbers,
    /// 0.1 for decimals; ten times that with Shift). What's been typed counts as the starting point.
    private func nudge(up: Bool, big: Bool) {
        let shown = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
            .filter { "0123456789.-".contains($0) }
        let start = Double(shown) ?? value
        let step = (self.step ?? (format(value).contains(".") ? 0.1 : 1)) * (big ? 10 : 1)
        // To the next whole step, so 0.47 goes to 0.5, not 0.57.
        let n = (start / step).rounded(up ? .down : .up) + (up ? 1 : -1)
        let v = min(max((n * step * 1e6).rounded() / 1e6, range.lowerBound), range.upperBound)
        onEditing(true)
        onChange(v)
        onEditing(false)
        text = format(v)
        cancelled = false
    }

    /// Reads the number out of whatever is in the field ("100%", "0.50s", "−18.8 dB" all work).
    private func commit() {
        guard text != format(value) else { return }
        let cleaned = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
            .filter { "0123456789.-".contains($0) }
        if let v = Double(cleaned) {
            onEditing(true)
            onChange(min(max(v, range.lowerBound), range.upperBound))
            onEditing(false)
        }
    }
}

/// Dropdown showing the current fade shape as a small drawing.
struct CurveMenu: View {
    let selection: FadeCurve
    let rising: Bool
    let active: Bool
    let onPick: (FadeCurve) -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: openMenu) {
            HStack(spacing: 5) {
                CurveGlyph(curve: selection, rising: rising, color: active ? Theme.accent : Theme.textDim)
                    .frame(width: 20, height: 12)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            .frame(width: 48, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : Theme.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(selection.label)
    }

    /// A native menu, so each item can show its curve beside the name; the current one is ticked
    /// and opens under the mouse, like a pop-up button.
    private func openMenu() {
        let (menu, current) = Self.menu(selection: selection, rising: rising, onPick: onPick)
        menu.popUp(positioning: current, at: NSEvent.mouseLocation, in: nil)
    }

    static func menu(selection: FadeCurve, rising: Bool, onPick: @escaping (FadeCurve) -> Void) -> (NSMenu, NSMenuItem?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var current: NSMenuItem?
        for curve in FadeCurve.allCases {
            let item = ActionItem(curve.label, checked: curve == selection) { onPick(curve) }
            // Drawn into the title rather than set as the item's image: macOS can be set to hide menu
            // item icons, but the title always shows.
            let attachment = NSTextAttachment()
            attachment.image = glyph(curve, rising: rising, color: .labelColor)
            attachment.bounds = CGRect(x: 0, y: -2, width: 22, height: 13)
            let title = NSMutableAttributedString(attachment: attachment)
            title.append(NSAttributedString(string: "   " + curve.label, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
            item.attributedTitle = title
            if curve == selection { current = item }
            menu.addItem(item)
        }
        return (menu, current)
    }

    /// The curve drawn as a small template image, for the menu items.
    static func glyph(_ curve: FadeCurve, rising: Bool, color: NSColor? = nil) -> NSImage {
        let size = NSSize(width: 22, height: 13)
        let image = NSImage(size: size, flipped: false) { r in
            let path = NSBezierPath()
            for i in 0...24 {
                let x = Double(i) / 24
                let y = curve.apply(rising ? x : 1 - x)
                let pt = NSPoint(x: 1.5 + CGFloat(x) * (r.width - 3), y: 1.5 + CGFloat(y) * (r.height - 3))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            (color ?? .black).setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

private struct CurveGlyph: View {
    let curve: FadeCurve
    let rising: Bool
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for i in 0...20 {
                let x = Double(i) / 20
                let y = curve.apply(rising ? x : 1 - x)
                let pt = CGPoint(x: 1 + CGFloat(x) * (size.width - 2), y: 1 + (1 - CGFloat(y)) * (size.height - 2))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct Chip: View {
    let label: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? Theme.accent : (hovering ? Theme.text : Theme.textDim))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : Theme.field)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct MenuField<Content: View>: View {
    let label: String
    var symbol: String?
    var height: CGFloat = 28
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                }
                Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 11)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Font family chooser: a field showing the current font that opens a searchable list, each name
/// drawn in its own face. Type to filter; Return picks the first match.
private struct FontPicker: View {
    let selection: String
    let onPick: (String) -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 8) {
                Text(selection.isEmpty ? "System" : selection)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .popover(isPresented: $open, arrowEdge: .leading) {
            FontList(selection: selection) { family in
                onPick(family)
                open = false
            }
        }
    }
}

private struct FontList: View {
    let selection: String
    let onPick: (String) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private static let families = NSFontManager.shared.availableFontFamilies

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = [""] + Self.families
        guard !q.isEmpty else { return all }
        return all.filter { ($0.isEmpty ? "System" : $0).localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textFaint)
                TextField("Search fonts", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($focused)
                    .onSubmit { if let first = matches.first { onPick(first) } }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches, id: \.self) { family in
                            FontRow(family: family, selected: family == selection) { onPick(family) }
                                .id(family)
                        }
                        if matches.isEmpty {
                            Text("No fonts match").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint).padding(12)
                        }
                    }
                    .padding(4)
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .frame(width: 260, height: 360)
        .background(Theme.panel)
        .onAppear { focused = true }
    }
}

private struct FontRow: View {
    let family: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(family.isEmpty ? "System" : family)
                    .font(family.isEmpty ? .system(size: 14) : .custom(family, size: 14))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct ColorField: View {
    let color: RGBA
    let onChange: (RGBA) -> Void

    var body: some View {
        ColorPicker("", selection: Binding(get: { color.color }, set: { onChange(RGBA($0)) }), supportsOpacity: false)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Width × height entry for a custom sequence size. Return or clicking away applies, Esc reverts.
private struct FrameSizeFields: View {
    let width: Int
    let height: Int
    let apply: (Int, Int) -> Void
    @State private var w = ""
    @State private var h = ""
    @FocusState private var focus: Int?

    var body: some View {
        HStack(spacing: 6) {
            field($w, tag: 0)
            Text("×").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            field($h, tag: 1)
        }
        .onAppear(perform: sync)
        .onChange(of: width) { _, _ in sync() }
        .onChange(of: height) { _, _ in sync() }
        .onChange(of: focus) { _, new in
            if new == nil { commit() }
        }
    }

    private func field(_ text: Binding<String>, tag: Int) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.text)
            .focused($focus, equals: tag)
            // ↑/↓: two pixels bigger or smaller (twenty with Shift), since sizes are kept even.
            .arrowSteps(focus == tag) { up, big in
                let was = Int(text.wrappedValue.filter(\.isNumber)) ?? (tag == 0 ? width : height)
                let n = max(16, min(8192, was / 2 * 2 + (up ? 2 : -2) * (big ? 10 : 1)))
                text.wrappedValue = String(n)
                commit()
            }
            .onSubmit {
                commit()
                focus = nil
            }
            .onExitCommand {
                sync()
                focus = nil
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.text.opacity(focus == tag ? 0.85 : 0)))
            // The whole box is the click target, not just the line of text.
            .contentShape(Rectangle())
            .onTapGesture { focus = tag }
    }

    private func sync() {
        w = String(width)
        h = String(height)
    }

    private func commit() {
        guard let nw = Int(w.filter(\.isNumber)), let nh = Int(h.filter(\.isNumber)) else { return sync() }
        // Encoders need even dimensions.
        let cw = min(8192, max(16, nw / 2 * 2)), ch = min(8192, max(16, nh / 2 * 2))
        if cw != width || ch != height { apply(cw, ch) } else { sync() }
    }
}

/// A tint wheel: drag the puck toward a colour to push that tonal range toward it. Double-click resets.
private struct ColorWheel: View {
    let title: String
    let point: WheelPoint
    let onChange: (WheelPoint) -> Void
    let onEnd: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    private static let size: CGFloat = 78

    var body: some View {
        let s = Self.size
        let active = point.x != 0 || point.y != 0
        VStack(spacing: 7) {
            ZStack {
                Circle().fill(Theme.field)
                // Hue ring: red at 0°, green at 120°, blue at 240°, matching the direction the puck tints.
                Circle()
                    .strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, Color(red: 1, green: 0, blue: 1), .red], center: .center), lineWidth: 3)
                    .opacity(hovering || dragging ? 0.95 : 0.6)
                Rectangle().fill(Theme.ink.opacity(0.1)).frame(width: 1, height: s - 14)
                Rectangle().fill(Theme.ink.opacity(0.1)).frame(width: s - 14, height: 1)
                Circle()
                    .fill(active ? Theme.accent : Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
                    .frame(width: dragging ? 13 : 11, height: dragging ? 13 : 11)
                    .offset(x: CGFloat(point.x) * (s / 2 - 8), y: CGFloat(point.y) * (s / 2 - 8))
            }
            .frame(width: s, height: s)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        dragging = true
                        var x = Double((v.location.x - s / 2) / (s / 2 - 8))
                        var y = Double((v.location.y - s / 2) / (s / 2 - 8))
                        let m = (x * x + y * y).squareRoot()
                        if m > 1 { x /= m; y /= m }
                        // A small dead zone makes it easy to return to exactly neutral.
                        if m < 0.06 { x = 0; y = 0 }
                        onChange(WheelPoint(x: (x * 100).rounded() / 100, y: (y * 100).rounded() / 100))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnd()
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                onChange(WheelPoint())
                onEnd()
            })
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(active ? Theme.text : Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .help("Drag to tint \(title.lowercased()). Double-click to reset.")
    }
}


/// Beside the Speed field: turns the clip's speed ramp on (the graph opens) or off. A small ramp
/// curve, lit like an active fade curve when on.
private struct RampButton: View {
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RampGlyph()
                .stroke(on ? Theme.accent : Theme.textDim, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 11, height: 8)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(on ? Theme.accent.opacity(0.16) : Theme.ink.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(on ? "Remove the speed ramp" : "Speed ramp: ease into and out of the speed")
    }
}

private struct RampGlyph: SwiftUI.Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.22, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX + r.width * 0.6, y: r.minY),
                   control1: CGPoint(x: r.minX + r.width * 0.42, y: r.maxY),
                   control2: CGPoint(x: r.minX + r.width * 0.4, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// A clip's speed across its footage, under the Speed row. The flat middle is the speed (the same as
/// the slider). An inner dot pulled in from either edge makes a ramp; its outer dot then slides left or
/// right to say where the ramp begins, and up or down for the speed before (or after) it. Across the graph
/// is the clip's footage, which stays put while the clip's length changes.
///
/// Two shapes, picked under the graph: 4-point eases into the speed and back out; 2-point eases from one
/// speed to another and holds it to the end (its right dot sets both where the ease ends and that speed).
/// While a dot is held, its speed shows beside it, its timecode takes the clip length's place under the graph,
/// and the playhead goes to its frame.
private struct SpeedRampGraph: View {
    struct Shape {
        var mid: Double
        /// Where the ramps begin and end, as fractions across the footage: in-ramp `p1...p2`, out-ramp `p3...p4`.
        var p1 = 0.0, p2 = 0.0, p3 = 1.0, p4 = 1.0
        var start: Double
        var end: Double
        var hasIn: Bool { p2 - p1 > 0.001 }
        var hasOut: Bool { p4 - p3 > 0.001 }
        /// Eases in and holds: the 2-point shape.
        var isTwoPoint: Bool { hasIn && !hasOut }
    }

    let clip: Clip
    let fps: Double
    let onEditing: (Bool) -> Void
    /// The shape mid-drag, and the fraction across the footage of the dot being dragged (nil for the flat middle).
    let onChange: (Shape, Double?) -> Void
    /// A shape set in one go (the 2-point / 4-point buttons).
    let onSet: (Shape) -> Void

    private enum Part { case inStart, inEnd, outStart, outEnd, line }
    @State private var dragging: Part?
    @State private var drawn: Shape?
    /// The shape the graph was in when the drag began, kept until it ends (a dot pulled away mid-drag
    /// doesn't switch it).
    @State private var draggingTwo = false

    private static let lo = 0.1, hi = 10.0
    private static let height: CGFloat = 76

    /// The shape last picked, which new ramps start in (2-point until another is picked).
    private static let twoPointKey = "speedRampTwoPoint"
    static var twoPoint: Bool { UserDefaults.standard.object(forKey: twoPointKey) as? Bool ?? true }

    /// Timeline time of a point `f` of the way across a clip's footage.
    static func time(of f: Double, in clip: Clip) -> Double {
        let s0 = clip.sourceStart
        return clip.start + clip.timelineSpan(from: s0, to: s0 + clip.sourceLength * min(1, max(0, f)))
    }

    /// The clip's ramp as the graph draws it.
    private var shape: Shape {
        let s0 = clip.sourceStart, L = max(1e-6, clip.sourceLength), s1 = s0 + L
        let f = { (s: Double) in min(1, max(0, (s - s0) / L)) }
        var out = Shape(mid: clip.speed, start: clip.speed, end: clip.speed)
        if let r = clip.ramp, clip.isRamped {
            if r.inTo > r.inFrom, r.inTo > s0 + 1e-6 {
                out.p1 = f(r.inFrom)
                out.p2 = f(r.inTo)
                out.start = clip.speed(atSource: s0 + out.p1 * L)
            }
            if r.outTo > r.outFrom, r.outFrom < s1 - 1e-6 {
                out.p3 = max(out.p2, f(r.outFrom))
                out.p4 = max(out.p3, f(r.outTo))
                out.end = clip.speed(atSource: s0 + out.p4 * L)
            }
        }
        return out
    }

    private func two(_ s: Shape) -> Bool { dragging != nil ? draggingTwo : s.isTwoPoint }

    private func y(_ v: Double, _ h: CGFloat) -> CGFloat {
        let n = (log(min(max(v, Self.lo), Self.hi)) - log(Self.lo)) / (log(Self.hi) - log(Self.lo))
        return 6 + (h - 12) * CGFloat(1 - n)
    }

    private func speed(_ y: CGFloat, _ h: CGFloat) -> Double {
        let n = Double(1 - (y - 6) / (h - 12))
        let v = exp(log(Self.lo) + min(1, max(0, n)) * (log(Self.hi) - log(Self.lo)))
        // A little pull toward 100%.
        return abs(log(v)) < 0.06 ? 1 : v
    }

    /// Where each dot is drawn.
    private func points(_ s: Shape, w: CGFloat, h: CGFloat) -> [(Part, CGPoint)] {
        let midY = y(s.mid, h)
        let x = { (f: Double) in min(max(5, CGFloat(f) * w), w - 5) }
        var out: [(Part, CGPoint)] = [(.inEnd, CGPoint(x: x(s.p2), y: midY))]
        // 2-point has no way back out, so no dot to start one.
        if !two(s) { out.append((.outStart, CGPoint(x: x(s.p3), y: midY))) }
        if s.hasIn { out.append((.inStart, CGPoint(x: x(s.p1), y: y(s.start, h)))) }
        if s.hasOut { out.append((.outEnd, CGPoint(x: x(s.p4), y: y(s.end, h)))) }
        return out
    }

    var body: some View {
        let s = drawn ?? shape
        VStack(spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        // 100%, for reference.
                        var base = Path()
                        base.move(to: CGPoint(x: 0, y: y(1, h)))
                        base.addLine(to: CGPoint(x: w, y: y(1, h)))
                        ctx.stroke(base, with: .color(Theme.ink.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        // The speed across the footage.
                        let line = curve(s, w: w, h: h)
                        var area = line
                        area.addLine(to: CGPoint(x: w, y: y(1, h)))
                        area.addLine(to: CGPoint(x: 0, y: y(1, h)))
                        area.closeSubpath()
                        ctx.fill(area, with: .color(Theme.ink.opacity(0.05)))
                        ctx.stroke(line, with: .color(Theme.text), lineWidth: 1.5)
                    }
                    ForEach(points(s, w: w, h: h), id: \.0) { part, p in dot(at: p, held: part == dragging) }
                    if let part = dragging {
                        let p = anchor(part, s, w: w, h: h)
                        // The speed beside the dot, on whichever side has room.
                        let pct = "\(Int((speedAt(part, s) * 100).rounded()))%"
                        Text(pct)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.text)
                            .fixedSize()
                            .position(x: p.x > w - 44 ? p.x - 26 : p.x + 26, y: p.y < 16 ? p.y + 12 : p.y - 11)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    if dragging == nil {
                        guard let part = hit(g.startLocation, s: s, w: w, h: h) else { return }
                        draggingTwo = s.isTwoPoint
                        dragging = part
                        drawn = s
                        onEditing(true)
                    }
                    guard let part = dragging, var d = drawn else { return }
                    let p = g.location
                    var f = Double(min(max(0, p.x), w) / w)
                    if p.x < 6 { f = 0 }
                    if p.x > w - 6 { f = 1 }
                    switch part {
                    case .inEnd:
                        let had = d.hasIn
                        d.p2 = min(max(f, d.p1), d.p3)
                        if !d.hasIn { d.p1 = d.p2; d.start = d.mid } else if !had { d.p1 = 0; d.start = 1 }
                        // 2-point: the right dot is also the speed it eases to.
                        if draggingTwo { d.mid = speed(p.y, h) }
                    case .outStart:
                        let had = d.hasOut
                        d.p3 = max(min(f, d.p4), d.p2)
                        if !d.hasOut { d.p4 = d.p3; d.end = d.mid } else if !had { d.p4 = 1; d.end = 1 }
                    case .inStart:
                        // Up to its inner dot, never onto it (pulling the inner dot back out removes a ramp).
                        d.p1 = min(f, d.p2 - 0.01)
                        d.start = speed(p.y, h)
                    case .outEnd:
                        d.p4 = max(f, d.p3 + 0.01)
                        d.end = speed(p.y, h)
                    case .line:
                        d.mid = speed(p.y, h)
                    }
                    // A ramp squeezed to nothing is gone.
                    if !d.hasIn { d.p1 = 0; d.p2 = 0; d.start = d.mid }
                    if !d.hasOut { d.p3 = 1; d.p4 = 1; d.end = d.mid }
                    drawn = d
                    onChange(d, part == .line ? nil : fraction(part, d))
                }.onEnded { _ in
                    guard dragging != nil else { return }
                    dragging = nil
                    drawn = nil
                    onEditing(false)
                })
                .onContinuousHover { phase in
                    guard dragging == nil else { return }
                    if case .active(let p) = phase {
                        switch hit(p, s: s, w: w, h: h) {
                        case .inEnd: (two(s) ? NSCursor.openHand : NSCursor.resizeLeftRight).set()
                        case .outStart: NSCursor.resizeLeftRight.set()
                        case .inStart, .outEnd: NSCursor.openHand.set()
                        case .line: NSCursor.resizeUpDown.set()
                        case nil: NSCursor.arrow.set()
                        }
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            }
            .frame(height: Self.height)
            HStack(spacing: 0) {
                modes(s)
                Spacer()
                // While a dot is held, the timecode it's at; otherwise how long the clip plays with its ramp.
                if let part = dragging, part != .line {
                    Text(Timecode.string(Self.time(of: fraction(part, s), in: clip), fps: fps))
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.text)
                } else {
                    Text(String(format: "%.1fs", clip.duration))
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textFaint)
                        .help("How long the clip plays")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
    }

    /// The 2-point and 4-point buttons.
    private func modes(_ s: Shape) -> some View {
        let isTwo = two(s)
        return HStack(spacing: 1.5) {
            ForEach([true, false], id: \.self) { twoPoint in
                Button { pick(twoPoint: twoPoint, from: s) } label: {
                    RampModeGlyph(twoPoint: twoPoint)
                        .stroke(Theme.text.opacity(isTwo == twoPoint ? 1 : 0.55), lineWidth: 1.3)
                        .frame(width: 12, height: 7)
                        .frame(width: 20, height: 13)
                        .background(RoundedRectangle(cornerRadius: 3).fill(isTwo == twoPoint ? Theme.ink.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(twoPoint ? "2-point: ease from one speed to another" : "4-point: ease into the speed and back out")
            }
        }
        .padding(1.5)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.bg))
    }

    /// Switches shape, keeping as much of the ramp as fits the other one. Remembered for new ramps.
    private func pick(twoPoint: Bool, from s: Shape) {
        UserDefaults.standard.set(twoPoint, forKey: Self.twoPointKey)
        guard twoPoint != s.isTwoPoint else { return }
        var d = s
        if twoPoint {
            if d.hasIn {
                // Drop the way back out.
                d.p3 = 1; d.p4 = 1; d.end = d.mid
            } else {
                // Only a way out: it becomes the one ease, from the speed to the end speed.
                d = Shape(mid: s.end, p1: s.p3, p2: s.p4, p3: 1, p4: 1, start: s.mid, end: s.end)
            }
        } else {
            // Ease back to the starting speed, in the room after the first ease (made if there's little).
            if d.p2 > 0.6 {
                let k = 0.6 / d.p2
                d.p1 *= k; d.p2 *= k
            }
            let room = 1 - d.p2
            d.p3 = d.p2 + room * 0.4
            d.p4 = d.p2 + room * 0.7
            d.end = d.start
        }
        onSet(d)
    }

    /// Where a part's speed label hangs.
    private func anchor(_ part: Part, _ s: Shape, w: CGFloat, h: CGFloat) -> CGPoint {
        let x = { (f: Double) in min(max(5, CGFloat(f) * w), w - 5) }
        switch part {
        case .inStart: return CGPoint(x: x(s.p1), y: y(s.start, h))
        case .outEnd: return CGPoint(x: x(s.p4), y: y(s.end, h))
        case .inEnd: return CGPoint(x: x(s.p2), y: y(s.mid, h))
        case .outStart: return CGPoint(x: x(s.p3), y: y(s.mid, h))
        case .line: return CGPoint(x: CGFloat(s.p2 + s.p3) / 2 * w, y: y(s.mid, h))
        }
    }

    /// How far across the footage a dot is.
    private func fraction(_ part: Part, _ s: Shape) -> Double {
        switch part {
        case .inStart: s.p1
        case .inEnd: s.p2
        case .outStart: s.p3
        case .outEnd: s.p4
        case .line: (s.p2 + s.p3) / 2
        }
    }

    private func speedAt(_ part: Part, _ s: Shape) -> Double {
        switch part {
        case .inStart: s.start
        case .outEnd: s.end
        case .inEnd, .outStart, .line: s.mid
        }
    }

    /// The speed line: flat at the start speed, eased into the middle speed, held, eased out to the end speed.
    private func curve(_ s: Shape, w: CGFloat, h: CGFloat) -> Path {
        let ease = { (u: Double) in u * u * (3 - 2 * u) }
        let blend = { (a: Double, b: Double, u: Double) in exp(log(a) + (log(b) - log(a)) * ease(min(1, max(0, u)))) }
        let at = { (x: Double) -> Double in
            if s.hasIn, x < s.p2 { return x <= s.p1 ? s.start : blend(s.start, s.mid, (x - s.p1) / (s.p2 - s.p1)) }
            if s.hasOut, x > s.p3 { return x >= s.p4 ? s.end : blend(s.mid, s.end, (x - s.p3) / (s.p4 - s.p3)) }
            return s.mid
        }
        var path = Path()
        let n = 160
        for i in 0...n {
            let x = Double(i) / Double(n)
            let pt = CGPoint(x: CGFloat(x) * w, y: y(at(x), h))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    /// The nearest dot within reach (an inner dot when they sit together), else the flat middle.
    private func hit(_ p: CGPoint, s: Shape, w: CGFloat, h: CGFloat) -> Part? {
        var near: (part: Part, d: CGFloat)?
        for (part, at) in points(s, w: w, h: h) {
            let d: CGFloat = hypot(p.x - at.x, p.y - at.y)
            guard d < 10 else { continue }
            let inner = part == Part.inEnd || part == Part.outStart
            if let n = near {
                // Two dots together: the inner one, which makes or shapes the ramp.
                if abs(n.d - d) < 2 { if inner { near = (part, d) } } else if d < n.d { near = (part, d) }
            } else {
                near = (part, d)
            }
        }
        if let near {
            // Inner dots on top of each other: whichever side the drag is toward.
            if !two(s), near.part == Part.inEnd || near.part == Part.outStart {
                let x2 = CGFloat(s.p2) * w, x3 = CGFloat(s.p3) * w
                if abs(x2 - x3) < 10 { return p.x < (x2 + x3) / 2 ? .inEnd : .outStart }
            }
            return near.part
        }
        let midY = y(s.mid, h)
        if p.x > CGFloat(s.p2) * w, p.x < CGFloat(s.p3) * w, abs(p.y - midY) < 8 { return .line }
        return nil
    }

    private func dot(at p: CGPoint, held: Bool) -> some View {
        let size: CGFloat = held ? 12 : 10
        return Circle().fill(Theme.text).frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Theme.field, lineWidth: 2.5).padding(-2.5))
            .position(p)
            .allowsHitTesting(false)
    }
}

/// The ramp shapes on the graph's buttons: one ease up (2-point), or up and back down (4-point).
private struct RampModeGlyph: SwiftUI.Shape {
    let twoPoint: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let lo = r.maxY, hi = r.minY, w = r.width
        let at = { (f: CGFloat) in r.minX + w * f }
        p.move(to: CGPoint(x: r.minX, y: lo))
        if twoPoint {
            p.addLine(to: CGPoint(x: at(0.25), y: lo))
            p.addCurve(to: CGPoint(x: at(0.7), y: hi), control1: CGPoint(x: at(0.5), y: lo), control2: CGPoint(x: at(0.45), y: hi))
            p.addLine(to: CGPoint(x: r.maxX, y: hi))
        } else {
            p.addLine(to: CGPoint(x: at(0.12), y: lo))
            p.addCurve(to: CGPoint(x: at(0.4), y: hi), control1: CGPoint(x: at(0.28), y: lo), control2: CGPoint(x: at(0.24), y: hi))
            p.addLine(to: CGPoint(x: at(0.6), y: hi))
            p.addCurve(to: CGPoint(x: at(0.88), y: lo), control1: CGPoint(x: at(0.76), y: hi), control2: CGPoint(x: at(0.72), y: lo))
            p.addLine(to: CGPoint(x: r.maxX, y: lo))
        }
        return p
    }
}

/// Up and down arrow keys while a field is being typed in: `step(up, shift)`, and the keys go no
/// further (a text field would otherwise move the cursor to the start or end).
private struct ArrowSteps: ViewModifier {
    let active: Bool
    let step: (Bool, Bool) -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: active) { _, on in on ? start() : stop() }
            .onAppear { if active { start() } }
            .onDisappear(perform: stop)
    }

    private func start() {
        stop()
        let step = step
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 126 || e.keyCode == 125,
                  e.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return e }
            step(e.keyCode == 126, e.modifierFlags.contains(.shift))
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    /// ↑/↓ step a number field while it's being typed in (see `ArrowSteps`).
    func arrowSteps(_ active: Bool, step: @escaping (Bool, Bool) -> Void) -> some View {
        modifier(ArrowSteps(active: active, step: step))
    }
}


/// Shows or hides part of the captions' look: a bare eye, a little brighter on hover.
private struct CaptionEye: View {
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // The tracks' eye (MiniKey), without its box.
            Glyph(symbol: on ? "eye" : "eye.slash", size: 9.5, weight: .semibold)
                .foregroundStyle(on ? Theme.textDim : Theme.textFaint)
                // Hovered: a touch brighter than it is, on or off.
                .brightness(hovering ? 0.1 : 0)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(on ? "Hide" : "Show")
    }
}

/// A caption's words, retyped in place: set on Return or when the field is left; Escape puts them back.
/// Double-clicking a caption on the timeline puts the cursor here.
private struct CaptionTextField: View {
    @ObservedObject var model: EditorModel
    let block: CaptionBlock
    @State private var text = ""
    /// The caption as it was when typing began: its words are the ones retyped, however the text changes.
    @State private var editing: CaptionBlock?
    @State private var cancelled = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1...4)
            .focused($focused)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            .onAppear { text = block.text; takeRequest() }
            .onChange(of: block) { _, b in if !focused { text = b.text } }
            .onChange(of: model.captionEditRequest) { _, _ in takeRequest() }
            // Shown in the viewer as it's typed (the playhead goes to the caption if it's elsewhere).
            .onChange(of: text) { _, t in
                guard focused, let b = editing else { return }
                model.typeCaptionText(b, t)
            }
            .onChange(of: focused) { _, now in
                if now {
                    editing = block
                    if model.playhead < block.start || model.playhead >= block.end { model.seek(to: (block.start + block.end) / 2) }
                } else {
                    commit()
                }
            }
            .onSubmit { focused = false }
            .onExitCommand {
                cancelled = true
                model.discardLive()
                text = block.text
                focused = false
            }
    }

    private func takeRequest() {
        guard model.captionEditRequest == block.id else { return }
        model.captionEditRequest = nil
        DispatchQueue.main.async { focused = true }
    }

    /// Typing ends: what was typed is one undo step. Emptied, the caption's words are left out.
    private func commit() {
        defer { editing = nil; cancelled = false }
        guard !cancelled, let b = editing else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.discardLive()
            model.setCaptionText(b, to: "")
        } else {
            model.commitLive()
        }
    }
}
