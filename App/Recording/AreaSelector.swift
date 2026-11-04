import Foundation
import AppKit

/// Låter användaren dra upp ett område på valfri skärm. Ett genomskinligt överlägg per skärm;
/// skärmen dämpas utom i det valda området. Släpp musen för att välja, ↩ för att återanvända
/// förra området, ⎋ för att avbryta.
///
/// Resultatet är en rektangel i globala CoreGraphics-punkter (origo uppe till vänster på
/// huvudskärmen), samma rymd som markördatan.
@MainActor
final class AreaSelector {
    private var windows: [NSWindow] = []
    private var completion: ((CGRect?) -> Void)?
    private static let lastAreaKey = "lastArea"

    func run(_ completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        let last = Self.lastArea
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let view = AreaSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenFrame = screen.frame
            view.lastArea = last.flatMap { Self.cocoaRect(fromCG: $0) }
            view.onFinish = { [weak self] cocoaRect in self?.finish(cocoaRect) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSApp.activate()
        NSCursor.crosshair.push()
    }

    private func finish(_ cocoaRect: NSRect?) {
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        let rect = cocoaRect.map(Self.cgRect(fromCocoa:))
        if let rect { Self.lastArea = rect }
        let done = completion
        completion = nil
        // Ge fönsterservern en stund att ta bort överläggen innan strömmen startar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { done?(rect) }
    }

    // MARK: - Koordinater

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Cocoa (origo nere till vänster) → CoreGraphics (origo uppe till vänster).
    static func cgRect(fromCocoa r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cocoaRect(fromCG r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    private static var lastArea: CGRect? {
        get {
            guard let s = UserDefaults.standard.string(forKey: lastAreaKey) else { return nil }
            let r = NSRectFromString(s)
            return r.width > 10 && r.height > 10 ? r : nil
        }
        set {
            UserDefaults.standard.set(newValue.map { NSStringFromRect($0) }, forKey: lastAreaKey)
        }
    }
}

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

private final class AreaSelectionView: NSView {
    var screenFrame: NSRect = .zero
    /// Förra området i globala Cocoa-punkter.
    var lastArea: NSRect?
    var onFinish: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSRect?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                         width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let r = current, r.width >= 40, r.height >= 40 else {
            current = nil; start = nil; needsDisplay = true
            return
        }
        onFinish?(r.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY).integral)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish?(nil) // ⎋
        case 36, 76: // ↩
            if let lastArea { onFinish?(lastArea) }
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let local = current ?? lastArea.map { $0.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
        if let r = local, r.intersects(bounds) {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            let border = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            (current == nil ? NSColor.white.withAlphaComponent(0.5) : NSColor.white).setStroke()
            if current == nil { border.setLineDash([6, 4], count: 2, phase: 0) }
            border.stroke()
            let label = current == nil
                ? "Förra området — ↩ för att använda det"
                : "\(Int(r.width)) × \(Int(r.height))"
            draw(label: label, near: r)
        } else {
            draw(label: "Dra upp området som ska spelas in  ·  ⎋ avbryter",
                 near: NSRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0))
        }
    }

    private func draw(label: String, near r: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: label, attributes: attrs)
        let size = text.size()
        var origin = NSPoint(x: r.midX - size.width / 2, y: r.minY - size.height - 14)
        if origin.y < 8 { origin.y = r.maxY + 10 }
        let bg = NSRect(x: origin.x - 8, y: origin.y - 4, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6).fill()
        text.draw(at: origin)
    }
}
