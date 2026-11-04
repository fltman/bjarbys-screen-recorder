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
    }

    // Filernas placering uppifrån.
    private let rulerH: CGFloat = 22
    private let clipY: CGFloat = 26, clipH: CGFloat = 58
    private let zoomY: CGFloat = 90, zoomH: CGFloat = 28
    private let waveY: CGFloat = 124, waveH: CGFloat = 32
    private let leading: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let pps = effectivePPS(width: geo.size.width)
            let contentWidth = max(geo.size.width, CGFloat(model.duration * pps) + leading * 2)
            VStack(spacing: 0) {
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
                HStack(spacing: 8) {
                    Text(lanesLegend).font(.caption2).foregroundStyle(.secondary)
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

    private var lanesLegend: String {
        var parts = ["Klipp", "Zoom"]
        if !model.micWave.isEmpty { parts.append("Mikrofon") }
        if !model.systemWave.isEmpty { parts.append("Datorljud") }
        return parts.joined(separator: " · ")
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
                let label = Text(String(format: "%g×", piece.speed)).font(.caption.bold()).foregroundStyle(.white)
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
                ctx.draw(Text(String(format: "%.1f×", zoom.scale)).font(.caption.weight(.semibold)),
                         at: CGPoint(x: rect.midX, y: rect.midY))
            }
            if selected {
                for hx in [rect.minX + 3, rect.maxX - 3] {
                    ctx.fill(Capsule().path(in: CGRect(x: hx - 2, y: rect.minY + 6, width: 4, height: rect.height - 12)),
                             with: .color(.white))
                }
            }
        }

        // Vågformer.
        var y = waveY
        for (wave, color) in [(model.micWave, Color.green), (model.systemWave, Color.blue)] where !wave.isEmpty {
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
                : String(format: "%.2f", s)
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
        var lo: Double?, hi: Double?
        for p in model.timeMap.pieces {
            let a = max(zoom.start, p.sourceStart), b = min(zoom.end, p.sourceEnd)
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
        }
    }
}
