import SwiftUI
import AVFoundation
import RecorderKit

/// Ovanpå förhandsvisningen: lagren som syns just nu går att klicka på, dra och skala direkt i
/// bilden. Räknar om mellan vyns punkter och bildytans pixlar (videon passas in i spelaren).
struct CanvasEditOverlay: View {
    @ObservedObject var model: EditorModel
    /// Lagret som dras och hur det såg ut när dragningen började (allt räknas från det).
    @State private var dragStart: Overlay?
    /// Faktaruta/QR följer pekaren medan den dras och lägger sig i närmaste hörn vid släpp.
    @State private var floatingOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let canvas = model.plan.canvas
            let video = AVMakeRect(aspectRatio: canvas, insideRect: CGRect(origin: .zero, size: geo.size))
            let scale = video.width / max(canvas.width, 1)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(visible(), id: \.id) { o in
                    if let rect = viewRect(o, video: video, scale: scale) {
                        let selected = o.id == model.selectedOverlayID
                        let shown = selected && dragStart?.id == o.id && (o.kind == .fact || o.kind == .qr)
                            ? rect.offsetBy(dx: floatingOffset.width, dy: floatingOffset.height) : rect
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(selected ? Color.accentColor : Color.white.opacity(0.001),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .background(Color.white.opacity(0.001))
                            .frame(width: shown.width, height: shown.height)
                            .position(x: shown.midX, y: shown.midY)
                            .gesture(moveGesture(o, scale: scale, video: video))
                            .onTapGesture { model.selectedOverlayID = o.id }
                            .help(Text(verbatim: o.title))
                        if selected && resizable(o) {
                            Circle()
                                .fill(Color.accentColor)
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                .frame(width: 12, height: 12)
                                .position(x: shown.maxX, y: shown.maxY)
                                .gesture(resizeGesture(o, scale: scale))
                        }
                    }
                }
            }
        }
    }

    /// Lagren som syns vid spelhuvudet och går att flytta.
    private func visible() -> [Overlay] {
        model.plan.overlayTrack.visible(at: model.currentTime).map(\.overlay)
            .filter { $0.kind != .title && !($0.kind == .video && $0.isFullFrame) }
    }

    private func resizable(_ o: Overlay) -> Bool { [.text, .image, .video, .callout].contains(o.kind) }

    /// Lagrets ram i vyns punkter (origo uppe till vänster).
    private func viewRect(_ o: Overlay, video: CGRect, scale: CGFloat) -> CGRect? {
        let canvasH = model.plan.canvas.height
        let f: CGRect
        if o.kind == .callout, let target = o.target {
            f = model.plan.canvasRect(content: target.cgRect, at: model.sourceTimeAtPlayhead)
        } else if let frame = model.plan.frame(of: o) {
            f = frame
        } else { return nil }
        return CGRect(x: video.minX + f.minX * scale, y: video.minY + (canvasH - f.maxY) * scale,
                      width: f.width * scale, height: f.height * scale)
    }

    private func moveGesture(_ o: Overlay, scale: CGFloat, video: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if dragStart?.id != o.id { dragStart = o; model.selectedOverlayID = o.id }
                guard let start = dragStart else { return }
                let canvas = model.plan.canvas
                let dx = Double(v.translation.width / scale), dy = Double(v.translation.height / scale)
                switch o.kind {
                case .fact, .qr:
                    floatingOffset = v.translation
                case .callout:
                    guard let t = start.target else { return }
                    // Målet ligger i innehållet: räkna om med skärmytans storlek och zoomen.
                    let zoom = model.plan.cameraPath.viewport(at: model.sourceTimeAtPlayhead).scale
                    let sr = model.plan.screenRect
                    model.updateOverlay(o.id) {
                        $0.target = Rect(x: t.x + dx / Double(sr.width * zoom), y: t.y + dy / Double(sr.height * zoom),
                                         width: t.width, height: t.height)
                    }
                default:
                    guard let f = start.frame else { return }
                    model.updateOverlay(o.id) {
                        $0.frame = Rect(x: f.x + dx / Double(canvas.width), y: f.y + dy / Double(canvas.height),
                                        width: f.width, height: f.height)
                    }
                }
            }
            .onEnded { v in
                if o.kind == .fact || o.kind == .qr, let rect = viewRect(o, video: video, scale: scale) {
                    // Närmaste hörn för mitten där rutan släpptes.
                    let c = CGPoint(x: rect.midX + v.translation.width, y: rect.midY + v.translation.height)
                    let left = c.x < video.midX, top = c.y < video.midY
                    model.updateOverlay(o.id) { $0.corner = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight) }
                }
                dragStart = nil
                floatingOffset = .zero
            }
    }

    private func resizeGesture(_ o: Overlay, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragStart?.id != o.id { dragStart = o }
                guard let start = dragStart else { return }
                let canvas = model.plan.canvas
                let dx = Double(v.translation.width / scale)
                switch o.kind {
                case .callout:
                    guard let t = start.target else { return }
                    let zoom = model.plan.cameraPath.viewport(at: model.sourceTimeAtPlayhead).scale
                    let sr = model.plan.screenRect
                    let dy = Double(v.translation.height / scale)
                    model.updateOverlay(o.id) {
                        $0.target = Rect(x: t.x, y: t.y, width: max(0.01, t.width + dx / Double(sr.width * zoom)),
                                         height: max(0.01, t.height + dy / Double(sr.height * zoom)))
                    }
                case .text:
                    guard let f = start.frame else { return }
                    // Texten växer åt båda håll från mitten: dubbla förflyttningen i bredd.
                    model.updateOverlay(o.id) {
                        $0.frame = Rect(x: f.x, y: f.y, width: min(0.95, max(0.1, f.width + 2 * dx / Double(canvas.width))), height: f.height)
                        $0.size = max(0.5, min(2.5, start.size * (1 + dx / Double(canvas.width * f.width))))
                    }
                default:
                    guard let f = start.frame else { return }
                    let w = min(1, max(0.06, f.width + dx / Double(canvas.width)))
                    model.updateOverlay(o.id) { $0.frame = Rect(x: f.x, y: f.y, width: w, height: f.height * w / max(f.width, 0.01)) }
                }
            }
            .onEnded { _ in dragStart = nil }
    }
}
