import SwiftUI
import UIKit
import MirooCore

/// Transparent full-size layer above the video that turns touches into mouse/scroll events for the Mac.
///  1 finger  : left button (tap = click, drag = drag)   – press is delayed ~25 ms to tell it apart from a 2-finger gesture
///  2 fingers : scroll (with momentum); a quick two-finger tap = right click
struct TouchSurface: UIViewRepresentable {
    let onEvent: (InputKind, Float, Float) -> Void
    var onThreeFingers: () -> Void = {}
    func makeUIView(context: Context) -> TouchView { let v = TouchView(); v.onEvent = onEvent; v.onThreeFingers = onThreeFingers; return v }
    func updateUIView(_ v: TouchView, context: Context) { v.onEvent = onEvent; v.onThreeFingers = onThreeFingers }
}

final class TouchView: UIView {
    var onEvent: ((InputKind, Float, Float) -> Void)?
    var onThreeFingers: (() -> Void)?
    private var threeFingerFired = false
    private var tracked: [UITouch] = []
    private enum Mode { case idle, pending, drag, scroll }
    private var mode = Mode.idle
    private var pendingWork: DispatchWorkItem?
    private var lastCentroid = CGPoint.zero
    private var scrollStart = CGPoint.zero, scrollStartTime: TimeInterval = 0, scrolled = false
    private var velocity = CGPoint.zero, lastScrollTime: TimeInterval = 0
    private var momentumLink: CADisplayLink?
    private var momentumV = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true; backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    private func norm(_ p: CGPoint) -> (Float, Float) {
        (Float(min(max(p.x / max(bounds.width, 1), 0), 1)), Float(min(max(p.y / max(bounds.height, 1), 0), 1)))
    }
    private func centroid() -> CGPoint {
        let pts = tracked.map { $0.location(in: self) }
        guard !pts.isEmpty else { return .zero }
        return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopMomentum()
        tracked.append(contentsOf: touches)
        if tracked.count >= 3 {                       // three fingers: toggle the stats overlay (never reaches the Mac)
            pendingWork?.cancel()
            if mode == .drag { let (x, y) = norm(centroid()); onEvent?(.cancel, x, y) }
            if mode == .scroll { onEvent?(.scrollEnd, 0, 0) }
            mode = .idle
            if !threeFingerFired { threeFingerFired = true; onThreeFingers?() }
            return
        }
        switch tracked.count {
        case 1:
            mode = .pending
            let start = tracked[0].location(in: self)
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.mode == .pending else { return }
                self.mode = .drag
                let (x, y) = self.norm(start); self.onEvent?(.down, x, y)
            }
            pendingWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: w)
        default:
            pendingWork?.cancel()
            if mode == .drag { let (x, y) = norm(centroid()); onEvent?(.cancel, x, y) }
            if mode != .scroll {
                mode = .scroll
                lastCentroid = centroid(); scrollStart = lastCentroid; scrollStartTime = event?.timestamp ?? 0; scrolled = false
                velocity = .zero
                let (x, y) = norm(lastCentroid); onEvent?(.move, x, y)      // park the cursor under the fingers
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        switch mode {
        case .drag:
            if let t = tracked.first { let (x, y) = norm(t.location(in: self)); onEvent?(.move, x, y) }
        case .pending:
            // moved before the press fired: press now so the drag starts where the finger started
            if let t = tracked.first, hypot(t.location(in: self).x - t.previousLocation(in: self).x, t.location(in: self).y - t.previousLocation(in: self).y) > 2 {
                pendingWork?.cancel(); mode = .drag
                let (sx, sy) = norm(t.previousLocation(in: self)); onEvent?(.down, sx, sy)
                let (x, y) = norm(t.location(in: self)); onEvent?(.move, x, y)
            }
        case .scroll:
            let c = centroid()
            let dx = c.x - lastCentroid.x, dy = c.y - lastCentroid.y
            lastCentroid = c
            if dx != 0 || dy != 0 {
                scrolled = scrolled || hypot(c.x - scrollStart.x, c.y - scrollStart.y) > 8
                let now = event?.timestamp ?? 0
                let dt = max(0.004, now - lastScrollTime); lastScrollTime = now
                velocity = CGPoint(x: velocity.x * 0.6 + dx / CGFloat(dt) * 0.4, y: velocity.y * 0.6 + dy / CGFloat(dt) * 0.4)
                onEvent?(.scroll, Float(dx), Float(dy))
            }
        case .idle: break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, event: event, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, event: event, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        let loc = touches.first?.location(in: self) ?? lastCentroid
        let wasTracked = tracked.count
        tracked.removeAll { touches.contains($0) }
        if tracked.isEmpty { threeFingerFired = false }
        if threeFingerFired { return }
        switch mode {
        case .pending:
            pendingWork?.cancel()
            if !cancelled { let (x, y) = norm(loc); onEvent?(.down, x, y); onEvent?(.up, x, y) }   // a quick tap
            mode = .idle
        case .drag:
            let (x, y) = norm(loc); onEvent?(cancelled ? .cancel : .up, x, y); mode = .idle
        case .scroll:
            if wasTracked >= 2 && tracked.count < wasTracked, tracked.count == 1 || tracked.isEmpty {
                if !scrolled, !cancelled, (event?.timestamp ?? 0) - scrollStartTime < 0.3 {
                    let (x, y) = norm(lastCentroid); onEvent?(.secondaryClick, x, y)
                    onEvent?(.scrollEnd, 0, 0); mode = tracked.isEmpty ? .idle : .scroll; return
                }
                if scrolled { startMomentum() } else { onEvent?(.scrollEnd, 0, 0) }
            }
            if tracked.isEmpty { mode = .idle }
        case .idle: break
        }
    }

    // MARK: momentum (inertial scrolling after the fingers lift)
    private func startMomentum() {
        let speed = hypot(velocity.x, velocity.y)
        guard speed > 180 else { onEvent?(.scrollEnd, 0, 0); return }
        momentumV = velocity
        let l = CADisplayLink(target: self, selector: #selector(momentumStep(_:)))
        l.add(to: .main, forMode: .common); momentumLink = l
    }
    @objc private func momentumStep(_ l: CADisplayLink) {
        let dt = CGFloat(l.targetTimestamp - l.timestamp)
        momentumV = CGPoint(x: momentumV.x * pow(0.045, dt), y: momentumV.y * pow(0.045, dt))     // ~0.5 s half-life feel
        if hypot(momentumV.x, momentumV.y) < 30 { stopMomentum(); onEvent?(.scrollEnd, 0, 0); return }
        onEvent?(.scroll, Float(momentumV.x * dt), Float(momentumV.y * dt))
    }
    private func stopMomentum() { momentumLink?.invalidate(); momentumLink = nil }
}
