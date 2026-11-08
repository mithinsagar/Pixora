#if PIXORA_UI_TESTING
import AppKit
import CoreGraphics

/// Testing build only: plays a script of real input through the app's window, the same route events from the trackpad
/// take, and reports how smoothly it drew. Steps separated by ";":
/// wait S · section NAME · swipe DX DY [SECONDS] · pinch FACTOR · key NAME · click X Y · hold X Y · shot NAME · say TEXT · scroll DY · quit
@MainActor
final class Rehearsal: NSObject {
    private static var current: Rehearsal?
    private let steps: [[String]]
    private let model: AppModel
    private var frames: [CFTimeInterval] = []
    private var link: CADisplayLink?
    /// Through the app's event queue rather than straight to the window, so event monitors see it too.
    private var viaQueue = false
    private let dir = ProcessInfo.processInfo.environment["PIXORA_TEST_SHOTS"] ?? NSTemporaryDirectory()

    static func run(_ script: String, model: AppModel) {
        let r = Rehearsal(script: script, model: model)
        current = r
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await r.play()
        }
    }

    init(script: String, model: AppModel) {
        steps = script.split(separator: ";").map { $0.split(separator: " ").map(String.init) }
        self.model = model
    }

    private var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 } }

    private func log(_ s: String) { fputs("REHEARSAL \(s)\n", stderr) }

    private func play() async {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        for step in steps {
            guard let verb = step.first else { continue }
            let n = step.dropFirst().compactMap(Double.init)
            switch verb {
            case "wait": try? await Task.sleep(for: .seconds(n.first ?? 1))
            case "say": log(step.dropFirst().joined(separator: " "))
            case "swipe": await swipe(dx: n[0], dy: n[1], seconds: n.count > 2 ? n[2] : 0.28)
            case "scroll": await pageScroll(dy: n[0])
            case "queue": viaQueue = true
            case "section": goTo(step[1])
            case "fullscreen": window?.toggleFullScreen(nil); try? await Task.sleep(for: .seconds(3))
            case "windows": windows()
            case "resize":
                if let w = window { w.setFrame(NSRect(x: 0, y: 0, width: n[0], height: n[1]), display: true) }
                try? await Task.sleep(for: .seconds(1))
            case "pinch": await pinch(n[0])
            case "key": key(step[1])
            case "click": await click(CGPoint(x: n[0], y: n[1]), hold: 0)
            case "hold": await click(CGPoint(x: n[0], y: n[1]), hold: 0.7)
            case "drag": await drag(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]))
            case "shot": shot(step[1])
            case "state": report()
            case "measure": await measure(seconds: n.first ?? 1)
            case "quit": exit(0)
            default: log("unknown step \(verb)")
            }
        }
    }

    /// Every window the app owns, for finding what sits over the content in full screen.
    private func windows() {
        for w in NSApp.windows {
            log("window \(type(of: w)) frame \(w.frame) level \(w.level.rawValue) visible \(w.isVisible) ignoresMouse \(w.ignoresMouseEvents) fullScreen \(w.styleMask.contains(.fullScreen))")
        }
        // Asks the window server which window a real click would reach: synthetic clicks skip that step.
        if let w = window, let screen = w.screen {
            let spot = NSPoint(x: w.frame.minX + 34, y: w.frame.maxY - 28)
            let hit = NSWindow.windowNumber(at: spot, belowWindowWithWindowNumber: 0)
            let name = NSApp.windows.first { $0.windowNumber == hit }.map { String(describing: type(of: $0)) } ?? "another app (\(hit))"
            log("a real click on the close spot reaches: \(name), screen \(Int(screen.frame.height)) high")
        }
        if let w = window, let button = w.standardWindowButton(.closeButton) {
            var chain: [String] = [], v: NSView? = button
            while let view = v { chain.append("\(type(of: view))\(view.isHidden ? "(hidden)" : "")"); v = view.superview }
            log("close button in \(button.window.map { String(describing: type(of: $0)) } ?? "no window"): \(chain.joined(separator: " < "))")
        }
    }

    private func report() {
        let v = model.viewer.map { "viewer index \($0.index) of \($0.photos.count)" } ?? "viewer closed"
        let tile = model.viewer.flatMap { model.tileFrame($0.current.id) }
        log("\(v), favorites \(model.favorites.count), section \(model.section), tile \(tile.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "none")")
    }

    // MARK: Input

    private var centre: CGPoint {
        guard let w = window else { return .zero }
        return CGPoint(x: w.frame.width / 2, y: w.frame.height / 2 + 30)
    }

    /// An event built without a window reports its location in screen points, so it's placed where the window's own
    /// coordinates would be and `sendEvent` hit-tests it like any other.
    private func place(_ e: CGEvent, at p: CGPoint) {
        e.location = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }

    private func scrollEvent(dx: Int32, dy: Int32, phase: Int64, at p: CGPoint, time: Double) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        e.timestamp = CGEventTimestamp(time * 1e9)
        place(e, at: p)
        if let ns = NSEvent(cgEvent: e) { if viaQueue { NSApp.postEvent(ns, atStart: false) } else { window?.sendEvent(ns) } }
    }

    private func swipe(dx: Double, dy: Double, seconds: Double) async {
        startMeasuring()
        let count = max(4, Int(seconds * 120))
        let p = centre, t0 = ProcessInfo.processInfo.systemUptime
        for i in 0..<count {
            // Fingers accelerate, then ease off.
            let a = sin(Double(i) / Double(count) * .pi / 2), b = sin(Double(i + 1) / Double(count) * .pi / 2)
            scrollEvent(dx: Int32((b - a) * dx), dy: Int32((b - a) * dy), phase: i == 0 ? 1 : 2, at: p, time: t0 + Double(i) / 120)
            try? await Task.sleep(for: .milliseconds(8))
        }
        scrollEvent(dx: 0, dy: 0, phase: 4, at: p, time: t0 + seconds)
        try? await Task.sleep(for: .milliseconds(650))
        stopMeasuring("swipe \(Int(dx)),\(Int(dy))")
    }

    /// Plain page scrolling, for checking the grid.
    private func pageScroll(dy: Double) async {
        startMeasuring()
        let p = centre, t0 = ProcessInfo.processInfo.systemUptime
        let count = Int(abs(dy) / 10)   // 1,200 points a second: a brisk scroll
        for i in 0..<count {
            scrollEvent(dx: 0, dy: Int32(dy / Double(count)), phase: i == 0 ? 1 : 2, at: p, time: t0 + Double(i) / 120)
            try? await Task.sleep(for: .milliseconds(8))
        }
        scrollEvent(dx: 0, dy: 0, phase: 4, at: p, time: t0 + 2)
        try? await Task.sleep(for: .milliseconds(200))
        stopMeasuring("page scroll")
    }

    private func pinch(_ factor: Double) async {
        startMeasuring()
        let count = 30, p = centre, each = pow(factor, 1 / Double(count)) - 1
        for i in 0...count + 1 {
            guard let e = CGEvent(source: nil) else { continue }
            e.type = CGEventType(rawValue: 29) ?? .null   // gesture
            e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)   // zoom
            e.setDoubleValueField(CGEventField(rawValue: 113)!, value: i > count ? 0 : each)
            e.setIntegerValueField(CGEventField(rawValue: 132)!, value: i == 0 ? 1 : (i > count ? 4 : 2))
            place(e, at: p)
            if let ns = NSEvent(cgEvent: e) {
                if i == 0 { log("pinch event type \(ns.type.rawValue), magnification \(ns.type == .magnify ? ns.magnification : -1)") }
                window?.sendEvent(ns)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(300))
        stopMeasuring("pinch \(factor)")
    }

    /// Changes page the way the sidebar does: no animation asked for by the caller.
    private func goTo(_ name: String) {
        let pages: [String: SidebarItem] = ["find": .find, "search": .search, "review": .review, "people": .people, "all": .allPhotos,
                                            "places": .places, "insights": .insights, "import": .importer, "settings": .settings]
        if let page = pages[name] { model.section = page } else { log("unknown section \(name)") }
    }

    private func key(_ name: String) {
        guard let w = window else { return }
        let codes: [String: (UInt16, String)] = ["left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
                                                 "space": (49, " "), "esc": (53, "\u{1B}"), "return": (36, "\r"), "delete": (51, "\u{7F}")]
        let (code, chars) = codes[name] ?? (0, name)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                w.sendEvent(e)
            }
        }
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) {
        guard let w = window else { return }
        let flipped = CGPoint(x: p.x, y: w.contentView!.bounds.height - p.y)
        if let e = NSEvent.mouseEvent(with: type, location: flipped, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) {
            if viaQueue { NSApp.postEvent(e, atStart: false) } else { w.sendEvent(e) }
        }
    }

    private func click(_ p: CGPoint, hold: Double) async {
        if let frame = window?.contentView?.superview {
            let y = frame.isFlipped ? p.y : frame.bounds.height - p.y
            log("click \(Int(p.x)),\(Int(p.y)) lands on \(frame.hitTest(CGPoint(x: p.x, y: y)).map { String(describing: type(of: $0)) } ?? "nothing")")
        }
        mouse(.leftMouseDown, p)
        try? await Task.sleep(for: .seconds(max(0.05, hold)))
        mouse(.leftMouseUp, p)
    }

    private func drag(from a: CGPoint, to b: CGPoint) async {
        mouse(.leftMouseDown, a)
        for i in 1...30 {
            let t = Double(i) / 30
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try? await Task.sleep(for: .milliseconds(12))
        }
        mouse(.leftMouseUp, b)
    }

    // MARK: Measuring

    private func startMeasuring() {
        frames = []
        link = window?.contentView?.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ l: CADisplayLink) { frames.append(l.timestamp) }

    private func stopMeasuring(_ label: String) {
        link?.invalidate(); link = nil
        report(label)
    }

    private func measure(seconds: Double) async {
        startMeasuring()
        try? await Task.sleep(for: .seconds(seconds))
        stopMeasuring("idle or playing")
    }

    private func report(_ label: String) {
        guard frames.count > 2 else { log("\(label): no frames"); return }
        let gaps = zip(frames.dropFirst(), frames).map { $0 - $1 }.sorted()
        let typical = gaps[gaps.count / 2]
        let slow = gaps.filter { $0 > typical * 1.6 }.count
        log(String(format: "%@: %d frames, typical %.1f ms (%.0f fps), worst %.1f ms, %d late", label, frames.count, typical * 1000, 1 / typical, (gaps.last ?? 0) * 1000, slow))
    }

    private func shot(_ name: String) {
        guard let w = window else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", "\(dir)/\(name).png"]
        try? p.run(); p.waitUntilExit()
        log("shot \(name)")
    }
}
#endif
