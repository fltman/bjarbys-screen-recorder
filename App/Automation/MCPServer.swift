import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import RecorderKit

/// MCP-server över stdin/stdout (JSON-RPC 2.0, en rad per meddelande), så att agenter som
/// Claude Code kan spela in, transkribera, redigera och exportera:
///
///     claude mcp add skarminspelare -- "/Applications/Bjarbys skärminspelare.app/Contents/MacOS/Skarminspelare" --mcp
///
/// Allt görs i den här processen med RecorderKit; den vanliga appen behöver inte vara igång.
/// Startad av ett program i Terminal lånar processen Terminals behörighet för skärminspelning.
/// stdout är protokollet — loggning går till stderr.
@MainActor
enum MCPServer {
    static var isRequested: Bool { CommandLine.arguments.contains("--mcp") }
    static let protocolVersion = "2025-06-18"

    private static var active: CaptureSession?

    static func run() {
        let lines = AsyncStream<String> { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
            thread.start()
        }
        Task { @MainActor in
            for await line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                await handle(line)
            }
            // stdin stängd: klienten har gått.
            if let s = active { _ = await s.stop() }
            exit(0)
        }
    }

    // MARK: - Protokoll

    private static func handle(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = msg["method"] as? String else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        guard let id else { return } // notifieringar (t.ex. notifications/initialized) besvaras inte
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            reply(id, ["protocolVersion": requested ?? protocolVersion,
                       "capabilities": ["tools": [String: Any]()],
                       "serverInfo": ["name": "skarminspelare", "version": appVersion],
                       "instructions": instructions])
        case "ping":
            reply(id, [String: Any]())
        case "tools/list":
            reply(id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await call(name, args)
                reply(id, ["content": [["type": "text", "text": text]]])
            } catch {
                reply(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private static func reply(_ id: Any, _ result: Any) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(Data(("skarminspelare: " + s + "\n").utf8))
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static let instructions = """
    Bjarbys skärminspelare records the Mac screen as data (screen without cursor, separate audio tracks, \
    mouse and click events) and adds polish afterwards: auto-zoom on clicks, a smoothed cursor, background, \
    captions. Typical flow: record_screen (or start_recording/stop_recording) → optionally transcribe → \
    edit_recording → render_frames to check the result visually → export. Recordings are referred to by \
    path, by name, or as "latest". All times are seconds on the recording's own timeline.
    """

    // MARK: - Verktyg

    private static func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }
    private static let recordingArg: [String: Any] = ["type": "string", "description": "Path to a .bsrec bundle, its name, or \"latest\"."]

    private static var tools: [[String: Any]] {
        [
            ["name": "list_recordings", "description": "List recordings in the library, newest first.",
             "inputSchema": schema([:])],
            ["name": "record_screen",
             "description": "Record the main display for a number of seconds and return the new recording. Blocks until done.",
             "inputSchema": schema(["seconds": ["type": "number", "minimum": 1, "maximum": 900],
                                    "microphone": ["type": "boolean", "description": "Record the default microphone (default false)."],
                                    "system_audio": ["type": "boolean", "description": "Record computer audio (default true)."],
                                    "keystrokes": ["type": "boolean", "description": "Record keyboard shortcuts (needs Input Monitoring)."]],
                                   required: ["seconds"])],
            ["name": "start_recording", "description": "Start recording the main display. Stop with stop_recording.",
             "inputSchema": schema(["microphone": ["type": "boolean"], "system_audio": ["type": "boolean"], "keystrokes": ["type": "boolean"]])],
            ["name": "stop_recording", "description": "Stop the recording started with start_recording.",
             "inputSchema": schema([:])],
            ["name": "transcribe",
             "description": "Transcribe speech locally with whisper.cpp (KB-Whisper for Swedish). Saves transcript.json and returns the text with timestamps.",
             "inputSchema": schema(["recording": recordingArg,
                                    "language": ["type": "string", "description": "sv (default), en, … or auto"],
                                    "model": ["type": "string", "description": "Model file in whisper.cpp/models, optional."]],
                                   required: ["recording"])],
            ["name": "edit_recording",
             "description": "Change how a recording is presented. Only the given options change; the recording itself is never altered.",
             "inputSchema": schema([
                "recording": recordingArg,
                "aspect": ["type": "string", "enum": ["source", "wide", "vertical", "square", "classic"]],
                "framing": ["type": "string", "enum": ["fit", "fill"], "description": "fill = fill the frame and follow the cursor (Reel)."],
                "background_preset": ["type": "integer", "minimum": 0, "maximum": 7],
                "padding": ["type": "number", "minimum": 0, "maximum": 0.25],
                "auto_zoom": ["type": "boolean", "description": "Suggest zooms from clicks (regenerates suggestions)."],
                "zoom_scale": ["type": "number", "minimum": 1.25, "maximum": 4],
                "cursor_scale": ["type": "number", "minimum": 0.8, "maximum": 3],
                "captions": ["type": "boolean", "description": "Burn in captions (needs a transcript)."],
                "shortcuts": ["type": "boolean", "description": "Show recorded keyboard shortcuts."],
                "cut": ["type": "array", "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                        "description": "Ranges [start, end] in seconds to cut out."],
                "restore": ["type": "array", "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                            "description": "Previously cut ranges to bring back."],
                "remove_dead_time": ["type": "number", "description": "Cut stretches longer than this many seconds with no speech and no input."],
                "voice_isolation": ["type": "boolean", "description": "Remove background noise from the microphone."],
                "normalize_loudness": ["type": "boolean", "description": "Set the microphone level to -16 LUFS."],
                "duck_system_audio": ["type": "boolean"],
                "hide_sensitive": ["type": "boolean", "description": "Find e-mails, phone numbers, ID numbers, cards and keys on screen and blur them."],
             ], required: ["recording"])],
            ["name": "render_frames",
             "description": "Render finished frames (with all polish) as PNG files at output times, so you can look at them.",
             "inputSchema": schema(["recording": recordingArg,
                                    "times": ["type": "array", "items": ["type": "number"], "description": "Output times in seconds."],
                                    "directory": ["type": "string", "description": "Where to write the PNGs (default: a temporary folder)."]],
                                   required: ["recording", "times"])],
            ["name": "screenshot",
             "description": "Take a polished screenshot (on a background, with padding, rounded corners and shadow) of an app's window, the main display or an area. Returns the PNG path. Good for README images.",
             "inputSchema": schema(["app": ["type": "string", "description": "App name (e.g. \"Safari\"); its largest on-screen window is taken."],
                                    "window_title": ["type": "string", "description": "Part of the window title, to pick among the app's windows."],
                                    "area": ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4,
                                             "description": "[x, y, width, height] in points on the main display (top-left origin)."],
                                    "polish": ["type": "boolean", "description": "Background, padding and shadow (default true)."],
                                    "background_preset": ["type": "integer", "minimum": 0, "maximum": 7],
                                    "path": ["type": "string"]])],
            ["name": "make_guide",
             "description": "Make a step-by-step guide from the recording: one finished image per click or keyboard shortcut, with what was said as the text. Writes guide.md, guide.html (self-contained) and PNGs.",
             "inputSchema": schema(["recording": recordingArg,
                                    "title": ["type": "string"],
                                    "directory": ["type": "string", "description": "Output folder (default: ~/Movies/<name> – guide)."]],
                                   required: ["recording"])],
            ["name": "export",
             "description": "Export the edited recording. Returns the file path.",
             "inputSchema": schema(["recording": recordingArg,
                                    "preset": ["type": "string", "enum": ExportPreset.all.map(\.id)],
                                    "path": ["type": "string", "description": "Output file (default: ~/Movies/<name>.<ext>)."],
                                    "subtitles": ["type": "boolean", "description": "Also write an .srt next to the video (default true if transcribed)."]],
                                   required: ["recording"])],
        ]
    }

    struct ToolError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private static func call(_ name: String, _ a: [String: Any]) async throws -> String {
        switch name {
        case "list_recordings": return listRecordings()
        case "record_screen":
            let seconds = min(900, max(1, a["seconds"] as? Double ?? 5))
            let session = try await startSession(a)
            try await Task.sleep(for: .seconds(seconds))
            let meta = await session.stop()
            return describe(session.bundle, meta: meta)
        case "start_recording":
            guard active == nil else { throw ToolError("A recording is already running; stop it first.") }
            active = try await startSession(a)
            return "Recording started: \(active!.bundle.url.path)"
        case "stop_recording":
            guard let s = active else { throw ToolError("No recording is running.") }
            active = nil
            let meta = await s.stop()
            return describe(s.bundle, meta: meta)
        case "transcribe": return try await transcribe(a)
        case "edit_recording": return try await edit(a)
        case "render_frames": return try await renderFrames(a)
        case "export": return try await export(a)
        case "make_guide": return try await makeGuide(a)
        case "screenshot": return try await screenshot(a)
        default: throw ToolError("Unknown tool \(name)")
        }
    }

    // MARK: - Inspelning

    private static func startSession(_ a: [String: Any]) async throws -> CaptureSession {
        guard CGPreflightScreenCaptureAccess() else {
            throw ToolError("Screen recording permission is missing for the process that started this server (usually the terminal). Grant it in System Settings › Privacy & Security › Screen & System Audio Recording, then restart the client.")
        }
        var options = CaptureOptions()
        if a["microphone"] as? Bool == true {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            options.microphone = Devices.defaultMicrophone
        }
        options.systemAudio = a["system_audio"] as? Bool ?? true
        options.keystrokes = a["keystrokes"] as? Bool ?? false
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ToolError("No display found.")
        }
        let dir = RecordingLibrary.defaultDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = try CaptureSession(target: CaptureTarget.display(display, in: content), options: options, directory: dir)
        try await session.start()
        log("spelar in till \(session.bundle.url.path)")
        return session
    }

    private static func describe(_ bundle: RecordingBundle, meta: RecordingMeta) -> String {
        let tracks = meta.tracks.filter { !$0.failed }.map(\.kind.rawValue).joined(separator: ", ")
        return """
        Recording: \(bundle.url.path)
        Name: \(bundle.name)
        Duration: \(String(format: "%.1f", meta.duration)) s, \(meta.source.pixelWidth)×\(meta.source.pixelHeight)
        Tracks: \(tracks)\(meta.finished ? "" : " (not finished)")
        """
    }

    // MARK: - Bibliotek

    private static func listRecordings() -> String {
        let items = RecordingLibrary.scan()
        guard !items.isEmpty else { return "No recordings in \(RecordingLibrary.defaultDirectory.path)." }
        return items.map { item in
            let m = item.meta
            let d = m.map { String(format: "%.1f s", $0.duration) } ?? "?"
            let transcribed = FileManager.default.fileExists(atPath: item.bundle.transcriptURL.path) ? ", transcribed" : ""
            return "- \(item.bundle.name) (\(d)\(transcribed)): \(item.bundle.url.path)"
        }.joined(separator: "\n")
    }

    private static func resolve(_ a: [String: Any]) throws -> LoadedRecording {
        let ref = (a["recording"] as? String ?? "latest").trimmingCharacters(in: .whitespaces)
        let items = RecordingLibrary.scan()
        let bundle: RecordingBundle?
        if ref.lowercased() == "latest" || ref.lowercased() == "senaste" {
            bundle = items.first?.bundle
        } else if FileManager.default.fileExists(atPath: NSString(string: ref).expandingTildeInPath) {
            bundle = RecordingBundle(url: URL(fileURLWithPath: NSString(string: ref).expandingTildeInPath))
        } else {
            bundle = items.first { $0.bundle.name == ref }?.bundle
                ?? items.first { $0.bundle.name.localizedCaseInsensitiveContains(ref) }?.bundle
        }
        guard let bundle else { throw ToolError("No recording matches \"\(ref)\". Use list_recordings.") }
        return try LoadedRecording.load(bundle)
    }

    // MARK: - Tal

    private static func transcribe(_ a: [String: Any]) async throws -> String {
        let rec = try resolve(a)
        let language = a["language"] as? String ?? UserDefaults.standard.string(forKey: "speechLanguage") ?? "sv"
        let configured = UserDefaults.standard.string(forKey: "whisperRoot") ?? ""
        guard let root = configured.isEmpty ? WhisperSetup.findRoot() : URL(fileURLWithPath: configured) else {
            throw ToolError("whisper.cpp not found. Build it in ~/Projekt/whisper.cpp or ~/whisper.cpp, or choose its folder in the app.")
        }
        var setup = WhisperSetup(root: root, model: a["model"] as? String ?? "", language: language)
        if setup.model.isEmpty { setup.model = WhisperSetup.preferredModel(among: setup.availableModels, language: language) ?? "" }
        let t = try await Transcriber.run(rec, setup: setup)
        try rec.bundle.saveTranscript(t)
        guard !t.words.isEmpty else { return "No speech found (model \(setup.model))." }
        // Meningarna med tid.
        var lines: [String] = []
        var current = "", start = t.words[0].start
        for w in t.words {
            if w.startsSegment && !current.isEmpty {
                lines.append(String(format: "[%.1f] ", start) + current)
                current = ""; start = w.start
            }
            current += (current.isEmpty ? "" : " ") + w.text
        }
        if !current.isEmpty { lines.append(String(format: "[%.1f] ", start) + current) }
        return "Model: \(setup.model), \(t.words.count) words.\n" + lines.joined(separator: "\n")
    }

    // MARK: - Redigering

    private static func ranges(_ v: Any?) -> [ClosedRange<Double>] {
        (v as? [[Double]] ?? (v as? [[NSNumber]])?.map { $0.map(\.doubleValue) } ?? [])
            .compactMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]...$0[1] : nil }
    }

    private static func edit(_ a: [String: Any]) async throws -> String {
        var rec = try resolve(a)
        var p = rec.bundle.loadProject(duration: rec.meta.duration)
        var notes: [String] = []
        if let s = a["aspect"] as? String { p.aspect = EditProject.Aspect(rawValue: s) ?? p.aspect }
        if let s = a["framing"] as? String { p.framing = EditProject.Framing(rawValue: s) ?? p.framing }
        if let i = a["background_preset"] as? Int, EditProject.Background.presets.indices.contains(i) {
            p.background = EditProject.Background.presets[i]
        }
        if let v = a["padding"] as? Double { p.padding = min(0.25, max(0, v)) }
        if let v = a["cursor_scale"] as? Double { p.cursor.scale = min(3, max(0.8, v)) }
        if let v = a["captions"] as? Bool {
            p.captions.visible = v
            if v && rec.transcript == nil { notes.append("Captions need a transcript: run transcribe first.") }
        }
        if let v = a["shortcuts"] as? Bool { p.shortcuts.visible = v }
        if let v = a["duck_system_audio"] as? Bool { p.audio.duckSystem = v }
        if let v = a["zoom_scale"] as? Double { p.zoomScale = min(4, max(1.25, v)) }
        if let v = a["auto_zoom"] as? Bool {
            p.autoZoom = v
            let manual = p.zooms.filter { !$0.isAuto }
            p.zooms = (manual + (v ? AutoZoom.generate(events: rec.events, mapping: rec.mapping,
                                                      duration: rec.meta.duration, scale: p.zoomScale) : []))
                .sorted { $0.start < $1.start }
        }
        for r in ranges(a["cut"]) { p.cut(r) }
        for r in ranges(a["restore"]) { p.restore(r) }
        if let minimum = a["remove_dead_time"] as? Double {
            if rec.hasMicrophone && rec.transcript == nil {
                notes.append("Dead time not removed: the recording has a microphone but no transcript, so pauses in speech would count as dead. Run transcribe first.")
            } else {
                let dead = DeadTime.find(events: rec.events, speech: rec.transcript?.speech() ?? [],
                                         duration: rec.meta.duration, minimum: max(0.5, minimum))
                for r in dead { p.cut(r) }
                notes.append("Removed \(dead.count) dead stretches (\(String(format: "%.1f", dead.map { $0.upperBound - $0.lowerBound }.reduce(0, +))) s).")
            }
        }
        if let v = a["voice_isolation"] as? Bool {
            if v, rec.isolatedMicrophone == nil, let mic = rec.asset(.microphone) {
                _ = try await VoiceIsolation.process(mic, to: rec.bundle.isolatedMicrophoneURL)
                rec.isolatedMicrophone = AVURLAsset(url: rec.bundle.isolatedMicrophoneURL)
            }
            p.audio.voiceIsolation = v && rec.isolatedMicrophone != nil
        }
        if a["normalize_loudness"] as? Bool == true {
            let source = p.audio.voiceIsolation ? rec.isolatedMicrophone : rec.asset(.microphone)
            if let source, let m = try await Loudness.measure(source) {
                let (gain, limited) = Loudness.gain(for: m)
                p.audio.microphoneVolume = gain
                p.audio.microphoneMuted = false
                notes.append(String(format: "Microphone was %.1f LUFS; gain %+.1f dB%@.", m.integrated, 20 * log10(gain),
                                    limited ? " (limited by peaks)" : ""))
            } else {
                notes.append("No microphone audio to level.")
            }
        }
        if a["hide_sensitive"] as? Bool == true {
            let found = try await MaskScanner.scan(rec, kinds: Set(SensitiveText.Kind.allCases.filter { $0 != .manual }))
            p.masks = p.masks.filter { $0.kind == .manual } + found
            notes.append("Hiding \(found.count) sensitive areas: " +
                         Dictionary(grouping: found, by: \.kind).map { "\($0.value.count) \($0.key.rawValue)" }.joined(separator: ", ") + ".")
        } else if a["hide_sensitive"] as? Bool == false {
            p.masks = p.masks.filter { $0.kind == .manual }
        }
        try rec.bundle.saveProject(p)
        let map = TimeMap(segments: p.segments)
        return ([String(format: "Saved. Output %.1f s (of %.1f s recorded), %d parts, %d zooms, %d masks, aspect %@%@, captions %@.",
                        map.outputDuration, rec.meta.duration, p.segments.count, p.zooms.count, p.masks.count,
                        p.aspect.rawValue, p.framing == .fill ? " (fill)" : "",
                        p.captions.visible && rec.transcript != nil ? "on" : "off")] + notes).joined(separator: "\n")
    }

    // MARK: - Bilder och export

    private static func renderFrames(_ a: [String: Any]) async throws -> String {
        let rec = try resolve(a)
        let times = (a["times"] as? [Double]) ?? ((a["times"] as? [NSNumber])?.map(\.doubleValue) ?? [])
        guard !times.isEmpty else { throw ToolError("Give at least one time.") }
        let dir = (a["directory"] as? String).map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("skarminspelare-rutor-\(UUID().uuidString.prefix(8))")
        let project = rec.bundle.loadProject(duration: rec.meta.duration)
        let (images, plan) = try await FrameGrabber.frames(rec, project: project, outputTimes: times)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [String] = []
        for (t, image) in zip(times, images) {
            let file = dir.appendingPathComponent(String(format: "frame-%07.2f.png", t))
            try FrameGrabber.writePNG(image, to: file)
            out.append(file.path)
        }
        return "Rendered \(out.count) frames (\(Int(plan.canvas.width))×\(Int(plan.canvas.height)), output length \(String(format: "%.1f", plan.outputDuration)) s):\n" + out.joined(separator: "\n")
    }

    private static func screenshot(_ a: [String: Any]) async throws -> String {
        guard CGPreflightScreenCaptureAccess() else {
            throw ToolError("Screen recording permission is missing for the process that started this server.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        var image: CGImage
        var isWindow = false
        var name = "Skärmen"
        if let app = a["app"] as? String {
            let title = (a["window_title"] as? String)?.lowercased()
            let windows = content.windows.filter { w in
                guard let owner = w.owningApplication, w.isOnScreen, w.windowLayer == 0, w.frame.width > 50 else { return false }
                let match = owner.applicationName.localizedCaseInsensitiveContains(app)
                    || owner.bundleIdentifier.localizedCaseInsensitiveContains(app)
                return match && (title.map { (w.title ?? "").lowercased().contains($0) } ?? true)
            }
            guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                let names = Set(content.windows.compactMap { $0.isOnScreen && $0.windowLayer == 0 ? $0.owningApplication?.applicationName : nil })
                throw ToolError("No on-screen window for \"\(app)\". Apps with windows: \(names.sorted().joined(separator: ", "))")
            }
            image = try await Screenshot.capture(window: window)
            isWindow = true
            name = window.owningApplication?.applicationName ?? app
        } else {
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw ToolError("No display found.")
            }
            let area = (a["area"] as? [Double]) ?? (a["area"] as? [NSNumber])?.map(\.doubleValue)
            let rect = area.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
            image = try await Screenshot.capture(display: display, area: rect, excluding: own)
            if rect != nil { name = "Område" }
        }
        if a["polish"] as? Bool ?? true {
            var style = Screenshot.Style()
            if let i = a["background_preset"] as? Int, EditProject.Background.presets.indices.contains(i) {
                style.background = EditProject.Background.presets[i]
            }
            guard let polished = Screenshot.polish(image, style: style, isWindow: isWindow) else { throw ToolError("Polishing failed.") }
            image = polished
        }
        let url = (a["path"] as? String).map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? Screenshot.newURL(name: name)
        try Screenshot.writePNG(image, to: url)
        return "Screenshot (\(image.width)×\(image.height)): \(url.path)"
    }

    private static func makeGuide(_ a: [String: Any]) async throws -> String {
        let rec = try resolve(a)
        let project = rec.bundle.loadProject(duration: rec.meta.duration)
        let title = a["title"] as? String ?? rec.bundle.name
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let dir = (a["directory"] as? String).map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? movies.appendingPathComponent("\(rec.bundle.name) – guide", isDirectory: true)
        let out = try await GuideMaker.make(rec, project: project, title: title, in: dir)
        guard out.steps > 0 else { return "No clicks or keyboard shortcuts in the kept parts; the guide is empty.\n\(out.html.path)" }
        return "Guide with \(out.steps) steps:\n\(out.markdown.path)\n\(out.html.path)"
            + (rec.transcript == nil ? "\nTip: transcribe first, and the steps get what was said as text." : "")
    }

    private static func export(_ a: [String: Any]) async throws -> String {
        let rec = try resolve(a)
        let presetID = a["preset"] as? String ?? "mp4-1080"
        guard let preset = ExportPreset.all.first(where: { $0.id == presetID }) else { throw ToolError("Unknown preset \(presetID).") }
        let project = rec.bundle.loadProject(duration: rec.meta.duration)
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let url = (a["path"] as? String).map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? movies.appendingPathComponent(rec.bundle.name).appendingPathExtension(preset.fileExtension)
        let started = Date()
        try await Exporter(recording: rec, project: project, preset: preset).run(to: url) { _ in }
        var text = String(format: "Exported %@ in %.1f s: %@", preset.name, Date().timeIntervalSince(started), url.path)
        if a["subtitles"] as? Bool ?? true, preset.id != "gif", let words = rec.transcript?.words, !words.isEmpty {
            let srt = url.deletingPathExtension().appendingPathExtension("srt")
            try Captions(words: words, timeMap: TimeMap(segments: project.segments)).srt.write(to: srt, atomically: true, encoding: .utf8)
            text += "\nSubtitles: \(srt.path)"
        }
        return text
    }
}
