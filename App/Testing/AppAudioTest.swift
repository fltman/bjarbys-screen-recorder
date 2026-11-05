import Foundation
import AVFoundation
import ScreenCaptureKit
import RecorderKit

/// `--prov-appljud <mapp>`: ljud per app, mätt med toner från processer vi själva startar.
///
/// 1. Separation: två `afplay` spelar 440 Hz och 660 Hz samtidigt. Den första spelas in på ett
///    eget spår (tapp per process), "övrigt datorljud" (allt utom den) på ett annat. Varje spår
///    ska ha sin ton och nästan inget av den andra.
/// 2. Synk: ScreenCaptureKits datorljud och en tapp av samma `afplay` spelas in samtidigt på
///    inspelningens klocka; en ton med skarp ansats ska börja på samma tid i båda.
///
/// Tonerna spelas tyst (volym 0,15) i högtalarna. Paketen raderas efteråt (`--behall` behåller
/// separationens paket, för att se redigeraren med appspår).
@MainActor
enum AppAudioTest {
    static func run(out: URL, keep: Bool = false) async -> Int32 {
        guard CGPreflightScreenCaptureAccess() else {
            print(#"{"fel":"Behörighet för skärminspelning saknas."}"#); return 2
        }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String: Any] = [:]
        do {
            let a = out.appendingPathComponent("ton-440.caf"), b = out.appendingPathComponent("ton-660.caf")
            let c = out.appendingPathComponent("ton-1000-ansats.caf")
            try tone(440, seconds: 4, silence: 0, to: a)
            try tone(660, seconds: 4, silence: 0, to: b)
            try tone(1000, seconds: 1.5, silence: 1.0, to: c)

            // 1. Separation.
            let pa = try play(a), pb = try play(b)
            defer { pa.terminate(); pb.terminate() }
            try await Task.sleep(for: .milliseconds(400))
            var options = CaptureOptions()
            options.systemAudio = true
            options.apps = [AudioSourceChoice(bundleID: "", name: "Ton 440", pids: [pa.processIdentifier])]
            let session = try await makeSession(options, dir: out)
            try await session.start()
            try await Task.sleep(for: .seconds(3))
            let meta = await session.stop()
            pa.terminate(); pb.terminate()
            let bundle = session.bundle
            var tracks: [String: Any] = [:]
            for track in meta.tracks where track.kind != .screen {
                let samples = try await read(bundle.url(for: track))
                let window = Array(samples.dropFirst(Int(0.8 * 48_000)).prefix(Int(1.5 * 48_000)))
                tracks[track.file] = [
                    "namn": track.deviceName,
                    "fallerade": track.failed,
                    "sekunder": Double(samples.count) / 48_000,
                    "topp": samples.map(abs).max() ?? 0,
                    "440_hz": goertzel(window, 440), "660_hz": goertzel(window, 660),
                    // Tonen spelar hela tiden: 50 ms-fönster utan ljud (efter de första 100 ms) är glapp.
                    "glapp_ms": gapMilliseconds(samples),
                ]
            }
            report["separation"] = tracks
            if keep { report["paket"] = bundle.url.path } else { try? FileManager.default.removeItem(at: bundle.url) }

            // 2. Synk mot ScreenCaptureKits datorljud.
            var sckOptions = CaptureOptions()
            sckOptions.systemAudio = true
            let sync = try await makeSession(sckOptions, dir: out)
            try await sync.start()
            let pc = try play(c)
            defer { pc.terminate() }
            try await Task.sleep(for: .milliseconds(300))
            let tapURL = sync.bundle.recordingDir.appendingPathComponent("tapp-prov.mov")
            let writer = try TrackWriter(kind: .app, url: tapURL, settings: .audio)
            let tap = ProcessTap(mode: .only([AudioSourceChoice(bundleID: "", name: "Ton 1000", pids: [pc.processIdentifier])]),
                                 name: "Ton 1000")
            let clock = sync.clock
            tap.onBuffer = { buffer, host in
                if let t = clock.map(host) { writer.append(buffer, at: t) }
            }
            try tap.start()
            try await Task.sleep(for: .seconds(2.5))
            tap.stop()
            _ = await writer.finish()
            let syncMeta = await sync.stop()
            pc.terminate()
            if let sys = syncMeta.track(.system) {
                let s1 = try await read(sync.bundle.url(for: sys)), s2 = try await read(tapURL)
                let o1 = onset(s1, 1000), o2 = onset(s2, 1000)
                report["synk"] = ["sck_ansats_s": o1 ?? -1, "tapp_ansats_s": o2 ?? -1,
                                  "skillnad_ms": (o1 != nil && o2 != nil) ? (o2! - o1!) * 1000 : 0]
            }
            try? FileManager.default.removeItem(at: sync.bundle.url)
            for f in [a, b, c] { try? FileManager.default.removeItem(at: f) }
        } catch {
            report["fel"] = error.localizedDescription
        }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
        return report["fel"] == nil ? 0 : 1
    }

    /// Felsökning av glapp: `tappar` (två tappar, ingen SCK), `sck` (bara SCK:s datorljud),
    /// `bada` (SCK-ljud och två tappar). Tonerna 6 s, inspelning 4 s, glapp per spår.
    static func diagnose(out: URL, variant: String) async -> Int32 {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let a = out.appendingPathComponent("d-440.caf"), b = out.appendingPathComponent("d-660.caf")
        try? tone(440, seconds: 6, silence: 0, to: a)
        try? tone(660, seconds: 6, silence: 0, to: b)
        guard let pa = try? play(a), let pb = try? play(b) else { return 1 }
        defer { pa.terminate(); pb.terminate() }
        try? await Task.sleep(for: .milliseconds(400))
        let clock = RecordingClock()
        clock.startIfNeeded(at: RecordingClock.hostNow())
        var files: [URL] = []
        var taps: [ProcessTap] = []
        var writers: [TrackWriter] = []
        var session: CaptureSession?
        if variant.hasPrefix("sck") || variant.hasPrefix("bada") {
            var o = CaptureOptions(); o.systemAudio = true
            session = try? await makeSession(o, dir: out)
            try? await session?.start()
        }
        if variant.hasPrefix("tappar") || variant.hasPrefix("bada") {
            for (i, mode) in [ProcessTap.Mode.only([AudioSourceChoice(bundleID: "", name: "A", pids: [pa.processIdentifier])]),
                              .allExcept([AudioSourceChoice(bundleID: "", name: "A", pids: [pa.processIdentifier])])].enumerated() {
                let url = out.appendingPathComponent("d-tapp-\(i).mov")
                guard let w = try? TrackWriter(kind: .app, url: url, settings: .audio) else { continue }
                let tap = ProcessTap(mode: mode, name: "d\(i)")
                let c = session?.clock ?? clock
                tap.onBuffer = { buf, host in if let t = c.map(host) { w.append(buf, at: t) } }
                try? tap.start()
                taps.append(tap); writers.append(w); files.append(url)
            }
        }
        if variant.hasSuffix("+ny") {
            // En ny ljudprocess ansluter mitt i (1000 Hz i 1 s), som en app som börjar spela.
            try? await Task.sleep(for: .seconds(1.5))
            let c = out.appendingPathComponent("d-1000.caf")
            try? tone(1000, seconds: 1, silence: 0, to: c)
            let pc = try? play(c)
            try? await Task.sleep(for: .seconds(2.5))
            pc?.terminate()
            try? FileManager.default.removeItem(at: c)
        } else {
            try? await Task.sleep(for: .seconds(4))
        }
        for t in taps { t.stop() }
        for w in writers { _ = await w.finish() }
        if let session {
            let meta = await session.stop()
            if let sys = meta.track(.system) { files.append(session.bundle.url(for: sys)) }
        }
        var lines: [String] = []
        for f in files {
            let s = (try? await read(f)) ?? []
            // Var 440 Hz-tonen (processen A) saknas: där A inte hördes, oavsett annat ljud.
            var gaps: [String] = []
            var i = 4800
            while i + 2400 <= s.count {
                let chunk = Array(s[i..<(i + 2400)])
                let missing = f.lastPathComponent == "d-tapp-1.mov"
                    ? (chunk.map(abs).max() ?? 0) < 0.01
                    : goertzel(chunk, 440) < 0.03
                if missing { gaps.append(String(format: "%.2f", Double(i) / 48_000)) }
                i += 2400
            }
            lines.append("\(f.lastPathComponent): \(String(format: "%.2f", Double(s.count) / 48_000)) s, tyst vid [\(gaps.joined(separator: " "))]")
        }
        print(lines.joined(separator: "\n"))
        if let session { try? FileManager.default.removeItem(at: session.bundle.url) }
        for f in files where f.pathExtension == "mov" && f.lastPathComponent.hasPrefix("d-") { try? FileManager.default.removeItem(at: f) }
        for f in [a, b] { try? FileManager.default.removeItem(at: f) }
        return 0
    }

    private static func makeSession(_ options: CaptureOptions, dir: URL) async throws -> CaptureSession {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "prov", code: 3, userInfo: [NSLocalizedDescriptionKey: "ingen skärm"])
        }
        return try CaptureSession(target: CaptureTarget.display(display, in: content), options: options, directory: dir)
    }

    /// En sinuston (amplitud 0,8) efter `silence` sekunders tystnad, 48 kHz mono.
    private static func tone(_ hz: Double, seconds: Double, silence: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount((silence + seconds) * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let start = Int(silence * 48_000)
        let p = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            p[i] = i < start ? 0 : Float(0.8 * sin(2 * .pi * hz * Double(i - start) / 48_000))
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func play(_ url: URL) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["-v", "0.15", url.path]
        try p.run()
        return p
    }

    /// Hela spåret som mono-flyttal i 48 kHz.
    private static func read(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var out: [Float] = []
        while let sb = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(block) / 4
            var chunk = [Float](repeating: 0, count: n)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: &chunk)
            out += chunk
        }
        return out
    }

    /// Sammanlagd tid (ms) i 50 ms-fönster med topp under 0,01, efter de första 100 ms.
    static func gapMilliseconds(_ x: [Float]) -> Int {
        let w = 2400
        var gaps = 0
        var i = 4800
        while i + w <= x.count {
            if (x[i..<(i + w)].map(abs).max() ?? 0) < 0.01 { gaps += 50 }
            i += w
        }
        return gaps
    }

    /// Amplituden för en frekvens (Goertzel), 0–1.
    static func goertzel(_ x: [Float], _ hz: Double) -> Double {
        guard !x.isEmpty else { return 0 }
        let k = 2 * cos(2 * .pi * hz / 48_000)
        var s1 = 0.0, s2 = 0.0
        for v in x { let s = Double(v) + k * s1 - s2; s2 = s1; s1 = s }
        let power = s1 * s1 + s2 * s2 - k * s1 * s2
        return 2 * power.squareRoot() / Double(x.count)
    }

    /// Första 5 ms-fönstret där tonen tydligt finns (amplitud över 0,02), interpolerat till
    /// den första samplingen över hälften av fönstrets topp.
    static func onset(_ x: [Float], _ hz: Double) -> Double? {
        let w = 240
        var i = 0
        while i + w <= x.count {
            if goertzel(Array(x[i..<(i + w)]), hz) > 0.02 {
                let window = x[max(0, i - w)..<(i + w)]
                let peak = window.map(abs).max() ?? 0
                if let j = window.firstIndex(where: { abs($0) > peak / 2 }) { return Double(j) / 48_000 }
                return Double(i) / 48_000
            }
            i += w / 2
        }
        return nil
    }
}
