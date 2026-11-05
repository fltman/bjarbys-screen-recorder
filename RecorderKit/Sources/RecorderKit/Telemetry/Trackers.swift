import Foundation
import AppKit
import ApplicationServices
import CryptoKit

/// Samplar markörens utseende ungefär 30 gånger per sekund. Skärmspåret spelas in utan
/// markör; den ritas tillbaka i efterhand från de här bilderna, i valfri storlek.
///
/// `NSCursor.currentSystemCursor` är markerad "to be deprecated" men finns i SDK 26.1 och är
/// det enda offentliga sättet att se andra appars markör.
@MainActor
public final class CursorSampler {
    private let clock: RecordingClock
    private let log: EventLogWriter
    private let bundle: RecordingBundle
    private var timer: Timer?
    private var catalog = CursorCatalog()
    private var lastID: String?
    private var lastTIFF: Data?

    public init(clock: RecordingClock, log: EventLogWriter, bundle: RecordingBundle) {
        self.clock = clock
        self.log = log
        self.bundle = bundle
    }

    public func start() {
        sample()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        try? BundleJSON.write(catalog, to: bundle.cursorCatalogURL)
    }

    private func sample() {
        guard let t = clock.seconds(RecordingClock.hostNow()) else { return }
        guard let cursor = NSCursor.currentSystem ?? Optional(NSCursor.arrow) else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return }
        if tiff == lastTIFF { return }
        lastTIFF = tiff
        let id = SHA256.hash(data: tiff).prefix(8).map { String(format: "%02x", $0) }.joined()
        if catalog.entry(id) == nil {
            store(image: image, id: id, hotSpot: cursor.hotSpot)
        }
        if id != lastID {
            lastID = id
            log.append(InputEvent(t: t, k: .cursor, cursor: id))
        }
    }

    private func store(image: NSImage, id: String, hotSpot: NSPoint) {
        // Största representationen (2× på Retina) så att markören är skarp även förstorad.
        var rect = NSRect(origin: .zero, size: NSSize(width: image.size.width * 2, height: image.size.height * 2))
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: bundle.cursorsDir.appendingPathComponent("\(id).png"))
        catalog.entries.append(.init(id: id, width: image.size.width, height: image.size.height,
                                     hotX: hotSpot.x, hotY: hotSpot.y))
        try? BundleJSON.write(catalog, to: bundle.cursorCatalogURL)
    }
}

/// Följer det inspelade fönstrets ram (10 Hz), så att markörens globala koordinater kan
/// räknas om till fönstrets innehåll även om fönstret flyttas.
public final class WindowTracker: @unchecked Sendable {
    private let windowID: CGWindowID
    private let clock: RecordingClock
    private let log: EventLogWriter
    private var timer: DispatchSourceTimer?
    private var last: CGRect?

    public init(windowID: CGWindowID, clock: RecordingClock, log: EventLogWriter) {
        self.windowID = windowID
        self.clock = clock
        self.log = log
    }

    public static func frame(of windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let time = clock.seconds(RecordingClock.hostNow()),
              let f = Self.frame(of: windowID), f != last else { return }
        last = f
        log.append(InputEvent(t: time, k: .frame, rect: Rect(f)))
    }
}

/// Läser ramen för gränssnittselementet under ett klick via Accessibility, så att
/// auto-zoomen kan rama in knappen och inte bara en ruta runt pekaren. Kräver att appen
/// har behörigheten Tillgänglighet; utan den görs ingenting.
public final class ElementProbe: @unchecked Sendable {
    private let log: EventLogWriter
    private let queue = DispatchQueue(label: "skarminspelare.ax", qos: .utility)
    private let systemWide = AXUIElementCreateSystemWide()

    public init(log: EventLogWriter) {
        self.log = log
        // Ett hängande program får inte bromsa oss mer än en tiondel.
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public func probe(at point: CGPoint, t: Double) {
        guard Self.isTrusted else { return }
        queue.async { [self] in
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
                  let element, let rect = Self.frame(of: element) else { return }
            log.append(InputEvent(t: t, k: .element, x: point.x, y: point.y, label: Self.label(of: element),
                                  rect: Rect(rect)))
        }
    }

    /// "knapp «Exportera»": rollen som systemet beskriver den och elementets namn, för
    /// steg-för-steg-guiden. Värdet i textfält läses aldrig (det kan vara vad som helst).
    static func label(of element: AXUIElement) -> String? {
        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let s = value as? String else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
        }
        let role = string(kAXRoleDescriptionAttribute)
        let name = string(kAXTitleAttribute) ?? string(kAXDescriptionAttribute) ?? string(kAXHelpAttribute)
        switch (role, name) {
        case let (r?, n?): return "\(r) «\(n)»"
        case let (nil, n?): return "«\(n)»"
        default: return nil
        }
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: pos, size: size)
    }
}
