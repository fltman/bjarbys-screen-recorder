import Foundation
import AppKit
import CoreGraphics
import CoreMedia

/// Lyssnar på mus och (valfritt) tangentbord med en CGEventTap som bara lyssnar och aldrig
/// ändrar något. Tappen körs på en egen tråd med egen run loop, så att huvudtråden aldrig
/// kan fördröja den.
///
/// Mushändelser kräver ingen behörighet. Tangenter kräver Indataövervakning, och även då
/// sparas bara kortkommandon (⌘ ⌃ ⌥ eller specialtangenter) — aldrig vanlig text. Lösenordsfält
/// når inte tappen alls (Secure Input).
public final class InputRecorder: @unchecked Sendable {
    private let clock: RecordingClock
    private let log: EventLogWriter
    private let wantsKeystrokes: Bool
    /// Anropas vid varje musnedtryck med global punkt och tidslinjetid (för elementramen).
    public var onMouseDown: ((CGPoint, Double) -> Void)?

    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var globalMonitor: Any?
    private var lastMove: Double = -1
    public private(set) var keystrokesActive = false
    public private(set) var usesFallbackMonitor = false

    public init(clock: RecordingClock, log: EventLogWriter, keystrokes: Bool) {
        self.clock = clock
        self.log = log
        self.wantsKeystrokes = keystrokes
    }

    public static var hasKeystrokePermission: Bool { CGPreflightListenEventAccess() }

    public func start() {
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            self.installTap()
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            if self.tap != nil { CFRunLoopRun() }
        }
        t.name = "skarminspelare.eventtap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        if tap == nil { installFallbackMonitor() }
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
        if let globalMonitor {
            DispatchQueue.main.async { NSEvent.removeMonitor(globalMonitor) }
        }
        globalMonitor = nil
    }

    // MARK: - Tappen

    private static let mouseTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
        .otherMouseDragged, .scrollWheel,
    ]

    private func mask(keys: Bool) -> CGEventMask {
        var m: CGEventMask = 0
        for t in Self.mouseTypes { m |= CGEventMask(1) << t.rawValue }
        if keys { m |= CGEventMask(1) << CGEventType.keyDown.rawValue }
        return m
    }

    private func installTap() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<InputRecorder>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        let keys = wantsKeystrokes && Self.hasKeystrokePermission
        var port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: .listenOnly, eventsOfInterest: mask(keys: keys),
                                     callback: callback, userInfo: refcon)
        keystrokesActive = keys && port != nil
        if port == nil && keys {
            port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: .listenOnly, eventsOfInterest: mask(keys: false),
                                     callback: callback, userInfo: refcon)
        }
        guard let port else { return }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Reserv om tappen inte gick att skapa: en global NSEvent-övervakare på huvudtråden.
    private func installFallbackMonitor() {
        usesFallbackMonitor = true
        DispatchQueue.main.async { [self] in
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                               .rightMouseUp, .leftMouseDragged, .rightMouseDragged, .scrollWheel]
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
                if let cg = e.cgEvent { self?.handle(cg.type, cg) }
            }
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let t = clock.seconds(RecordingClock.hostNow()) else { return }
        let p = event.location
        switch type {
        case .mouseMoved:
            // Högst 240 rader per sekund räcker gott för utjämningen.
            guard t - lastMove >= 1.0 / 240 else { return }
            lastMove = t
            log.append(InputEvent(t: t, k: .move, x: p.x, y: p.y))
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard t - lastMove >= 1.0 / 240 else { return }
            lastMove = t
            log.append(InputEvent(t: t, k: .drag, x: p.x, y: p.y, b: Self.button(type)))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let clicks = Int(event.getIntegerValueField(.mouseEventClickState))
            log.append(InputEvent(t: t, k: .down, x: p.x, y: p.y, b: Self.button(type), n: clicks))
            onMouseDown?(p, t)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            log.append(InputEvent(t: t, k: .up, x: p.x, y: p.y, b: Self.button(type)))
        case .scrollWheel:
            let dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            guard dx != 0 || dy != 0 else { return }
            log.append(InputEvent(t: t, k: .scroll, x: p.x, y: p.y, dx: dx, dy: dy))
        case .keyDown:
            guard let label = Self.shortcutLabel(event) else { return }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            log.append(InputEvent(t: t, k: .key, code: code, label: label))
        default:
            break
        }
    }

    private static func button(_ type: CGEventType) -> Int {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: 0
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: 1
        default: 2
        }
    }

    /// Specialtangenter som visas även utan modifierare.
    private static let specialKeys: [Int64: String] = [
        36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Etiketten för ett kortkommando, eller nil om tangenttrycket är vanlig text som
    /// aldrig ska sparas.
    static func shortcutLabel(_ event: CGEvent) -> String? {
        let flags = event.flags
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let hasCommandLike = flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
        let special = specialKeys[code]
        // Mellanslag och ↩ utan modifierare är oftast vanligt skrivande; spara inte dem.
        if !hasCommandLike && (special == nil || code == 49 || code == 36) { return nil }
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        if let special { return s + special }
        // Tecknet utan modifierare, som användaren ser det på tangenten.
        let ns = NSEvent(cgEvent: event)
        let chars = ns?.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return s + chars
    }
}
