import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import RecorderKit
import SwiftUI

/// Provlägen som körs direkt ur appbinären, utan gränssnitt:
///
///     Skarminspelare --prov-inspelning 5 [--mik] [--kamera] [--stadad] [--katalog <mapp>]
///     Skarminspelare --prov-aterstall <mapp>
///     Skarminspelare --prov-transkribera <paket> [--modell <fil>] [--sprak sv]
///     Skarminspelare --prov-ljudstyrka <ljudfil>
///     Skarminspelare --prov-vyer <mapp> <paket>   (alla fönster och paneler som bilder)
///     Skarminspelare --prov-flashback <del-s> <buffert-s> <kör-s> <spara-s> <mapp>
///     Skarminspelare --prov-rostisolering <ljudfil> <ut.caf>
///     Skarminspelare --prov-maskera <paket> <t1,t2,…> <mapp>   (söker känslig text, renderar)
///     Skarminspelare --prov-appljud <mapp>   (ljud per app: separation och synk, med egna toner)
///     Skarminspelare --prov-bildfrekvens <mapp> [bilder/s]   (verklig bildtakt i inspelningen)
///     Skarminspelare --prov-fonsterflytt <mapp>   (fönsterinspelning där fönstret flyttas)
///     Skarminspelare --prov-hdr <mapp>   (HDR: ett eget EDR-fält mätt i inspelning och export)
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
            } else if let i = args.firstIndex(of: "--prov-transkribera"), args.count > i + 1 {
                code = await transcribeTest(bundle: URL(fileURLWithPath: args[i + 1]),
                                            model: value(after: "--modell", in: args),
                                            language: value(after: "--sprak", in: args) ?? "sv")
            } else if let i = args.firstIndex(of: "--prov-maskera"), args.count > i + 3 {
                code = await renderTest(bundle: URL(fileURLWithPath: args[i + 1]),
                                        times: args[i + 2].split(separator: ",").compactMap { Double($0) },
                                        out: URL(fileURLWithPath: args[i + 3]), scanMasks: true)
            } else if let i = args.firstIndex(of: "--prov-rostisolering"), args.count > i + 2 {
                do {
                    let started = Date()
                    let r = try await VoiceIsolation.process(AVURLAsset(url: URL(fileURLWithPath: args[i + 1])),
                                                             to: URL(fileURLWithPath: args[i + 2]))
                    print(String(format: #"{"fordrojning_ms":%.1f,"sekunder":%.2f,"fil":"%@"}"#, r.latency * 1000,
                                 Date().timeIntervalSince(started), r.url.path))
                    code = 0
                } catch {
                    print(#"{"fel":"\#(error.localizedDescription)"}"#); code = 1
                }
            } else if let i = args.firstIndex(of: "--prov-flashback"), args.count > i + 5 {
                code = await flashbackTest(segment: Double(args[i + 1]) ?? 4, buffer: Double(args[i + 2]) ?? 10,
                                           run: Double(args[i + 3]) ?? 13, save: Double(args[i + 4]) ?? 10,
                                           out: URL(fileURLWithPath: args[i + 5]))
            } else if let i = args.firstIndex(of: "--prov-teleprompter"), args.count > i + 1 {
                // Rutan efter 6 s rullning (2 s inledning + 4 s), utanför skärmen.
                let model = TeleprompterModel(text: """
                    Hej och välkommen! I den här korta genomgången visar jag hur du exporterar en film \
                    från redigeraren. Först öppnar vi inspelningen i biblioteket. Sedan väljer vi format \
                    och bakgrund, och till sist trycker vi på Exportera längst upp till höger. Klart!
                    """, wpm: 150, fontSize: 26)
                model.start()
                try? await Task.sleep(for: .seconds(6))
                let view = NSHostingView(rootView: TeleprompterView(model: model))
                view.frame = NSRect(x: 0, y: 0, width: 760, height: 210)
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                print(#"{"fil":"\#(args[i + 1])"}"#)
                code = 0
            } else if let i = args.firstIndex(of: "--prov-uppladdning"), args.count > i + 2 {
                // Mot en lokal provserver med påhittade provnycklar — aldrig riktiga.
                let config = S3Config(endpoint: args[i + 2], bucket: "provhink", region: "auto", accessKeyID: "PROVNYCKEL",
                                      publicBaseURL: "https://media.exempel.test", prefix: "prov")
                do {
                    let link = try await S3Uploader.upload(URL(fileURLWithPath: args[i + 1]), config: config, secret: "provhemlighet")
                    print(#"{"lank":"\#(link.absoluteString)"}"#); code = 0
                } catch {
                    print(#"{"fel":"\#(error.localizedDescription)"}"#); code = 1
                }
            } else if let i = args.firstIndex(of: "--prov-vyer"), args.count > i + 2 {
                code = await viewSnapshots(out: URL(fileURLWithPath: args[i + 1]), bundle: URL(fileURLWithPath: args[i + 2]))
            } else if let i = args.firstIndex(of: "--prov-ljudstyrka"), args.count > i + 1 {
                let m = try? await Loudness.measure(AVURLAsset(url: URL(fileURLWithPath: args[i + 1])))
                print(m.map { String(format: #"{"lufs":%.2f,"topp_dbfs":%.2f,"forstarkning_db":%.2f}"#, $0.integrated,
                                     20 * log10($0.peak), 20 * log10(Loudness.gain(for: $0).gain)) } ?? #"{"fel":"tyst eller oläsbar"}"#)
                code = m == nil ? 1 : 0
            } else if let i = args.firstIndex(of: "--prov-trim"), args.count > i + 1 {
                // Trimningens gränser på två delar [0–1] och [2–3] (sparas inte i paketet).
                do {
                    let model = EditorModel(recording: try LoadedRecording.load(RecordingBundle(url: URL(fileURLWithPath: args[i + 1]))))
                    model.persists = false
                    model.update { $0.segments = [.init(start: 0, end: 1), .init(start: 2, end: 3)] }
                    let a = model.project.segments[0].id, b = model.project.segments[1].id
                    @MainActor func state() -> String { model.project.segments.map { String(format: "[%.2f–%.2f %g×]", $0.start, $0.end, $0.speed) }.joined(separator: " ") }
                    var lines: [String] = []
                    model.trimSegment(a, end: 1.8); lines.append("A slut 1,8: \(state())")
                    model.trimSegment(a, end: 2.5); lines.append("A slut 2,5 (grannen vid 2): \(state())")
                    model.trimSegment(b, start: 0.5); lines.append("B start 0,5 (A slutar 2): \(state())")
                    model.trimSegment(a, start: -1); lines.append("A start -1: \(state())")
                    model.trimSegment(b, end: 99); lines.append("B slut 99 (inspelningen \(String(format: "%.2f", model.recording.meta.duration))): \(state())")
                    model.trimSegment(b, start: 2.98); lines.append("B start 2,98 (minst 0,1 s): \(state())")
                    model.moveSegment(b, toIndexAmongOthers: 0)
                    lines.append("B först: \(state()) — ordning \(model.project.segments.map { $0.id == a ? "A" : "B" }.joined())")
                    model.moveSegment(b, toIndexAmongOthers: 1)
                    lines.append("B sist igen: \(model.project.segments.map { $0.id == a ? "A" : "B" }.joined())")
                    model.selectedSegmentID = a
                    print(lines.joined(separator: "\n"))
                    code = 0
                } catch { print(error.localizedDescription); code = 1 }
            } else if let i = args.firstIndex(of: "--prov-penna"), args.count > i + 1 {
                code = await inkTest(out: URL(fileURLWithPath: args[i + 1]))
            } else if let i = args.firstIndex(of: "--prov-enhet"), args.count > i + 2 {
                // Enheterna, och en kort inspelning från den första kameran (eller --enhet <namn>).
                // Bara måtten skrivs ut; paketet raderas (kameran fångar den som sitter där).
                DeviceSession.allowScreenDevices()
                try? await Task.sleep(for: .seconds(1))
                let devices = DeviceSession.devices()
                for d in devices { print("enhet: \(d.name)\(d.isScreen ? " (iPhone/iPad)" : "") — \(d.id)") }
                let wanted = value(after: "--enhet", in: args)
                guard let device = devices.first(where: { wanted == nil ? !$0.isScreen : $0.name.localizedCaseInsensitiveContains(wanted!) }) else {
                    print("ingen enhet att spela in från"); code = 2; return
                }
                do {
                    let session = try DeviceSession(deviceID: device.id, microphoneID: args.contains("--mik") ? "standard" : nil,
                                                    fps: 30, directory: URL(fileURLWithPath: args[i + 1]))
                    defer { if ProcessInfo.processInfo.environment["SKARM_BEHALL"] == nil { try? FileManager.default.removeItem(at: session.bundle.url) } }
                    try await session.start()
                    try await Task.sleep(for: .seconds(Double(args[i + 2]) ?? 3))
                    let meta = await session.stop()
                    print("källa: \(meta.source.kind.rawValue) «\(meta.source.title)» \(meta.source.pixelWidth)×\(meta.source.pixelHeight), längd \(String(format: "%.2f", meta.duration)) s")
                    for t in meta.tracks {
                        let asset = AVURLAsset(url: session.bundle.url(for: t))
                        let d = (try? await asset.load(.duration))?.seconds ?? 0
                        var extra = ""
                        if let v = try? await asset.loadTracks(withMediaType: .video).first {
                            let n = (try? await v.load(.nominalFrameRate)) ?? 0
                            extra = String(format: ", %.1f bilder/s", n)
                        }
                        print(String(format: "  %@: %@, start %.3f, längd %.2f s%@", t.kind.rawValue, t.failed ? "MISSLYCKADES" : "ok", t.start, d, extra))
                    }
                    print("Quick Look: \(FileManager.default.fileExists(atPath: session.bundle.quickLookDir.appendingPathComponent("Thumbnail.png").path))")
                    code = 0
                } catch { print(error.localizedDescription); code = 1 }
            } else if let i = args.firstIndex(of: "--prov-ansikten"), args.count > i + 1 {
                // Ansiktena i kameraspåret (Vision), utan att spara något i paketet.
                do {
                    let rec = try LoadedRecording.load(RecordingBundle(url: URL(fileURLWithPath: args[i + 1])))
                    guard let camera = rec.asset(.camera) else { print("ingen kamera i paketet"); code = 2; return }
                    let started = Date()
                    let track = try await FaceTrack.analyze(camera, from: rec.meta.track(.camera)?.start ?? 0, to: rec.meta.duration)
                    print(String(format: "prov: %d på %.1f s (inspelningen %.1f s)", track.samples.count,
                                 Date().timeIntervalSince(started), rec.meta.duration))
                    for smp in track.samples.prefix(12) {
                        print(String(format: "  %.2f s: mitt (%.3f, %.3f), höjd %.3f", smp.t, smp.x, smp.y, smp.h))
                    }
                    code = 0
                } catch { print(error.localizedDescription); code = 1 }
            } else if let i = args.firstIndex(of: "--prov-slaihop"), args.count > i + 3 {
                // Slår ihop paketen (i den givna ordningen) till ett nytt i mappen och mäter resultatet.
                let bundles = args[(i + 2)...].prefix { !$0.hasPrefix("--") }.map { RecordingBundle(url: URL(fileURLWithPath: $0)) }
                do {
                    let merged = try await RecordingMerger.merge(Array(bundles), into: URL(fileURLWithPath: args[i + 1]))
                    let meta = try merged.readMeta()
                    var lines = ["paket: \(merged.url.path)", String(format: "längd: %.3f s", meta.duration)]
                    for t in meta.tracks {
                        let asset = AVURLAsset(url: merged.url(for: t), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                        let d = (try? await asset.load(.duration))?.seconds ?? -1
                        let n = (try? await asset.loadTracks(withMediaType: t.kind == .screen || t.kind == .camera ? .video : .audio).count) ?? 0
                        lines.append(String(format: "  %@ %@: start %.3f, längd %.3f s, %d spår", t.kind.rawValue, t.file, t.start, d, n))
                    }
                    let events = merged.readEvents()
                    lines.append("händelser: \(events.count), första \(events.first.map { String(format: "%.3f", $0.t) } ?? "–"), sista \(events.last.map { String(format: "%.3f", $0.t) } ?? "–")")
                    lines.append("markörbilder: \(merged.readCursors().entries.count)")
                    if let tr = merged.readTranscript() { lines.append("ord: \(tr.words.count), sista slutar \(String(format: "%.3f", tr.words.last?.end ?? 0))") }
                    print(lines.joined(separator: "\n"))
                    code = 0
                } catch { print(error.localizedDescription); code = 1 }
            } else if let i = args.firstIndex(of: "--prov-bildfrekvens"), args.count > i + 1 {
                let fps = args.count > i + 2 ? Int(args[i + 2]) ?? 120 : 120
                code = await FrameRateTest.run(out: URL(fileURLWithPath: args[i + 1]), fps: fps)
            } else if let i = args.firstIndex(of: "--prov-fonsterflytt"), args.count > i + 1 {
                code = await WindowMoveTest.run(out: URL(fileURLWithPath: args[i + 1]))
            } else if let i = args.firstIndex(of: "--prov-hdr-syntetisk"), args.count > i + 1 {
                // Valfritt: bredd höjd bilder/s sekunder (för att mäta exportfarten i full storlek).
                let n = args.dropFirst(i + 2).prefix(4).compactMap { Int($0) }
                code = n.count == 4
                    ? await HDRTest.synthetic(out: URL(fileURLWithPath: args[i + 1]), width: n[0], height: n[1], fps: n[2], seconds: n[3])
                    : await HDRTest.synthetic(out: URL(fileURLWithPath: args[i + 1]))
            } else if let i = args.firstIndex(of: "--prov-hdr"), args.count > i + 1 {
                code = await HDRTest.run(out: URL(fileURLWithPath: args[i + 1]))
            } else if let i = args.firstIndex(of: "--prov-tappglapp"), args.count > i + 2 {
                code = await AppAudioTest.diagnose(out: URL(fileURLWithPath: args[i + 1]), variant: args[i + 2])
            } else if let i = args.firstIndex(of: "--prov-appljud"), args.count > i + 1 {
                code = await AppAudioTest.run(out: URL(fileURLWithPath: args[i + 1]), keep: args.contains("--behall"))
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
        options.hideDesktopIcons = args.contains("--stadad")
        options.hideNotifications = args.contains("--stadad")
        options.liveVoiceProcessing = args.contains("--rensa")
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
    static func renderTest(bundle url: URL, times: [Double], out: URL, scanMasks: Bool = false) async -> Int32 {
        do {
            let rec = try LoadedRecording.load(RecordingBundle(url: url))
            var project = rec.bundle.loadProject(duration: rec.meta.duration)
            if scanMasks {
                // Masker söks men sparas inte i paketet.
                let started = Date()
                project.masks = try await MaskScanner.scan(rec, kinds: Set(SensitiveText.Kind.allCases))
                let list = project.masks.map { m in
                    String(format: "{\"typ\":\"%@\",\"tips\":\"%@\",\"tid\":[%.1f,%.1f],\"nyckelrutor\":%d}",
                           m.kind.rawValue, m.hint, m.start, m.end, m.keyframes.count)
                }
                print(String(format: "{\"sokning_s\":%.1f,\"masker\":[%@]}", Date().timeIntervalSince(started),
                             list.joined(separator: ",")))
            }
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
    /// `--prov-transkribera <paket> [--modell <fil>] [--sprak sv]`: transkriberar med
    /// whisper.cpp, sparar transcript.json och skriver orden och undertexterna.
    static func transcribeTest(bundle url: URL, model: String?, language: String) async -> Int32 {
        do {
            let rec = try LoadedRecording.load(RecordingBundle(url: url))
            guard let root = WhisperSetup.findRoot() else {
                print(#"{"fel":"hittar inte whisper.cpp"}"#); return 1
            }
            var setup = WhisperSetup(root: root, model: "", language: language)
            setup.model = model ?? WhisperSetup.preferredModel(among: setup.availableModels, language: language) ?? ""
            let started = Date()
            let transcript = try await Transcriber.run(rec, setup: setup)
            try rec.bundle.saveTranscript(transcript)
            let project = rec.bundle.loadProject(duration: rec.meta.duration)
            let captions = Captions(words: transcript.words, timeMap: TimeMap(segments: project.segments))
            let report: [String: Any] = [
                "modell": setup.model,
                "sekunder": (Date().timeIntervalSince(started) * 10).rounded() / 10,
                "ord": transcript.words.map { String(format: "%.2f–%.2f %@", $0.start, $0.end, $0.text) },
                "undertexter": captions.cues.map { String(format: "%.2f–%.2f ", $0.start, $0.end) + $0.text.replacingOccurrences(of: "\n", with: " / ") },
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "")
            return transcript.words.isEmpty ? 1 : 0
        } catch {
            print("{\"fel\":\"\(error.localizedDescription)\"}")
            return 1
        }
    }

    /// Kör flashback-bufferten med korta delar, sparar och mäter det ihopsydda paketet:
    /// längder, bildrutor och glapp i ljudet (där skarvarna sitter).
    static func flashbackTest(segment: Double, buffer: Double, run: Double, save: Double, out: URL) async -> Int32 {
        guard CGPreflightScreenCaptureAccess() else { print(#"{"fel":"behörighet saknas"}"#); return 2 }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("skarminspelare-flashback-prov")
        var options = CaptureOptions()
        options.systemAudio = true
        let recorder = FlashbackRecorder(bufferSeconds: buffer, segmentSeconds: segment, directory: work, options: options) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let d = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
            else { throw FlashbackError.empty }
            return CaptureTarget.display(d, in: content)
        }
        do {
            try await recorder.start()
            try await Task.sleep(for: .seconds(run))
            let started = Date()
            let bundle = try await recorder.save(last: save, into: out)
            let saveTime = Date().timeIntervalSince(started)
            let segments = recorder.segmentCount
            await recorder.stop()
            let meta = try bundle.readMeta()
            var report: [String: Any] = ["paket": bundle.url.path, "langd": meta.duration, "delar_kvar": segments,
                                         "spara_s": (saveTime * 100).rounded() / 100,
                                         "handelser": bundle.readEvents().count,
                                         "arbetsmapp_borta": !FileManager.default.fileExists(atPath: work.path)]
            for track in meta.tracks {
                let asset = AVURLAsset(url: bundle.url(for: track))
                let duration = try await asset.load(.duration).seconds
                guard let t = try await asset.loadTracks(withMediaType: track.kind == .screen ? .video : .audio).first,
                      let reader = try? AVAssetReader(asset: asset) else { continue }
                let output = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
                reader.add(output)
                reader.startReading()
                var times: [(Double, Double)] = []
                while let b = output.copyNextSampleBuffer() {
                    let pts = CMSampleBufferGetPresentationTimeStamp(b).seconds
                    let dur = CMSampleBufferGetDuration(b).seconds
                    times.append((pts, dur.isFinite ? dur : 0))
                }
                // Glapp: där nästa buffert börjar senare än föregående slutade (ljud), eller
                // största avståndet mellan rutor (bild).
                var gaps: [String] = []
                for (a, b) in zip(times, times.dropFirst()) where track.kind != .screen && b.0 - (a.0 + a.1) > 0.002 {
                    gaps.append(String(format: "%.3f+%.3f", a.0 + a.1, b.0 - (a.0 + a.1)))
                }
                let maxFrameGap = zip(times, times.dropFirst()).map { $1.0 - $0.0 }.max() ?? 0
                report[track.kind.rawValue] = ["langd": (duration * 1000).rounded() / 1000, "buffertar": times.count,
                                               "forsta": times.first?.0 ?? -1,
                                               "glapp": track.kind == .screen ? [] : gaps,
                                               "storsta_rutavstand": track.kind == .screen ? (maxFrameGap * 1000).rounded() / 1000 : 0]
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "")
            return 0
        } catch {
            await recorder.stop()
            print("{\"fel\":\"\(error.localizedDescription)\"}")
            return 1
        }
    }

    /// Ritar appens fönster och paneler utanför skärmen, för att granska utseendet.
    static func viewSnapshots(out: URL, bundle: URL) async -> Int32 {
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            func shot<V: View>(_ name: String, _ size: NSSize, _ view: V, dark: Bool = false) async throws {
                let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -6000, y: -6000), size: size),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                // Fönstrets bakgrund bakom vyn: annars blir det genomskinliga svart i PNG:en.
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                host.frame = NSRect(origin: .zero, size: size)
                window.contentView = host
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(700))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
                window.orderOut(nil)
            }
            let app = AppModel.shared
            try await shot("bibliotek", NSSize(width: 980, height: 640), LibraryView().environmentObject(app))
            try await shot("bibliotek-mork", NSSize(width: 980, height: 640), LibraryView().environmentObject(app), dark: true)
            try await shot("behorigheter", NSSize(width: 600, height: 560), PermissionsView())
            try await shot("hud", NSSize(width: 360, height: 140), HUDView(controller: app.recorder).padding(10), dark: true)
            try await shot("manus", NSSize(width: 560, height: 460), ScriptEditorView(settings: app.settings))
            try await shot("delning", NSSize(width: 520, height: 520), SharingSettingsView())
            try await shot("kortkommandon", NSSize(width: 520, height: 300), HotKeySettingsView())
            try await shot("sla-ihop", NSSize(width: 560, height: 470),
                           MergeSheet(library: app.library, selected: Set(app.library.items.prefix(2).map(\.bundle.url))) { _ in })
            let model = EditorModel(recording: try LoadedRecording.load(RecordingBundle(url: bundle)))
            for _ in 0..<40 where model.thumbnails.isEmpty || model.player.currentItem == nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            // Ett lager som går att dra, markerat och synligt vid spelhuvudet.
            if let o = model.project.overlays.first(where: { $0.kind != .title && !($0.kind == .video && $0.isFullFrame) }),
               let t = model.timeMap.output(at: o.at) {
                model.selectedOverlayID = o.id
                await model.seek(to: t + 0.5)
            }
            if model.selectedOverlayID == nil { model.selectedSegmentID = model.project.segments.first?.id }
            try await shot("redigerare", NSSize(width: 1400, height: 860), EditorView(model: model))
            try await shot("redigerare-mork", NSSize(width: 1400, height: 860), EditorView(model: model), dark: true)
            // En egen mask vid spelhuvudet, markerad. Sparas inte i paketet.
            model.persists = false
            model.addMaskAtPlayhead()
            try await shot("redigerare-mask", NSSize(width: 1400, height: 860), EditorView(model: model))
            model.selectedOverlayID = (model.project.overlays.first { $0.kind == .fact } ?? model.project.overlays.first)?.id
            for tab in InspectorView.Tab.allCases {
                UserDefaults.standard.set(tab.rawValue, forKey: "inspectorTab")
                try await shot("inspektor-\(tab.rawValue)", NSSize(width: 310, height: 860), InspectorView(model: model))
            }
            UserDefaults.standard.set(InspectorView.Tab.style.rawValue, forKey: "inspectorTab")
            model.markIn = min(1, model.duration * 0.25); model.markOut = min(3, model.duration * 0.75)
            try await shot("export", NSSize(width: 560, height: 720), ExportSheet(model: model))
            try await shot("export-flera", NSSize(width: 560, height: 760), ExportSheet(model: model, extra: ["mp4-4k", "ljud-m4a"]))
            try await shot("redigerare-markerat", NSSize(width: 1400, height: 860), EditorView(model: model))
            print(#"{"mapp":"\#(out.path)"}"#)
            return 0
        } catch {
            print("{\"fel\":\"\(error.localizedDescription)\"}")
            return 1
        }
    }

    /// Pennans fönster utan att visa det: syntetiska mushändelser (en båge och ett kort streck),
    /// strecken som lämnas vidare, livebilden som PNG och att strecken tonas bort.
    static func inkTest(out: URL) async -> Int32 {
        guard let screen = NSScreen.main else { return 3 }
        let overlay = InkOverlay()
        overlay.hold = 0.3
        var clock = 10.0
        overlay.now = { clock }
        var strokes: [([(t: Double, p: CGPoint)], String)] = []
        overlay.onStroke = { strokes.append(($0, $1)) }
        let window = InkWindow(screen: screen, overlay: overlay)
        guard let view = window.contentView as? InkView else { return 1 }
        func send(_ type: NSEvent.EventType, _ p: NSPoint) {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: view.mouseDown(with: e)
            case .leftMouseUp: view.mouseUp(with: e)
            default: view.mouseDragged(with: e)
            }
        }
        let c = NSPoint(x: screen.frame.width * 0.4, y: screen.frame.height * 0.5)
        send(.leftMouseDown, NSPoint(x: c.x + 120, y: c.y))
        for i in 1...30 {
            clock += 0.02
            let a = Double(i) / 30 * .pi * 1.6
            send(.leftMouseDragged, NSPoint(x: c.x + 120 * cos(a), y: c.y + 80 * sin(a)))
        }
        send(.leftMouseUp, NSPoint(x: c.x + 120 * cos(.pi * 1.6), y: c.y + 80 * sin(.pi * 1.6)))
        overlay.select(colorAt: 1)
        send(.leftMouseDown, NSPoint(x: c.x + 200, y: c.y - 150)); clock += 0.1
        send(.leftMouseDragged, NSPoint(x: c.x + 320, y: c.y - 100)); clock += 0.1
        send(.leftMouseUp, NSPoint(x: c.x + 330, y: c.y - 95))
        // Livebilden: lagren ritade till en bild.
        let w = Int(screen.frame.width), h = Int(screen.frame.height)
        if let layer = view.layer, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(CGColor(gray: 0.15, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            layer.render(in: ctx)
            if let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
            }
        }
        let layersBefore = view.layer?.sublayers?.count ?? 0
        try? await Task.sleep(for: .seconds(0.3 + InkTrack.fade + 0.4))
        let layersAfter = view.layer?.sublayers?.count ?? 0
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let first = strokes.first?.0.first
        print("streck: \(strokes.count), punkter: \(strokes.map { $0.0.count }), färger: \(strokes.map(\.1))")
        print(String(format: "första punkten t=%.2f global (%.0f, %.0f), väntat (%.0f, %.0f)", first?.t ?? -1, first?.p.x ?? -1, first?.p.y ?? -1,
                     screen.frame.minX + c.x + 120, mainH - (screen.frame.minY + c.y)))
        print(String(format: "sista punkten t=%.2f", strokes.first?.0.last?.t ?? -1))
        print("lager före bortgång: \(layersBefore), efter: \(layersAfter)")
        window.close()
        return strokes.count == 2 && layersAfter == 0 ? 0 : 1
    }

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
            // --utsnitt a,b: bara utdatatiden a–b.
            let cut = value(after: "--utsnitt", in: CommandLine.arguments)?.split(separator: ",").compactMap { Double($0) }
            let exporter = Exporter(recording: rec, project: project, preset: preset,
                                    fps: value(after: "--fps", in: CommandLine.arguments).flatMap { Int($0) },
                                    range: cut.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil },
                                    loudnessTarget: value(after: "--ljudniva", in: CommandLine.arguments).flatMap { Double($0) },
                                    quality: value(after: "--kvalitet", in: CommandLine.arguments).flatMap(Exporter.Quality.init(rawValue:)) ?? .normal)
            try await exporter.run(to: out) { _ in }
            let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            if let l = exporter.loudnessReport {
                print(String(format: "{\"uppmatt_lufs\":%.2f,\"forstarkning_db\":%.2f,\"begransad\":%@}", l.measured, l.gainDB,
                             l.limitedByPeaks ? "true" : "false"))
            }
            print(String(format: "{\"fil\":\"%@\",\"sekunder\":%.2f,\"byte\":%d,\"langd\":%.3f}",
                         out.path, Date().timeIntervalSince(started), size,
                         exporter.range.map { $0.upperBound - $0.lowerBound } ?? TimeMap(segments: project.segments).outputDuration))
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
