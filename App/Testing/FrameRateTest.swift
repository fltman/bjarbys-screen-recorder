import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import QuartzCore
import RecorderKit

/// `--prov-bildfrekvens <mapp> [bilder/s]`: hur många rutor inspelningen verkligen får.
///
/// ScreenCaptureKit skickar bara rutor när skärmen ändras, så provet visar ett eget fönster med
/// en ruta som rör sig hela tiden (Core Animation, begärd i skärmens takt). Huvudskärmen spelas in
/// i 3 s med fönstret synligt; rutornas tider i skärmspåret mäts. Paketet raderas efteråt.
@MainActor
enum FrameRateTest {
    static func run(out: URL, fps: Int) async -> Int32 {
        guard CGPreflightScreenCaptureAccess() else { print(#"{"fel":"Behörighet för skärminspelning saknas."}"#); return 2 }
        guard !ScreenLock.isLocked else { print(#"{"fel":"Skärmen är låst — fönstren ritas inte, mätningen blir fel."}"#); return 4 }
        guard let screen = NSScreen.main else { return 3 }
        var report: [String: Any] = ["begart": fps, "skarmens_max": screen.maximumFramesPerSecond]
        let frame = NSRect(x: screen.frame.minX + 160, y: screen.frame.maxY - 420, width: 500, height: 200)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let box = CALayer()
        box.backgroundColor = NSColor.white.cgColor
        box.frame = CGRect(x: 0, y: 60, width: 80, height: 80)
        view.layer?.addSublayer(box)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Rörelsen drivs av skärmens displaylänk: en ny position i varje bildruta skärmen visar.
        let driver = Driver(box: box)
        let link = view.displayLink(target: driver, selector: #selector(Driver.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        try? await Task.sleep(for: .milliseconds(400))

        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                throw NSError(domain: "prov", code: 1, userInfo: [NSLocalizedDescriptionKey: "ingen skärm"])
            }
            var options = CaptureOptions()
            options.systemAudio = false
            options.fps = fps
            let session = try CaptureSession(target: CaptureTarget.display(display, in: content, includingOwnApp: true),
                                             options: options, directory: out)
            defer { if ProcessInfo.processInfo.environment["SKARM_BEHALL"] == nil { try? FileManager.default.removeItem(at: session.bundle.url) } }
            try await session.start()
            let recStart = CACurrentMediaTime() - session.clock.elapsed
            try await Task.sleep(for: .seconds(3))
            let meta = await session.stop()

            // Rutornas tider (utom den sista, som läggs in igen vid stopp).
            let asset = AVURLAsset(url: session.bundle.trackURL(.screen))
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "prov", code: 2) }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            reader.startReading()
            var times: [Double] = []
            while let sb = output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sb) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
            }
            times.sort()
            if times.count > 2 { times.removeLast() }
            let gaps = zip(times, times.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
            let span = (times.last ?? 0) - (times.first ?? 0)
            report["rutor"] = times.count
            report["rutor_per_s"] = span > 0 ? (Double(times.count - 1) / span * 10).rounded() / 10 : 0
            if !gaps.isEmpty {
                report["intervall_median_ms"] = (gaps[gaps.count / 2] * 100).rounded() / 100
                report["intervall_p95_ms"] = (gaps[min(gaps.count - 1, gaps.count * 95 / 100)] * 100).rounded() / 100
                report["intervall_max_ms"] = (gaps.last! * 100).rounded() / 100
            }
            report["tappade"] = meta.droppedFrames
            report["luckor"] = meta.gaps.map { [$0.start, $0.end] }
            let st = driver.stamps.map { $0 - recStart }.filter { $0 >= 0 && $0 <= 3 }
            report["skarmens_bildrutor_per_s"] = (Double(st.count) / 3 * 10).rounded() / 10
            if let g = zip(st, st.dropFirst()).map({ ($1 - $0, $0) }).max(by: { $0.0 < $1.0 }) {
                report["displaylank_storsta_lucka"] = [(g.0 * 1000).rounded(), (g.1 * 100).rounded() / 100]
            }
            // Rutor per halvsekund, för att se var det stannar.
            var bins = [Int](repeating: 0, count: 8)
            for t in times { let b = Int(t / 0.5); if b >= 0 && b < bins.count { bins[b] += 1 } }
            report["per_halvsekund"] = bins
        } catch {
            report["fel"] = error.localizedDescription
        }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
        return report["fel"] == nil ? 0 : 1
    }
}

private final class Driver: NSObject {
    let box: CALayer
    var steps = 0
    var stamps: [Double] = []
    init(box: CALayer) { self.box = box }
    @objc func step(_ link: CADisplayLink) {
        steps += 1
        stamps.append(CACurrentMediaTime())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.position.x = 40 + CGFloat(steps % 120) * 3.5
        CATransaction.commit()
    }
}

/// Om skärmen är låst (eller skärmsläckaren med lås visas): då ritas inga fönster, och prov som
/// spelar in skärmens innehåll mäter fel. Uppmätt: en ström under låsning gav långa svep av
/// `idle`-rutor som såg ut som tappade bilder.
enum ScreenLock {
    static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
