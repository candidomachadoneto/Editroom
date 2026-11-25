import AppKit
import QuartzCore

/// Connected agents' cursors while they're working in instant mode or between edits: each smoothly
/// glides to where it acts, pulses briefly on edit, bobs gently while waiting, and fades away after
/// a while without a call. Keyed by unique cursor id so parallel swarm agents never collide.
@MainActor
final class AgentPresence {
    static let shared = AgentPresence()

    private struct Parked {
        let cursor = CALayer()
        let tag = CALayer()
        let text = CATextLayer()
        let pulse = CAShapeLayer()
        var current: CGPoint
        var target: CGPoint
        var since: Double
        var pulseAt: Double
    }

    private var window: NSWindow?
    private weak var host: NSWindow?
    private let root = CALayer()
    private var parked: [String: Parked] = [:]
    private var timer: Timer?
    /// How long a cursor waits for its agent's next call.
    static let linger = 12.0

    /// Leaves an agent's cursor at a point (overlay coordinates: from the window's top-left).
    func park(_ name: String, color: NSColor, at point: CGPoint, in host: NSWindow) {
        glide(name, name: name, color: color, to: point, in: host, pulse: false, spawnOffsetY: 0)
    }

    /// Smoothly glides an agent's cursor to a point without blocking the edit pipeline.
    func glide(_ key: String, name: String, color: NSColor, to point: CGPoint, in host: NSWindow,
               pulse: Bool = true, spawnOffsetY: CGFloat = -26) {
        attach(to: host)
        let now = CACurrentMediaTime()
        if var existing = parked[key] {
            existing.target = point
            existing.since = now
            if pulse { existing.pulseAt = now }
            parked[key] = existing
        } else {
            var p = makeParked(name, color: color, scale: host.backingScaleFactor)
            p.current = CGPoint(x: point.x, y: spawnOffsetY == 0 ? point.y : max(24, point.y + spawnOffsetY))
            p.target = point
            p.since = now
            p.pulseAt = pulse ? now : -10
            parked[key] = p
        }
        tick()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    /// Takes an agent's cursor back for its next edit; returns where it was, if it's still around.
    func take(_ key: String) -> CGPoint? {
        guard let p = parked.removeValue(forKey: key) else { return nil }
        p.cursor.removeFromSuperlayer()
        p.tag.removeFromSuperlayer()
        p.pulse.removeFromSuperlayer()
        return p.current
    }

    private func makeParked(_ name: String, color: NSColor, scale: CGFloat) -> Parked {
        let p = Parked(current: .zero, target: .zero, since: 0, pulseAt: -10)
        p.pulse.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
        p.pulse.fillColor = color.withAlphaComponent(0.22).cgColor
        p.pulse.strokeColor = color.withAlphaComponent(0.9).cgColor
        p.pulse.lineWidth = 1.5
        p.pulse.opacity = 0
        p.cursor.contents = MagicShow.cursorImage(color, scale: scale)
        p.cursor.contentsScale = scale
        p.cursor.bounds = CGRect(x: 0, y: 0, width: 18, height: 24)
        p.cursor.anchorPoint = CGPoint(x: 2 / 18, y: 2 / 24)
        p.tag.backgroundColor = color.blended(withFraction: 0.18, of: .black)?.cgColor
        p.tag.cornerRadius = 4
        p.text.contentsScale = scale
        p.text.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        p.text.fontSize = 10
        p.text.foregroundColor = NSColor.white.cgColor
        p.text.alignmentMode = .center
        p.text.string = name
        let w = ceil((name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width) + 12
        p.tag.bounds = CGRect(x: 0, y: 0, width: w, height: 16)
        p.text.frame = CGRect(x: 0, y: 1.5, width: w, height: 14)
        p.tag.addSublayer(p.text)
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
            timer?.invalidate()
            timer = nil
            return
        }
        if window.frame != host.frame { window.setFrame(host.frame, display: false) }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in Array(parked.keys) {
            guard var p = parked[key] else { continue }
            let age = now - p.since
            if age > Self.linger + 0.5 {
                _ = take(key)
                continue
            }
            // Exponentially ease toward the latest target point (~150ms snap).
            let dx = p.target.x - p.current.x
            let dy = p.target.y - p.current.y
            if abs(dx) + abs(dy) < 0.5 {
                p.current = p.target
            } else {
                p.current.x += dx * 0.28
                p.current.y += dy * 0.28
            }
            parked[key] = p
            // A slow bob, so it reads as live rather than stuck.
            let bob = CGFloat(sin(now * 2.2 + Double(abs(key.hashValue) % 7))) * 2
            let fade = Float(max(0, min(1, (Self.linger + 0.5 - age) / 0.5)))
            p.cursor.position = CGPoint(x: p.current.x, y: p.current.y + bob)
            p.tag.position = CGPoint(x: p.current.x + 10 + p.tag.bounds.width / 2, y: p.current.y + 26 + bob)
            p.cursor.opacity = fade
            p.tag.opacity = fade
            let pulseAge = now - p.pulseAt
            if pulseAge >= 0, pulseAge < 0.36 {
                let u = CGFloat(pulseAge / 0.36)
                p.pulse.position = p.current
                p.pulse.transform = CATransform3DMakeScale(0.45 + u * 1.15, 0.45 + u * 1.15, 1)
                p.pulse.opacity = Float(1 - u) * fade
            } else {
                p.pulse.opacity = 0
            }
        }
        CATransaction.commit()
        if parked.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}

private final class PresenceView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
