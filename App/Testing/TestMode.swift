import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import RecorderKit
import SwiftUI

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
            } else if let i = args.firstIndex(of: "--prov-rendera"), args.count > i + 3 {
                code = await renderTest(bundle: URL(fileURLWithPath: args[i + 1]),
                                        times: args[i + 2].split(separator: ",").compactMap { Double($0) },
                                        out: URL(fileURLWithPath: args[i + 3]))
            } else if let i = args.firstIndex(of: "--prov-exportera"), args.count > i + 3 {
                code = await exportTest(bundle: URL(fileURLWithPath: args[i + 1]), preset: args[i + 2],
                                        out: URL(fileURLWithPath: args[i + 3]))
            } else if let i = args.firstIndex(of: "--prov-redigerare"), args.count > i + 2 {
                code = await editorSnapshot(bundle: URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]),
                                            selectFirstZoom: args.contains("--markera-zoom"))
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

    /// `--prov-rendera <paket> <t1,t2,…> <mapp>`: färdiga rutor som PNG vid utdatatiderna,
    /// genom samma komposition och kompositör som förhandsvisning och export.
    static func renderTest(bundle url: URL, times: [Double], out: URL) async -> Int32 {
        do {
            let rec = try LoadedRecording.load(RecordingBundle(url: url))
            var project = rec.bundle.loadProject(duration: rec.meta.duration)
            if project.autoZoom && !project.zooms.contains(where: { $0.isAuto }) {
                project.zooms += AutoZoom.generate(events: rec.events, mapping: rec.mapping,
                                                   duration: rec.meta.duration, scale: project.zoomScale)
            }
            let canvas = RenderPlan.canvasSize(aspect: project.aspect, source: rec.sourceSize, shortSide: 1080)
            let plan = rec.makePlan(project: project, canvas: canvas)
            let built = try await CompositionBuilder.build(rec, plan: plan, fps: 60)
            let generator = AVAssetImageGenerator(asset: built.composition)
            generator.videoComposition = built.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var written: [String] = []
            for t in times {
                let (image, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
                let file = out.appendingPathComponent(String(format: "ruta-%06.2f.png", t))
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: file)
                let s = plan.timeMap.source(at: t)
                let v = plan.cameraPath.viewport(at: s)
                written.append(String(format: "{\"t\":%.2f,\"fil\":\"%@\",\"zoom\":%.3f,\"mitt\":[%.3f,%.3f]}",
                                      t, file.path, v.scale, v.center.x, v.center.y))
            }
            let zooms = project.zooms.map { String(format: "[%.2f,%.2f,%.2f]", $0.start, $0.end, $0.scale) }
            print("{\"bildyta\":\"\(Int(canvas.width))x\(Int(canvas.height))\",\"zoomar\":[\(zooms.joined(separator: ","))],\"rutor\":[\(written.joined(separator: ","))]}")
            return 0
        } catch {
            print("{\"fel\":\"\(error.localizedDescription)\"}")
            return 1
        }
    }

    /// `--prov-redigerare <paket> <png> [--markera-zoom]`: ritar redigerarfönstret utanför
    /// skärmen, så att layouten kan granskas utan att någon sitter vid datorn.
    static func editorSnapshot(bundle url: URL, out: URL, selectFirstZoom: Bool) async -> Int32 {
        do {
            let model = EditorModel(recording: try LoadedRecording.load(RecordingBundle(url: url)))
            // Låt kompositionen, miniatyrerna och vågformerna bli klara.
            for _ in 0..<40 where model.thumbnails.isEmpty || model.player.currentItem == nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(500))
            if selectFirstZoom, let z = model.project.zooms.first {
                model.selectedZoomID = z.id
                await model.seek(to: model.timeMap.output(at: (z.start + z.end) / 2) ?? 0)
            }
            let size = NSSize(width: 1400, height: 860)
            let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: EditorView(model: model))
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(800))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: out)
            print("{\"fil\":\"\(out.path)\",\"zoomar\":\(model.project.zooms.count),\"miniatyrer\":\(model.thumbnails.count)}")
            window.orderOut(nil)
            return 0
        } catch {
            print("{\"fel\":\"\(error.localizedDescription)\"}")
            return 1
        }
    }

    /// `--prov-exportera <paket> <förval-id> <fil>`.
    static func exportTest(bundle url: URL, preset id: String, out: URL) async -> Int32 {
        guard let preset = ExportPreset.all.first(where: { $0.id == id }) else {
            print("{\"fel\":\"okänt förval\"}"); return 64
        }
        do {
            let rec = try LoadedRecording.load(RecordingBundle(url: url))
            var project = rec.bundle.loadProject(duration: rec.meta.duration)
            if project.autoZoom && !project.zooms.contains(where: { $0.isAuto }) {
                project.zooms += AutoZoom.generate(events: rec.events, mapping: rec.mapping,
                                                   duration: rec.meta.duration, scale: project.zoomScale)
            }
            let started = Date()
            let exporter = Exporter(recording: rec, project: project, preset: preset)
            try await exporter.run(to: out) { _ in }
            let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            print(String(format: "{\"fil\":\"%@\",\"sekunder\":%.2f,\"byte\":%d,\"langd\":%.3f}",
                         out.path, Date().timeIntervalSince(started), size, TimeMap(segments: project.segments).outputDuration))
            return 0
        } catch {
            print("{\"fel\":\"\(error.localizedDescription)\"}")
            return 1
        }
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
