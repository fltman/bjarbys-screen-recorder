import SwiftUI
import RecorderKit

/// Tidslinjen visar den redigerade filmen (utdatatid): delar med miniatyrer, zoomblock och
/// ljudets vågformer. Zoomarna lagras i källtid men ritas där de hamnar efter klippen.
struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @State private var pixelsPerSecond: Double = 0
    @State private var drag: DragMode?

    private enum DragMode {
        case scrub
        case move(UUID, start: Double, end: Double, outStart: Double)
        case resizeStart(UUID)
        case resizeEnd(UUID)
        case moveOverlay(UUID, outStart: Double)
        case resizeOverlay(UUID, duration: Double)
        /// Trimma en del (flytta början/slutet i inspelningen) från värdet när dragningen började.
        case trimStart(UUID, start: Double, speed: Double)
        case trimEnd(UUID, end: Double, speed: Double)
        /// ⌥: sträck delen — samma innehåll, ny längd i filmen, alltså ny hastighet.
        case stretch(UUID, sourceLength: Double, outLength: Double, fromStart: Bool)
        /// Flytta den markerade delen till en ny plats i ordningen.
        case moveSegment(UUID, grab: CGFloat)
    }
    /// Var pekaren är medan en del flyttas (för spöket och insättningsmärket).
    @State private var moveX: CGFloat = 0
    @State private var moveStartX: CGFloat = 0

    /// Platsen bland de andra delarna där den flyttade delen hamnar, och märkets x.
    private func dropTarget(for id: UUID, at px: CGFloat, pps: Double) -> (index: Int, x: CGFloat)? {
        let segments = model.project.segments.filter { $0.duration > 0.001 }
        let pieces = model.editTimeMap.pieces
        let others = zip(segments, pieces).filter { $0.0.id != id }
        guard !others.isEmpty else { return nil }
        let t = self.t(px, pps)
        let index = others.filter { t > ($0.1.outputStart + $0.1.outputEnd) / 2 }.count
        let mx = index == 0 ? x(others[0].1.outputStart, pps) : x(others[index - 1].1.outputEnd, pps)
        return (index, mx)
    }

    /// Delens kant under punkten i klippfilen: vid en gräns mellan två delar den sida pekaren är på.
    private func segmentEdge(at p: CGPoint, pps: Double) -> (seg: EditProject.ClipSegment, isStart: Bool)? {
        guard p.y >= clipY && p.y <= clipY + clipH else { return nil }
        let map = model.editTimeMap
        let segments = model.project.segments.filter { $0.duration > 0.001 }
        var best: (seg: EditProject.ClipSegment, isStart: Bool, d: CGFloat)?
        for (seg, piece) in zip(segments, map.pieces) {
            let x0 = x(piece.outputStart, pps), x1 = x(piece.outputEnd, pps)
            for (isStart, ex) in [(true, x0), (false, x1)] {
                let d = abs(p.x - ex)
                guard d <= 7 else { continue }
                // Inåt i delen räknas före utåt, så att gränsen mellan två delar går att ta i båda.
                let inside = isStart ? p.x >= ex : p.x <= ex
                let score = d - (inside ? 3 : 0)
                if best == nil || score < best!.d { best = (seg, isStart, score) }
            }
        }
        return best.map { ($0.seg, $0.isStart) }
    }

    // Filernas placering uppifrån. Undertexter och masker får egna filer när de finns.
    private let rulerH: CGFloat = 22
    private let clipY: CGFloat = 26, clipH: CGFloat = 58
    private let zoomY: CGFloat = 90, zoomH: CGFloat = 26
    private let laneH: CGFloat = 20
    private let waveH: CGFloat = 30
    private let leading: CGFloat = 12
    /// Valfria filer under zoomen, i ordning; nil = filen finns inte.
    private var optionalLanes: [String] {
        var lanes: [String] = []
        if !model.project.overlays.isEmpty { lanes.append("overlays") }
        if model.plan.captions != nil { lanes.append("captions") }
        if !model.project.masks.isEmpty { lanes.append("masks") }
        if !model.project.audioClips.isEmpty { lanes.append("audio") }
        return lanes
    }
    private func laneY(_ name: String) -> CGFloat? {
        optionalLanes.firstIndex(of: name).map { zoomY + zoomH + 6 + CGFloat($0) * (laneH + 4) }
    }
    private var overlayY: CGFloat? { laneY("overlays") }
    private var captionY: CGFloat? { laneY("captions") }
    private var maskY: CGFloat? { laneY("masks") }
    private var audioY: CGFloat? { laneY("audio") }
    private var waveY: CGFloat { zoomY + zoomH + 8 + CGFloat(optionalLanes.count) * (laneH + 4) }

    /// Höjden tidslinjen behöver för filerna som finns.
    static func height(for model: EditorModel) -> CGFloat {
        let waves = model.waveLanes.count
        let extra = (model.plan.captions == nil ? 0 : 24) + (model.project.masks.isEmpty ? 0 : 24)
            + (model.project.overlays.isEmpty ? 0 : 24) + (model.project.audioClips.isEmpty ? 0 : 24)
        return 26 + 58 + 6 + 26 + 8 + CGFloat(extra) + CGFloat(max(waves, 1)) * 34 + 10 + 26
    }

    /// Ikonerna till vänster, en per fil.
    private var laneIcons: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            laneIcon("film", y: clipY + clipH / 2, help: "Klipp")
            laneIcon("plus.magnifyingglass", y: zoomY + zoomH / 2, help: "Zoom")
            if let y = overlayY { laneIcon("square.on.square", y: y + laneH / 2, help: "Bildlager") }
            if let y = captionY { laneIcon("captions.bubble", y: y + laneH / 2, help: "Undertexter") }
            if let y = audioY { laneIcon("music.note", y: y + laneH / 2, help: "Extra ljud") }
            if let y = maskY { laneIcon("eye.slash", y: y + laneH / 2, help: "Dölj känsligt") }
            ForEach(Array(model.waveLanes.enumerated()), id: \.offset) { i, w in
                laneIcon(w.icon, y: waveY + CGFloat(i) * (waveH + 4) + waveH / 2, help: LocalizedStringKey(w.name))
            }
        }
        .frame(width: 30)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private func laneIcon(_ name: String, y: CGFloat, help: LocalizedStringKey) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 18)
            .position(x: 15, y: y)
            .help(help)
    }

    var body: some View {
        GeometryReader { geo in
            let pps = effectivePPS(width: geo.size.width)
            let contentWidth = max(geo.size.width, CGFloat(model.duration * pps) + leading * 2)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                laneIcons
                Divider()
                ScrollView(.horizontal, showsIndicators: true) {
                    Canvas { ctx, size in
                        draw(&ctx, size: size, pps: pps)
                    }
                    .frame(width: contentWidth, height: geo.size.height - 26)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { handleDrag($0, pps: pps) }
                        .onEnded { _ in dragEnded() })
                    .onContinuousHover { hover($0, pps: pps) }
                }
                }
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { log(pps) }, set: { pixelsPerSecond = exp($0) }),
                           in: log(fitPPS(width: geo.size.width) * 0.8)...log(600))
                        .frame(width: 140)
                        .controlSize(.mini)
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func fitPPS(width: CGFloat) -> Double {
        max(2, Double(width - leading * 2) / max(model.duration, 0.1))
    }

    private func effectivePPS(width: CGFloat) -> Double {
        pixelsPerSecond > 0 ? pixelsPerSecond : fitPPS(width: width)
    }

    private func x(_ t: Double, _ pps: Double) -> CGFloat { leading + CGFloat(t * pps) }
    private func t(_ x: CGFloat, _ pps: Double) -> Double { Double(x - leading) / pps }

    // MARK: - Rita

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, pps: Double) {
        let map = model.editTimeMap
        drawRuler(&ctx, size: size, pps: pps)

        // Delar med miniatyrer.
        let segments = model.project.segments.filter { $0.duration > 0.001 }
        for (seg, piece) in zip(segments, map.pieces) {
            let rect = CGRect(x: x(piece.outputStart, pps), y: clipY,
                              width: max(2, CGFloat((piece.outputEnd - piece.outputStart) * pps) - 1), height: clipH)
            let shape = RoundedRectangle(cornerRadius: 6).path(in: rect)
            ctx.fill(shape, with: .color(.black.opacity(0.35)))
            var inner = ctx
            inner.clip(to: shape)
            let source = model.recording.sourceSize
            let thumbW = clipH * (source.height > 0 ? source.width / source.height : 16 / 10)
            var px = rect.minX
            while px < rect.maxX {
                let source = map.source(at: t(px + thumbW / 2, pps))
                if let thumb = nearestThumbnail(source) {
                    inner.draw(Image(decorative: thumb, scale: 1), in: CGRect(x: px, y: rect.minY, width: thumbW, height: clipH))
                }
                px += thumbW
            }
            if piece.speed != 1 {
                let label = Text(AppLocale.format("%g×", piece.speed)).font(.caption.bold()).foregroundStyle(.white)
                ctx.fill(Capsule().path(in: CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 34, height: 18)),
                         with: .color(.black.opacity(0.65)))
                ctx.draw(label, at: CGPoint(x: rect.minX + 23, y: rect.minY + 15))
            }
            if let layout = seg.cameraLayout, model.recording.hasCamera, rect.width > 60 {
                let icon = switch layout {
                case .bubble: "person.crop.circle"
                case .large: "person.fill"
                case .split: "rectangle.split.2x1"
                case .hidden: "person.slash"
                }
                let x0 = rect.minX + (piece.speed != 1 ? 46 : 6)
                ctx.fill(Capsule().path(in: CGRect(x: x0, y: rect.minY + 6, width: 26, height: 18)), with: .color(.black.opacity(0.65)))
                ctx.draw(Image(systemName: icon), at: CGPoint(x: x0 + 13, y: rect.minY + 15))
            }
            let selected = seg.id == model.selectedSegmentID
            ctx.stroke(shape, with: .color(selected ? .accentColor : .white.opacity(0.25)), lineWidth: selected ? 3 : 1)
            if selected {
                // Handtag i ändarna: dra för att trimma, ⌥-dra för att ändra farten.
                for hx in [rect.minX + 4, rect.maxX - 4] {
                    ctx.fill(Capsule().path(in: CGRect(x: hx - 2.5, y: rect.minY + 14, width: 5, height: rect.height - 28)),
                             with: .color(.white))
                }
            }
            // Flyttas: delen tonas ned på sin gamla plats.
            if case let .moveSegment(id, _) = drag, id == seg.id {
                ctx.fill(shape, with: .color(.black.opacity(0.5)))
            }
            // Medan delen dras: längden i filmen (och farten när den sträcks).
            if let id = draggedSegmentID, id == seg.id {
                let len = piece.outputEnd - piece.outputStart
                let text = piece.speed == 1 ? AppLocale.format("%.1f s", len) : AppLocale.format("%.1f s · %g×", len, (piece.speed * 100).rounded() / 100)
                let label = Text(text).font(.caption.monospacedDigit().bold()).foregroundStyle(.white)
                let w: CGFloat = piece.speed == 1 ? 52 : 92
                ctx.fill(Capsule().path(in: CGRect(x: rect.midX - w / 2, y: rect.maxY - 24, width: w, height: 18)),
                         with: .color(.accentColor))
                ctx.draw(label, at: CGPoint(x: rect.midX, y: rect.maxY - 15))
            }
        }

        // Delen som flyttas: ett spöke vid pekaren och ett märke där den hamnar.
        if case let .moveSegment(id, grab) = drag, let piece = piece(for: id),
           let target = dropTarget(for: id, at: moveX, pps: pps) {
            let w = max(2, CGFloat((piece.outputEnd - piece.outputStart) * pps) - 1)
            let ghost = CGRect(x: moveX - grab, y: clipY + 4, width: w, height: clipH - 8)
            ctx.fill(RoundedRectangle(cornerRadius: 6).path(in: ghost), with: .color(.accentColor.opacity(0.35)))
            ctx.stroke(RoundedRectangle(cornerRadius: 6).path(in: ghost), with: .color(.accentColor), lineWidth: 2)
            ctx.fill(Path(CGRect(x: target.x - 1.5, y: clipY - 4, width: 3, height: clipH + 8)), with: .color(.accentColor))
        }

        // Zoomblock.
        for zoom in model.project.zooms {
            guard let r = outputRange(of: zoom) else { continue }
            let rect = CGRect(x: x(r.lowerBound, pps), y: zoomY, width: max(6, CGFloat((r.upperBound - r.lowerBound) * pps)), height: zoomH)
            let shape = RoundedRectangle(cornerRadius: 6).path(in: rect)
            let base: Color = zoom.isAuto ? .purple : .orange
            let selected = zoom.id == model.selectedZoomID
            ctx.fill(shape, with: .color(base.opacity(selected ? 0.55 : 0.32)))
            ctx.stroke(shape, with: .color(base.opacity(selected ? 1 : 0.7)), lineWidth: selected ? 2 : 1)
            if rect.width > 44 {
                ctx.draw(Text(AppLocale.format("%.1f×", zoom.scale)).font(.caption.weight(.semibold)),
                         at: CGPoint(x: rect.midX, y: rect.midY))
            }
            if selected {
                for hx in [rect.minX + 3, rect.maxX - 3] {
                    ctx.fill(Capsule().path(in: CGRect(x: hx - 2, y: rect.minY + 6, width: 4, height: rect.height - 12)),
                             with: .color(.white))
                }
            }
        }

        // Undertexter: en ruta per textrad, med början av texten.
        if let y = captionY, let captions = model.plan.captions {
            for cue in captions.cues {
                let rect = CGRect(x: x(cue.start, pps), y: y, width: max(3, CGFloat((cue.end - cue.start) * pps) - 2), height: laneH)
                let shape = RoundedRectangle(cornerRadius: 4).path(in: rect)
                ctx.fill(shape, with: .color(.teal.opacity(0.22)))
                ctx.stroke(shape, with: .color(.teal.opacity(0.55)), lineWidth: 0.8)
                if rect.width > 30 {
                    var inner = ctx
                    inner.clip(to: shape)
                    inner.draw(Text(cue.text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 10)),
                               at: CGPoint(x: rect.minX + 5, y: rect.midY), anchor: .leading)
                }
            }
        }

        // Bildlager: block per ruta, färg efter sort.
        if let y = overlayY {
            for o in model.project.overlays {
                guard let start = model.editTimeMap.output(at: o.at) else { continue }
                let rect = CGRect(x: x(start, pps), y: y, width: max(4, CGFloat(o.duration * pps)), height: laneH)
                let shape = RoundedRectangle(cornerRadius: 4).path(in: rect)
                let color: Color = switch o.kind {
                case .title: .indigo
                case .callout: .blue
                case .fact: .mint
                case .qr: .brown
                case .text: .purple
                case .image: .cyan
                case .video: .orange
                }
                let selected = o.id == model.selectedOverlayID
                ctx.fill(shape, with: .color(color.opacity(selected ? 0.5 : 0.25)))
                ctx.stroke(shape, with: .color(color.opacity(selected ? 1 : 0.6)), lineWidth: selected ? 2 : 0.8)
                if rect.width > 34 {
                    var inner = ctx
                    inner.clip(to: shape)
                    inner.draw(Text(o.title).font(.system(size: 10, weight: .medium)),
                               at: CGPoint(x: rect.minX + 5, y: rect.midY), anchor: .leading)
                }
            }
        }

        // Extra ljud: block per klipp.
        if let y = audioY {
            for c in model.project.audioClips {
                guard let start = model.editTimeMap.output(at: c.at) else { continue }
                let end = min(model.duration, start + c.duration)
                let rect = CGRect(x: x(start, pps), y: y, width: max(4, CGFloat((end - start) * pps)), height: laneH)
                let shape = RoundedRectangle(cornerRadius: 4).path(in: rect)
                let color: Color = c.role == .music ? .pink : (c.role == .narration ? .orange : .yellow)
                ctx.fill(shape, with: .color(color.opacity(0.22)))
                ctx.stroke(shape, with: .color(color.opacity(0.6)), lineWidth: 0.8)
                if rect.width > 34 {
                    var inner = ctx
                    inner.clip(to: shape)
                    inner.draw(Text(c.text.isEmpty ? c.file : c.text).font(.system(size: 10)),
                               at: CGPoint(x: rect.minX + 5, y: rect.midY), anchor: .leading)
                }
            }
        }

        // Övergångar: en romb i varje snitt som har en, bred som övergången.
        for cut in model.plan.cutPlan.cuts {
            let px = x(cut.output, pps)
            let w = max(8, CGFloat(cut.transition.duration * pps))
            let band = CGRect(x: px - w / 2, y: clipY + clipH - 10, width: w, height: 8)
            ctx.fill(Path(roundedRect: band, cornerRadius: 4), with: .color(.white.opacity(0.75)))
            let icon = switch cut.transition.kind {
            case .crossfade: "×"
            case .dip: "●"
            case .blur: "≈"
            case .flash: "✦"
            case .none: ""
            }
            ctx.draw(Text(icon).font(.system(size: 8, weight: .bold)).foregroundStyle(.black.opacity(0.7)),
                     at: CGPoint(x: px, y: band.midY))
        }

        // Kapitel: flaggor på linjalen.
        for c in model.project.chapters {
            guard let t = model.editTimeMap.output(at: c.at) else { continue }
            let px = x(t, pps)
            ctx.fill(Path(CGRect(x: px, y: 0, width: 1.5, height: clipY + clipH)), with: .color(.accentColor.opacity(0.8)))
            ctx.fill(Path(roundedRect: CGRect(x: px, y: 1, width: 9, height: 7), cornerRadius: 1.5), with: .color(.accentColor))
            ctx.draw(Text(c.title).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor),
                     at: CGPoint(x: px + 12, y: 5), anchor: .leading)
        }

        // Masker: där något döljs i den redigerade filmen.
        if let y = maskY {
            for mask in model.project.masks {
                guard let r = outputRange(start: mask.start, end: mask.end) else { continue }
                let rect = CGRect(x: x(r.lowerBound, pps), y: y, width: max(4, CGFloat((r.upperBound - r.lowerBound) * pps)), height: laneH)
                let shape = RoundedRectangle(cornerRadius: 4).path(in: rect)
                let selected = mask.id == model.selectedMaskID
                let color: Color = mask.enabled ? .red : .gray
                ctx.fill(shape, with: .color(color.opacity(selected ? 0.45 : 0.22)))
                ctx.stroke(shape, with: .color(color.opacity(selected ? 1 : 0.55)), lineWidth: selected ? 2 : 0.8)
                if rect.width > 40 {
                    var inner = ctx
                    inner.clip(to: shape)
                    inner.draw(Text(mask.hint).font(.system(size: 10, design: .monospaced)),
                               at: CGPoint(x: rect.minX + 5, y: rect.midY), anchor: .leading)
                }
            }
        }

        // Vågformer.
        var y = waveY
        for (wave, color) in model.waveLanes.map({ ($0.samples, $0.color) }) {
            let mid = y + waveH / 2
            var path = Path()
            var px = max(leading, 0)
            let end = x(model.duration, pps)
            while px < end {
                let s = map.source(at: t(px, pps))
                let i = Int(s / max(model.recording.meta.duration, 0.001) * Double(wave.count))
                let v = (i >= 0 && i < wave.count) ? CGFloat(min(1, sqrt(Double(wave[i])))) : 0
                let h = max(1, v * waveH / 2)
                path.addRect(CGRect(x: px, y: mid - h, width: 1.4, height: h * 2))
                px += 2
            }
            ctx.fill(path, with: .color(color.opacity(0.7)))
            y += waveH + 4
        }

        // Spelhuvudet.
        let px = x(model.currentTime, pps)
        ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.red))
        ctx.fill(Path { p in
            p.move(to: CGPoint(x: px - 6, y: 0)); p.addLine(to: CGPoint(x: px + 6, y: 0))
            p.addLine(to: CGPoint(x: px, y: 9)); p.closeSubpath()
        }, with: .color(.red))
    }

    private func drawRuler(_ ctx: inout GraphicsContext, size: CGSize, pps: Double) {
        let steps: [Double] = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { $0 * pps >= 70 } ?? 600
        var s = 0.0
        while s <= model.duration + step {
            let px = x(s, pps)
            ctx.fill(Path(CGRect(x: px, y: rulerH - 7, width: 1, height: 7)), with: .color(.secondary))
            let label = s >= 60 || step >= 1
                ? String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
                : AppLocale.format("%.2f", s)
            ctx.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary),
                     at: CGPoint(x: px + 3, y: 7), anchor: .leading)
            s += step
        }
    }

    private func nearestThumbnail(_ source: Double) -> CGImage? {
        guard !model.thumbnails.isEmpty else { return nil }
        var best = model.thumbnails[0]
        for th in model.thumbnails where abs(th.t - source) < abs(best.t - source) { best = th }
        return best.image
    }

    /// Var en zoom (i källtid) syns i den redigerade filmen, eller nil om den är bortklippt.
    private func outputRange(of zoom: EditProject.ZoomSegment) -> ClosedRange<Double>? {
        outputRange(start: zoom.start, end: zoom.end)
    }

    private func outputRange(start: Double, end: Double) -> ClosedRange<Double>? {
        var lo: Double?, hi: Double?
        for p in model.editTimeMap.pieces {
            let a = max(start, p.sourceStart), b = min(end, p.sourceEnd)
            guard b > a else { continue }
            let oa = p.outputStart + (a - p.sourceStart) / p.speed
            let ob = p.outputStart + (b - p.sourceStart) / p.speed
            lo = min(lo ?? oa, oa); hi = max(hi ?? ob, ob)
        }
        guard let lo, let hi else { return nil }
        return lo...hi
    }

    // MARK: - Dra

    /// Delen som trimmas eller sträcks just nu.
    private var draggedSegmentID: UUID? {
        switch drag {
        case let .trimStart(id, _, _), let .trimEnd(id, _, _), let .stretch(id, _, _, _): id
        default: nil
        }
    }

    @State private var lastPPS: Double = 100

    private func handleDrag(_ value: DragGesture.Value, pps: Double) {
        lastPPS = pps
        let map = model.editTimeMap
        if drag == nil {
            let p = value.startLocation
            drag = .scrub
            if let edge = segmentEdge(at: p, pps: pps) {
                model.selectedSegmentID = edge.seg.id
                model.selectedZoomID = nil
                if NSEvent.modifierFlags.contains(.option) {
                    drag = .stretch(edge.seg.id, sourceLength: edge.seg.duration, outLength: edge.seg.outputDuration,
                                    fromStart: edge.isStart)
                } else {
                    drag = edge.isStart ? .trimStart(edge.seg.id, start: edge.seg.start, speed: edge.seg.speed)
                                        : .trimEnd(edge.seg.id, end: edge.seg.end, speed: edge.seg.speed)
                }
            } else if p.y >= zoomY && p.y <= zoomY + zoomH {
                model.selectedZoomID = nil
                for zoom in model.project.zooms.reversed() {
                    guard let r = outputRange(of: zoom) else { continue }
                    let x0 = x(r.lowerBound, pps), x1 = x(r.upperBound, pps)
                    guard p.x >= x0 - 6 && p.x <= x1 + 6 else { continue }
                    model.selectedZoomID = zoom.id
                    model.selectedSegmentID = nil
                    if abs(p.x - x0) <= 7 { drag = .resizeStart(zoom.id) }
                    else if abs(p.x - x1) <= 7 { drag = .resizeEnd(zoom.id) }
                    else { drag = .move(zoom.id, start: zoom.start, end: zoom.end, outStart: r.lowerBound) }
                    break
                }
            } else if let y = overlayY, p.y >= y && p.y <= y + laneH {
                let hit = model.project.overlays.last { o in
                    guard let s = model.editTimeMap.output(at: o.at) else { return false }
                    return p.x >= x(s, pps) - 4 && p.x <= x(s + o.duration, pps) + 4
                }
                model.selectedOverlayID = hit?.id
                if let hit, let s = model.editTimeMap.output(at: hit.at) {
                    // Högra kanten ändrar längden, resten flyttar.
                    drag = abs(p.x - x(s + hit.duration, pps)) <= 7 ? .resizeOverlay(hit.id, duration: hit.duration)
                                                                    : .moveOverlay(hit.id, outStart: s)
                }
            } else if let y = maskY, p.y >= y && p.y <= y + laneH {
                let hit = model.project.masks.last { m in
                    guard let r = outputRange(start: m.start, end: m.end) else { return false }
                    return p.x >= x(r.lowerBound, pps) - 4 && p.x <= x(r.upperBound, pps) + 4
                }
                model.selectedMaskID = hit?.id
            } else if p.y >= clipY && p.y <= clipY + clipH {
                let hit = segment(atOutputLive: t(p.x, pps))
                // Den markerade delen flyttas när den dras; en annan del markeras och spolas till.
                if let hit, hit.id == model.selectedSegmentID, let piece = piece(for: hit.id) {
                    drag = .moveSegment(hit.id, grab: p.x - x(piece.outputStart, pps))
                    moveX = p.x; moveStartX = p.x
                } else {
                    model.selectedSegmentID = hit?.id
                }
                model.selectedZoomID = nil
            }
        }
        switch drag {
        case .scrub, .none:
            model.scrub(to: t(value.location.x, pps))
        case let .move(id, start, end, outStart):
            let newOut = max(0, outStart + Double(value.translation.width) / pps)
            let newStart = map.source(at: newOut)
            let length = end - start
            model.updateZoom(id) { z in
                z.start = min(newStart, model.recording.meta.duration - length)
                z.end = z.start + length
            }
        case let .resizeStart(id):
            let s = map.source(at: t(value.location.x, pps))
            model.updateZoom(id) { $0.start = s }
        case let .resizeEnd(id):
            let s = map.source(at: t(value.location.x, pps))
            model.updateZoom(id) { $0.end = s }
        case let .moveOverlay(id, outStart):
            let newOut = max(0, min(model.duration - 0.2, outStart + Double(value.translation.width) / pps))
            model.updateOverlay(id) { $0.at = map.source(at: newOut) }
        case let .resizeOverlay(id, duration):
            let d = max(0.5, duration + Double(value.translation.width) / pps)
            model.updateOverlay(id) { $0.duration = d }
        case .moveSegment:
            moveX = value.location.x
        case let .trimStart(id, start, speed):
            model.trimSegment(id, start: start + Double(value.translation.width) / pps * speed)
        case let .trimEnd(id, end, speed):
            model.trimSegment(id, end: end + Double(value.translation.width) / pps * speed)
        case let .stretch(id, sourceLength, outLength, fromStart):
            let dx = Double(value.translation.width) / pps
            let length = max(0.05, outLength + (fromStart ? -dx : dx))
            let speed = max(0.25, min(8, sourceLength / length))
            model.setSpeed((speed * 100).rounded() / 100, for: id)
        }
    }

    /// När en del trimmats: spelhuvudet till den nya kanten, så att den första (eller sista)
    /// bilden syns.
    private func dragEnded() {
        if case let .moveSegment(id, _) = drag {
            // Ett klick utan dragning spolar dit, som i resten av tidslinjen.
            if abs(moveX - moveStartX) < 3 {
                model.scrub(to: t(moveX, lastPPS))
            } else if let target = dropTarget(for: id, at: moveX, pps: lastPPS) {
                model.moveSegment(id, toIndexAmongOthers: target.index)
            }
        }
        if case let .trimStart(id, _, _) = drag, let piece = piece(for: id) { model.scrub(to: piece.outputStart) }
        if case let .trimEnd(id, _, _) = drag, let piece = piece(for: id) { model.scrub(to: max(piece.outputStart, piece.outputEnd - 1.0 / 60)) }
        drag = nil
    }

    private func segment(atOutputLive t: Double) -> EditProject.ClipSegment? {
        let segments = model.project.segments.filter { $0.duration > 0.001 }
        return zip(segments, model.editTimeMap.pieces).first { t >= $0.1.outputStart && t < $0.1.outputEnd }?.0
    }

    private func piece(for id: UUID) -> TimeMap.Piece? {
        let segments = model.project.segments.filter { $0.duration > 0.001 }
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return nil }
        let pieces = model.editTimeMap.pieces
        return i < pieces.count ? pieces[i] : nil
    }

    /// Pekaren visar att en kant går att dra.
    private func hover(_ phase: HoverPhase, pps: Double) {
        switch phase {
        case .active(let p):
            if segmentEdge(at: p, pps: pps) != nil { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        case .ended:
            NSCursor.arrow.set()
        }
    }
}
