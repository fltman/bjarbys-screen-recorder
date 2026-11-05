import Foundation
import CoreGraphics

/// Producentens underlag och regler. Producenten (en AI i Claude Code via MCP, eller en
/// människa) fattar besluten; verktygen här beskriver materialet och kontrollerar besluten
/// — de fattar inga själva. Samma princip som Generativet-studion.
public enum Producer {
    // MARK: - Underlaget

    /// Allt producenten behöver om en inspelning, kort och i källtid.
    public static func overview(_ rec: LoadedRecording, project: EditProject) -> String {
        let map = TimeMap(segments: project.segments)
        var out: [String] = []
        out.append("Recording: \(rec.bundle.name), \(fmt(rec.meta.duration)) s recorded, source \(rec.meta.source.kind.rawValue) «\(rec.meta.source.title)» \(rec.meta.source.pixelWidth)×\(rec.meta.source.pixelHeight).")
        let tracks = rec.meta.tracks.filter { !$0.failed }.map(\.kind.rawValue).joined(separator: ", ")
        out.append("Tracks: \(tracks). Output now: \(fmt(map.outputDuration)) s in \(project.segments.count) part(s), aspect \(project.aspect.rawValue)\(project.framing == .fill ? " (fill)" : "").")
        out.append("All times below are SOURCE seconds (the recording's own timeline). Overlays, chapters, cuts and audio clips use source time too.")

        out.append("\n## Current decisions")
        out.append("Parts kept: " + project.segments.map { "[\(fmt($0.start))–\(fmt($0.end))\($0.speed != 1 ? " ×\(fmt($0.speed))" : "")]" }.joined(separator: " "))
        out.append("Zooms: \(project.zooms.count) (\(project.zooms.filter(\.isAuto).count) suggested from clicks).")
        out.append("Overlays: " + (project.overlays.isEmpty ? "none" : project.overlays.map { "\($0.kind.rawValue)@\(fmt($0.at)) «\($0.title)»" }.joined(separator: "; ")))
        out.append("Chapters: " + (project.chapters.isEmpty ? "none" : project.chapters.map { "\(fmt($0.at)) \($0.title)" }.joined(separator: "; ")))
        out.append("Audio clips: " + (project.audioClips.isEmpty ? "none" : project.audioClips.map { "\($0.role.rawValue)@\(fmt($0.at)) \(fmt($0.duration)) s" }.joined(separator: "; ")))
        out.append("Captions: \(rec.transcript == nil ? "no transcript" : (project.captions.visible ? "on" : "off")). Masks: \(project.masks.count).")
        // Pennan: det presentatören ritade på skärmen pekar ut något (ritas i efterhand, avstängbart).
        let ink = InkTrack(events: rec.events, mapping: rec.mapping)
        if !ink.isEmpty {
            out.append("Pen strokes (drawn live, shown \(project.showsInk ? "on" : "off"), stay \(fmt(project.inkHold)) s): " + ink.strokes.map { st in
                let xs = st.points.map(\.p.x), ys = st.points.map(\.p.y)
                return "\(fmt(st.start))–\(fmt(st.end)) around (\(fmt3(Double((xs.min()! + xs.max()!) / 2))), \(fmt3(Double((ys.min()! + ys.max()!) / 2))))"
            }.joined(separator: "; "))
        }

        // Skrivande (bara när och var, aldrig vad): skurar med skrivmarkörens område.
        var bursts: [(start: Double, end: Double, area: CGRect?)] = []
        for e in rec.events where e.k == .typing {
            let r = e.rect.map { rec.mapping.normalize($0.cgRect, at: e.t) }
            if var last = bursts.last, e.t - last.end <= AutoZoom.typingGap {
                last.end = e.t
                if let r { last.area = last.area.map { $0.union(r) } ?? r }
                bursts[bursts.count - 1] = last
            } else {
                bursts.append((e.t, e.t, r))
            }
        }
        if !bursts.isEmpty {
            out.append("Typing (only when and where, never what): " + bursts.prefix(60).map { b in
                "\(fmt(b.start))–\(fmt(b.end))" + (b.area.map { " at (\(fmt3($0.midX)), \(fmt3($0.midY)))" } ?? "")
            }.joined(separator: "; "))
        }

        if let words = rec.transcript?.words, !words.isEmpty {
            out.append("\n## What is said (transcript, \(words.count) words)")
            var current = "", start = words[0].start
            for (i, w) in words.enumerated() {
                let ended = i > 0 && (w.startsSegment || words[i - 1].text.last.map { ".!?".contains($0) } == true)
                if ended && !current.isEmpty { out.append("[\(fmt(start))] \(current)"); current = ""; start = w.start }
                current += (current.isEmpty ? "" : " ") + w.text
            }
            if !current.isEmpty { out.append("[\(fmt(start))] \(current)") }
        } else if rec.hasMicrophone || rec.hasComputerAudio {
            out.append("\n## What is said\nNot transcribed yet — run the transcribe tool first.")
        }

        var labels: [Double: (String?, CGRect?)] = [:]
        for e in rec.events where e.k == .element {
            labels[e.t] = (e.label, e.rect.map { rec.mapping.normalize($0.cgRect, at: e.t) })
        }
        let actions = rec.events.filter { $0.k == .down || $0.k == .key }
        if !actions.isEmpty {
            out.append("\n## What happens on screen (clicks with the element's name and frame, 0–1 of the screen)")
            for e in actions.prefix(200) {
                if e.k == .key { out.append("[\(fmt(e.t))] shortcut \(e.label ?? "?")"); continue }
                let (label, rect) = labels[e.t] ?? (nil, nil)
                let p = e.point.map { rec.mapping.normalize($0, at: e.t) }
                var line = "[\(fmt(e.t))] \(e.b == 1 ? "right-click" : ((e.n ?? 1) >= 2 ? "double-click" : "click"))"
                if let label { line += " on \(label)" }
                if let r = rect, r.width > 0, r.width < 0.9 { line += " frame=[\(fmt3(r.minX)),\(fmt3(r.minY)),\(fmt3(r.width)),\(fmt3(r.height))]" }
                else if let p { line += " at=(\(fmt3(p.x)),\(fmt3(p.y)))" }
                out.append(line)
            }
        }

        let dead = DeadTime.find(events: rec.events, speech: rec.transcript?.speech() ?? [], duration: rec.meta.duration)
        if !dead.isEmpty {
            out.append("\n## Dead time (no speech, no input, ≥ 2 s)")
            out.append(dead.map { "[\(fmt($0.lowerBound))–\(fmt($0.upperBound))]" }.joined(separator: " "))
            if rec.hasMicrophone && rec.transcript == nil { out.append("(Unreliable without a transcript: pauses in speech count as dead.)") }
        }
        return out.joined(separator: "\n")
    }

    public static func fmt(_ x: Double) -> String { String(format: "%.1f", x) }
    static func fmt3(_ x: Double) -> String { String(format: "%.3f", x) }

    /// Ramen för elementet under klicket närmast `t` (inom 1,5 s), normaliserad.
    public static func clickTarget(_ rec: LoadedRecording, near t: Double) -> (rect: CGRect, label: String?)? {
        let downs = rec.events.filter { $0.k == .down && abs($0.t - t) <= 1.5 }
        guard let click = downs.min(by: { abs($0.t - t) < abs($1.t - t) }) else { return nil }
        if let el = rec.events.first(where: { $0.k == .element && $0.t == click.t }), let r = el.rect {
            let n = rec.mapping.normalize(r.cgRect, at: click.t)
            if n.width > 0.003 && n.width < 0.9 && n.height < 0.9 { return (n, el.label) }
        }
        guard let p = click.point.map({ rec.mapping.normalize($0, at: click.t) }) else { return nil }
        return (CGRect(x: p.x - 0.03, y: p.y - 0.02, width: 0.06, height: 0.04), nil)
    }

    // MARK: - Reglerna

    public struct Issue: Equatable, Sendable {
        public enum Severity: String, Sendable { case error, warning }
        public let severity: Severity
        public let message: String
    }

    /// Kontrollerar besluten. Fel stoppar leveransen; varningar ska producenten kunna motivera.
    public static func preflight(project: EditProject, words: [Transcript.Word], duration: Double,
                                 mediaExists: (String) -> Bool = { _ in true }) -> [Issue] {
        var issues: [Issue] = []
        func error(_ s: String) { issues.append(.init(severity: .error, message: s)) }
        func warn(_ s: String) { issues.append(.init(severity: .warning, message: s)) }
        let map = TimeMap(segments: project.segments)
        let output = map.outputDuration

        for o in project.overlays {
            let name = "\(o.kind.rawValue)@\(fmt(o.at)) «\(o.title)»"
            if map.output(at: o.at) == nil { error("\(name) is in a cut part and will never show.") }
            if o.duration < 1 { error("\(name) shows for \(fmt(o.duration)) s — too short to read (≥ 1 s).") }
            if o.duration > 15 { warn("\(name) shows for \(fmt(o.duration)) s — long for an overlay.") }
            switch o.kind {
            case .title:
                if o.title.isEmpty { error("\(name) has no title.") }
                if o.title.count > 60 { error("\(name): title over 60 characters.") }
            case .fact:
                if o.title.isEmpty { error("\(name) has no title.") }
                if o.lines.count > 3 { error("\(name): more than 3 lines.") }
                if o.lines.contains(where: { $0.count > 70 }) { warn("\(name): a line over 70 characters.") }
            case .qr:
                if !(o.url.hasPrefix("https://") || o.url.hasPrefix("http://")) { error("\(name): QR url must start with http(s)://.") }
            case .callout:
                guard let r = o.target else { error("\(name) has no target frame."); break }
                if r.x < -0.01 || r.y < -0.01 || r.x + r.width > 1.01 || r.y + r.height > 1.01 || r.width <= 0 || r.height <= 0 {
                    error("\(name): target frame outside the screen.")
                }
                if o.title.count > 32 { warn("\(name): label over 32 characters.") }
            case .text:
                if o.title.isEmpty { error("\(name) has no text.") }
                if o.title.count > 120 { warn("\(name): over 120 characters — long to read on screen.") }
            case .image:
                if o.file.isEmpty || !mediaExists(o.file) { error("\(name): image \(o.file) is missing in media/.") }
                if o.frame == nil { error("\(name) has no frame.") }
            case .video:
                if o.file.isEmpty || !mediaExists(o.file) { error("\(name): video \(o.file) is missing in media/.") }
            }
        }
        // Två rutor i samma hörn samtidigt.
        let fixed = project.overlays.filter { $0.kind == .fact || $0.kind == .qr }
        for (i, a) in fixed.enumerated() {
            for b in fixed[(i + 1)...] where a.corner == b.corner {
                if a.at < b.at + b.duration && b.at < a.at + a.duration {
                    error("\(a.kind.rawValue)@\(fmt(a.at)) and \(b.kind.rawValue)@\(fmt(b.at)) overlap in the same corner.")
                }
            }
        }
        let titles = project.overlays.filter { $0.kind == .title }.count
        if titles > 2 { warn("\(titles) title cards — more than 2 interrupts a demo.") }
        if output > 0, Double(project.overlays.count) > output / 6 {
            warn("\(project.overlays.count) overlays in \(fmt(output)) s — dense (more than one per 6 s).")
        }
        if output > 90 && project.chapters.isEmpty { warn("Over 90 s without chapters.") }
        for c in project.chapters where map.output(at: c.at) == nil { error("Chapter «\(c.title)» at \(fmt(c.at)) is in a cut part.") }

        // Ljudklipp.
        let narration = project.audioClips.filter { $0.role == .narration }.sorted { $0.at < $1.at }
        for c in project.audioClips where !mediaExists(c.file) { error("Audio clip \(c.file) is missing in media/.") }
        for (a, b) in zip(narration, narration.dropFirst()) {
            guard let oa = map.output(at: a.at), let ob = map.output(at: b.at) else { continue }
            if oa + a.duration > ob { error("Narration at \(fmt(a.at)) runs into the next one at \(fmt(b.at)).") }
        }
        let speech = Transcript(words: words).speech()
        for c in narration {
            if speech.contains(where: { $0.lowerBound < c.at + c.duration && c.at < $0.upperBound }) {
                warn("Narration at \(fmt(c.at)) talks over the recorded speech.")
            }
            if map.output(at: c.at) == nil { error("Narration at \(fmt(c.at)) is in a cut part.") }
        }

        // Snitt mitt i ord.
        for s in project.segments {
            for edge in [s.start, s.end] where edge > 0.05 && edge < duration - 0.05 {
                if let w = words.first(where: { edge > $0.start + 0.04 && edge < $0.end - 0.04 }) {
                    warn("Cut at \(fmt(edge)) is inside the word «\(w.text)» (\(fmt(w.start))–\(fmt(w.end))).")
                }
            }
        }
        return issues
    }

    /// Täcker en fast ruta (faktaruta, QR, rubrikkort) det som klickas inom 2,5 s före, under eller
    /// efter att den visas? Räknas i den färdiga bilden, med zoomen.
    public static func coverage(plan: RenderPlan, events: [InputEvent], mapping: ContentMapping) -> [Issue] {
        var issues: [Issue] = []
        let clicks = events.filter { $0.k == .down }
        var frames: [Double: CGRect] = [:]
        for e in events where e.k == .element { if let r = e.rect { frames[e.t] = mapping.normalize(r.cgRect, at: e.t) } }
        for o in plan.project.overlays where o.kind != .callout {
            guard let box = plan.frame(of: o), let start = plan.timeMap.output(at: o.at) else { continue }
            let end = start + o.duration
            for c in clicks {
                guard let out = plan.timeMap.output(at: c.t), out >= start - 2.5, out <= end + 2.5 else { continue }
                let target: CGRect
                if let f = frames[c.t], f.width > 0, f.width < 0.9 { target = f }
                else if let p = c.point.map({ mapping.normalize($0, at: c.t) }) { target = CGRect(x: p.x - 0.01, y: p.y - 0.01, width: 0.02, height: 0.02) }
                else { continue }
                if box.intersects(plan.canvasRect(content: target, at: c.t)) {
                    issues.append(.init(severity: .error, message:
                        "\(o.kind.rawValue)@\(fmt(o.at)) «\(o.title)» covers what is clicked at \(fmt(c.t)) s — move it to another corner or another time."))
                    break
                }
            }
        }
        return issues
    }

    public static func report(_ issues: [Issue]) -> String {
        guard !issues.isEmpty else { return "Preflight: no problems." }
        let errors = issues.filter { $0.severity == .error }, warnings = issues.filter { $0.severity == .warning }
        var s = "Preflight: \(errors.count) error(s), \(warnings.count) warning(s)." + (errors.isEmpty ? "" : " Errors block delivery.")
        for i in errors { s += "\n✗ " + i.message }
        for i in warnings { s += "\n! " + i.message }
        return s
    }
}
