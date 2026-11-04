import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import RecorderKit

/// Provlägen som körs direkt ur appbinären, utan gränssnitt:
///
///     Skarminspelare --prov-inspelning 5 [--mik] [--kamera] [--katalog <mapp>]
///     Skarminspelare --prov-aterstall <mapp>
///
/// Skriver en JSON-rapport på stdout och avslutar med 0 vid lyckat prov.
/// Behörigheterna (skärminspelning m.m.) måste ha getts till appen.
@MainActor
enum TestMode {
    static var isRequested: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--prov-") }
    }

    static func run() {
        let args = CommandLine.arguments
        Task { @MainActor in
            let code: Int32
            if let i = args.firstIndex(of: "--prov-inspelning") {
                let seconds = args.count > i + 1 ? Double(args[i + 1]) ?? 5 : 5
                code = await recordingTest(seconds: seconds, args: args)
            } else if let i = args.firstIndex(of: "--prov-aterstall"), args.count > i + 1 {
                code = await recoveryTest(directory: URL(fileURLWithPath: args[i + 1]))
            } else {
                print("okänt provläge")
                code = 64
            }
            fflush(stdout)
            exit(code)
        }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
        return args[i + 1]
    }

    static func recordingTest(seconds: Double, args: [String]) async -> Int32 {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            print(#"{"fel":"Behörighet för skärminspelning saknas. Ge den i Systeminställningar och kör igen."}"#)
            return 2
        }
        let dir = value(after: "--katalog", in: args).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("skarminspelare-prov")
        var options = CaptureOptions()
        if args.contains("--mik") {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            options.microphone = Devices.defaultMicrophone
        }
        if args.contains("--kamera") {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            options.camera = Devices.cameras().first
        }
        options.systemAudio = !args.contains("--utan-datorljud")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                print(#"{"fel":"ingen skärm"}"#); return 3
            }
            let target = CaptureTarget.display(display, in: content)
            let session = try CaptureSession(target: target, options: options, directory: dir)
            var lastStatus = CaptureSession.Status()
            session.onStatus = { lastStatus = $0 }
            let startedAt = Date()
            try await session.start()
            try await Task.sleep(for: .seconds(seconds))
            let meta = await session.stop()
            let report = await describe(bundle: session.bundle, meta: meta,
                                        wall: Date().timeIntervalSince(startedAt), status: lastStatus)
            print(report)
            return meta.finished && meta.track(.screen) != nil ? 0 : 1
        } catch {
            print("{\"fel\":\"\(error.localizedDescription)\"}")
            return 1
        }
    }

    static func recoveryTest(directory: URL) async -> Int32 {
        let unfinished = Recovery.unfinished(in: directory)
        var lines: [String] = []
        for bundle in unfinished {
            do {
                let meta = try await Recovery.recover(bundle)
                lines.append(await describe(bundle: bundle, meta: meta, wall: 0, status: nil))
            } catch {
                lines.append("{\"paket\":\"\(bundle.url.path)\",\"fel\":\"\(error.localizedDescription)\"}")
            }
        }
        print("{\"aterstallda\":\(unfinished.count),\"paket\":[\(lines.joined(separator: ","))]}")
        return unfinished.isEmpty ? 1 : 0
    }

    static func describe(bundle: RecordingBundle, meta: RecordingMeta, wall: Double,
                         status: CaptureSession.Status?) async -> String {
        var tracks: [[String: Any]] = []
        for track in meta.tracks {
            let url = bundle.url(for: track)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration))?.seconds ?? -1
            tracks.append(["spar": track.kind.rawValue, "fil": track.file, "enhet": track.deviceName,
                           "fallerade": track.failed, "byte": size, "langd": duration])
        }
        let events = bundle.readEvents()
        var kinds: [String: Int] = [:]
        for e in events { kinds[e.k.rawValue, default: 0] += 1 }
        var obj: [String: Any] = [
            "paket": bundle.url.path,
            "klar": meta.finished, "aterstalld": meta.recovered,
            "langd": meta.duration, "vaggklocka": wall,
            "upplosning": "\(meta.source.pixelWidth)x\(meta.source.pixelHeight)",
            "skala": meta.source.pixelScale,
            "tappade_rutor": meta.droppedFrames,
            "spar": tracks,
            "handelser": kinds,
            "markorer": bundle.readCursors().entries.count,
            "tangenter": meta.keystrokesRecorded,
        ]
        if let status {
            obj["mik_tyst"] = status.micSilent
            obj["ledigt_gb"] = Double(status.freeBytes ?? 0) / 1e9
            obj["fallerade_spar"] = status.failedTracks.map(\.rawValue)
        }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
