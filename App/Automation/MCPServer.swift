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
                       "capabilities": ["tools": [String: Any](), "prompts": [String: Any]()],
                       "serverInfo": ["name": "skarminspelare", "version": appVersion],
                       "instructions": instructions])
        case "ping":
            reply(id, [String: Any]())
        case "tools/list":
            reply(id, ["tools": tools])
        case "prompts/list":
            reply(id, ["prompts": [["name": "producera",
                                    "description": "Produce a screen recording like a producer: cut, zoom, chapters, overlays, captions, optional narration, checked frame by frame, with a delivery note.",
                                    "arguments": [["name": "recording", "description": "Path, name or \"latest\"", "required": false]]]]])
        case "prompts/get":
            let ref = (params["arguments"] as? [String: Any])?["recording"] as? String ?? "latest"
            reply(id, ["description": "Producera en skärminspelning",
                       "messages": [["role": "user", "content": ["type": "text", "text": producerPrompt(ref)]]]])
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
    private static let appsArg: [String: Any] = [
        "type": "array", "items": ["type": "string"],
        "description": "Bundle ids of apps to record on their own audio tracks (see list_audio_apps). system_audio then means everything else.",
    ]

    private static var tools: [[String: Any]] {
        [
            ["name": "list_recordings", "description": "List recordings in the library, newest first.",
             "inputSchema": schema([:])],
            ["name": "record_screen",
             "description": "Record the main display for a number of seconds and return the new recording. Blocks until done.",
             "inputSchema": schema(["seconds": ["type": "number", "minimum": 1, "maximum": 900],
                                    "microphone": ["type": "boolean", "description": "Record the default microphone (default false)."],
                                    "system_audio": ["type": "boolean", "description": "Record computer audio (default true)."],
                                    "keystrokes": ["type": "boolean", "description": "Record keyboard shortcuts and when/where text is typed (never what) — typing suggests zooms on the caret (needs Input Monitoring; Accessibility for where)."],
                                    "apps": appsArg,
                                    "hdr": ["type": "boolean", "description": "Record in HDR (10-bit BT.2020 PQ; export with preset mp4-4k-hdr for HLG)."],
                                    "hide_desktop_icons": ["type": "boolean", "description": "Keep desktop icons out of the recording."],
                                    "hide_notifications": ["type": "boolean", "description": "Keep notifications and desktop widgets out of the recording."]],
                                   required: ["seconds"])],
            ["name": "start_recording", "description": "Start recording the main display. Stop with stop_recording.",
             "inputSchema": schema(["microphone": ["type": "boolean"], "system_audio": ["type": "boolean"], "keystrokes": ["type": "boolean"],
                                    "apps": appsArg, "hdr": ["type": "boolean"]])],
            ["name": "list_audio_apps", "description": "Apps connected to the audio system right now (bundle id, name, whether they are playing). Use the bundle ids in `apps` to record each app on its own track.",
             "inputSchema": schema([:])],
            ["name": "stop_recording", "description": "Stop the recording started with start_recording.",
             "inputSchema": schema([:])],
            ["name": "merge_recordings",
             "description": "Join takes into one new recording, one after the other in the given order (no re-encoding). Events, cursors and transcripts follow. The originals are not changed. All must have the same resolution and the same HDR/SDR.",
             "inputSchema": schema(["recordings": ["type": "array", "items": recordingArg, "minItems": 2]],
                                   required: ["recordings"])],
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
                "caption_highlight": ["type": "boolean", "description": "Highlight the word being said in the burned-in captions."],
                "caption_position": ["type": "string", "enum": ["bottom", "middle", "top"], "description": "Where captions sit (middle suits vertical Reels)."],
                "caption_style": ["type": "string", "enum": ["box", "outline"], "description": "White text on a dark box, or bold text with a black outline and no box."],
                "shortcuts": ["type": "boolean", "description": "Show recorded keyboard shortcuts."],
                "cut": ["type": "array", "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                        "description": "Ranges [start, end] in seconds to cut out."],
                "restore": ["type": "array", "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                            "description": "Previously cut ranges to bring back."],
                "remove_dead_time": ["type": "number", "description": "Cut stretches longer than this many seconds with no speech and no input."],
                "speed_up_dead_time": ["type": "number", "description": "Like remove_dead_time, but play those stretches at 4× instead of cutting them."],
                "voice_isolation": ["type": "boolean", "description": "Remove background noise from the microphone."],
                "normalize_loudness": ["type": "boolean", "description": "Set the microphone level to -16 LUFS."],
                "duck_system_audio": ["type": "boolean"],
                "hide_sensitive": ["type": "boolean", "description": "Find e-mails, phone numbers, ID numbers, cards and keys on screen and blur them."],
                "transition": ["type": "string", "enum": ["none", "dip", "blur", "flash", "crossfade"], "description": "Standard transition at every cut between parts (set_transition overrides one cut)."],
                "transition_duration": ["type": "number"],
                "fade_in_out": ["type": "boolean", "description": "Fade in from black at the start and out at the end."],
                "motion_blur": ["type": "boolean", "description": "Motion blur while the camera zooms and pans."],
                "window_frame": ["type": "string", "enum": ["none", "mac", "browser"], "description": "A drawn title bar above the recording: a macOS window or a browser with an address field."],
                "window_frame_dark": ["type": "boolean", "description": "Dark title bar."],
                "window_title": ["type": "string", "description": "Title in the macOS window frame."],
                "window_address": ["type": "string", "description": "Address in the browser frame's address field."],
                "camera_follow_face": ["type": "boolean", "description": "Keep the face centred in the camera bubble (faces are found once with Vision and saved in the bundle)."],
                "cursor_highlight": ["type": "boolean", "description": "A soft coloured halo under the cursor so it is easy to follow."],
                "cursor_highlight_color": ["type": "string", "description": "Halo colour as #RRGGBB (default #FFD60A, yellow)."],
                "ink": ["type": "boolean", "description": "Show what was drawn on screen with the pen during the recording (default true)."],
                "ink_hold": ["type": "number", "minimum": 0.5, "maximum": 15, "description": "Seconds a finished pen stroke stays before it fades (default 3)."],
                "click_sound": ["type": "boolean", "description": "A short soft click sound at every mouse click."],
                "camera_backdrop": ["type": "string", "enum": ["original", "blur", "remove"],
                                    "description": "Behind the person in the camera bubble: as recorded, blurred, or replaced by the film's background."],
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
            ["name": "get_overview",
             "description": "Everything a producer needs about a recording, in source time: current decisions, what is said, every click with the element's name and frame, shortcuts, dead time.",
             "inputSchema": schema(["recording": recordingArg], required: ["recording"])],
            ["name": "set_overlays",
             "description": "Set the overlay layer (replaces all overlays unless append is true). Kinds: title (centered card; lines[0] = subtitle), callout (outline around a UI element with a label; give target [x,y,w,h] 0–1, or target_click_at = time of a click to use that element's frame), fact (box with title + up to 3 lines, in a corner), qr (QR code card with title, url, lines[0] = label, in a corner). at = SOURCE seconds, duration = seconds on screen.",
             "inputSchema": schema(["recording": recordingArg,
                                    "append": ["type": "boolean"],
                                    "overlays": ["type": "array", "items": ["type": "object", "properties": [
                                        "kind": ["type": "string", "enum": ["title", "callout", "fact", "qr", "text", "image", "video"]],
                                        "offset": ["type": "number", "description": "video: where in the file to start (s)."],
                                        "volume": ["type": "number", "description": "video: its audio volume (0 = silent)."],
                                        "speed": ["type": "number", "description": "video: playback speed 0.25–4 (duration stays the time in the film)."],
                                        "crop": ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4,
                                                 "description": "video: the part of the video to show, [x, y, width, height] 0–1 of the video, origin top-left."],
                                        "softness": ["type": "number", "description": "video: soft edges 0–1 (0 = sharp with rounded corners and a shadow)."],
                                        "animation": ["type": "string", "enum": ["fade", "slide", "pop", "typewriter"],
                                                      "description": "How the layer comes in (typewriter: text and title only). Default fade."],
                                        "frame": ["type": "array", "items": ["type": "number"], "minItems": 3, "maxItems": 4,
                                                  "description": "text: [centerX, centerY, maxWidth]; image: [x, y, width, height] — 0–1 of the frame, origin top-left."],
                                        "file": ["type": "string", "description": "image: path to the image (copied into the bundle)."],
                                        "size": ["type": "number", "description": "text: size relative to default (1)."],
                                        "background": ["type": "boolean", "description": "text: on a dark plate (default true)."],
                                        "at": ["type": "number"], "duration": ["type": "number"],
                                        "title": ["type": "string"], "lines": ["type": "array", "items": ["type": "string"]],
                                        "url": ["type": "string"],
                                        "target": ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4],
                                        "target_click_at": ["type": "number"],
                                        "corner": ["type": "string", "enum": ["topLeft", "topRight", "bottomLeft", "bottomRight"]]],
                                        "required": ["kind", "at"]]]],
                                   required: ["recording", "overlays"])],
            ["name": "set_chapters",
             "description": "Set the chapters (replaces all). Each {at: SOURCE seconds, title}. A short chapter banner shows in the video; YouTube timestamps are returned.",
             "inputSchema": schema(["recording": recordingArg,
                                    "chapters": ["type": "array", "items": ["type": "object", "properties": [
                                        "at": ["type": "number"], "title": ["type": "string"]], "required": ["at", "title"]]],
                                    "banner": ["type": "boolean", "description": "Show the chapter banner in the video (default true)."]],
                                   required: ["recording", "chapters"])],
            ["name": "set_segments",
             "description": "Set the parts of the recording to keep, in output order (an edit decision list): [[start, end, speed?, camera?], …] in SOURCE seconds; camera is the camera layout for that part: \"bubble\", \"large\" (camera fills the frame, e.g. an intro), \"split\" (side by side with the screen) or \"hidden\". Cut at pauses between words, not inside them.",
             "inputSchema": schema(["recording": recordingArg,
                                    "keep": ["type": "array", "items": ["type": "array", "minItems": 2, "maxItems": 4]]],
                                   required: ["recording", "keep"])],
            ["name": "add_audio",
             "description": "Add an audio file to the recording: narration (made with the elevenlabs-dialogue skill — never raw TTS; confirm voice and language with the user first, it costs money), music (ducked under speech and narration) or effect. The file is copied into the bundle.",
             "inputSchema": schema(["recording": recordingArg,
                                    "file": ["type": "string"], "role": ["type": "string", "enum": ["narration", "music", "effect"]],
                                    "at": ["type": "number", "description": "SOURCE seconds."],
                                    "text": ["type": "string", "description": "What the narration says (for the say == show check)."],
                                    "volume": ["type": "number"], "fade_in": ["type": "number"], "fade_out": ["type": "number"],
                                    "replace": ["type": "boolean", "description": "Remove all existing clips of this role first."]],
                                   required: ["recording", "file", "role", "at"])],
            ["name": "set_transition",
             "description": "Set the transition into one part (cut number 1 = between the first and second part), or \"standard\" to use the project's. Kinds: none, dip (through black), blur, flash, crossfade (the parts blend; uses material just past the cut, the video length does not change).",
             "inputSchema": schema(["recording": recordingArg,
                                    "cut": ["type": "integer", "minimum": 1],
                                    "kind": ["type": "string", "enum": ["standard", "none", "dip", "blur", "flash", "crossfade"]],
                                    "duration": ["type": "number"]],
                                   required: ["recording", "cut", "kind"])],
            ["name": "preflight",
             "description": "Check the decisions against the rules. Errors block delivery; warnings must be justified in the delivery note.",
             "inputSchema": schema(["recording": recordingArg], required: ["recording"])],
            ["name": "save_delivery_note",
             "description": "Save the producer's letter to the human (leverans.md in the bundle, shown in the editor): what you chose and why, what you cut, 2–3 things for them to decide, next steps.",
             "inputSchema": schema(["recording": recordingArg, "markdown": ["type": "string"]], required: ["recording", "markdown"])],
            ["name": "make_bug_report",
             "description": "Make a bug report from a recording: rapport.md (what was said, environment, steps to reproduce), the video, a step-by-step guide with images and the app's system log for the recording's time. Returns the folder and a zip.",
             "inputSchema": schema(["recording": recordingArg,
                                    "title": ["type": "string"],
                                    "app": ["type": "string", "description": "The app the bug is in (for its version and log)."],
                                    "directory": ["type": "string"]],
                                   required: ["recording"])],
            ["name": "make_guide",
             "description": "Make a step-by-step guide from the recording: one finished image per click or keyboard shortcut, with what was said as the text. Writes guide.md, guide.html (self-contained) and PNGs.",
             "inputSchema": schema(["recording": recordingArg,
                                    "title": ["type": "string"],
                                    "directory": ["type": "string", "description": "Output folder (default: ~/Movies/<name> – guide)."]],
                                   required: ["recording"])],
            ["name": "export",
             "description": "Export the edited recording. Returns the file path. Audio only: ljud-m4a, ljud-wav (the mix), ljud-spar (a folder with one WAV per source — microphone, computer audio, each app, narration, music, effects — the same length as the film; they sum to the mix).",
             "inputSchema": schema(["recording": recordingArg,
                                    "preset": ["type": "string", "enum": ExportPreset.all.map(\.id)],
                                    "path": ["type": "string", "description": "Output file (default: ~/Movies/<name>.<ext>)."],
                                    "subtitles": ["type": "boolean", "description": "Also write an .srt next to the video (default true if transcribed)."],
                                    "fps": ["type": "integer", "description": "Frame rate of the file (default: the preset's, 60; use 120 for a 120 fps recording)."],
                                    "upload": ["type": "boolean", "description": "Upload to the S3/R2 bucket set up under Sharing in the app and return the public link."],
                                    "loudness": ["type": "number", "description": "Even out the whole film's audio to this loudness in LUFS (e.g. -14 for YouTube, -16 for podcasts), peaks kept under -1 dBFS."],
                                    "range": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2,
                                              "description": "Only this excerpt, [start, end] in OUTPUT seconds (the edited film's time), e.g. a short social clip."]],
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
        case "list_audio_apps":
            let apps = AudioProcesses.apps()
            guard !apps.isEmpty else { return "No apps are connected to the audio system right now." }
            return apps.map { "- \($0.name) (\($0.bundleID))\($0.isPlaying ? ", playing" : "")" }.joined(separator: "\n")
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
        case "merge_recordings":
            let refs = a["recordings"] as? [String] ?? []
            guard refs.count >= 2 else { throw ToolError("Give at least two recordings.") }
            let bundles = try refs.map { try resolve(["recording": $0]).bundle }
            guard Set(bundles.map(\.url)).count == bundles.count else { throw ToolError("The same recording is given twice.") }
            let merged = try await RecordingMerger.merge(bundles, into: RecordingLibrary.defaultDirectory)
            return describe(merged, meta: try merged.readMeta())
        case "transcribe": return try await transcribe(a)
        case "edit_recording": return try await edit(a)
        case "render_frames": return try await renderFrames(a)
        case "export": return try await export(a)
        case "make_guide": return try await makeGuide(a)
        case "get_overview":
            let rec = try resolve(a)
            return Producer.overview(rec, project: rec.bundle.loadProject(duration: rec.meta.duration))
        case "set_overlays": return try setOverlays(a)
        case "set_chapters": return try setChapters(a)
        case "set_segments": return try setSegments(a)
        case "set_transition":
            let rec = try resolve(a)
            var p = rec.bundle.loadProject(duration: rec.meta.duration)
            let cut = (a["cut"] as? Int) ?? 0
            guard cut >= 1, cut < p.segments.count else { throw ToolError("cut must be 1…\(max(1, p.segments.count - 1)) (there are \(p.segments.count) parts).") }
            let kind = a["kind"] as? String ?? "standard"
            if kind == "standard" { p.segments[cut].transitionIn = nil }
            else if let k = EditProject.Transition.Kind(rawValue: kind) {
                p.segments[cut].transitionIn = .init(kind: k, duration: min(2, max(0.2, number(a["duration"]) ?? p.transition.duration)))
            }
            try rec.bundle.saveProject(p)
            let cuts = CutPlan(segments: p.segments, timeMap: TimeMap(segments: p.segments), standard: p.transition).cuts
            return "Saved. Cuts with transitions: " + (cuts.isEmpty ? "none" : cuts.map { "\($0.transition.kind.rawValue) \(Producer.fmt($0.transition.duration)) s at \(Producer.fmt($0.output)) s" }.joined(separator: "; "))
        case "add_audio": return try await addAudio(a)
        case "preflight":
            let rec = try resolve(a)
            let project = rec.bundle.loadProject(duration: rec.meta.duration)
            let canvas = RenderPlan.canvasSize(aspect: project.aspect, source: rec.sourceSize, shortSide: 1080)
            let plan = rec.makePlan(project: project, canvas: canvas)
            return Producer.report(Producer.preflight(project: project, words: rec.transcript?.words ?? [],
                                                      duration: rec.meta.duration) { name in
                FileManager.default.fileExists(atPath: rec.bundle.mediaDir.appendingPathComponent(name).path)
            } + Producer.coverage(plan: plan, events: rec.events, mapping: rec.mapping))
        case "save_delivery_note":
            let rec = try resolve(a)
            guard let md = a["markdown"] as? String, !md.isEmpty else { throw ToolError("markdown is empty.") }
            try md.write(to: rec.bundle.deliveryNoteURL, atomically: true, encoding: .utf8)
            return "Saved: \(rec.bundle.deliveryNoteURL.path)"
        case "screenshot": return try await screenshot(a)
        case "make_bug_report":
            let rec = try resolve(a)
            let project = rec.bundle.loadProject(duration: rec.meta.duration)
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            let dir = (a["directory"] as? String).map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
                ?? movies.appendingPathComponent("Felrapport – \(rec.bundle.name)", isDirectory: true)
            let out = try await BugReport.make(rec, project: project, title: a["title"] as? String ?? rec.bundle.name,
                                               app: a["app"] as? String, in: dir)
            return "Bug report: \(out.report.path)\nFolder: \(out.folder.path)" + (out.zip.map { "\nZip: \($0.path)" } ?? "")
                + "\n\n" + ((try? String(contentsOf: out.report, encoding: .utf8)) ?? "")
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
        options.hdr = a["hdr"] as? Bool ?? false
        options.hideDesktopIcons = a["hide_desktop_icons"] as? Bool ?? false
        options.hideNotifications = a["hide_notifications"] as? Bool ?? false
        let running = AudioProcesses.apps()
        options.apps = (a["apps"] as? [String] ?? []).map { id in
            AudioSourceChoice(bundleID: id, name: running.first { $0.bundleID == id }?.name ?? id)
        }
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
        if let v = a["caption_highlight"] as? Bool { p.captions.highlightWord = v }
        if let v = (a["caption_position"] as? String).flatMap(EditProject.CaptionStyle.Position.init(rawValue:)) { p.captions.position = v }
        if let v = (a["caption_style"] as? String).flatMap(EditProject.CaptionStyle.Look.init(rawValue:)) { p.captions.look = v }
        if let v = a["captions"] as? Bool {
            p.captions.visible = v
            if v && rec.transcript == nil { notes.append("Captions need a transcript: run transcribe first.") }
        }
        if let v = a["shortcuts"] as? Bool { p.shortcuts.visible = v }
        if let v = a["duck_system_audio"] as? Bool { p.audio.duckSystem = v }
        if let v = a["transition"] as? String, let k = EditProject.Transition.Kind(rawValue: v) { p.transition.kind = k }
        if let v = a["transition_duration"] as? Double { p.transition.duration = min(1.5, max(0.2, v)) }
        if let v = a["fade_in_out"] as? Bool { p.fadeInOut = v }
        if let v = a["motion_blur"] as? Bool { p.motionBlur = v }
        if let v = (a["window_frame"] as? String).flatMap(EditProject.ChromeStyle.Kind.init(rawValue:)) { p.chrome.kind = v }
        if let v = a["window_frame_dark"] as? Bool { p.chrome.dark = v }
        if let v = a["window_title"] as? String { p.chrome.title = v }
        if let v = a["window_address"] as? String { p.chrome.address = v }
        if let v = a["camera_follow_face"] as? Bool {
            if v, rec.bundle.readFaceTrack() == nil, let camera = rec.asset(.camera) {
                let track = try await FaceTrack.analyze(camera, from: rec.meta.track(.camera)?.start ?? 0, to: rec.meta.duration)
                if track.samples.isEmpty { notes.append("No face found in the camera picture.") } else { try rec.bundle.saveFaceTrack(track) }
            }
            p.camera.followFace = v && rec.bundle.readFaceTrack() != nil
        }
        if let v = a["cursor_highlight"] as? Bool { p.cursor.highlight = v }
        if let v = a["cursor_highlight_color"] as? String, v.hasPrefix("#"), v.count == 7 { p.cursor.highlightColor = v }
        if let v = a["ink"] as? Bool { p.showsInk = v }
        if let v = number(a["ink_hold"]) { p.inkHold = min(15, max(0.5, v)) }
        if let v = a["click_sound"] as? Bool { p.cursor.clickSound = v }
        if let v = (a["camera_backdrop"] as? String).flatMap(EditProject.CameraStyle.Backdrop.init(rawValue:)) { p.camera.backdrop = v }
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
        if let minimum = a["speed_up_dead_time"] as? Double {
            if rec.hasMicrophone && rec.transcript == nil {
                notes.append("Dead time not sped up: the recording has a microphone but no transcript. Run transcribe first.")
            } else {
                let dead = DeadTime.find(events: rec.events, speech: rec.transcript?.speech() ?? [],
                                         duration: rec.meta.duration, minimum: max(0.5, minimum))
                    .filter { r in p.isKept((r.lowerBound + r.upperBound) / 2) }
                for r in dead { p.setSpeed(4, in: r) }
                notes.append("Sped up \(dead.count) dead stretches to 4×.")
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

    // MARK: - Producentens verktyg

    private static func number(_ v: Any?) -> Double? { (v as? Double) ?? (v as? NSNumber)?.doubleValue ?? (v as? Int).map(Double.init) }

    private static func setOverlays(_ a: [String: Any]) throws -> String {
        let rec = try resolve(a)
        var p = rec.bundle.loadProject(duration: rec.meta.duration)
        guard let list = a["overlays"] as? [[String: Any]] else { throw ToolError("overlays must be an array of objects.") }
        var made: [Overlay] = []
        var notes: [String] = []
        for o in list {
            guard let kind = Overlay.Kind(rawValue: o["kind"] as? String ?? ""), let at = number(o["at"]) else {
                throw ToolError("Each overlay needs kind (title|callout|fact|qr) and at.")
            }
            var overlay = Overlay(kind: kind, at: at, duration: number(o["duration"]) ?? (kind == .title ? 2.5 : 4),
                                  title: o["title"] as? String ?? "", lines: o["lines"] as? [String] ?? [],
                                  url: o["url"] as? String ?? "",
                                  corner: Overlay.Corner(rawValue: o["corner"] as? String ?? "") ?? (kind == .qr ? .bottomRight : .topRight))
            overlay.animation = (o["animation"] as? String).flatMap(Overlay.Animation.init(rawValue:)) ?? .fade
            if let f = (o["frame"] as? [Any])?.compactMap(number), f.count >= 3 {
                overlay.frame = Rect(x: f[0], y: f[1], width: f[2], height: f.count > 3 ? f[3] : 0)
            }
            if let size = number(o["size"]) { overlay.size = size }
            if let bg = o["background"] as? Bool { overlay.background = bg }
            if kind == .text && overlay.frame == nil { overlay.frame = Rect(x: 0.5, y: 0.2, width: 0.6, height: 0) }
            if kind == .video {
                guard let path = o["file"] as? String,
                      FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath) else {
                    throw ToolError("video overlays need file = path to an existing video.")
                }
                let src = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
                let name = "video-\(UUID().uuidString.prefix(6)).\(src.pathExtension.isEmpty ? "mov" : src.pathExtension.lowercased())"
                try FileManager.default.createDirectory(at: rec.bundle.mediaDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: src, to: rec.bundle.mediaDir.appendingPathComponent(name))
                overlay.file = name
                overlay.offset = number(o["offset"]) ?? 0
                overlay.volume = number(o["volume"]) ?? 1
                overlay.speed = max(0.25, min(4, number(o["speed"]) ?? 1))
                overlay.softness = max(0, min(1, number(o["softness"]) ?? 0))
                if let c = (o["crop"] as? [Any])?.compactMap(number), c.count == 4 {
                    overlay.crop = Rect(x: max(0, c[0]), y: max(0, c[1]), width: min(1, c[2]), height: min(1, c[3]))
                }
                if overlay.frame == nil { overlay.frame = Rect(x: 0, y: 0, width: 1, height: 1) }
                if o["duration"] == nil, let length = videoLength(src) { overlay.duration = max(0.5, (length - overlay.offset) / overlay.speed) }
            }
            if kind == .image {
                guard let path = o["file"] as? String,
                      FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath) else {
                    throw ToolError("image overlays need file = path to an existing image.")
                }
                let src = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
                let name = "bild-\(UUID().uuidString.prefix(6)).\(src.pathExtension.isEmpty ? "png" : src.pathExtension.lowercased())"
                try FileManager.default.createDirectory(at: rec.bundle.mediaDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: src, to: rec.bundle.mediaDir.appendingPathComponent(name))
                overlay.file = name
                if overlay.frame == nil { overlay.frame = Rect(x: 0.62, y: 0.08, width: 0.3, height: 0.3) }
            }
            if let t = (o["target"] as? [Any])?.compactMap(number), t.count == 4 {
                overlay.target = Rect(x: t[0], y: t[1], width: t[2], height: t[3])
            } else if kind == .callout, let click = number(o["target_click_at"]) ?? Optional(at) {
                if let found = Producer.clickTarget(rec, near: click) {
                    overlay.target = Rect(found.rect)
                    if overlay.title.isEmpty, let label = found.label {
                        // «knapp «Exportera»» → «Exportera»
                        overlay.title = label.split(separator: "«").last.map { String($0).replacingOccurrences(of: "»", with: "") } ?? label
                    }
                } else {
                    notes.append("No click near \(Producer.fmt(click)) s for the callout «\(overlay.title)» — give target explicitly.")
                }
            }
            made.append(overlay)
        }
        p.overlays = (a["append"] as? Bool == true ? p.overlays : []) + made
        try rec.bundle.saveProject(p)
        let issues = Producer.preflight(project: p, words: rec.transcript?.words ?? [], duration: rec.meta.duration)
            .filter { $0.message.contains("@") }
        return (["Saved \(made.count) overlay(s); \(p.overlays.count) in total."] + notes
                + (issues.isEmpty ? [] : [Producer.report(issues)])).joined(separator: "\n")
    }

    /// En videofils längd (s), synkront — det här körs i verktygets egen tråd.
    private static func videoLength(_ url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        let box = UncheckedResult()
        Task.detached { box.value = try? await asset.load(.duration).seconds; semaphore.signal() }
        semaphore.wait()
        return box.value
    }

    private static func setChapters(_ a: [String: Any]) throws -> String {
        let rec = try resolve(a)
        var p = rec.bundle.loadProject(duration: rec.meta.duration)
        let list = (a["chapters"] as? [[String: Any]]) ?? []
        p.chapters = list.compactMap { c in number(c["at"]).map { Chapter(at: $0, title: c["title"] as? String ?? "") } }
            .sorted { $0.at < $1.at }
        if let banner = a["banner"] as? Bool { p.showsChapterBanner = banner }
        try rec.bundle.saveProject(p)
        let track = OverlayTrack(overlays: [], chapters: p.chapters, timeMap: TimeMap(segments: p.segments))
        return "Saved \(p.chapters.count) chapter(s). YouTube timestamps (output time):\n" + track.youtubeChapters
    }

    private static func setSegments(_ a: [String: Any]) throws -> String {
        let rec = try resolve(a)
        var p = rec.bundle.loadProject(duration: rec.meta.duration)
        let raw = (a["keep"] as? [[Any]]) ?? []
        let segs = raw.compactMap { row -> EditProject.ClipSegment? in
            let r = row.compactMap(number)
            guard r.count >= 2, r[1] > r[0] else { return nil }
            var seg = EditProject.ClipSegment(start: max(0, r[0]), end: min(rec.meta.duration, r[1]),
                                              speed: r.count > 2 ? max(0.25, min(8, r[2])) : 1)
            seg.cameraLayout = row.compactMap { $0 as? String }.first.flatMap(EditProject.CameraLayout.init(rawValue:))
            return seg
        }
        guard !segs.isEmpty else { throw ToolError("keep needs at least one [start, end] with end > start.") }
        p.segments = segs
        try rec.bundle.saveProject(p)
        let issues = Producer.preflight(project: p, words: rec.transcript?.words ?? [], duration: rec.meta.duration)
            .filter { $0.message.hasPrefix("Cut at") }
        return "Saved \(segs.count) part(s); output \(Producer.fmt(TimeMap(segments: segs).outputDuration)) s."
            + (issues.isEmpty ? "" : "\n" + Producer.report(issues))
    }

    private static func addAudio(_ a: [String: Any]) async throws -> String {
        let rec = try resolve(a)
        guard let path = a["file"] as? String, let role = AudioClip.Role(rawValue: a["role"] as? String ?? ""),
              let at = number(a["at"]) else { throw ToolError("file, role (narration|music|effect) and at are required.") }
        let source = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw ToolError("No file at \(source.path).") }
        guard let track = try? await AVURLAsset(url: source).loadTracks(withMediaType: .audio).first,
              let range = try? await track.load(.timeRange) else { throw ToolError("Not an audio file AVFoundation can read.") }
        try FileManager.default.createDirectory(at: rec.bundle.mediaDir, withIntermediateDirectories: true)
        let name = "\(role.rawValue)-\(UUID().uuidString.prefix(6)).\(source.pathExtension.isEmpty ? "m4a" : source.pathExtension)"
        try FileManager.default.copyItem(at: source, to: rec.bundle.mediaDir.appendingPathComponent(name))
        var p = rec.bundle.loadProject(duration: rec.meta.duration)
        if a["replace"] as? Bool == true { p.audioClips.removeAll { $0.role == role } }
        p.audioClips.append(AudioClip(role: role, at: at, file: name, text: a["text"] as? String ?? "",
                                      duration: range.duration.seconds, volume: number(a["volume"]) ?? (role == .music ? 0.35 : 1),
                                      fadeIn: number(a["fade_in"]) ?? (role == .music ? 1.5 : 0),
                                      fadeOut: number(a["fade_out"]) ?? (role == .music ? 2.5 : 0)))
        p.audioClips.sort { $0.at < $1.at }
        try rec.bundle.saveProject(p)
        return "Added \(role.rawValue) \(name) (\(Producer.fmt(range.duration.seconds)) s) at \(Producer.fmt(at)) s."
    }

    private static func producerPrompt(_ ref: String) -> String {
        """
        Du är producent för en skärminspelning i Bjarbys skärminspelare (MCP-servern "skarminspelare").
        Inspelning: \(ref). Människan som spelat in är slutredaktör; räkna med 2–4 varv.
        Verktygen renderar besluten — de fattar dem inte. Du fattar dem.

        1. Underlag: kör `get_overview`. Finns tal men inget transkript: `transcribe` först.
           Skriv EN fokusmening: vad ska tittaren kunna efteråt? Den är facit för vad som får plats.
        2. Klipp (`set_segments` eller `edit_recording` med remove_dead_time): bort med dödtid,
           felstarter, upprepningar och väntan; kvar med det som visar hur det görs. Snitt i
           pauserna mellan ord, aldrig mitt i ett ord. Snabba hellre upp väntan (×2–×4) än att
           klippa bort något tittaren behöver se hända.
        3. Rörelse: `edit_recording` med auto_zoom (zoomar ur klicken) och rimlig zoom_scale.
           Stående format för sociala medier: aspect vertical + framing fill.
        4. Kapitel (`set_chapters`): över 90 s → 3–7 kapitel, korta rubriker (2–4 ord).
        5. Bildlager (`set_overlays`): ett rubrikkort (title, ≤ 2,5 s) i början; markeringar
           (callout med target_click_at = klickets tid) på de klick som är själva poängen — inte på
           varje klick; faktarutor för det som sägs och är värt att minnas; QR för varje adress
           som nämns (kontrollera att adressen svarar). Högst ungefär en ruta per 6 s. Inget i
           bild får vara nödvändigt för den som bara lyssnar.
        6. Undertexter: på om det finns tal (`edit_recording` captions true). Brus: voice_isolation;
           nivå: normalize_loudness.
        7. Berättarröst bara om människan vill ha det. Fråga först om RÖST och SPRÅK — det kostar
           pengar. Använd elevenlabs-dialogue-skillen (Text to Dialogue, aldrig rå TTS), en fil per
           steg, sedan `add_audio` role narration med texten. Låt varje rad andas (~1 s paus).
           Klonad röst: säg i första repliken att det är en AI med den personens röst.
        8. `preflight`: åtgärda alla fel; varningar ska du kunna motivera.
        9. DET SOM SÄGS SKA SYNAS: kör `render_frames` vid varje overlay, kapitel och varje
           berättarrad, och LÄS bilderna. Stämmer inte bilden med texten — ändra besluten (tid,
           mål, text), inte verkligheten. Kolla också att markeringen sitter på rätt knapp och att
           inget täcker det viktiga.
        10. `save_delivery_note`: brevet till människan — Vad jag valde och varför → 2–3 saker jag
            vill att du tar ställning till → vad jag strök → nästa gång. Exportera bara om du blir
            ombedd (`export`); ladda aldrig upp eller publicera utan uttryckligt ja.
        """
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
            ?? (preset.codec == .audioStems ? movies.appendingPathComponent("\(rec.bundle.name) – ljudspår", isDirectory: true)
                : movies.appendingPathComponent(rec.bundle.name).appendingPathExtension(preset.fileExtension))
        let started = Date()
        let bounds = (a["range"] as? [Any])?.compactMap(number)
        let range = bounds.flatMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]...$0[1] : nil }
        let exporter = Exporter(recording: rec, project: project, preset: preset, fps: a["fps"] as? Int, range: range,
                                loudnessTarget: number(a["loudness"]))
        try await exporter.run(to: url) { _ in }
        var text = String(format: "Exported %@ in %.1f s: %@", preset.name, Date().timeIntervalSince(started), url.path)
        if !project.chapters.isEmpty, !preset.isAudioOnly, preset.codec != .gif {
            let track = OverlayTrack(overlays: [], chapters: project.chapters, timeMap: TimeMap(segments: project.segments))
            let span = range ?? 0...TimeMap(segments: project.segments).outputDuration
            text += "\nChapters are embedded in the file. YouTube timestamps:\n" + track.youtubeChapters(in: span)
        }
        if preset.codec == .audioStems {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
            text += "\n" + files.map { "- \($0)" }.joined(separator: "\n")
        }
        if let l = exporter.loudnessReport {
            text += String(format: "\nLoudness: measured %.1f LUFS, gain %+.1f dB%@.", l.measured, l.gainDB,
                           l.limitedByPeaks ? " (limited by peaks, under the target)" : "")
        }
        if a["subtitles"] as? Bool ?? true, preset.id != "gif", let words = rec.transcript?.words, !words.isEmpty {
            let srt = url.deletingPathExtension().appendingPathExtension("srt")
            let captions = Captions(words: words, timeMap: TimeMap(segments: project.segments))
            try (range.map { captions.srt(in: $0) } ?? captions.srt).write(to: srt, atomically: true, encoding: .utf8)
            text += "\nSubtitles: \(srt.path)"
        }
        if a["upload"] as? Bool == true {
            guard preset.codec != .audioStems else { throw ToolError(text + "\nNot uploaded: a folder of stems can't be uploaded; export ljud-m4a or ljud-wav.") }
            guard SharingStore.isReady else {
                throw ToolError(text + "\nNot uploaded: sharing is not set up (Sharing … in the app's menu).")
            }
            let link = try await SharingStore.share(url)
            text += "\nLink (copied to the clipboard): \(link.absoluteString)"
        }
        return text
    }
}

private final class UncheckedResult: @unchecked Sendable { var value: Double? }
