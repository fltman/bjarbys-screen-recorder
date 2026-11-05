import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import RecorderKit

/// `--prov-fonsterflytt <mapp>`: fönsterinspelning där fönstret flyttas mitt i.
///
/// Ett eget fönster med en röd ruta spelas in som fönster i 3 s; efter 1 s flyttas det 300 pt åt
/// höger och 120 pt nedåt. Provet tittar på att (1) flytten loggas som `frame`-händelser, (2) den
/// röda rutan ligger kvar på samma ställe i skärmspåret (inspelningen följer fönstret) och (3) den
/// röda rutans globala punkt räknas om till samma ställe i innehållet före och efter flytten —
/// det markören och zoomen bygger på. Paketet raderas efteråt.
@MainActor
enum WindowMoveTest {
    static func run(out: URL) async -> Int32 {
        guard CGPreflightScreenCaptureAccess() else { print(#"{"fel":"Behörighet för skärminspelning saknas."}"#); return 2 }
        var report: [String: Any] = [:]
        guard let screen = NSScreen.main else { return 3 }
        let start = NSRect(x: screen.frame.minX + 120, y: screen.frame.maxY - 560, width: 600, height: 400)
        let window = NSWindow(contentRect: start, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Provfönster"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: start.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        let red = CALayer()
        red.backgroundColor = NSColor.systemRed.cgColor
        // Röda rutan: 80×80 pt, 100 pt från vänster och 100 pt från toppen av innehållet.
        red.frame = CGRect(x: 100, y: start.height - 180, width: 80, height: 80)
        view.layer?.addSublayer(red)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(500))

        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let sc = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw NSError(domain: "prov", code: 1, userInfo: [NSLocalizedDescriptionKey: "provfönstret syns inte för ScreenCaptureKit"])
            }
            var options = CaptureOptions()
            options.systemAudio = false
            let session = try CaptureSession(target: CaptureTarget.fromPicker(SCContentFilter(desktopIndependentWindow: sc)),
                                             options: options, directory: out)
            defer { try? FileManager.default.removeItem(at: session.bundle.url) }
            try await session.start()
            try await Task.sleep(for: .seconds(1))
            window.setFrameOrigin(NSPoint(x: start.minX + 300, y: start.minY - 120))
            try await Task.sleep(for: .seconds(2))
            let meta = await session.stop()
            window.orderOut(nil)

            let events = session.bundle.readEvents().filter { $0.k == .frame }
            report["frame_handelser"] = events.map { e in [e.t, e.rect?.x ?? -1, e.rect?.y ?? -1] }
            report["kalla"] = "\(meta.source.kind.rawValue) \(meta.source.pixelWidth)x\(meta.source.pixelHeight)"

            // (2) Röda rutans mitt i skärmspåret före och efter flytten.
            let track = session.bundle.trackURL(.screen)
            for (name, t) in [("fore", 0.6), ("efter", 2.5)] {
                if let c = try await redCenter(track, at: t) { report["rod_i_sparet_\(name)"] = [c.x, c.y] }
            }

            // (3) Rutans globala punkt (CG: origo uppe till vänster) före och efter, normaliserad.
            let mapping = ContentMapping(meta: meta, events: session.bundle.readEvents())
            let mainH = NSScreen.screens.first?.frame.height ?? screen.frame.height
            func globalRed(_ f: NSRect) -> CGPoint {
                // Innehållets övre kant ligger under titelraden.
                let contentTop = mainH - (f.minY + window.contentRect(forFrameRect: f).height)
                return CGPoint(x: f.minX + 140, y: contentTop + 140)
            }
            let before = window.frameRect(forContentRect: start)
            let after = before.offsetBy(dx: 300, dy: -120)
            let nb = mapping.normalize(globalRed(before), at: 0.6), na = mapping.normalize(globalRed(after), at: 2.5)
            report["rod_normaliserad_fore"] = [round3(nb.x), round3(nb.y)]
            report["rod_normaliserad_efter"] = [round3(na.x), round3(na.y)]
        } catch {
            report["fel"] = error.localizedDescription
        }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
        return report["fel"] == nil ? 0 : 1
    }

    private static func round3(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }

    /// Mitten av de röda pixlarna i en ruta (normaliserad 0–1, origo uppe till vänster).
    private static func redCenter(_ url: URL, at t: Double) async throws -> CGPoint? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        guard let sb = output.copyNextSampleBuffer(), let px = CMSampleBufferGetImageBuffer(sb) else { return nil }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), row = CVPixelBufferGetBytesPerRow(px)
        let p = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
        var sx = 0, sy = 0, n = 0
        for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) {
            let o = y * row + x * 4
            if p[o + 2] > 200 && p[o + 1] < 90 && p[o] < 90 { sx += x; sy += y; n += 1 }
        } }
        guard n > 0 else { return nil }
        return CGPoint(x: (Double(sx) / Double(n) / Double(w) * 1000).rounded() / 1000,
                       y: (Double(sy) / Double(n) / Double(h) * 1000).rounded() / 1000)
    }
}
