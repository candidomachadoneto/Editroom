import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: EditorModel
    @State private var libraryWidth: CGFloat = 252
    @State private var timelineHeight: CGFloat = 360
    @State private var dropTargeted = false
    @AppStorage("magicEnabled") private var magicEnabled = true
    /// While Magic works the editor is locked: nothing under the mouse reacts (hover, scrubbing).
    @ObservedObject private var magic = MagicState.shared
    private var locked: Bool { magic.stage != nil }
    @Environment(\.openSettings) private var openSettings
    /// A new theme rebuilds the editor's views, so every colour is read again.
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            if model.viewerOnly {
                PreviewView(model: model)
            } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    LibraryView(model: model, media: model.media)
                        .frame(width: libraryWidth)
                        // `--library-width N` (testing): the Media panel that wide.
                        .onAppear {
                            let args = CommandLine.arguments
                            if let k = args.firstIndex(of: "--library-width"), args.count > k + 1, let w = Double(args[k + 1]) {
                                libraryWidth = min(440, max(190, w))
                            }
                        }
                        .background(MagicAnchor(key: "library"))
                    Splitter(vertical: true) { x in
                        libraryWidth = min(440, max(190, x - frame.minX))
                    }
                    PreviewView(model: model)
                    Hairline(vertical: true)
                    InspectorView(model: model)
                        .frame(width: InspectorView.width)
                        .background(MagicAnchor(key: "inspector"))
                }
                .allowsHitTesting(!locked)
                Splitter(vertical: false) { y in
                    timelineHeight = min(max(200, geo.size.height - 240), max(170, frame.maxY - y))
                }
                TimelinePanel(model: model)
                    .frame(height: min(timelineHeight, max(170, geo.size.height - 240)))
                    .allowsHitTesting(!locked)
            }
            // A Media item being scrubbed when Magic starts lets the viewer go back.
            .onChange(of: locked) { _, now in if now { model.sourcePreview.clear() } }
            // A hairline under the title bar.
            .overlay(alignment: .top) { Hairline(solid: true) }
            }
        }
        .id(themes.look)
        .background(Theme.bg)
        // Files dropped anywhere the timeline or library doesn't handle them are imported.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { model.handleOpen($0) }
            return true
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    Theme.accent.opacity(0.06)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .padding(6)
                    Text("Drop to import")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(Theme.raised))
                }
                .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(Theme.scheme)
        // The title bar in the panel black, not macOS's lighter default.
        .toolbarBackground(Theme.panel, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                    if model.isDirty {
                        Circle().fill(Theme.textFaint).frame(width: 5, height: 5)
                    }
                }
                .id(themes.look)
            }
            .withoutGlass()
            ToolbarItem(placement: .primaryAction) {
                ExportProgressPill(queue: model.exports)
                    .id(themes.look)
            }
            .withoutGlass()
            ToolbarItem(placement: .primaryAction) {
                SwarmHUDButton(model: model)
                    .padding(.trailing, 4)
                    .id(themes.look)
            }
            .withoutGlass()
            ToolbarItem(placement: .primaryAction) {
                MagicVoiceButton()
                    .padding(.trailing, 4)
                    .id(themes.look)
            }
            .withoutGlass()
            if magicEnabled {
                ToolbarItem(placement: .primaryAction) {
                    MagicButton(model: model)
                        .padding(.trailing, 8)
                        .id(themes.look)
                }
                .withoutGlass()
            }
            ToolbarItem(placement: .primaryAction) {
                PillButton(title: "Export", prominent: true) { model.showExport = true }
                    .help("Export (\(ShortcutStore.shared.combos(.export).first?.display ?? "⌘E"))")
                    .padding(.trailing, 10)
                    .id(themes.look)
            }
            .withoutGlass()
        }
        .sheet(isPresented: $model.showExport) {
            ExportSheet(model: model)
        }
        // "Manage AI Agents" (and `--show-agents`): Settings, on its Magic tab.
        .onChange(of: model.showAgents) { _, show in
            guard show else { return }
            // (`--settings-tab shortcuts|magic|updates`, testing: that tab instead.)
            let args = CommandLine.arguments
            let tab = args.firstIndex(of: "--settings-tab").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "magic"
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            openSettings()
            model.showAgents = false
        }
        .alert("Import", isPresented: Binding(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.importError ?? "")
        }
        .onAppear {
            KeyCommands.install(model)
            AppDelegate.shared?.model = model
        }
    }
}

/// Toolbar live Swarm HUD & Command Deck: displays pulsing color-coded squad dots whenever
/// nano-bots are editing in parallel, and lets the user launch multi-agent swarms in 1 click.
private struct SwarmHUDButton: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var presence = AgentPresence.shared
    @AppStorage(AgentPresence.enabledKey) private var swarmVisual = true
    @State private var open = false
    @State private var hovering = false

    private var activeSquads: [SwarmSquad] {
        var seen = Set<SwarmSquad>()
        return presence.activeBots.compactMap { bot in
            seen.insert(bot.squad).inserted ? bot.squad : nil
        }
    }

    var body: some View {
        let busy = !presence.activeBots.isEmpty
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    let dots = busy ? activeSquads : [.framer, .cards, .cutter, .audio]
                    ForEach(dots.prefix(5)) { sq in
                        Circle()
                            .fill(sq.swiftColor)
                            .frame(width: busy ? 6.5 : 5.5, height: busy ? 6.5 : 5.5)
                            .shadow(color: busy ? sq.swiftColor.opacity(0.8) : .clear, radius: 3)
                    }
                }
                Text(busy ? "\(presence.activeBots.count) Bots" : "Swarm")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(busy ? Color.white : (swarmVisual ? Theme.text : Theme.textFaint))
            }
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(
                Capsule().fill(busy ? Color(hex: 0x0F172A) : (hovering || open ? Theme.hover : Theme.field))
            )
            .overlay(
                Capsule().strokeBorder(busy ? Color(hex: 0x38BDF8).opacity(0.8) : Theme.ink.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Nano-Bot Swarm Command Deck (parallel color-coded agents)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SwarmCommandDeck(model: model, swarmVisual: $swarmVisual) { open = false }
        }
    }
}

private struct SwarmCommandDeck: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var presence = AgentPresence.shared
    @Binding var swarmVisual: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nano-Bot Swarm")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(presence.missionTitle ?? "Parallel color-coded agents working in sync")
                        .font(.system(size: 10.5))
                        .foregroundStyle(presence.missionTitle != nil ? Color(hex: 0x38BDF8) : Theme.textFaint)
                }
                Spacer()
                Toggle("", isOn: $swarmVisual)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(Color(hex: 0x38BDF8))
                    .help("Show visual nano-bot cursors & sync mesh by default")
            }

            // 6 Official Squads legend (Color + Role + Live status)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(SwarmSquad.allCases) { sq in
                    let active = presence.activeBots.first { $0.squad == sq }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sq.swiftColor)
                            .frame(width: 8, height: 8)
                            .shadow(color: active != nil ? sq.swiftColor : .clear, radius: 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sq.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text(active?.action.isEmpty == false ? active!.action : sq.roleDescription)
                                .font(.system(size: 9.5))
                                .foregroundStyle(active != nil ? sq.swiftColor : Theme.textFaint)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active != nil ? sq.swiftColor.opacity(0.12) : Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(active != nil ? sq.swiftColor.opacity(0.55) : .clear, lineWidth: 1))
                }
            }

            Divider().opacity(0.25)

            Text("LAUNCH PARALLEL SWARM")
                .font(Theme.label())
                .kerning(1.2)
                .foregroundStyle(Theme.textFaint)

            VStack(spacing: 6) {
                missionRow(title: "News Reel 9:16 (Full Swarm)",
                           detail: "9:16 · Face Track · Keep Card + Polish · Voice Enhance · Cut Silences",
                           squads: [.framer, .cards, .motion, .audio, .cutter]) {
                    close()
                    Task { await model.applyNewsReelMacro() }
                }
                missionRow(title: "Polish All Cards & Overlays",
                           detail: "Isolates V2+ cards, adds shadow/border & Slide Down entrance",
                           squads: [.cards, .motion]) {
                    close()
                    model.swarmPolishAllCards()
                }
                missionRow(title: "Cut Silences + Voice Enhance",
                           detail: "Removes dead air & activates studio vocal chain in sync",
                           squads: [.cutter, .audio]) {
                    close()
                    model.swarmAudioAndSilences()
                }
                missionRow(title: "Face Track All Video Clips",
                           detail: "Neural Engine face detection & auto-reframe across V1",
                           squads: [.framer]) {
                    close()
                    let ids = Set(model.project.clips.filter { $0.kind == .video || $0.kind == .image }.map(\.id))
                    Task { await model.autoReframeFaces(clipIDs: ids) }
                }
                missionRow(title: "Cinematic Finish",
                           detail: "Film Print grade · Card Polish · Pop motion · Voice Enhance",
                           squads: [.colorist, .cards, .motion, .audio]) {
                    close()
                    model.swarmCinematicFinish()
                }
            }
        }
        .padding(14)
        .frame(width: 368)
        .background(Theme.panel)
    }

    private func missionRow(title: String, detail: String, squads: [SwarmSquad], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    ForEach(squads) { sq in
                        Circle().fill(sq.swiftColor).frame(width: 6, height: 6)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

/// Bare-key shortcuts (space, V, C, arrows…) that should work anywhere except while typing.
@MainActor
enum KeyCommands {
    private static var installed = false
    /// The editor window, where the bare-key shortcuts work.
    private static weak var editor: NSWindow?

    static func install(_ model: EditorModel) {
        guard !installed else { return }
        installed = true
        // Hand the Dock the icon directly rather than relying on its cache of this bundle path.
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.backgroundColor = Theme.NS.panel
                window.titlebarAppearsTransparent = true
            }
            ThemeStore.shared.apply()
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event, model) ? nil : event }
        }
    }

    private static func handle(_ e: NSEvent, _ model: EditorModel) -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        let keys = ShortcutStore.shared
        // Settings is recording a shortcut: the key is for it.
        if keys.recording != nil { return false }
        // While the magic show runs, keys are handled by the show (any key skips to the end).
        if MagicShow.isRunning { return false }
        let combo = KeyCombo(event: e)
        if let responder = window.firstResponder, responder is NSText {
            // Plain keys that are also menu shortcuts (S, R, K, ⌫…) would be taken by the menu before the
            // text field sees them, so hand them straight to the window to be typed.
            if let combo, keys.isTypedMenuKey(combo) {
                window.sendEvent(e)
                return true
            }
            return false
        }
        // Only the editor window gets these; sheets, panels and Settings keep their keys. It's remembered from
        // the timeline, which the full-screen viewer takes out of the window.
        if let w = TimelineCanvas.current?.window { editor = w }
        guard editor === window, window.attachedSheet == nil, window.sheetParent == nil,
              !(window is NSPanel) else { return false }

        if e.keyCode == 53, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if model.viewerOnly { model.toggleViewerFullScreen(); return true }
            model.selection = []
            model.mediaSelection = []
            model.tool = .move
            return true
        }
        guard let combo, let action = keys.action(for: combo) else { return false }
        // ⌘ shortcuts of menu items go to the menu, so it flashes.
        if action.inMenu, combo.command { return false }
        perform(action, model)
        return true
    }

    static func perform(_ a: ShortcutAction, _ model: EditorModel) {
        switch a {
        case .new: model.newProject()
        case .open: model.openProject()
        case .save: model.save()
        case .saveAs: model.saveAs()
        case .importMedia: model.showImportPanel()
        case .export: model.showExport = true
        case .undo: model.undo()
        case .redo: model.redo()
        case .playPause: model.togglePlay()
        case .stepBack: model.step(frames: -1)
        case .stepForward: model.step(frames: 1)
        case .previousEdit: model.jumpToEdit(forward: false)
        case .nextEdit: model.jumpToEdit(forward: true)
        case .goToStart: model.seek(to: 0)
        case .goToEnd: model.seek(to: model.project.duration)
        case .loop: model.loop.toggle()
        case .fullScreenViewer: model.toggleViewerFullScreen()
        case .selectTool: model.tool = .move
        case .cutTool: model.tool = .cut
        case .split: model.splitAtPlayhead()
        case .addDissolve: model.addTransitionAtPlayhead()
        case .detachAudio: model.detachAudio()
        case .duplicate: model.duplicateSelection()
        case .freezeFrame: model.freezeFrame()
        case .reverse: model.reverseSelection()
        case .copyGrade: model.copyGrade()
        case .pasteGrade: model.pasteGrade()
        case .delete: model.deleteSelected()
        case .rippleDelete: model.deleteSelected(ripple: true)
        case .rippleTrimStart: model.rippleTrim(head: true)
        case .rippleTrimEnd: model.rippleTrim(head: false)
        case .addText: model.addAtPlayhead(.text)
        case .addMarker: model.addMarker()
        case .setIn: model.setInPoint()
        case .setOut: model.setOutPoint()
        case .clearInOut: model.clearRange()
        case .zoomIn: model.zoom(by: 1.4)
        case .zoomOut: model.zoom(by: 1 / 1.4)
        case .zoomToFit: model.zoomToFit()
        case .snapping: model.snapping.toggle()
        case .sticky: model.sticky.toggle()
        case .skimming: model.skimming.toggle()
        case .audioScrubbing: model.audioScrub.toggle()
        }
    }
}

extension ToolbarContent {
    /// Opts a toolbar item out of the system's shared glass background where that exists.
    @ToolbarContentBuilder
    func withoutGlass() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}


/// Magic Voice button (OpenAI GPT-2.1 Realtime + xAI Grok Voice + Multi-Model Team + Self-Improving Taste Memory).
/// Strictly decoupled: only calls `VoiceBridge` methods and observes `VoiceBridge.state`.
struct MagicVoiceButton: View {
    @ObservedObject private var bridge = VoiceBridge.shared
    @State private var hovering = false
    @State private var pulse = false
    @State private var showDeck = false

    private var tooltip: String {
        switch bridge.state {
        case .idle:
            return "Magic (\(bridge.voiceModel.shortLabel)) — Clique ou ⌘⇧M para falar com o editor."
        case .listening:
            if let team = bridge.activeTeamStatus { return "Equipe ativa: \(team)…" }
            return "Magic ouvindo (\(bridge.voiceModel.shortLabel))… Clique ou ⌘⇧M para parar."
        case .speaking:
            return "Magic respondendo… Fale por cima para interromper ou clique para parar."
        case .error(let msg):
            return msg
        }
    }

    private var iconName: String {
        switch bridge.state {
        case .idle, .listening: return "wand.and.stars"
        case .speaking: return "waveform"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var accentColor: Color {
        switch bridge.state {
        case .idle: return Theme.text
        case .listening: return Theme.accent
        case .speaking: return Color(hex: 0x38BDF8)
        case .error: return Color(hex: 0xEF4444)
        }
    }

    private var fillColor: Color {
        switch bridge.state {
        case .idle: return Theme.ink.opacity(hovering ? 0.14 : 0.08)
        case .listening: return Theme.accent.opacity(hovering ? 0.24 : 0.18)
        case .speaking: return Color(hex: 0x38BDF8).opacity(hovering ? 0.24 : 0.18)
        case .error: return Color(hex: 0xEF4444).opacity(hovering ? 0.22 : 0.15)
        }
    }

    private var strokeColor: Color {
        switch bridge.state {
        case .idle: return Theme.ink.opacity(0.06)
        case .listening: return Theme.accent.opacity(pulse ? 0.85 : 0.45)
        case .speaking: return Color(hex: 0x38BDF8).opacity(pulse ? 0.90 : 0.50)
        case .error: return Color(hex: 0xEF4444).opacity(0.60)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                bridge.toggle()
            } label: {
                HStack(spacing: 5) {
                    ZStack {
                        if bridge.state == .listening || bridge.state == .speaking {
                            let boost = CGFloat(bridge.state == .listening ? min(0.45, bridge.micLevel * 0.5) : 0.2)
                            Circle()
                                .fill(accentColor.opacity(pulse ? 0.30 : 0.10))
                                .frame(width: 17, height: 17)
                                .scaleEffect((pulse ? 1.12 : 0.88) + boost)
                        }
                        Image(systemName: iconName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accentColor)
                    }
                    .frame(width: 14, height: 14)

                    Text(bridge.activeTeamStatus != nil ? "Equipe…" : "Magic")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(bridge.state == .idle ? Theme.text : accentColor)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Theme.ink.opacity(0.12))
                .frame(width: 1, height: 14)

            Button {
                bridge.refreshPreferences()
                showDeck.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(bridge.state == .idle ? Theme.textDim : accentColor)
                    .padding(.horizontal, 7)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Escolher modelos (OpenAI, Claude, Gemini, Grok) e memória de gosto")
        }
        .fixedSize()
        .background(Capsule().fill(fillColor))
        .overlay(Capsule().strokeBorder(strokeColor, lineWidth: bridge.state == .idle ? 1 : 1.3))
        .onHover { hovering = $0 }
        .help(tooltip)
        .popover(isPresented: $showDeck, arrowEdge: .bottom) {
            VoiceDirectorPopover(bridge: bridge)
        }
        .onAppear {
            bridge.prewarm()
        }
        .onChange(of: bridge.state) { _, newState in
            if newState == .listening || newState == .speaking {
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    pulse = false
                }
            }
        }
    }
}

private struct VoiceDirectorPopover: View {
    @ObservedObject var bridge: VoiceBridge
    @State private var newRule = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diretor de Voz · Magic")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Voz streaming + equipe multi-modelo + gosto aprendido")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Button(bridge.state.isActive ? "Parar" : "Falar") {
                    bridge.toggle()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(bridge.state.isActive ? Color(hex: 0xEF4444) : Color(hex: 0x38BDF8))
            }

            // 1. Streaming Voice Front-End picker
            VStack(alignment: .leading, spacing: 6) {
                Text("VOZ EM TEMPO REAL (VELOCIDADE)")
                    .font(Theme.label()).kerning(1.1).foregroundStyle(Theme.textFaint)
                Picker("", selection: $bridge.voiceModel) {
                    ForEach(VoiceEngineModel.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if bridge.voiceModel.provider == .openai {
                    HStack(spacing: 6) {
                        Text("Detecção de fala:").font(.system(size: 10.5)).foregroundStyle(Theme.textDim)
                        Picker("", selection: $bridge.vadMode) {
                            ForEach(VoiceVADMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                    }
                }
            }

            Divider().opacity(0.25)

            // 2. Multi-Model Team (combine any models!)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("EQUIPE MULTI-MODELO (1 OU VÁRIOS JUNTOS)")
                        .font(Theme.label()).kerning(1.1).foregroundStyle(Theme.textFaint)
                    Spacer()
                    Text("\(bridge.enabledSpecialists.count) ativo\(bridge.enabledSpecialists.count == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x38BDF8))
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(SpecialistModel.allCases) { m in
                        let on = bridge.enabledSpecialists.contains(m)
                        Button {
                            bridge.toggleSpecialist(m)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(on ? Color(hex: 0x38BDF8) : Theme.textFaint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.label)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    Text(m.roleSummary)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(Theme.textFaint)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(on ? Color(hex: 0x38BDF8).opacity(0.12) : Theme.field))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(on ? Color(hex: 0x38BDF8).opacity(0.55) : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().opacity(0.25)

            // 3. Learned Editing Taste Memory (SQLite + Supermemory)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("GOSTO APRENDIDO (AUTO-APERFEIÇOAMENTO)")
                        .font(Theme.label()).kerning(1.1).foregroundStyle(Theme.textFaint)
                    Spacer()
                    Text("\(bridge.preferences.count)")
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(Theme.textFaint)
                }

                HStack(spacing: 6) {
                    TextField("Ex.: cortes secos sem fade, título dourado no topo…", text: $newRule)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
                        .onSubmit(saveQuickRule)
                    Button("Ensinar") { saveQuickRule() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if bridge.preferences.isEmpty {
                    Text("Fale durante a edição (ex.: \"sempre faz assim\") para o editor aprender seu estilo.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(bridge.preferences.prefix(8)) { pref in
                                HStack(spacing: 6) {
                                    Text(pref.scope == .global ? "Sempre" : "Projeto")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(pref.scope == .global ? Color(hex: 0xF5C542) : Color(hex: 0x38BDF8))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(Theme.raised))
                                    Text(pref.rule)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.textDim)
                                        .lineLimit(2)
                                    Spacer(minLength: 4)
                                    Button {
                                        bridge.deletePreference(id: pref.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Theme.textFaint)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Esquecer preferência")
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field.opacity(0.65)))
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }

            Divider().opacity(0.25)

            // 4. Keychain status (never shows secrets)
            HStack(spacing: 8) {
                keyStatusChip(.openai, title: "OpenAI")
                keyStatusChip(.xai, title: "xAI")
                Spacer()
                Text("⌘⇧M").font(Theme.mono(10, .medium)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(14)
        .frame(width: 392)
        .background(Theme.panel)
    }

    private func saveQuickRule() {
        let trimmed = newRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        bridge.addExplicitPreference(rule: trimmed, category: "style", scope: .global)
        newRule = ""
    }

    private func keyStatusChip(_ provider: VoiceKeychain.Provider, title: String) -> some View {
        let ok = VoiceKeychain.loadAPIKey(for: provider) != nil
        return Button {
            promptForAPIKey(provider: provider, title: title)
        } label: {
            HStack(spacing: 4) {
                Circle().fill(ok ? Color(hex: 0x22C55E) : Color(hex: 0xF97316)).frame(width: 6, height: 6)
                Text("\(title) Key").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
        }
        .buttonStyle(.plain)
        .help(ok ? "\(title) configurada no Keychain (clique para atualizar)" : "Clique para salvar \(provider.envName) no Keychain")
    }

    private func promptForAPIKey(provider: VoiceKeychain.Provider, title: String) {
        let alert = NSAlert()
        alert.messageText = "Chave \(title) (\(provider.envName))"
        alert.informativeText = "Salva com segurança apenas no Keychain do macOS (nunca em arquivos do projeto)."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = provider == .openai ? "sk-..." : "xai-..."
        alert.accessoryView = field
        alert.addButton(withTitle: "Salvar no Keychain")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, VoiceKeychain.saveAPIKey(key, for: provider) {
                bridge.prewarm()
            }
        }
    }
}

/// Starts the magic edit. With Claude or ChatGPT on this Mac, it asks what to make first, the AI works
/// it out in the background, and the swarm plays it onto the timeline. Without one, the swarm builds a
/// cut on its own. While the AI works, a click stops it.
struct MagicButton: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var state = MagicState.shared
    @ObservedObject var ai = MagicAgent.shared
    @ObservedObject var connections = AgentConnect.shared
    @State private var hovering = false

    private var hasMedia: Bool { model.project.assets.contains { $0.kind != .audio } || !model.project.clips.isEmpty }
    /// What Magic is doing, shown beside the button ("Looking at kareoke", "Analyzing 3 of 5", "Editing");
    /// the button itself names who is working.
    private var status: String? {
        if ai.running {
            if let stage = state.stage {
                // What it's doing right now, while the thinking show runs; the swarm says "Editing".
                if stage != "Editing", let doing = state.activity { return Self.sentence(doing) }
                return stage
            }
            guard let s = ai.status else { return nil }
            if let name = ai.agent?.name, s.hasPrefix("\(name) is ") { return Self.sentence(String(s.dropFirst(name.count + 4))) }
            return s
        }
        return ai.ready ?? state.status ?? state.stage
    }
    private static func sentence(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    private static func clipped(_ s: String) -> String { s.count > 40 ? String(s.prefix(39)) + "…" : s }
    /// Who's working, in the button: Claude or ChatGPT, or Local for Editroom's own cut.
    private var worker: String? {
        if ai.running { return ai.agent?.name }
        return state.busy || state.stage != nil ? "Local" : nil
    }
    /// While Magic works, hovering offers Stop in the same space.
    private var offerStop: Bool { working && hovering }
    /// Anything Magic is doing that Stop (or esc) can stop: an AI working, Local reading or studying, the
    /// thinking show, or the swarm.
    private var working: Bool { ai.running || state.busy || state.stage != nil }

    /// One of the button's faces.
    private func face(_ text: String, spinning: Bool = false, icon: String = "wand.and.sparkles") -> some View {
        HStack(spacing: 5) {
            if spinning {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Right-aligned, so it grows to the left, away from the button.
            // Kept at its own size (long ones cut short by hand): in the toolbar, anything that can
            // shrink is shrunk, and the button must never be.
            Text(Self.clipped(status ?? ""))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text.opacity(0.6))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .id(status ?? "")
                .transition(.opacity)
                .animation(.easeOut(duration: 0.2), value: status)
                .allowsHitTesting(false)
            button.fixedSize().layoutPriority(1)
        }
        .fixedSize()
    }

    private var button: some View {
        Button {
            if working { MagicShow.stopAll() }
            else {
                connections.refresh()
                ai.note = nil
                ai.asking = true
            }
        } label: {
            ZStack {
                // Sized for who's working (or AI), with room for Stop: it changes size only when a run
                // starts or ends, never during one.
                face(worker ?? "AI", spinning: worker != nil).hidden()
                face("Stop", icon: "stop.fill").hidden()
                Group {
                    if let worker {
                        face(worker, spinning: true)
                    } else {
                        // Finished while away: sparkles until they're back.
                        face("AI", icon: "sparkles")
                    }
                }
                .opacity(offerStop ? 0 : 1)
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Stop")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                .opacity(offerStop ? 1 : 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .fixedSize()
            .background(Capsule().fill(Theme.ink.opacity(hovering ? 0.14 : 0.08)))
            .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(MagicAnchor(key: "magicButton"))
        .disabled(!working && (!hasMedia || MagicShow.isRunning))
        .opacity(hasMedia || working ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // Which AIs are connected can change in AI Agents or in the apps themselves.
        .onAppear { connections.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connections.refresh()
        }
        .help(working ? "Stop Magic (esc)" : !hasMedia ? "Import some clips first"
              : "Magic: have Claude or ChatGPT edit, or make a quick cut")
        // One popover: what to make, or what the AI said when it finished.
        .popover(isPresented: Binding(get: { ai.asking || ai.note != nil },
                                      set: { if !$0 { ai.asking = false; ai.note = nil } }), arrowEdge: .bottom) {
            Group {
                if let note = ai.note {
                    MagicNoteView(note: note, model: model) { ai.note = nil }
                } else {
                    MagicPopover(model: model, ai: ai) { ai.asking = false }
                }
            }
            // The whole popover, arrow included, in the panel colour: otherwise its lighter system
            // background flickers through at the top while it resizes.
            .presentationBackground(Theme.panel)
        }
    }
}
