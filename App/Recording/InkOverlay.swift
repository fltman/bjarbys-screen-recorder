import Foundation
import AppKit
import QuartzCore
import RecorderKit

/// Pennan: rita på skärmen under inspelningen. Ett genomskinligt fönster per skärm tar emot
/// musen medan pennan är på; strecken syns direkt och tonas bort som i filmen, men kommer aldrig
/// med i bilden (appen utesluts ur inspelningen). Varje färdigt streck lämnas till `onStroke`
/// och loggas som en `ink`-händelse, som renderaren ritar i efterhand — avstängbar, och den
/// zoomar med innehållet.
///
/// Esc eller kortkommandot stänger pennan; 1–5 byter färg.
@MainActor
final class InkOverlay {
    private var windows: [InkWindow] = []
    private(set) var isActive = false
    var color = InkTrack.colors[0]
    /// Hur länge ett färdigt streck ligger kvar (samma som filmens standard).
    var hold = InkTrack.standardHold
    /// Tiden på inspelningens tidslinje just nu, eller nil (paus: strecken loggas inte).
    var now: () -> Double? = { nil }
    /// Ett färdigt streck: punkter med tidslinjetid och global punkt (origo uppe till vänster).
    var onStroke: (([(t: Double, p: CGPoint)], String) -> Void)?
    /// Pennan slogs på eller av (för musens loggning och HUD:en).
    var onChange: ((Bool) -> Void)?

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive else { return }
        isActive = true
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let w = InkWindow(screen: screen, overlay: self)
            w.orderFrontRegardless()
            if NSMouseInRect(mouse, screen.frame, false) { w.makeKey() }
            windows.append(w)
        }
        // Appen aktiveras inte (panelen tar emot tangenterna ändå): det inspelade programmet
        // ska inte tappa fokus i bild.
        onChange?(true)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        for w in windows { w.orderOut(nil); w.close() }
        windows = []
        onChange?(false)
    }

    func select(colorAt index: Int) {
        guard InkTrack.colors.indices.contains(index) else { return }
        color = InkTrack.colors[index]
    }

    /// Global punkt (CG: origo uppe till vänster på huvudskärmen) för en punkt på skärmen (Cocoa).
    static func global(_ p: NSPoint) -> CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: mainHeight - p.y)
    }
}

final class InkWindow: NSPanel {
    init(screen: NSScreen, overlay: InkOverlay) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        let view = InkView(frame: NSRect(origin: .zero, size: screen.frame.size), overlay: overlay,
                           contentHeight: screen.frame.height)
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class InkView: NSView {
    private weak var overlay: InkOverlay?
    private let lineWidth: CGFloat
    private var current: (layer: CAShapeLayer, viewPoints: [NSPoint], points: [(t: Double, p: CGPoint)], color: String)?

    init(frame: NSRect, overlay: InkOverlay, contentHeight: CGFloat) {
        self.overlay = overlay
        // Samma bredd i förhållande till höjden som i filmen.
        lineWidth = max(2, CGFloat(InkTrack.widthFraction) * contentHeight)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        guard let overlay else { return }
        window?.makeKey()
        let shape = CAShapeLayer()
        shape.fillColor = nil
        shape.strokeColor = NSColor(ciColor: RenderPlan.color(hex: overlay.color)).cgColor
        shape.lineWidth = lineWidth
        shape.lineCap = .round
        shape.lineJoin = .round
        layer?.addSublayer(shape)
        current = (shape, [], [], overlay.color)
        add(event)
    }

    override func mouseDragged(with event: NSEvent) { add(event) }

    override func mouseUp(with event: NSEvent) {
        add(event)
        guard let stroke = current, let overlay else { return }
        current = nil
        if !stroke.points.isEmpty { overlay.onStroke?(stroke.points, stroke.color) }
        // Ligger kvar och tonas bort som i filmen.
        let fade = InkTrack.fade
        DispatchQueue.main.asyncAfter(deadline: .now() + overlay.hold) { [weak shape = stroke.layer] in
            guard let shape else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { shape.removeFromSuperlayer() }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0
            a.duration = fade
            shape.opacity = 0
            shape.add(a, forKey: "fade")
            CATransaction.commit()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { overlay?.stop(); return }  // Esc
        if let c = event.charactersIgnoringModifiers, let n = Int(c), (1...5).contains(n) {
            overlay?.select(colorAt: n - 1)
            return
        }
        super.keyDown(with: event)
    }

    private func add(_ event: NSEvent) {
        guard var stroke = current, let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        if let last = stroke.viewPoints.last, hypot(local.x - last.x, local.y - last.y) < 1.5 { return }
        stroke.viewPoints.append(local)
        if let t = overlay?.now() {
            let onScreen = window.convertPoint(toScreen: event.locationInWindow)
            stroke.points.append((t, InkOverlay.global(onScreen)))
        }
        let path = InkTrack.path(stroke.viewPoints.indices.map { InkStroke.Point(t: 0, p: stroke.viewPoints[$0]) }[...]) { $0 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.layer.path = path
        CATransaction.commit()
        current = stroke
    }
}
