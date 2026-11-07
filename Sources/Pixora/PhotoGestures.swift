import SwiftUI
import AppKit

/// Sits behind a photo and takes the trackpad and mouse. Pinch zooms. Two fingers or a click-drag swipe the photo, or
/// pan it when zoomed in. Double-click or two-finger double-tap toggles zoom. Holding still on it, or pressing
/// firmly, asks to lift the subject. It never takes keyboard focus, so the screen's keys keep working.
struct PhotoGestureSurface: NSViewRepresentable {
    var zoomed: Bool
    var onZoom: (CGFloat, CGPoint) -> Void
    var onZoomEnded: () -> Void
    var onPan: (CGSize) -> Void
    var onToggle: (CGPoint) -> Void
    var onSwipe: (CGSize, TimeInterval) -> Void = { _, _ in }
    var onSwipeEnded: () -> Void = {}
    /// One notch of a plain mouse wheel: −1 back, 1 forward.
    var onWheelStep: (Int) -> Void = { _ in }
    var onHold: ((CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }
    func updateNSView(_ view: SurfaceView, context: Context) {
        view.onZoom = onZoom; view.onZoomEnded = onZoomEnded; view.onPan = onPan; view.onToggle = onToggle
        view.onSwipe = onSwipe; view.onSwipeEnded = onSwipeEnded; view.onWheelStep = onWheelStep; view.onHold = onHold
        if view.zoomed != zoomed { view.zoomed = zoomed; view.window?.invalidateCursorRects(for: view) }
    }

    final class SurfaceView: NSView {
        var zoomed = false
        var onZoom: (CGFloat, CGPoint) -> Void = { _, _ in }
        var onZoomEnded: () -> Void = {}
        var onPan: (CGSize) -> Void = { _ in }
        var onToggle: (CGPoint) -> Void = { _ in }
        var onSwipe: (CGSize, TimeInterval) -> Void = { _, _ in }
        var onSwipeEnded: () -> Void = {}
        var onWheelStep: (Int) -> Void = { _ in }
        var onHold: ((CGPoint) -> Void)?
        private var swiping = false
        private var hold: DispatchWorkItem?
        private var travelled: CGFloat = 0
        private var lastWheelStep: TimeInterval = 0
        private var held = false

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { if zoomed { addCursorRect(bounds, cursor: .openHand) } }

        private func point(_ event: NSEvent) -> CGPoint {
            let p = convert(event.locationInWindow, from: nil)
            return CGPoint(x: p.x - bounds.midX, y: p.y - bounds.midY)
        }

        override func magnify(with event: NSEvent) {
            onZoom(event.magnification, point(event))
            if event.phase == .ended || event.phase == .cancelled { onZoomEnded() }
        }
        override func smartMagnify(with event: NSEvent) { onToggle(point(event)) }

        override func scrollWheel(with event: NSEvent) {
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            if event.modifierFlags.contains(.command) {   // zooming with a plain mouse wheel
                onZoom(event.scrollingDeltaY * step * 0.01, point(event))
            } else if zoomed {
                onPan(CGSize(width: event.scrollingDeltaX * step, height: event.scrollingDeltaY * step))
            } else if !event.hasPreciseScrollingDeltas {
                wheelStep(event)
            } else if event.momentumPhase == [] {   // the coasting after fingers lift isn't part of the swipe
                if event.phase == .began || event.phase == .changed {
                    swiping = true
                    onSwipe(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), event.timestamp)
                } else if event.phase == .ended || event.phase == .cancelled, swiping {
                    swiping = false
                    onSwipeEnded()
                }
            }
        }

        private func wheelStep(_ event: NSEvent) {
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            guard delta != 0, event.timestamp - lastWheelStep > 0.22 else { return }
            lastWheelStep = event.timestamp
            onWheelStep(delta < 0 ? 1 : -1)
        }

        override func mouseDown(with event: NSEvent) {
            travelled = 0
            held = false
            hold?.cancel()
            if event.clickCount == 2 {
                onToggle(point(event))
            } else if zoomed {
                NSCursor.closedHand.set()
            } else if onHold != nil {
                let p = point(event)
                let work = DispatchWorkItem { [weak self] in self?.startHold(at: p) }
                hold = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.48, execute: work)
            }
        }
        override func mouseDragged(with event: NSEvent) {
            if zoomed { onPan(CGSize(width: event.deltaX, height: event.deltaY)); return }
            guard !held else { return }
            travelled += abs(event.deltaX) + abs(event.deltaY)
            if travelled > 4 { hold?.cancel() }
            swiping = true
            onSwipe(CGSize(width: event.deltaX, height: event.deltaY), event.timestamp)
        }
        override func mouseUp(with event: NSEvent) {
            hold?.cancel()
            window?.invalidateCursorRects(for: self)
            if swiping { swiping = false; onSwipeEnded() }
        }

        /// A firm press on a Force Touch trackpad.
        override func pressureChange(with event: NSEvent) {
            if event.stage == 2, !held, !zoomed, onHold != nil {
                hold?.cancel()
                startHold(at: point(event))
            }
        }

        private func startHold(at p: CGPoint) {
            held = true
            if swiping { swiping = false; onSwipeEnded() }
            onHold?(p)
        }
    }
}
