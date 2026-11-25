import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    private enum PanelTab { case media, script }

    @ObservedObject var model: EditorModel
    @ObservedObject var media: MediaStore
    @State private var tab: PanelTab = .media
    @State private var dropTargeted = false
    @State private var search = ""
    /// Thumbnails (the default) or a list, from Settings > General.
    @AppStorage(MediaLayout.key) private var layout = MediaLayout.thumbnails
    /// How wide the panel is, so a list's pictures can grow a little when it's widened.
    @State private var panelWidth: CGFloat = 252

    /// 64 points wide at the usual width, up to 104 as the panel is widened.
    private var thumbWidth: CGFloat { min(104, max(64, 64 + (panelWidth - 252) * 0.21)) }

    /// What's said in clips, for searching it (and to update as clips are heard).
    @ObservedObject private var transcripts = Transcripts.shared
    @ObservedObject private var scenes = SceneTagStore.shared

    /// Words typed in "quotes": what's said.
    private var phrases: [String] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard let re = try? NSRegularExpression(pattern: #"["“”]([^"“”]*)["“”]?"#) else { return [] }
        let ns = q as NSString
        return re.matches(in: q, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Where a clip says the first quoted phrase, to show under it.
    private func snippet(_ a: MediaAsset) -> (before: String, match: String, after: String)? {
        guard let phrase = phrases.first else { return nil }
        return media.transcript(a.id)?.snippet(phrase, typing: true)
    }

    /// The search: words in "quotes" are what's said in a clip; anything else is in its name.
    private var shown: [MediaAsset] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.project.assets }
        var phrases: [String] = []
        var rest = q
        if let re = try? NSRegularExpression(pattern: #"["“”]([^"“”]*)["“”]?"#) {
            let ns = q as NSString
            for m in re.matches(in: q, range: NSRange(location: 0, length: ns.length)) {
                let phrase = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty { phrases.append(phrase) }
            }
            rest = re.stringByReplacingMatches(in: q, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return model.project.assets.filter { a in
            // Plain words: in its name, or what it shows ("pool"), each word as it's typed.
            if !rest.isEmpty, !a.name.localizedCaseInsensitiveContains(rest) {
                let tags = media.sceneTags(a.id)
                let words = rest.lowercased().split(separator: " ").map(String.init)
                guard words.allSatisfy({ w in a.name.lowercased().contains(w) || tags?.shows(w, typing: w == words.last) == true }) else { return false }
            }
            guard !phrases.isEmpty else { return true }
            guard let t = media.transcript(a.id) else { return false }
            return phrases.allSatisfy { t.says($0, typing: true) }
        }
    }

    var body: some View {
        // Library items used by whatever is selected on the timeline.
        let inSelection = Set(model.selection.compactMap { model.project.clip($0)?.assetID })
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    tabPill("MEDIA", selected: tab == .media) { tab = .media }
                    tabPill("SCRIPT", selected: tab == .script) { tab = .script }
                }
                if model.importCount > 0 {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                }
                Spacer()
                AddButton(model: model, symbol: "textformat", payload: .text, help: "Text: click to add at the playhead, or drag to the timeline")
                AddButton(model: model, symbol: "solid", payload: .solid, help: "Solid: click to add at the playhead, or drag to the timeline")
                IconButton(symbol: "square.and.arrow.down", size: 26, help: "Import Media (⌘I)") { model.showImportPanel() }
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .frame(height: 44)
            .contentShape(Rectangle())
            // Right-click: the header buttons' actions in words, and how the list looks.
            .contextMenu { panelMenu }

            if tab == .script {
                ScriptEditorView(model: model, media: media, clock: model.clock)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.project.assets.isEmpty {
                        SearchField(text: $search)
                        Text("Imported media\nappears here")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textFaint)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                    } else {
                        SearchField(text: $search)
                        let order = shown.map(\.id)
                        if layout == .thumbnails {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8, alignment: .top)], spacing: 10) {
                                ForEach(shown) { asset in
                                    AssetTile(model: model, media: media, asset: asset, snippet: snippet(asset), offline: media.looksOffline(asset), selected: inSelection.contains(asset.id),
                                              picked: model.mediaSelection.contains(asset.id), pickedCount: model.mediaSelection.count,
                                              matchesSequence: model.sequenceMatches(asset))
                                        .simultaneousGesture(TapGesture().onEnded { model.clickMedia(asset.id, in: order) })
                                }
                            }
                        } else {
                            VStack(spacing: 3) {
                                ForEach(shown) { asset in
                                    AssetRow(model: model, media: media, asset: asset, snippet: snippet(asset), thumbWidth: thumbWidth, offline: media.looksOffline(asset), selected: inSelection.contains(asset.id),
                                             picked: model.mediaSelection.contains(asset.id), pickedCount: model.mediaSelection.count,
                                             matchesSequence: model.sequenceMatches(asset))
                                        // A click picks it (⇧ for a range, ⌘ to add or take away); a double-click adds it.
                                        .simultaneousGesture(TapGesture().onEnded { model.clickMedia(asset.id, in: order) })
                                }
                            }
                        }
                        if shown.isEmpty {
                            Text(search.contains("\"") || search.contains("“") ? "Nothing says \(search)" : "No media matches “\(search)”")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textFaint)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            // The part of the list on screen, for Magic's scans.
            .background(MagicAnchor(key: "libraryList"))
            // The same menu on the space around the items (each item keeps its own).
            .contextMenu { panelMenu }
            }
        }
        .background(Theme.panel)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { panelWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in panelWidth = w }
        })
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(Theme.accent.opacity(dropTargeted ? 0.9 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { model.importFiles($0) }
            return true
        }
    }
}

extension LibraryView {
    private func tabPill(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.label())
                .kerning(1.2)
                .foregroundStyle(selected ? Theme.text : Theme.textFaint)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Theme.raised : .clear))
        }
        .buttonStyle(.plain)
    }

    /// The Media panel's own menu: add a text or solid at the playhead, import, and List or Thumbnails.
    @ViewBuilder var panelMenu: some View {
        Button("Add Text") { model.addAtPlayhead(.text) }
        Button("Add Solid") { model.addAtPlayhead(.solid) }
        Button("Import Media…") { model.showImportPanel() }
            .keyboardShortcut("i", modifiers: .command)
        Divider()
        Picker("View as", selection: $layout) {
            ForEach(MediaLayout.allCases) { Text($0.name).tag($0) }
        }
        .pickerStyle(.inline)
    }
}

/// Descript-style live Transcript Text Editor: click any sentence to jump the playhead there,
/// or click the scissors icon to ripple-cut that exact phrase out of video + audio in 1 undo step.
private struct ScriptEditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var media: MediaStore
    @ObservedObject var clock: Clock
    @ObservedObject private var transcripts = Transcripts.shared
    @State private var filter = ""
    @State private var hoveredID: String?

    private struct SentenceLine: Identifiable {
        let id: String
        let clipID: UUID
        let start: Double
        let end: Double
        let text: String
    }

    private var lines: [SentenceLine] {
        let audioClips = model.project.clips
            .filter { $0.kind == .audio && $0.assetID != nil }
            .sorted { $0.start < $1.start }
        var out: [SentenceLine] = []
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        for c in audioClips {
            guard let aid = c.assetID, let tr = media.transcript(aid), !tr.isEmpty else { continue }
            let s0 = c.sourceStart
            let s1 = c.sourceStart + c.sourceLength
            let spd = max(0.05, c.speed)
            for (idx, sent) in tr.sentences().enumerated() {
                guard sent.end > s0 && sent.start < s1 else { continue }
                let clippedStart = max(s0, sent.start)
                let clippedEnd = min(s1, sent.end)
                let tStart = c.start + (clippedStart - s0) / spd
                let tEnd = min(c.end, c.start + (clippedEnd - s0) / spd)
                guard tEnd - tStart > 0.04 else { continue }
                if !q.isEmpty, !sent.text.lowercased().contains(q) { continue }
                out.append(SentenceLine(id: "\(c.id.uuidString)-\(idx)", clipID: c.id, start: tStart, end: tEnd, text: sent.text))
            }
        }
        return out
    }

    var body: some View {
        let now = Double(clock.frame) / max(1, model.project.fps)
        let items = lines
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    _ = model.removeSilences(clipIDs: [])
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "scissors").font(.system(size: 10, weight: .semibold))
                        Text("Cut Silences").font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.raised))
                }
                .buttonStyle(.plain)
                .help("Automatically remove dead air across timeline audio clips")

                let allEnhanced = !model.project.clips.filter({ $0.kind == .audio }).isEmpty
                    && model.project.clips.filter({ $0.kind == .audio }).allSatisfy { $0.voiceEnhance == true }
                Button {
                    model.mutate { p in
                        for i in p.clips.indices where p.clips[i].kind == .audio {
                            p.clips[i].voiceEnhance = allEnhanced ? nil : true
                        }
                    }
                    AppleHaptics.click()
                    model.showToast(allEnhanced ? "Voice Enhance OFF" : "Voice Enhance ON")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 10, weight: .semibold))
                        Text("Enhance").font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(allEnhanced ? Color.black : Theme.text)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(allEnhanced ? Color(hex: 0x38BDF8) : Theme.raised))
                }
                .buttonStyle(.plain)
                .help("Studio Voice Enhance (HPF + Presence EQ + Limiter)")

                Spacer()
            }
            .padding(.horizontal, 12)

            SearchField(text: $filter)
                .padding(.horizontal, 12)

            if items.isEmpty {
                VStack(spacing: 10) {
                    Spacer(minLength: 18)
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textFaint)
                    Text(model.project.clips.contains(where: { $0.kind == .audio })
                         ? "No speech transcript ready yet."
                         : "Add video or audio with speech to edit by text.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textFaint)
                        .multilineTextAlignment(.center)
                    if model.project.clips.contains(where: { $0.kind == .audio }), Transcripts.available {
                        Button("Transcribe Timeline") {
                            for c in model.project.clips where c.kind == .audio {
                                if let aid = c.assetID, let url = media.soundURL(aid) {
                                    Transcripts.shared.make(url, soon: true)
                                }
                            }
                            model.showToast("Transcribing timeline audio…")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { line in
                            let active = now >= line.start - 0.05 && now <= line.end + 0.05
                            let hovering = hoveredID == line.id
                            HStack(alignment: .top, spacing: 6) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(Timecode.short(line.start))
                                        .font(Theme.mono(9.5, .medium))
                                        .foregroundStyle(active ? Color(hex: 0x38BDF8) : Theme.textFaint)
                                    Text(line.text)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(active ? Theme.text : Theme.textDim)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if hovering || active {
                                    Button {
                                        model.cutTimeSpan(from: line.start, to: line.end, clipIDs: [line.clipID])
                                    } label: {
                                        Image(systemName: "scissors")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(Color(hex: 0xF5C542))
                                            .frame(width: 22, height: 22)
                                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.raised))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Ripple-cut this sentence out of the timeline")
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(active ? Color(hex: 0x38BDF8).opacity(0.14) : (hovering ? Theme.hover : Theme.field.opacity(0.6))))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(active ? Color(hex: 0x38BDF8).opacity(0.65) : .clear, lineWidth: 1))
                            .contentShape(Rectangle())
                            .onHover { hoveredID = $0 ? line.id : (hoveredID == line.id ? nil : hoveredID) }
                            .onTapGesture {
                                model.seek(to: line.start)
                                AppleHaptics.tick()
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            // A quote searches what's said: the icon says so as soon as it's typed.
            let saying = text.contains("\"") || text.contains("“")
            Image(systemName: saying ? "text.bubble" : "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(saying ? Theme.text : Theme.textFaint)
                .help(saying ? "Searching what's said in your clips" : "")
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.text.opacity(focused ? 0.85 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

/// A library item's picture. Moving the mouse across a video's thumbnail scrubs through it.
private struct MediaThumb: View {
    @ObservedObject var media: MediaStore
    /// Where to show the hovered frame full size; nil keeps scrubbing to the thumbnail.
    var preview: SourcePreviewState?
    let asset: MediaAsset
    let offline: Bool
    var compact = false
    @State private var scrub: CGFloat?
    @State private var frame: CGImage?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.5)
                if let frame, scrub != nil {
                    Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height).clipped()
                } else if let poster = media.posters[asset.id] {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height).clipped()
                } else {
                    Image(systemName: asset.kind == .audio ? "waveform" : asset.kind == .image ? "photo" : "film")
                        .font(.system(size: compact ? 13 : 20, weight: .regular))
                        .foregroundStyle(asset.kind == .audio ? Theme.textDim : Theme.textFaint)
                        .frame(width: g.size.width, height: g.size.height)
                }
                if offline {
                    Color.black.opacity(0.6)
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        .frame(width: g.size.width, height: g.size.height)
                }
                if let scrub {
                    Rectangle().fill(Color.white).frame(width: 1.5, height: g.size.height).offset(x: scrub - 0.75)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard asset.kind == .video, !offline, asset.duration > 0 else { return }
                switch phase {
                case .active(let p):
                    let x = min(max(0, p.x), g.size.width)
                    scrub = x
                    let fraction = Double(x / max(1, g.size.width))
                    // A frame made ahead, at once; until the strip is made, one decoded from the file.
                    let quick = media.instantFrame(asset: asset, at: fraction)
                    if let quick {
                        frame = quick
                    } else {
                        // Quantise so nearby positions share cached frames.
                        let steps = 60.0
                        let t = min(asset.duration - 0.05, (fraction * steps).rounded() / steps * asset.duration)
                        media.scrubFrame(asset: asset.id, time: max(0, t)) { img in
                            if scrub != nil { frame = img }
                        }
                    }
                    // The main viewer shows it too, full size and in playback's colours.
                    let exact = min(asset.duration - 0.02, fraction * asset.duration)
                    preview?.hover(asset, at: max(0, exact), media: media)
                case .ended:
                    scrub = nil
                    frame = nil
                    preview?.clear()
                }
            }
        }
    }
}

func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

private struct AddButton: View {
    let model: EditorModel
    let symbol: String
    let payload: DragPayload
    let help: String
    @State private var hovering = false

    var body: some View {
        Glyph(symbol: symbol, size: 12)
            .foregroundStyle(hovering ? Theme.text : Theme.textDim)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onTapGesture { model.addAtPlayhead(payload) }
            .background(MagicAnchor(key: payload == .text ? "addText" : "addSolid"))
            .onDrag {
                model.dragPayload = payload
                return NSItemProvider(object: ("editroom:" + (payload == .text ? "text" : "solid")) as NSString)
            }
            .help(help)
    }
}

/// Shared behaviour for a library item: double-click adds it, drag it out, right-click for more.
private struct AssetActions: ViewModifier {
    let model: EditorModel
    let asset: MediaAsset
    let offline: Bool
    let picked: Bool
    let pickedCount: Int
    let matchesSequence: Bool

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) { model.addAtPlayhead(.asset(asset.id)) }
            .onDrag {
                model.dragPayload = .asset(asset.id)
                // Dragging one of several picked items takes them all, in the Media panel's order.
                let ids = picked && pickedCount > 1
                    ? model.project.assets.map(\.id).filter { model.mediaSelection.contains($0) }
                    : [asset.id]
                return NSItemProvider(object: ("editroom:" + ids.map(\.uuidString).joined(separator: ",")) as NSString)
            }
            .contextMenu {
                if offline {
                    Button("Locate…") { model.locate(asset.id) }
                    Divider()
                }
                Button("Add to Timeline") { model.addAtPlayhead(.asset(asset.id)) }
                if asset.kind == .video {
                    Button("Match Sequence to Clip") { model.matchSequence(to: asset) }
                        .disabled(matchesSequence)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.path)]) }
                if !offline {
                    // Normally automatic (when Editroom comes back to the front); this is for being sure.
                    let ids = picked && pickedCount > 1 ? model.mediaSelection : [asset.id]
                    Button(ids.count > 1 ? "Reload \(ids.count) Items from Disk" : "Reload from Disk") {
                        Task { await model.reloadMedia(ids) }
                    }
                }
                Divider()
                // The picked items when this is one of them; otherwise just this one.
                if picked, pickedCount > 1 {
                    Button("Delete \(pickedCount) Items") { model.removeAssets(model.mediaSelection) }
                } else {
                    Button("Delete") { model.removeAssets([asset.id]) }
                }
            }
    }
}

private struct AssetRow: View {
    let model: EditorModel
    let media: MediaStore
    let asset: MediaAsset
    /// Where it says what's being searched for.
    var snippet: (before: String, match: String, after: String)?
    var thumbWidth: CGFloat = 64
    let offline: Bool
    /// Used by a clip selected on the timeline.
    let selected: Bool
    /// Picked in the Media panel.
    let picked: Bool
    let pickedCount: Int
    /// The sequence already has this video's size and rate. Passed in (rather than read from the
    /// model in the menu) so the row, and its menu, update when the sequence changes.
    let matchesSequence: Bool
    @State private var hovering = false

    /// Under the name: just how long it is (the frame size is on hover).
    private var detail: String {
        switch asset.kind {
        case .video: Timecode.short(asset.duration)
        case .audio: Timecode.short(asset.duration) + "  ·  Audio"
        case .image: "Photo"
        }
    }

    /// On hover: everything about the file.
    private var details: String {
        var parts = [asset.name]
        if asset.kind != .image { parts.append(Timecode.short(asset.duration)) }
        if asset.width > 0 { parts.append("\(asset.width)×\(asset.height)") }
        if asset.kind == .video, asset.fps > 0 { parts.append(String(format: "%g fps", (asset.fps * 100).rounded() / 100)) }
        if asset.kind == .audio { parts.append("Audio") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 9) {
            MediaThumb(media: media, preview: model.sourcePreview, asset: asset, offline: offline, compact: true)
                .frame(width: thumbWidth, height: (thumbWidth * 9 / 16).rounded())
                .background(MagicAnchor(key: asset.id.uuidString))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovering || selected || picked ? Theme.text : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                if let snippet { SaidLine(snippet: snippet) }
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(picked ? Theme.ink.opacity(0.12) : hovering ? Theme.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(picked ? Theme.ink.opacity(0.18) : Theme.control.opacity(selected ? 1 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(details)
        .modifier(AssetActions(model: model, asset: asset, offline: offline, picked: picked, pickedCount: pickedCount,
                               matchesSequence: matchesSequence))
    }
}

/// How the Media panel shows its items.
enum MediaLayout: String, CaseIterable, Identifiable {
    case thumbnails, list
    static let key = "mediaLayout"
    var id: String { rawValue }
    var name: String { self == .list ? "List" : "Thumbnails" }
}

/// A Media item as a larger picture, its name underneath: the Thumbnails layout.
private struct AssetTile: View {
    let model: EditorModel
    let media: MediaStore
    let asset: MediaAsset
    var snippet: (before: String, match: String, after: String)?
    let offline: Bool
    let selected: Bool
    let picked: Bool
    let pickedCount: Int
    let matchesSequence: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            MediaThumb(media: media, preview: model.sourcePreview, asset: asset, offline: offline)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(MagicAnchor(key: asset.id.uuidString))
                .overlay(alignment: .bottomTrailing) {
                    if asset.kind != .image {
                        Text(Timecode.short(asset.duration))
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Color(hex: 0xF2F2F0))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.black.opacity(0.55)))
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(picked ? Theme.ink.opacity(0.85) : Theme.control.opacity(selected ? 1 : 0), lineWidth: picked ? 1.5 : 1))
            Text(asset.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering || selected || picked ? Theme.text : Theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 2)
            if let snippet { SaidLine(snippet: snippet).padding(.horizontal, 2) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(picked ? Theme.ink.opacity(0.12) : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .modifier(AssetActions(model: model, asset: asset, offline: offline, picked: picked, pickedCount: pickedCount,
                               matchesSequence: matchesSequence))
    }
}

/// What a clip says around the words being searched for, those words in bold.
private struct SaidLine: View {
    let snippet: (before: String, match: String, after: String)

    var body: some View {
        (Text("“" + (snippet.before.isEmpty ? "" : snippet.before + " "))
            + Text(snippet.match).bold().foregroundColor(Theme.text)
            + Text((snippet.after.isEmpty ? "" : " " + snippet.after) + "”"))
            .font(.system(size: 10))
            .foregroundStyle(Theme.textDim)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
