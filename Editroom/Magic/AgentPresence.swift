import AppKit
import QuartzCore
import SwiftUI

/// Functional Nano-Bot Squads: each squad has a distinct color, role, and visual signature
/// so parallel agents working across the timeline and preview read immediately at a glance.
enum SwarmSquad: String, CaseIterable, Identifiable {
    case cutter
    case framer
    case cards
    case colorist
    case motion
    case audio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cutter: return "Cutter"
        case .framer: return "Framer"
        case .cards: return "Cards"
        case .colorist: return "Color"
        case .motion: return "Motion"
        case .audio: return "Audio"
        }
    }

    var roleDescription: String {
        switch self {
        case .cutter: return "Cuts, silences, trims & ripple"
        case .framer: return "Auto-reframe, face track, crop & align"
        case .cards: return "Keep Card, Remove BG, polish & blur"
        case .colorist: return "Looks, exposure, contrast & grade"
        case .motion: return "Animations, keyframes, titles & captions"
        case .audio: return "Voice Enhance, levels, fades & ducking"
        }
    }

    var symbol: String {
        switch self {
        case .cutter: return "scissors"
        case .framer: return "viewfinder"
        case .cards: return "doc.text.viewfinder"
        case .colorist: return "camera.filters"
        case .motion: return "sparkles"
        case .audio: return "waveform"
        }
    }

    var hex: UInt32 {
        switch self {
        case .cutter: return 0xF97316   // Electric Orange
        case .framer: return 0x38BDF8   // Laser Cyan
        case .cards: return 0xF5C542    // Editorial Gold
        case .colorist: return 0x10B981 // Studio Emerald
        case .motion: return 0xFB7185   // Coral Neon
        case .audio: return 0x22C55E    // Broadcast Green
        }
    }

    var nsColor: NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    var swiftColor: Color { Color(hex: hex) }

    /// Infers the most accurate squad from an agent name or edit label.
    static func infer(agent: String = "", label: String = "") -> SwarmSquad {
        let s = (agent + " " + label).lowercased()
        if s.contains("cort") || s.contains("cut") || s.contains("split") || s.contains("trim") || s.contains("silenc") || s.contains("blade") || s.contains("delete") {
            return .cutter
        }
        if s.contains("card") || s.contains("print") || s.contains("background") || s.contains("bg") || s.contains("polish") || s.contains("style") || s.contains("highlight") || s.contains("blur") || s.contains("mask") {
            return .cards
        }
        if s.contains("color") || s.contains("grade") || s.contains("look") || s.contains("colour") || s.contains("lut") {
            return .colorist
        }
        if s.contains("audio") || s.contains("som") || s.contains("voice") || s.contains("gain") || s.contains("fade") || s.contains("duck") || s.contains("sound") {
            return .audio
        }
        if s.contains("titul") || s.contains("title") || s.contains("anim") || s.contains("keyframe") || s.contains("motion") || s.contains("lower") || s.contains("caption") || s.contains("legend") || s.contains("transition") {
            return .motion
        }
        return .framer
    }
}

/// Live summary of an active nano-bot for the toolbar Swarm HUD.
struct ActiveSwarmBot: Identifiable, Equatable {
    let id: String
    let name: String
    let squad: SwarmSquad
    let action: String
}

/// One choreographed nano-bot step inside a parallel visual swarm wave.
struct SwarmJob {
    let botID: String
    let squad: SwarmSquad
    let action: String
    let target: CGPoint
    let highlightRect: CGRect?
    let delay: Double
}

/// Visual Nano-Bot Swarm overlay: renders parallel color-coded cursors with motion trails,
/// double energy shockwaves, target highlight boxes, and live swarm synchronization mesh lines
/// across both the Preview Canvas and the Timeline — completely non-blocking and hit-test transparent.
@MainActor
final class AgentPresence: ObservableObject {
    static let shared = AgentPresence()

    static let enabledKey = "swarmVisualEnabled"
    /// Nano-Bot visual swarm is ON by default in Editroom-Pro.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    @Published private(set) var activeBots: [ActiveSwarmBot] = []
    @Published private(set) var missionTitle: String?

    private struct Parked {
        let key: String
        var displayName: String
        var squad: SwarmSquad
        var color: NSColor
        var action: String
        let cursor = CALayer()
        let tag = CALayer()
        let dot = CALayer()
        let text = CATextLayer()
        let pulse = CAShapeLayer()
        let pulse2 = CAShapeLayer()
        let targetBox = CAShapeLayer()
        var trailLayers: [CALayer] = []
        var trailPoints: [CGPoint] = []
        var current: CGPoint
        var target: CGPoint
        var since: Double
        var pulseAt: Double
        var linger: Double
    }

    private var window: NSWindow?
    private weak var host: NSWindow?
    private let root = CALayer()
    private let meshLayer = CAShapeLayer()
    private var parked: [String: Parked] = [:]
    private var timer: Timer?
    private var missionResetTask: Task<Void, Never>?
    /// How long an external MCP cursor waits between calls.
    static let linger = 10.0

    private init() {
        meshLayer.fillColor = nil
        meshLayer.strokeColor = NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.22).cgColor
        meshLayer.lineWidth = 1.1
        meshLayer.lineDashPattern = [4, 4]
        root.addSublayer(meshLayer)
    }

    /// Leaves an agent's cursor parked at a point (overlay coordinates: from the window's top-left).
    func park(_ name: String, color: NSColor, at point: CGPoint, in host: NSWindow) {
        glide(name, name: name, color: color, to: point, in: host, pulse: false, spawnOffsetY: 0)
    }

    /// Smoothly glides a nano-bot cursor to a target point with motion trail, energy ripple,
    /// optional glowing target box around the edited clip/layer, and live role/action badge.
    func glide(_ key: String, name: String, color: NSColor? = nil, squad: SwarmSquad? = nil,
               action: String = "", to point: CGPoint, highlightRect: CGRect? = nil,
               in host: NSWindow, pulse: Bool = true, spawnOffsetY: CGFloat = -28,
               linger: Double = AgentPresence.linger) {
        guard Self.enabled else { return }
        attach(to: host)
        let resolvedSquad = squad ?? SwarmSquad.infer(agent: name, label: action)
        let resolvedColor = color ?? resolvedSquad.nsColor
        let now = CACurrentMediaTime()
        let badgeText = action.isEmpty ? name : "\(name) · \(action)"

        if var existing = parked[key] {
            existing.target = point
            existing.since = now
            existing.linger = linger
            existing.squad = resolvedSquad
            existing.action = action
            existing.displayName = name
            if pulse { existing.pulseAt = now }
            updateBadge(&existing, text: badgeText, color: resolvedColor, scale: host.backingScaleFactor)
            updateTargetBox(&existing, rect: highlightRect, color: resolvedColor)
            parked[key] = existing
        } else {
            var p = makeParked(key: key, name: name, badgeText: badgeText, squad: resolvedSquad,
                               action: action, color: resolvedColor, scale: host.backingScaleFactor)
            let startPt = CGPoint(x: point.x + CGFloat((abs(key.hashValue) % 5) - 2) * 14,
                                  y: spawnOffsetY == 0 ? point.y : max(24, point.y + spawnOffsetY))
            p.current = startPt
            p.target = point
            p.trailPoints = Array(repeating: startPt, count: p.trailLayers.count)
            p.since = now
            p.linger = linger
            p.pulseAt = pulse ? now : -10
            updateTargetBox(&p, rect: highlightRect, color: resolvedColor)
            parked[key] = p
        }
        publishActiveBots()
        tick()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    /// Launches a coordinated wave of parallel nano-bots across multiple squads/targets.
    /// Completely non-blocking: the real timeline edits finish immediately while the swarm
    /// visibly glides, pulses, locks onto every clip/layer, and synchronizes in real time.
    func dispatchWave(mission: String, jobs: [SwarmJob], in host: NSWindow) {
        guard Self.enabled, !jobs.isEmpty else { return }
        missionTitle = mission
        AppleHaptics.tick(minInterval: 0.05)

        let maxDelay = jobs.map(\.delay).max() ?? 0
        for job in jobs {
            let run: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                self.glide(job.botID,
                           name: job.squad.label,
                           color: job.squad.nsColor,
                           squad: job.squad,
                           action: job.action,
                           to: job.target,
                           highlightRect: job.highlightRect,
                           in: host,
                           pulse: true,
                           spawnOffsetY: -36,
                           linger: 2.2)
            }
            if job.delay <= 0.001 {
                run()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + job.delay) {
                    MainActor.assumeIsolated { run() }
                }
            }
        }

        missionResetTask?.cancel()
        missionResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((maxDelay + 0.25) * 1_000_000_000))
            if !Task.isCancelled { AppleHaptics.align() }
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            if !Task.isCancelled { self?.missionTitle = nil }
        }
    }

    /// Takes an agent's cursor back for its next edit; returns where it was, if it's still around.
    func take(_ key: String) -> CGPoint? {
        guard let p = parked.removeValue(forKey: key) else { return nil }
        p.cursor.removeFromSuperlayer()
        p.tag.removeFromSuperlayer()
        p.pulse.removeFromSuperlayer()
        p.pulse2.removeFromSuperlayer()
        p.targetBox.removeFromSuperlayer()
        for t in p.trailLayers { t.removeFromSuperlayer() }
        publishActiveBots()
        return p.current
    }

    func clearAll() {
        for key in Array(parked.keys) { _ = take(key) }
        meshLayer.path = nil
        missionTitle = nil
    }

    private func publishActiveBots() {
        let next = parked.values
            .sorted { $0.key < $1.key }
            .map { ActiveSwarmBot(id: $0.key, name: $0.displayName, squad: $0.squad, action: $0.action) }
        if next != activeBots { activeBots = next }
    }

    private func updateBadge(_ p: inout Parked, text: String, color: NSColor, scale: CGFloat) {
        p.color = color
        p.tag.backgroundColor = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 0.90).cgColor
        p.tag.borderColor = color.withAlphaComponent(0.85).cgColor
        p.tag.borderWidth = 1.0
        p.dot.backgroundColor = color.cgColor
        p.text.string = text
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let textW = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let w = textW + 22
        p.tag.bounds = CGRect(x: 0, y: 0, width: w, height: 18)
        p.dot.frame = CGRect(x: 6, y: 6, width: 6, height: 6)
        p.text.frame = CGRect(x: 15, y: 2.5, width: textW + 4, height: 14)
        p.cursor.contents = MagicShow.cursorImage(color, scale: scale)
    }

    private func updateTargetBox(_ p: inout Parked, rect: CGRect?, color: NSColor) {
        guard let r = rect, r.width > 4, r.height > 4 else {
            p.targetBox.path = nil
            return
        }
        p.targetBox.path = CGPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerWidth: 5, cornerHeight: 5, transform: nil)
        p.targetBox.strokeColor = color.withAlphaComponent(0.92).cgColor
        p.targetBox.fillColor = color.withAlphaComponent(0.11).cgColor
    }

    private func makeParked(key: String, name: String, badgeText: String, squad: SwarmSquad,
                            action: String, color: NSColor, scale: CGFloat) -> Parked {
        var p = Parked(key: key, displayName: name, squad: squad, color: color, action: action,
                       current: .zero, target: .zero, since: 0, pulseAt: -10, linger: Self.linger)

        p.targetBox.lineWidth = 1.8
        p.targetBox.opacity = 0

        p.pulse.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
        p.pulse.fillColor = color.withAlphaComponent(0.22).cgColor
        p.pulse.strokeColor = color.withAlphaComponent(0.95).cgColor
        p.pulse.lineWidth = 1.6
        p.pulse.opacity = 0

        p.pulse2.path = CGPath(ellipseIn: CGRect(x: -18, y: -18, width: 36, height: 36), transform: nil)
        p.pulse2.fillColor = nil
        p.pulse2.strokeColor = color.withAlphaComponent(0.65).cgColor
        p.pulse2.lineWidth = 1.2
        p.pulse2.opacity = 0

        // 6 luminous nano-trail dots behind the cursor.
        for i in 0..<6 {
            let dot = CALayer()
            let sz = CGFloat(6 - i) * 1.15
            dot.bounds = CGRect(x: 0, y: 0, width: sz, height: sz)
            dot.cornerRadius = sz / 2
            dot.backgroundColor = color.cgColor
            dot.opacity = 0
            p.trailLayers.append(dot)
            root.addSublayer(dot)
        }

        p.cursor.contents = MagicShow.cursorImage(color, scale: scale)
        p.cursor.contentsScale = scale
        p.cursor.bounds = CGRect(x: 0, y: 0, width: 18, height: 24)
        p.cursor.anchorPoint = CGPoint(x: 2 / 18, y: 2 / 24)
        p.cursor.shadowColor = color.cgColor
        p.cursor.shadowOpacity = 0.65
        p.cursor.shadowRadius = 6
        p.cursor.shadowOffset = .zero

        p.tag.cornerRadius = 9
        p.tag.shadowColor = NSColor.black.cgColor
        p.tag.shadowOpacity = 0.45
        p.tag.shadowRadius = 4
        p.tag.shadowOffset = CGSize(width: 0, height: 2)

        p.dot.cornerRadius = 3
        p.text.contentsScale = scale
        p.text.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        p.text.fontSize = 10
        p.text.foregroundColor = NSColor.white.cgColor
        p.text.alignmentMode = .left
        p.tag.addSublayer(p.dot)
        p.tag.addSublayer(p.text)
        updateBadge(&p, text: badgeText, color: color, scale: scale)

        root.addSublayer(p.targetBox)
        root.addSublayer(p.pulse2)
        root.addSublayer(p.pulse)
        root.addSublayer(p.tag)
        root.addSublayer(p.cursor)
        return p
    }

    private func attach(to host: NSWindow) {
        if window != nil, self.host === host { return }
        let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        let view = PresenceView(frame: NSRect(origin: .zero, size: host.frame.size))
        view.wantsLayer = true
        view.layer?.addSublayer(root)
        root.frame = view.bounds
        root.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        w.contentView = view
        host.addChildWindow(w, ordered: .above)
        window = w
        self.host = host
    }

    private func tick() {
        guard let host, let window else {
            for key in Array(parked.keys) { _ = take(key) }
            meshLayer.path = nil
            timer?.invalidate()
            timer = nil
            return
        }
        if window.frame != host.frame { window.setFrame(host.frame, display: false) }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var activePoints: [CGPoint] = []
        var anyRemoved = false

        for key in Array(parked.keys) {
            guard var p = parked[key] else { continue }
            let age = now - p.since
            if age > p.linger + 0.45 {
                _ = take(key)
                anyRemoved = true
                continue
            }
            // Fast organic spring-like glide (~130ms settle) with motion trail capture.
            let dx = p.target.x - p.current.x
            let dy = p.target.y - p.current.y
            let speed = hypot(dx, dy)
            if speed < 0.6 {
                p.current = p.target
            } else {
                p.current.x += dx * 0.27
                p.current.y += dy * 0.27
            }

            if !p.trailPoints.isEmpty {
                p.trailPoints.insert(p.current, at: 0)
                if p.trailPoints.count > p.trailLayers.count {
                    p.trailPoints.removeLast()
                }
            }
            parked[key] = p

            let bob = CGFloat(sin(now * 2.8 + Double(abs(key.hashValue) % 11))) * 2.2
            let fade = Float(max(0, min(1, (p.linger + 0.45 - age) / 0.45)))
            let pos = CGPoint(x: p.current.x, y: p.current.y + bob)
            p.cursor.position = pos
            let tagX = min(host.frame.width - p.tag.bounds.width / 2 - 8, max(p.tag.bounds.width / 2 + 8, pos.x + 12 + p.tag.bounds.width / 2))
            let tagY = min(host.frame.height - 14, pos.y + 24)
            p.tag.position = CGPoint(x: tagX, y: tagY)
            p.cursor.opacity = fade
            p.tag.opacity = fade
            p.dot.opacity = Float(0.65 + 0.35 * sin(now * 7.5)) * fade

            // Luminous trail scales opacity with movement velocity.
            let trailGain = Float(min(1.0, speed / 18.0)) * fade
            for (idx, dot) in p.trailLayers.enumerated() {
                if idx < p.trailPoints.count {
                    dot.position = p.trailPoints[idx]
                    dot.opacity = trailGain * Float(1.0 - Double(idx) / Double(p.trailLayers.count)) * 0.65
                }
            }

            // Double shockwave pulse + glowing target highlight box on impact.
            let pulseAge = now - p.pulseAt
            if pulseAge >= 0, pulseAge < 0.52 {
                let u = CGFloat(pulseAge / 0.52)
                p.pulse.position = p.current
                p.pulse.transform = CATransform3DMakeScale(0.4 + u * 1.4, 0.4 + u * 1.4, 1)
                p.pulse.opacity = Float(1 - u) * fade

                let u2 = CGFloat(max(0, (pulseAge - 0.08) / 0.44))
                p.pulse2.position = p.current
                p.pulse2.transform = CATransform3DMakeScale(0.5 + u2 * 1.85, 0.5 + u2 * 1.85, 1)
                p.pulse2.opacity = (pulseAge > 0.08 ? Float(1 - u2) * 0.7 : 0) * fade
            } else {
                p.pulse.opacity = 0
                p.pulse2.opacity = 0
            }

            if p.targetBox.path != nil, pulseAge >= 0, pulseAge < 0.95 {
                let u = Float(pulseAge / 0.95)
                p.targetBox.opacity = (1 - u * u) * fade
            } else {
                p.targetBox.opacity = 0
            }

            if age < 2.4 { activePoints.append(pos) }
        }

        // Draw subtle synchronization mesh lines between concurrently working nano-bots!
        if activePoints.count >= 2 {
            let mesh = CGMutablePath()
            for i in 0..<activePoints.count {
                for j in (i + 1)..<activePoints.count {
                    let a = activePoints[i], b = activePoints[j]
                    if hypot(a.x - b.x, a.y - b.y) < 720 {
                        mesh.move(to: a)
                        mesh.addLine(to: b)
                    }
                }
            }
            meshLayer.path = mesh
            meshLayer.lineDashPhase = CGFloat(-now * 28)
            meshLayer.opacity = 1
        } else {
            meshLayer.path = nil
            meshLayer.opacity = 0
        }

        CATransaction.commit()
        if anyRemoved { publishActiveBots() }
        if parked.isEmpty {
            meshLayer.path = nil
            timer?.invalidate()
            timer = nil
        }
    }
}

private final class PresenceView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
