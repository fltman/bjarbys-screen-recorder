import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import AVFoundation
import Vision
import os

/// Den delade Core Image-kontexten, på GPU:n. Rutorna stannar i IOSurface/Metal hela vägen.
public enum RenderContext {
    public static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    public static let shared: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ]
        if let device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()
}

/// Allt som behövs för att rita en färdig ruta, beräknat en gång. Oföränderlig och
/// trådsäker; kompositören anropar `render` från sin egen kö.
public final class RenderPlan: @unchecked Sendable {
    public let canvas: CGSize
    public let project: EditProject
    public let timeMap: TimeMap
    public let cursorPath: CursorPath
    public let cameraPath: CameraPath
    /// Skärmytan i bildytan (Core Image-koordinater, origo nere till vänster).
    public let screenRect: CGRect
    let sourceSize: CGSize
    let pixelsPerPoint: Double
    let background: CIImage?
    let mask: CIImage
    let shadow: CIImage?
    let ring: CIImage
    let sprites: [String: Sprite]
    let fallbackSprite: Sprite
    let cameraMask: CIImage?
    let cameraShadow: CIImage?
    let cameraRect: CGRect
    let bubbleRadius: CGFloat
    /// Inspelningen har en kamera (oavsett om bubblan visas som standard).
    let hasCameraTrack: Bool
    /// Kameralayouten per del, i filmens ordning (samma som `timeMap.pieces`).
    let segmentLayouts: [EditProject.CameraLayout]
    /// Inspelningen fyller bildytan (Reel-läge) i stället för att ligga med marginal.
    let fills: Bool
    /// Ingen bakgrund: allt utanför skärmytan (och skuggan, bubblan, texterna) är genomskinligt.
    public let transparent: Bool
    public let shortcuts: ShortcutTrack?
    /// Kortkommandobubblorna, ritade i förväg i bildytans pixlar, per text.
    let shortcutPills: [String: CIImage]
    /// Undertexterna i utdatatid (också underlaget för .srt), eller nil utan transkript.
    public let captions: Captions?
    let showsCaptions: Bool
    let captionImages = CaptionImageCache()
    /// Talet i utdatatid, för att sänka datorljudet under det.
    public let speech: [ClosedRange<Double>]
    /// Bildlagret och kapitlen i utdatatid.
    public let overlayTrack: OverlayTrack
    /// Snitten med sina övergångar.
    public let cutPlan: CutPlan
    let overlayImages = CaptionImageCache()
    /// Paketets media/, för bildlager.
    let mediaDir: URL?
    /// Videolagren i den ordning deras spår ligger i kompositionen.
    public var videoOverlayIDs: [UUID] { project.overlays.filter { $0.kind == .video }.map(\.id) }
    /// Inspelningen är HDR (PQ, SDR-vitt på 100 nits).
    public let sourceHDR: Bool
    /// Källtiden där kamerans första ruta finns (bubblan tonas in därifrån).
    let cameraStart: Double
    /// Rutorna ritas i HDR (BT.2100 HLG) i stället för SDR (sRGB/BT.709).
    public let outputHDR: Bool

    /// ScreenCaptureKits HDR10-förval lägger SDR-vitt på 100 nits; Core Image har SDR-vitt
    /// (1,0 linjärt) på 203 nits, som BT.2408. Uppmätt: Y 509 (PQ 0,508) → 0,492 linjärt.
    static let hdrScreenGain = 203.0 / 100.0
    /// HLG:s tak i Core Images linjära skala (1000 nits / 203), uppmätt: 4,93 → HLG 1,0.
    static let hlgHeadroom: Float = 4.926
    /// Högdagrarnas tak i inspelningen efter lyftet: en XDR-skärm når 1600 nits = 16 × 100.
    static let hdrSourceHeadroom: Float = 16

    /// Skärmrutan i Core Images skala: SDR-vitt på 1,0, oavsett inspelning. Till HLG trycks
    /// högdagrarna ihop med `CIToneMapHeadroom` (lämnar allt upp till 1,0 orört, uppmätt);
    /// till SDR klipps de vid vitt — en tonmappning mot 1,0 hade sänkt SDR-vitt till 0,35.
    func prepareScreen(_ image: CIImage) -> CIImage {
        guard sourceHDR else { return image }
        let lifted = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(Self.hdrScreenGain)])
        guard outputHDR else { return lifted }
        return lifted.applyingFilter("CIToneMapHeadroom", parameters: [
            "inputSourceHeadroom": Self.hdrSourceHeadroom, "inputTargetHeadroom": Self.hlgHeadroom])
    }

    struct Sprite {
        let image: CIImage
        /// Storlek i punkter och hotspot i punkter från övre vänstra hörnet.
        let size: CGSize
        let hotSpot: CGPoint
    }

    // MARK: - Bildytans storlek

    /// Bildytans storlek i pixlar: kortaste sidan `shortSide`, proportioner ur `aspect`
    /// (eller källans). Jämna tal, som kodarna kräver.
    public static func canvasSize(aspect: EditProject.Aspect, source: CGSize, shortSide: Int) -> CGSize {
        let ratio = aspect.ratio ?? (source.width / max(source.height, 1))
        func even(_ v: Double) -> Double { (v / 2).rounded() * 2 }
        if ratio >= 1 {
            return CGSize(width: even(Double(shortSide) * ratio), height: Double(shortSide))
        } else {
            return CGSize(width: Double(shortSide), height: even(Double(shortSide) / ratio))
        }
    }

    // MARK: - Bygga

    public init(canvas: CGSize, project: EditProject, meta: RecordingMeta, events: [InputEvent],
                cursors: CursorCatalog, cursorsDir: URL, hasCamera: Bool, words: [Transcript.Word] = [],
                transparentBackground: Bool = false, mediaDir: URL? = nil,
                cursorPath: CursorPath? = nil, cameraPath: CameraPath? = nil, outputHDR: Bool = false) {
        self.transparent = transparentBackground
        self.sourceHDR = meta.hdr
        self.cameraStart = meta.track(.camera)?.start ?? 0
        self.outputHDR = outputHDR
        self.mediaDir = mediaDir
        self.canvas = canvas
        self.project = project
        timeMap = TimeMap(segments: project.segments)
        sourceSize = CGSize(width: max(meta.source.pixelWidth, 1), height: max(meta.source.pixelHeight, 1))
        let mapping = ContentMapping(meta: meta, events: events)
        pixelsPerPoint = mapping.pixelsPerPoint(at: 0)
        let cursorPath = cursorPath ?? CursorPath(events: events, mapping: mapping, duration: meta.duration,
                                                  style: project.cursor)
        self.cursorPath = cursorPath

        // Skärmytan: marginal runt om, källans proportioner, centrerad. I Reel-läge täcker den
        // hela bildytan och sticker ut på ena axeln; kameran visar då en del av den.
        let srcRatio = sourceSize.width / sourceSize.height
        fills = project.framing == .fill && abs(srcRatio - canvas.width / canvas.height) > 0.01
        let w: CGFloat, h: CGFloat
        if fills {
            let cover = max(canvas.width / sourceSize.width, canvas.height / sourceSize.height)
            w = (sourceSize.width * cover).rounded(); h = (sourceSize.height * cover).rounded()
        } else {
            let pad = project.padding * min(canvas.width, canvas.height)
            let avail = CGRect(origin: .zero, size: canvas).insetBy(dx: pad, dy: pad)
            let fit = min(avail.width / sourceSize.width, avail.height / sourceSize.height)
            w = (sourceSize.width * fit).rounded(); h = (sourceSize.height * fit).rounded()
        }
        screenRect = CGRect(x: ((canvas.width - w) / 2).rounded(), y: ((canvas.height - h) / 2).rounded(), width: w, height: h)
        let visible = CGSize(width: min(1, canvas.width / w), height: min(1, canvas.height / h))
        // Luppar zoomar inte kameran; de ritas för sig (`lens`).
        self.cameraPath = cameraPath ?? CameraPath(zooms: project.zooms.filter { $0.style == .camera }, cursor: cursorPath, duration: meta.duration,
                                                   visible: visible, followAtRest: fills)

        let radius = fills ? 0 : project.cornerRadius * min(w, h)
        mask = Self.roundedRect(screenRect, radius: radius, color: .white)
        if !fills, project.shadow > 0.01, project.padding > 0.005 {
            let blur = max(4, screenRect.height * 0.035)
            let base = Self.roundedRect(screenRect.offsetBy(dx: 0, dy: -screenRect.height * 0.015), radius: radius,
                                        color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.75 * project.shadow))
            let canvasRect = CGRect(origin: .zero, size: canvas)
            shadow = Self.prerender(base.applyingGaussianBlur(sigma: blur).cropped(to: canvasRect), extent: canvasRect)
        } else {
            shadow = nil
        }
        background = fills
            ? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvas))
            : Self.makeBackground(project.background, canvas: canvas)
        ring = Self.makeRing()

        var sprites: [String: Sprite] = [:]
        for entry in cursors.entries {
            let url = cursorsDir.appendingPathComponent("\(entry.id).png")
            if let loaded = CIImage(contentsOf: url), entry.width > 0 {
                let img = Self.prerender(loaded, extent: loaded.extent)
                sprites[entry.id] = Sprite(image: img, size: CGSize(width: entry.width, height: entry.height),
                                           hotSpot: CGPoint(x: entry.hotX, y: entry.hotY))
            }
        }
        self.sprites = sprites
        fallbackSprite = Self.arrowSprite()

        // Kamerabubblan är fast i bildytan; den zoomar inte med skärmen. Räknas ut även när den är
        // dold, eftersom en enskild del kan visa den.
        self.hasCameraTrack = hasCamera
        self.segmentLayouts = project.segments.filter { $0.duration > 0.001 }.map {
            $0.cameraLayout ?? (project.camera.visible ? .bubble : .hidden)
        }
        if hasCamera {
            let d = (canvas.height * project.camera.size).rounded()
            let margin = (min(canvas.width, canvas.height) * 0.035).rounded()
            let x: CGFloat, y: CGFloat
            switch project.camera.corner {
            case .bottomRight: x = canvas.width - d - margin; y = margin
            case .bottomLeft: x = margin; y = margin
            case .topRight: x = canvas.width - d - margin; y = canvas.height - d - margin
            case .topLeft: x = margin; y = canvas.height - d - margin
            }
            cameraRect = CGRect(x: x, y: y, width: d, height: d)
            let r = project.camera.shape == .circle ? d / 2 : d * 0.18
            bubbleRadius = r
            cameraMask = Self.roundedRect(cameraRect, radius: r, color: .white)
            let sh = Self.roundedRect(cameraRect.offsetBy(dx: 0, dy: -d * 0.03), radius: r,
                                      color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            let blurred = sh.applyingGaussianBlur(sigma: d * 0.05)
            cameraShadow = Self.prerender(blurred.cropped(to: cameraRect.insetBy(dx: -d * 0.3, dy: -d * 0.3)),
                                          extent: cameraRect.insetBy(dx: -d * 0.3, dy: -d * 0.3).integral)
        } else {
            cameraRect = .zero
            cameraMask = nil
            cameraShadow = nil
            bubbleRadius = 0
        }

        // Undertexter och tal i utdatatid.
        if words.isEmpty {
            captions = nil
            speech = []
        } else {
            captions = Captions(words: words, timeMap: timeMap)
            let map = timeMap
            speech = Transcript(words: words).speech().compactMap { r in
                guard let a = map.output(at: r.lowerBound) ?? map.output(at: r.upperBound),
                      let b = map.output(at: r.upperBound) ?? map.output(at: r.lowerBound), b >= a else { return nil }
                return a...b
            }
        }
        showsCaptions = project.captions.visible && !(captions?.cues.isEmpty ?? true)
        overlayTrack = OverlayTrack(overlays: project.overlays, chapters: project.chapters, timeMap: timeMap)
        cutPlan = CutPlan(segments: project.segments, timeMap: timeMap, standard: project.transition)

        // Kortkommandon: bara de texter som faktiskt förekommer ritas, en gång var.
        let track = ShortcutTrack(events: events, timeMap: timeMap)
        if project.shortcuts.visible && !track.items.isEmpty {
            shortcuts = track
            let pillHeight = (min(canvas.width, canvas.height) * 0.062 * project.shortcuts.size).rounded()
            var pills: [String: CIImage] = [:]
            for text in track.texts { pills[text] = Self.makePill(text, height: pillHeight) }
            shortcutPills = pills
        } else {
            shortcuts = nil
            shortcutPills = [:]
        }
    }

    public var outputDuration: Double { timeMap.outputDuration }

    // MARK: - Rita en ruta

    /// Den färdiga rutan vid utdatatiden `t`.
    public func render(outputTime t: Double, screen: CIImage?, camera: CIImage?, media: [UUID: CIImage] = [:],
                       alternate: CIImage? = nil) -> CIImage {
        let screen = screen.map(prepareScreen), alternate = alternate.map(prepareScreen)
        let s = timeMap.source(at: t)
        let canvasRect = CGRect(origin: .zero, size: canvas)
        var layer = CIImage.empty()
        // Skärmen i skärmytan med maskerna (det luppen förstorar — aldrig den råa bilden).
        var maskedScreen: CIImage?

        if let screen {
            let e = screen.extent
            let scaled = screen
                .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: screenRect.width / e.width, y: screenRect.height / e.height))
                .transformed(by: CGAffineTransform(translationX: screenRect.minX, y: screenRect.minY))
            var masked = applyMasks(to: scaled, at: s)
            // Övertoning: den andra delens bild ur skärmspår B, maskad efter sin egen källtid.
            if let alternate, let active = cutPlan.active(at: t), active.cut.transition.kind == .crossfade {
                let ae = alternate.extent
                let other = alternate
                    .transformed(by: CGAffineTransform(translationX: -ae.minX, y: -ae.minY))
                    .transformed(by: CGAffineTransform(scaleX: screenRect.width / ae.width, y: screenRect.height / ae.height))
                    .transformed(by: CGAffineTransform(translationX: screenRect.minX, y: screenRect.minY))
                let otherMasked = applyMasks(to: other, at: active.cut.alternateSource(at: t))
                // Andelen av den andra bilden: växer mot snittet, sedan är den andra bilden den förra delen.
                let share = t < active.cut.output ? active.progress : 1 - active.progress
                masked = masked.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: otherMasked, kCIInputTimeKey: max(0, min(1, share))])
                    .cropped(to: screenRect)
            }
            maskedScreen = masked
            layer = masked.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask,
            ])
        }

        // Luppen: under markören, ovanpå skärmen.
        if let maskedScreen, let lens = lens(at: s, placed: maskedScreen) { layer = lens.composited(over: layer) }

        // Markören och klicken ritas i skärmytan och zoomar med innehållet.
        let k = screenRect.width / sourceSize.width * pixelsPerPoint
        if project.cursor.visible && cursorPath.hasData {
            if project.cursor.clickEffect {
                for (click, progress) in cursorPath.activeClicks(at: s) {
                    let p = point(click.point)
                    let radius = (8 + 26 * progress) * k * project.cursor.scale / 1.6
                    let alpha = 0.85 * (1 - progress)
                    let ringImage = ring
                        .transformed(by: CGAffineTransform(scaleX: radius * 2 / ring.extent.width, y: radius * 2 / ring.extent.height))
                        .transformed(by: CGAffineTransform(translationX: p.x - radius, y: p.y - radius))
                    layer = Self.withAlpha(ringImage, alpha).composited(over: layer)
                }
            }
            let opacity = project.cursor.hideWhenIdle ? cursorPath.opacity(at: s) : 1
            if opacity > 0.01 {
                let sprite = cursorPath.cursorID(at: s).flatMap { sprites[$0] } ?? fallbackSprite
                let p = point(cursorPath.position(at: s))
                let size = CGSize(width: sprite.size.width * k * project.cursor.scale,
                                  height: sprite.size.height * k * project.cursor.scale)
                let sx = size.width / sprite.image.extent.width
                let sy = size.height / sprite.image.extent.height
                let hx = sprite.hotSpot.x * k * project.cursor.scale
                let hyFromTop = sprite.hotSpot.y * k * project.cursor.scale
                let placed = sprite.image
                    .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                    .transformed(by: CGAffineTransform(translationX: p.x - hx, y: p.y - (size.height - hyFromTop)))
                layer = Self.withAlpha(placed, opacity).composited(over: layer)
            }
        }

        // Markeringar: i innehållet, så att de följer knappen när bilden zoomas.
        for shown in overlayTrack.visible(at: t) where shown.overlay.kind == .callout {
            guard let target = shown.overlay.target else { continue }
            let a = point(CGPoint(x: target.x, y: target.y))
            let b = point(CGPoint(x: target.x + target.width, y: target.y + target.height))
            var rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            rect = rect.insetBy(dx: -max(5, rect.height * 0.25), dy: -max(5, rect.height * 0.25))
            // Dyker upp något större och drar ihop sig om målet.
            let grow = 0.18 * (1 - Self.easeOut(shown.entrance))
            rect = rect.insetBy(dx: -rect.width * grow / 2, dy: -rect.height * grow / 2)
            layer = Self.withAlpha(OverlayRenderer.calloutFrame(rect, canvas: canvas), shown.opacity).composited(over: layer)
            let text = shown.overlay.title
            if !text.isEmpty {
                let label = overlayImages.image(for: "callout|\(shown.overlay.id)|\(text)") {
                    OverlayRenderer.calloutLabel(text, canvas: canvas)
                }
                let e = label.extent
                let gap = OverlayRenderer.unit(canvas) * 0.012
                var y = rect.maxY + gap
                if y + e.height > screenRect.maxY { y = rect.minY - gap - e.height }
                let x = min(max(rect.midX - e.width / 2, screenRect.minX + gap), screenRect.maxX - e.width - gap)
                let placed = label.transformed(by: CGAffineTransform(translationX: x.rounded() - e.minX, y: y.rounded() - e.minY))
                layer = Self.withAlpha(placed, shown.opacity).composited(over: layer)
            }
        }

        if let shadow { layer = layer.composited(over: shadow) }

        // Zoomen: punkten `center` i innehållet hamnar mitt i skärmytan, förstorad `zoom` gånger.
        if let transform = cameraTransform(at: s) {
            layer = layer.transformed(by: transform)
        }
        if project.motionBlur { layer = motionBlurred(layer, t: t, s: s) }
        if let move = layoutTransform(at: t) { layer = layer.transformed(by: move) }
        let screenAlpha = layoutFrame(at: t).screenAlpha
        if screenAlpha < 0.999 { layer = Self.withAlpha(layer, screenAlpha) }

        var out = layer.composited(over: backgroundImage(screen: screen))

        let lf = layoutFrame(at: t)
        if let camera, hasCameraTrack, lf.cameraAlpha > 0.001 {
            let rect = lf.camera
            let e = camera.extent
            // Utsnitt med layoutens proportioner (en kvadrat för bubblan), mitt i kamerabilden.
            let aspect = rect.width / max(rect.height, 1)
            let cw = e.width / e.height > aspect ? e.height * aspect : e.width
            let ch = cw / aspect
            var cam = camera.cropped(to: CGRect(x: e.midX - cw / 2, y: e.midY - ch / 2, width: cw, height: ch))
                .transformed(by: CGAffineTransform(translationX: -(e.midX - cw / 2), y: -(e.midY - ch / 2)))
            if project.camera.mirror {
                cam = cam.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -cw, y: 0))
            }
            if project.camera.backdrop != .original, let person = Self.personMask(cam) {
                // Personen skarp, bakgrunden suddig eller utbytt mot filmens egen bakgrund.
                let behind: CIImage
                if project.camera.backdrop == .blur {
                    behind = cam.clampedToExtent().applyingGaussianBlur(sigma: min(cw, ch) * 0.035).cropped(to: cam.extent)
                } else {
                    let bg = backgroundImage(screen: screen)
                    let toCam = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
                        .concatenating(CGAffineTransform(scaleX: cw / rect.width, y: ch / rect.height))
                    behind = bg.transformed(by: toCam).cropped(to: cam.extent)
                        .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.35])
                }
                cam = cam.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: behind,
                                                                         kCIInputMaskImageKey: person])
            }
            cam = cam.transformed(by: CGAffineTransform(scaleX: rect.width / cw, y: rect.height / ch))
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            let isBubble = rect == cameraRect && abs(lf.cameraRadius - bubbleRadius) < 0.5
            let mask = isBubble ? (cameraMask ?? Self.roundedRect(rect, radius: lf.cameraRadius, color: .white))
                                : Self.roundedRect(rect, radius: lf.cameraRadius, color: .white)
            var bubble = cam.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask,
            ])
            var shadow: CIImage?
            if isBubble { shadow = cameraShadow } else if lf.shadow {
                let d = min(rect.width, rect.height)
                shadow = Self.roundedRect(rect.offsetBy(dx: 0, dy: -d * 0.02), radius: lf.cameraRadius,
                                          color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.4))
                    .applyingGaussianBlur(sigma: d * 0.035).cropped(to: rect.insetBy(dx: -d * 0.2, dy: -d * 0.2))
            }
            // Kameran kommer igång en stund efter skärmen: bubblan tonas in och växer lite i stället
            // för att poppa fram.
            let appear = Self.easeOut((s - cameraStart) / 0.3) * lf.cameraAlpha
            if appear < 0.999 {
                let k = 0.9 + 0.1 * Self.easeOut((s - cameraStart) / 0.3)
                let grow = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                    .concatenating(CGAffineTransform(scaleX: k, y: k))
                    .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
                bubble = Self.withAlpha(bubble.transformed(by: grow), appear)
                shadow = shadow.map { Self.withAlpha($0.transformed(by: grow), appear) }
            }
            if let shadow { out = shadow.composited(over: out) }
            out = bubble.composited(over: out)
        }

        // Övergångar i snitten: på filmen, men före lagren och texterna, så att de går att
        // läsa genom övergången.
        let u = OverlayRenderer.unit(canvas)
        out = applyTransition(out, at: t, unit: u, canvasRect: canvasRect)

        // Bildlagret som ligger fast i bildytan: rubrikkort, faktarutor, QR-kort, text, bilder.
        for shown in overlayTrack.visible(at: t) where shown.overlay.kind != .callout {
            let o = shown.overlay
            if o.kind == .video {
                if let frame = media[o.id] { out = Self.withAlpha(videoLayer(frame, o), shown.opacity).composited(over: out) }
                continue
            }
            let key = "\(o.kind.rawValue)|\(o.id)|\(o.title)|\(o.lines.joined(separator: "¦"))|\(o.url)"
            let key2 = key + "|\(o.file)|\(o.size)|\(o.background)|\(o.frame.map { "\($0.width)x\($0.height)" } ?? "")"
            let image = overlayImages.image(for: key2) { overlayImage(o) }
            let e = image.extent
            let slide = (1 - Self.easeOut(shown.entrance)) * u * 0.02
            if o.kind == .title {
                out = Self.withAlpha(CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.38)).cropped(to: canvasRect),
                                     shown.opacity).composited(over: out)
            }
            var origin = placement(of: o, size: e.size)
            origin.y -= slide
            let placed = image.transformed(by: CGAffineTransform(translationX: origin.x.rounded() - e.minX, y: origin.y.rounded() - e.minY))
            out = Self.withAlpha(placed, shown.opacity).composited(over: out)
        }

        // Kapitelraden, uppe till vänster när ett kapitel börjar.
        if project.showsChapterBanner, let banner = overlayTrack.chapterBanner(at: t) {
            let image = overlayImages.image(for: "chapter|\(banner.number)|\(banner.of)|\(banner.title)") {
                OverlayRenderer.chapterBanner(banner.title, number: banner.number, of: banner.of, canvas: canvas)
            }
            let e = image.extent
            let m = (u * 0.04).rounded()
            let placed = image.transformed(by: CGAffineTransform(translationX: m - e.minX, y: canvas.height - m - e.height - e.minY))
            out = Self.withAlpha(placed, banner.opacity).composited(over: out)
        }

        // Undertexten: fast i bildytan, nere i mitten.
        if showsCaptions, let captions, let cue = captions.cue(at: t) {
            let image = captionImages.image(for: cue.text) { Self.makeCaption(cue.text, canvas: canvas, size: project.captions.size) }
            let e = image.extent
            let margin = (min(canvas.width, canvas.height) * 0.05).rounded()
            out = image.transformed(by: CGAffineTransform(translationX: ((canvas.width - e.width) / 2).rounded() - e.minX,
                                                          y: margin - e.minY)).composited(over: out)
        }

        // Kortkommandot ligger fast i bildytan, ovanpå allt, och glider upp när det dyker upp.
        if let shortcuts, let shown = shortcuts.visible(at: t), let pill = shortcutPills[shown.text],
           shown.opacity > 0.01 {
            let e = pill.extent
            var margin = (min(canvas.width, canvas.height) * 0.055).rounded()
            // Med undertexter nere ligger kortkommandot ovanför dem.
            if showsCaptions && project.shortcuts.position == .bottom { margin += Self.captionReserve(canvas: canvas, size: project.captions.size) }
            let rise = (1 - shown.entrance) * e.height * 0.3
            let y = project.shortcuts.position == .bottom ? margin - rise : canvas.height - margin - e.height + rise
            let placed = pill.transformed(by: CGAffineTransform(translationX: ((canvas.width - e.width) / 2).rounded() - e.minX,
                                                                y: y - e.minY))
            out = Self.withAlpha(placed, shown.opacity).composited(over: out)
        }
        if project.fadeInOut {
            let fadeIn = 0.6, fadeOut = 0.8, end = timeMap.outputDuration
            let black = max(t < fadeIn ? 1 - t / fadeIn : 0, t > end - fadeOut ? (t - (end - fadeOut)) / fadeOut : 0)
            if black > 0.001 {
                out = Self.withAlpha(CIImage(color: .black).cropped(to: canvasRect), min(1, black)).composited(over: out)
            }
        }
        return out.cropped(to: canvasRect)
    }

    /// Övergången nära ett snitt: 1 mitt i snittet, 0 en halv övergångslängd bort.
    func transitionAmount(at t: Double) -> Double { cutPlan.active(at: t)?.amount ?? 0 }

    private func applyTransition(_ image: CIImage, at t: Double, unit u: CGFloat, canvasRect: CGRect) -> CIImage {
        guard let active = cutPlan.active(at: t), active.amount > 0.001 else { return image }
        let a = active.amount
        switch active.cut.transition.kind {
        case .none, .crossfade:
            return image
        case .dip:
            return Self.withAlpha(CIImage(color: .black).cropped(to: canvasRect), a).composited(over: image)
        case .flash:
            return Self.withAlpha(CIImage(color: .white).cropped(to: canvasRect), a * 0.85).composited(over: image)
        case .blur:
            let zoom = 1 + 0.06 * a
            let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            return image.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                    .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                    .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
                .applyingGaussianBlur(sigma: Double(u) * 0.025 * a)
                .cropped(to: canvasRect)
        }
    }

    /// Döljer maskernas områden i skärmbilden (före zoom, så att de följer innehållet).
    func applyMasks(to screen: CIImage, at s: Double) -> CIImage {
        var out = screen
        for mask in project.masks {
            guard let r = mask.rect(at: s) else { continue }
            // Lite marginal: OCR-rutan sitter tätt kring bokstäverna.
            let a = point(CGPoint(x: r.minX, y: r.minY)), b = point(CGPoint(x: r.maxX, y: r.maxY))
            var rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            rect = rect.insetBy(dx: -max(4, rect.height * 0.25), dy: -max(3, rect.height * 0.2)).integral
                .intersection(screenRect)
            guard !rect.isEmpty else { continue }
            let patch: CIImage
            switch mask.style {
            case .blur:
                let sigma = max(6, rect.height * 0.45)
                patch = screen.cropped(to: rect).clampedToExtent().applyingGaussianBlur(sigma: sigma)
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.6])
                    .cropped(to: rect)
            case .pixelate:
                patch = screen.cropped(to: rect).clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, rect.height / 2.5),
                                                                kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY)])
                    .cropped(to: rect)
            case .solid:
                patch = Self.roundedRect(rect, radius: min(6, rect.height * 0.2),
                                         color: CIColor(red: 0.12, green: 0.12, blue: 0.14))
            }
            out = patch.composited(over: out)
        }
        return out
    }

    /// Begränsar mittpunkten utifrån vad som syns i hela bildytan, axel för axel. Täcker det
    /// inzoomade innehållet inte bildytan längs en axel centreras det där (annars förskjuts
    /// det och lämnar tom bakgrund på ena sidan, t.ex. liggande innehåll i stående format).
    /// Täcker det, hålls mittpunkten så att ingen bakgrund syns vid kanten. Gränserna växer
    /// steglöst med zoomen, så inget hoppar.
    func coverageClamped(_ c: CGPoint, zoom: Double) -> CGPoint {
        func axis(_ v: Double, canvas: Double, content: Double) -> Double {
            let half = canvas / (2 * content * max(zoom, 1))
            return half >= 0.5 ? 0.5 : min(max(v, half), 1 - half)
        }
        return CGPoint(x: axis(c.x, canvas: canvas.width, content: screenRect.width),
                       y: axis(c.y, canvas: canvas.height, content: screenRect.height))
    }

    /// Normaliserad innehållspunkt (origo uppe till vänster) → bildytan.
    func point(_ n: CGPoint) -> CGPoint {
        CGPoint(x: screenRect.minX + n.x * screenRect.width, y: screenRect.maxY - n.y * screenRect.height)
    }

    private func backgroundImage(screen: CIImage?) -> CIImage {
        // Genomskinligt: en helt klar yta över hela bildytan, så att varje bildpunkt skrivs
        // (återanvända buffertar kan annars ha kvar förra rutans innehåll).
        if transparent { return CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: canvas)) }
        if let background { return background }
        // Oskärpa: skärmen själv, fylld över hela bildytan, suddig och lite mörkare.
        guard let screen else { return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvas)) }
        let e = screen.extent
        let fill = max(canvas.width / e.width, canvas.height / e.height) / 4
        let small = screen.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 18)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.08, kCIInputSaturationKey: 1.2])
        let up = blurred.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        let dx = (canvas.width - e.width * fill * 4) / 2, dy = (canvas.height - e.height * fill * 4) / 2
        return up.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: CGRect(origin: .zero, size: canvas))
    }

    // MARK: - Byggstenar

    static func withAlpha(_ image: CIImage, _ alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
        ])
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = rect
        f.radius = Float(max(0, radius))
        f.color = color
        return f.outputImage ?? CIImage.empty()
    }

    /// Ritar en bild en gång till en IOSurface-backad pixelbuffert. En `CGImage` hade laddats
    /// upp till GPU:n på nytt för varje ruta (syns som `processCompressedRegion2D` i en
    /// sampling av exporten); en IOSurface delas direkt med GPU:n.
    static func prerender(_ image: CIImage, extent: CGRect) -> CIImage {
        let w = Int(extent.width.rounded()), h = Int(extent.height.rounded())
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard w > 0, h > 0,
              CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return image }
        let moved = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        RenderContext.shared.render(moved, to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    public static func color(hex: String) -> CIColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return CIColor(red: 0.2, green: 0.2, blue: 0.25) }
        return CIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255)
    }

    static func makeBackground(_ bg: EditProject.Background, canvas: CGSize) -> CIImage? {
        let rect = CGRect(origin: .zero, size: canvas)
        switch bg.kind {
        case .blur:
            return nil
        case .solid:
            return CIImage(color: color(hex: bg.colorA)).cropped(to: rect)
        case .gradient:
            let a: Double = bg.angle * Double.pi / 180
            let w = Double(canvas.width), h = Double(canvas.height)
            let c = CGPoint(x: w / 2, y: h / 2)
            let spanX: Double = abs(cos(a)) * w
            let spanY: Double = abs(sin(a)) * h
            let half: Double = (spanX + spanY) / 2
            let d = CGPoint(x: cos(a) * half, y: -sin(a) * half)
            let f = CIFilter.linearGradient()
            f.point0 = CGPoint(x: c.x - d.x, y: c.y - d.y)
            f.point1 = CGPoint(x: c.x + d.x, y: c.y + d.y)
            f.color0 = color(hex: bg.colorA)
            f.color1 = color(hex: bg.colorB)
            // Ett svagt ljus uppe till vänster ger djup utan att ta uppmärksamhet.
            let glow = CIFilter.radialGradient()
            glow.center = CGPoint(x: canvas.width * 0.25, y: canvas.height * 0.85)
            glow.radius0 = 0
            glow.radius1 = Float(max(canvas.width, canvas.height) * 0.7)
            glow.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.18)
            glow.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            guard let base = f.outputImage, let light = glow.outputImage else { return nil }
            return prerender(light.composited(over: base).cropped(to: rect), extent: rect)
        }
    }

    /// Klickringen: blå ring med genomskinlig fyllning och vit kant, så att den syns både
    /// mot ljusa och mörka gränssnitt. Ritad en gång i hög upplösning.
    static func makeRing() -> CIImage {
        let size = 256
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        let r = CGRect(x: 18, y: 18, width: size - 36, height: size - 36)
        ctx.setFillColor(CGColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 0.22))
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.setLineWidth(24)
        ctx.strokeEllipse(in: r)
        ctx.setStrokeColor(CGColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1))
        ctx.setLineWidth(14)
        ctx.strokeEllipse(in: r)
        guard let img = ctx.makeImage() else { return CIImage.empty() }
        let ci = CIImage(cgImage: img)
        return prerender(ci, extent: ci.extent)
    }

    /// En kortkommandobubbla: mörk, rundad, vit text. Ritad i exakt de pixlar den visas i,
    /// så att texten blir skarp, och lagd i en IOSurface.
    static func makePill(_ text: String, height: CGFloat) -> CIImage {
        let font = NSFont.systemFont(ofSize: height * 0.46, weight: .semibold)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            .kern: height * 0.02,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padX = height * 0.42
        let width = (bounds.width + padX * 2).rounded(.up)
        let w = Int(width), h = Int(height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = height * 0.28
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 0.78))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: radius - 1, cornerHeight: radius - 1, transform: nil))
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.setLineWidth(max(1, height * 0.025))
        ctx.strokePath()
        // Texten centrerad optiskt: mitt i bubblan mellan versalhöjd och baslinje.
        let capHeight = CTFontGetCapHeight(font)
        ctx.textPosition = CGPoint(x: (width - bounds.width) / 2 - bounds.minX, y: (height - capHeight) / 2)
        CTLineDraw(line, ctx)
        guard let img = ctx.makeImage() else { return CIImage.empty() }
        let ci = CIImage(cgImage: img)
        return prerender(ci, extent: ci.extent)
    }

    /// En videoruta i sin ram: helbild fyller bildytan; bild-i-bild passas in med hörn och skugga.
    func videoLayer(_ frame: CIImage, _ o: Overlay) -> CIImage {
        let full = frame.extent
        // Utsnittet (origo uppe till vänster i lagret, nere till vänster i Core Image).
        var source = frame
        if let c = o.crop {
            let r = CGRect(x: full.minX + full.width * c.x, y: full.minY + full.height * (1 - c.y - c.height),
                           width: full.width * c.width, height: full.height * c.height).integral.intersection(full)
            if r.width > 1, r.height > 1 { source = frame.cropped(to: r) }
        }
        let e = source.extent
        let moved = source.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let canvasRect = CGRect(origin: .zero, size: canvas)
        if o.isFullFrame {
            let k = max(canvas.width / e.width, canvas.height / e.height)
            return moved.transformed(by: CGAffineTransform(scaleX: k, y: k))
                .transformed(by: CGAffineTransform(translationX: (canvas.width - e.width * k) / 2, y: (canvas.height - e.height * k) / 2))
                .cropped(to: canvasRect)
        }
        let f = o.frame ?? Rect(x: 0.6, y: 0.08, width: 0.34, height: 0.34)
        let box = CGRect(x: canvas.width * f.x, y: canvas.height * (1 - f.y - f.height), width: canvas.width * f.width, height: canvas.height * f.height)
        let k = min(box.width / e.width, box.height / e.height)
        let size = CGSize(width: e.width * k, height: e.height * k)
        let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        let radius = min(size.width, size.height) * 0.05
        let scaled = moved.transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        // Mjuka kanter: masken krymps och suddas, och skuggan tas bort (den hade fått en hård kant).
        if o.softness > 0.01 {
            let feather = min(size.width, size.height) * 0.12 * min(1, o.softness)
            let mask = Self.roundedRect(rect.insetBy(dx: feather, dy: feather), radius: radius + feather, color: .white)
                .applyingGaussianBlur(sigma: feather / 2).cropped(to: rect)
            return scaled.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                       kCIInputMaskImageKey: mask])
        }
        let placed = scaled
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                            kCIInputMaskImageKey: Self.roundedRect(rect, radius: radius, color: .white)])
        let u = OverlayRenderer.unit(canvas)
        let shadow = overlayImages.image(for: "videoshadow|\(Int(rect.minX))|\(Int(rect.minY))|\(Int(rect.width))|\(Int(rect.height))") {
            let s = Self.roundedRect(rect.offsetBy(dx: 0, dy: -u * 0.008), radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5))
                .applyingGaussianBlur(sigma: u * 0.014).cropped(to: rect.insetBy(dx: -u * 0.05, dy: -u * 0.05))
            return Self.prerender(s, extent: s.extent.integral)
        }
        return placed.composited(over: shadow)
    }

    func overlayImage(_ o: Overlay) -> CIImage {
        switch o.kind {
        case .title: OverlayRenderer.title(o, canvas: canvas)
        case .qr: OverlayRenderer.qr(o, canvas: canvas)
        case .text: OverlayRenderer.text(o, canvas: canvas)
        case .image: OverlayRenderer.image(o, mediaDir: mediaDir, canvas: canvas)
        default: OverlayRenderer.fact(o, canvas: canvas)
        }
    }

    /// Var en fast ruta (rubrikkort, faktaruta, QR, text, bild) hamnar i bildytan, givet dess storlek.
    func placement(of o: Overlay, size e: CGSize) -> CGPoint {
        let m = (OverlayRenderer.unit(canvas) * 0.045).rounded()
        if o.kind == .title { return CGPoint(x: (canvas.width - e.width) / 2, y: (canvas.height - e.height) / 2) }
        if o.kind == .text {
            // frame.x/y = textens mitt (0–1, origo uppe till vänster).
            let f = o.frame ?? Rect(x: 0.5, y: 0.5, width: 0.6, height: 0)
            return CGPoint(x: canvas.width * f.x - e.width / 2, y: canvas.height * (1 - f.y) - e.height / 2)
        }
        if o.kind == .image {
            // frame = ramen; bilden centreras i den.
            let f = o.frame ?? Rect(x: 0.6, y: 0.1, width: 0.3, height: 0.3)
            let cx = canvas.width * (f.x + f.width / 2), cy = canvas.height * (1 - f.y - f.height / 2)
            return CGPoint(x: cx - e.width / 2, y: cy - e.height / 2)
        }
        let left = o.corner == .topLeft || o.corner == .bottomLeft
        let bottom = o.corner == .bottomLeft || o.corner == .bottomRight
        var y = bottom ? m : canvas.height - m - e.height
        // Inte under undertexterna, och inte över kamerabubblan i samma hörn.
        if bottom && showsCaptions { y += Self.captionReserve(canvas: canvas, size: project.captions.size) }
        if cameraMask != nil && project.camera.visible && Self.sameCorner(o.corner, project.camera.corner) {
            y += bottom ? cameraRect.height + m * 0.5 : -(cameraRect.height + m * 0.5)
        }
        return CGPoint(x: left ? m : canvas.width - m - e.width, y: y)
    }

    /// Rutans ram i bildytan (för preflight: täcker den något viktigt?).
    public func frame(of o: Overlay) -> CGRect? {
        guard o.kind != .callout else { return nil }
        if o.kind == .video {
            // Helbild täcker allt med avsikt; bild-i-bild räknas med det som syns: videons
            // (beskurna) bild inpassad i ramen.
            guard !o.isFullFrame, let f = o.frame else { return nil }
            let box = CGRect(x: canvas.width * f.x, y: canvas.height * (1 - f.y - f.height),
                             width: canvas.width * f.width, height: canvas.height * f.height)
            guard let mediaDir, let size = Self.videoSize(mediaDir.appendingPathComponent(o.file)) else { return box }
            let c = o.crop ?? Rect(x: 0, y: 0, width: 1, height: 1)
            let w = size.width * c.width, h = size.height * c.height
            guard w > 0, h > 0 else { return box }
            let k = min(box.width / w, box.height / h)
            return CGRect(x: box.midX - w * k / 2, y: box.midY - h * k / 2, width: w * k, height: h * k)
        }
        let image = overlayImage(o)
        return CGRect(origin: placement(of: o, size: image.extent.size), size: image.extent.size)
    }

    // MARK: - Lupp

    /// Hur länge luppen växer fram och krymper bort i blockets ändar.
    static let lensRamp = 0.25

    /// Ett runt förstoringsglas vid markören under ett lupp-block: skärmen runt markören förstorad
    /// `scale` gånger i en cirkel (18 % av skärmytans höjd), med vit kant och skugga. Växer fram
    /// och krymper bort i ändarna.
    func lens(at s: Double, placed: CIImage) -> CIImage? {
        guard cursorPath.hasData,
              let z = project.zooms.first(where: { $0.style == .lens && s >= $0.start - Self.lensRamp && s <= $0.end + Self.lensRamp })
        else { return nil }
        let grow = min(1, max(0, (s - (z.start - Self.lensRamp)) / Self.lensRamp), max(0, ((z.end + Self.lensRamp) - s) / Self.lensRamp))
        let k = Self.easeOut(grow)
        guard k > 0.01 else { return nil }
        let radius = screenRect.height * 0.18 * k
        let magnification = 1 + (max(1.1, z.scale) - 1) * k
        let c = point(cursorPath.position(at: s))
        // Skärmen som den ligger i skärmytan (med maskerna), förstorad kring markören; bara det lilla
        // området som syns i luppen beskärs ut först.
        let r0 = radius / magnification + 2
        let source = placed.clampedToExtent().cropped(to: CGRect(x: c.x - r0, y: c.y - r0, width: r0 * 2, height: r0 * 2))
        let zoomed = source.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: magnification, y: magnification))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
        let disk = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
        let glass = zoomed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: Self.roundedRect(disk, radius: radius, color: .white),
        ]).cropped(to: disk)
        let border = max(2, radius * 0.035)
        let rim = Self.roundedRect(disk.insetBy(dx: -border, dy: -border), radius: radius + border, color: .white)
        let shadow = Self.roundedRect(disk.offsetBy(dx: 0, dy: -radius * 0.06), radius: radius,
                                      color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            .applyingGaussianBlur(sigma: radius * 0.12).cropped(to: disk.insetBy(dx: -radius * 0.5, dy: -radius * 0.5))
        return glass.composited(over: rim).composited(over: shadow)
    }

    // MARK: - Kameralayout per del

    struct LayoutFrame: Equatable {
        var screen: CGRect
        var camera: CGRect
        var cameraRadius: CGFloat
        var cameraAlpha: Double
        var screenAlpha: Double
        var shadow: Bool
    }

    /// Hur lång tid ett byte av layout mellan två delar tar (efter snittet).
    static let layoutChange = 0.5

    func frame(for layout: EditProject.CameraLayout) -> LayoutFrame {
        let full = CGRect(origin: .zero, size: canvas)
        let bubble = LayoutFrame(screen: screenRect, camera: cameraRect, cameraRadius: bubbleRadius,
                                 cameraAlpha: 1, screenAlpha: 1, shadow: true)
        switch layout {
        case .bubble: return bubble
        case .hidden:
            var f = bubble; f.cameraAlpha = 0; return f
        case .large:
            // Kameran fyller bilden; skärmen tonas bort bakom den.
            return LayoutFrame(screen: screenRect, camera: full, cameraRadius: 0, cameraAlpha: 1, screenAlpha: 0, shadow: false)
        case .split:
            let pad = (min(canvas.width, canvas.height) * 0.04).rounded()
            let area: CGRect, cam: CGRect
            if canvas.width >= canvas.height {
                let cw = ((canvas.width - 3 * pad) * 0.36).rounded()
                cam = CGRect(x: canvas.width - pad - cw, y: pad, width: cw, height: canvas.height - 2 * pad)
                area = CGRect(x: pad, y: pad, width: canvas.width - 3 * pad - cw, height: canvas.height - 2 * pad)
            } else {
                let chh = ((canvas.height - 3 * pad) * 0.4).rounded()
                cam = CGRect(x: pad, y: pad, width: canvas.width - 2 * pad, height: chh)
                area = CGRect(x: pad, y: 2 * pad + chh, width: canvas.width - 2 * pad, height: canvas.height - 3 * pad - chh)
            }
            let k = min(area.width / screenRect.width, area.height / screenRect.height)
            let size = CGSize(width: screenRect.width * k, height: screenRect.height * k)
            let screen = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
            return LayoutFrame(screen: screen, camera: cam, cameraRadius: min(cam.width, cam.height) * 0.06,
                               cameraAlpha: 1, screenAlpha: 1, shadow: true)
        }
    }

    /// Layouten vid utdatatiden `t`: delens, och de första 0,5 s efter ett snitt på väg från den
    /// förra delens.
    func layoutFrame(at t: Double) -> LayoutFrame {
        let pieces = timeMap.pieces
        guard hasCameraTrack, !segmentLayouts.isEmpty, segmentLayouts.count == pieces.count,
              let i = pieces.lastIndex(where: { $0.outputStart <= t }) ?? (pieces.isEmpty ? nil : 0) else {
            return frame(for: hasCameraTrack && project.camera.visible ? .bubble : .hidden)
        }
        let current = frame(for: segmentLayouts[i])
        guard i > 0, segmentLayouts[i - 1] != segmentLayouts[i] else { return current }
        let p = (t - pieces[i].outputStart) / Self.layoutChange
        guard p < 1 else { return current }
        let previous = frame(for: segmentLayouts[i - 1])
        let k = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(k) }
        func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
        }
        return LayoutFrame(screen: mix(previous.screen, current.screen), camera: mix(previous.camera, current.camera),
                           cameraRadius: mix(previous.cameraRadius, current.cameraRadius),
                           cameraAlpha: previous.cameraAlpha + (current.cameraAlpha - previous.cameraAlpha) * k,
                           screenAlpha: previous.screenAlpha + (current.screenAlpha - previous.screenAlpha) * k,
                           shadow: current.shadow || previous.shadow)
    }

    /// Hur skärmlagret flyttas och skalas av layouten (nil när det ligger som vanligt).
    func layoutTransform(at t: Double) -> CGAffineTransform? {
        let target = layoutFrame(at: t).screen
        guard target != screenRect, screenRect.width > 0 else { return nil }
        let k = target.width / screenRect.width
        return CGAffineTransform(translationX: -screenRect.midX, y: -screenRect.midY)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: target.midX, y: target.midY))
    }

    /// Videofilernas bildstorlek (med rotation), sparad per fil.
    private static let videoSizes = OSAllocatedUnfairLock(initialState: [URL: CGSize]())

    static func videoSize(_ url: URL) -> CGSize? {
        if let hit = videoSizes.withLock({ $0[url] }) { return hit }
        let asset = AVURLAsset(url: url)
        let box = SizeBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: natural).applying(transform)
                box.size = CGSize(width: abs(r.width), height: abs(r.height))
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        guard let size = box.size else { return nil }
        videoSizes.withLock { $0[url] = size }
        return size
    }
    private final class SizeBox: @unchecked Sendable { var size: CGSize? }

    /// Var personen är i en kamerabild (1 = person), i bildens egna koordinater, med mjuk kant.
    /// Apples personsegmentering på en nedskalad kopia (bubblan är liten); nil om den inte går.
    static func personMask(_ image: CIImage) -> CIImage? {
        let e = image.extent
        let k = min(1, 512 / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: small, options: [.ciContext: RenderContext.shared])
        guard (try? handler.perform([request])) != nil, let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        let me = mask.extent
        return mask
            .transformed(by: CGAffineTransform(scaleX: e.width / me.width, y: e.height / me.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .clampedToExtent().applyingGaussianBlur(sigma: max(1.5, e.width * 0.004)).cropped(to: e)
    }

    /// Slutaren öppen halva rutan, och oskärpans längsta sträcka i pixlar vid 1080p.
    static let shutter: Double = 0.5
    static let maxBlur: Double = 18

    /// Kamerans transform vid källtiden `s` (zoom och panorering), eller nil när den står i
    /// utgångsläget.
    func cameraTransform(at s: Double) -> CGAffineTransform? {
        let (zoom, raw) = cameraPath.viewport(at: s)
        guard zoom > 1.0005 || fills else { return nil }
        let p = point(coverageClamped(raw, zoom: zoom))
        return CGAffineTransform(translationX: -p.x, y: -p.y)
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
            .concatenating(CGAffineTransform(translationX: screenRect.midX, y: screenRect.midY))
    }

    /// Hur kameran rört sig den senaste 1/60 sekunden (utdatatid): förflyttningen av punkten mitt
    /// i skärmytan och zoomens förhållande. Nil i ett snitt (källtiden hoppar) eller utan rörelse.
    func cameraMotion(t: Double, s: Double) -> (shift: CGVector, zoomRatio: Double)? {
        let s0 = timeMap.source(at: max(0, t - 1.0 / 60))
        guard s0 < s, s - s0 < 0.1 else { return nil }
        let now = cameraTransform(at: s) ?? .identity, before = cameraTransform(at: s0) ?? .identity
        let c = CGPoint(x: screenRect.midX, y: screenRect.midY)
        let prev = c.applying(now.inverted()).applying(before)
        return (CGVector(dx: c.x - prev.x, dy: c.y - prev.y), Double(now.a / max(before.a, 0.0001)))
    }

    /// Rörelseoskärpa: längs panoreringen (`CIMotionBlur`) och ut från mitten vid zoom
    /// (`CIZoomBlur`), som en slutare öppen halva rutan (180° vid 60 bilder/s), med tak så att
    /// texten går att ana även i en snabb zoom. Ingenting när kameran står still.
    func motionBlurred(_ image: CIImage, t: Double, s: Double) -> CIImage {
        guard let motion = cameraMotion(t: t, s: s) else { return image }
        let extent = image.extent
        let unit = min(canvas.width, canvas.height) / 1080
        var out = image
        let length = min(Self.maxBlur * unit, hypot(motion.shift.dx, motion.shift.dy) * Self.shutter)
        if length > 0.75 {
            // Uppmätt: radien r ger ett streck på ~4,7 r (åt båda håll).
            out = out.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: length / 4.7, kCIInputAngleKey: atan2(motion.shift.dy, motion.shift.dx),
            ]).cropped(to: extent)
        }
        // Strecket i skärmytans hörn; CIZoomBlur drar ut en punkt ~0,023 × avståndet × mängden (uppmätt).
        let reach = hypot(screenRect.width, screenRect.height) / 2
        let radial = min(Self.maxBlur * unit, abs(motion.zoomRatio - 1) * reach * Self.shutter)
        if radial > 0.75 {
            out = out.applyingFilter("CIZoomBlur", parameters: [
                kCIInputCenterKey: CIVector(x: screenRect.midX, y: screenRect.midY), "inputAmount": radial / (0.023 * reach),
            ]).cropped(to: extent)
        }
        return out
    }

    /// Var en innehållsrektangel (0–1) syns i bildytan vid källtiden `s`, med zoomen.
    public func canvasRect(content r: CGRect, at s: Double) -> CGRect {
        let a = point(CGPoint(x: r.minX, y: r.minY)), b = point(CGPoint(x: r.maxX, y: r.maxY))
        var rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let (zoom, raw) = cameraPath.viewport(at: s)
        if zoom > 1.0005 || fills {
            let c = point(coverageClamped(raw, zoom: zoom))
            rect = rect.applying(CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                .concatenating(CGAffineTransform(translationX: screenRect.midX, y: screenRect.midY)))
        }
        if let t = timeMap.output(at: s), let move = layoutTransform(at: t) { rect = rect.applying(move) }
        return rect
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(max(x, 0), 1), 3) }

    static func sameCorner(_ a: Overlay.Corner, _ b: EditProject.CameraStyle.Corner) -> Bool {
        switch (a, b) {
        case (.topLeft, .topLeft), (.topRight, .topRight), (.bottomLeft, .bottomLeft), (.bottomRight, .bottomRight): true
        default: false
        }
    }

    /// Undertextens radhöjd i pixlar.
    static func captionFontSize(canvas: CGSize, size: Double) -> CGFloat {
        (min(canvas.width, canvas.height) * 0.042 * size).rounded()
    }

    /// Höjden två rader undertext tar, för att lägga annat ovanför.
    static func captionReserve(canvas: CGSize, size: Double) -> CGFloat {
        captionFontSize(canvas: canvas, size: size) * 2.9
    }

    /// En undertext: vit text på en mörk, rundad platta, en eller två rader, centrerade.
    static func makeCaption(_ text: String, canvas: CGSize, size: Double) -> CIImage {
        let fontSize = captionFontSize(canvas: canvas, size: size)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let lines = text.split(separator: "\n").map { line in
            CTLineCreateWithAttributedString(NSAttributedString(string: String(line), attributes: [
                .font: font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]))
        }
        guard !lines.isEmpty else { return CIImage.empty() }
        let widths = lines.map { CTLineGetBoundsWithOptions($0, .useOpticalBounds).width }
        let lineHeight = (fontSize * 1.28).rounded()
        let padX = (fontSize * 0.6).rounded(), padY = (fontSize * 0.38).rounded()
        let width = (min(widths.max() ?? 0, canvas.width * 0.9) + padX * 2).rounded(.up)
        let height = lineHeight * CGFloat(lines.count) + padY * 2
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        let radius = fontSize * 0.35
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.62))
        ctx.fillPath()
        let descent = -font.descender
        for (i, line) in lines.enumerated() {
            // Första raden överst.
            let baseline = height - padY - lineHeight * CGFloat(i + 1) + (lineHeight - fontSize) / 2 + descent
            ctx.textPosition = CGPoint(x: ((width - widths[i]) / 2).rounded(), y: baseline.rounded())
            CTLineDraw(line, ctx)
        }
        guard let img = ctx.makeImage() else { return CIImage.empty() }
        let ci = CIImage(cgImage: img)
        return prerender(ci, extent: ci.extent)
    }

    static func arrowSprite() -> Sprite {
        let cursor = NSCursor.arrow
        var rect = NSRect(origin: .zero, size: NSSize(width: cursor.image.size.width * 2, height: cursor.image.size.height * 2))
        let cg = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        let image = cg.map { CIImage(cgImage: $0) }.map { prerender($0, extent: $0.extent) } ?? CIImage.empty()
        return Sprite(image: image, size: cursor.image.size, hotSpot: cursor.hotSpot)
    }
}

/// Undertexterna ritas när de behövs och sparas, eftersom en lång inspelning kan ha hundratals.
/// Kompositören ritar rutor parallellt, därav låset.
final class CaptionImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: CIImage] = [:]
    private var order: [String] = []
    static let capacity = 12

    func image(for text: String, make: () -> CIImage) -> CIImage {
        lock.lock()
        if let hit = images[text] { lock.unlock(); return hit }
        lock.unlock()
        let made = make()
        lock.lock()
        images[text] = made
        order.append(text)
        if order.count > Self.capacity { images[order.removeFirst()] = nil }
        lock.unlock()
        return made
    }
}
