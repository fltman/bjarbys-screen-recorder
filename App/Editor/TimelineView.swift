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
                        .onEnded { _ in drag = nil })
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
        let map = model.timeMap
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
            let selected = seg.id == model.selectedSegmentID
            ctx.stroke(shape, with: .color(selected ? .accentColor : .white.opacity(0.25)), lineWidth: selected ? 3 : 1)
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
                guard let start = model.timeMap.output(at: o.at) else { continue }
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
                guard let start = model.timeMap.output(at: c.at) else { continue }
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
            guard let t = model.timeMap.output(at: c.at) else { continue }
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
        for p in model.timeMap.pieces {
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

    private func handleDrag(_ value: DragGesture.Value, pps: Double) {
        let map = model.timeMap
        if drag == nil {
            let p = value.startLocation
            drag = .scrub
            if p.y >= zoomY && p.y <= zoomY + zoomH {
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
                    guard let s = model.timeMap.output(at: o.at) else { return false }
                    return p.x >= x(s, pps) - 4 && p.x <= x(s + o.duration, pps) + 4
                }
                model.selectedOverlayID = hit?.id
                if let hit, let s = model.timeMap.output(at: hit.at) {
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
                model.selectedSegmentID = model.segment(atOutput: t(p.x, pps))?.id
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
        }
    }
}
