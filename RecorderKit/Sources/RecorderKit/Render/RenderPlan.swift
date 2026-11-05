import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

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
    /// Inspelningen fyller bildytan (Reel-läge) i stället för att ligga med marginal.
    let fills: Bool
    public let shortcuts: ShortcutTrack?
    /// Kortkommandobubblorna, ritade i förväg i bildytans pixlar, per text.
    let shortcutPills: [String: CIImage]

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
                cursors: CursorCatalog, cursorsDir: URL, hasCamera: Bool,
                cursorPath: CursorPath? = nil, cameraPath: CameraPath? = nil) {
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
        self.cameraPath = cameraPath ?? CameraPath(zooms: project.zooms, cursor: cursorPath, duration: meta.duration,
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

        // Kamerabubblan är fast i bildytan; den zoomar inte med skärmen.
        if hasCamera && project.camera.visible {
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
        }

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
    public func render(outputTime t: Double, screen: CIImage?, camera: CIImage?) -> CIImage {
        let s = timeMap.source(at: t)
        let canvasRect = CGRect(origin: .zero, size: canvas)
        var layer = CIImage.empty()

        if let screen {
            let e = screen.extent
            let scaled = screen
                .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: screenRect.width / e.width, y: screenRect.height / e.height))
                .transformed(by: CGAffineTransform(translationX: screenRect.minX, y: screenRect.minY))
            layer = scaled.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask,
            ])
        }

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

        if let shadow { layer = layer.composited(over: shadow) }

        // Zoomen: punkten `center` i innehållet hamnar mitt i skärmytan, förstorad `zoom` gånger.
        let (zoom, rawCenter) = cameraPath.viewport(at: s)
        let center = coverageClamped(rawCenter, zoom: zoom)
        if zoom > 1.0005 || fills {
            let p = point(center)
            let transform = CGAffineTransform(translationX: -p.x, y: -p.y)
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                .concatenating(CGAffineTransform(translationX: screenRect.midX, y: screenRect.midY))
            layer = layer.transformed(by: transform)
        }

        var out = layer.composited(over: backgroundImage(screen: screen))

        if let camera, let cameraMask {
            let e = camera.extent
            let side = min(e.width, e.height)
            var cam = camera.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
                .transformed(by: CGAffineTransform(translationX: -(e.midX - side / 2), y: -(e.midY - side / 2)))
            if project.camera.mirror {
                cam = cam.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -side, y: 0))
            }
            cam = cam.transformed(by: CGAffineTransform(scaleX: cameraRect.width / side, y: cameraRect.height / side))
                .transformed(by: CGAffineTransform(translationX: cameraRect.minX, y: cameraRect.minY))
            let bubble = cam.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: cameraMask,
            ])
            if let cameraShadow { out = cameraShadow.composited(over: out) }
            out = bubble.composited(over: out)
        }

        // Kortkommandot ligger fast i bildytan, ovanpå allt, och glider upp när det dyker upp.
        if let shortcuts, let shown = shortcuts.visible(at: t), let pill = shortcutPills[shown.text],
           shown.opacity > 0.01 {
            let e = pill.extent
            let margin = (min(canvas.width, canvas.height) * 0.055).rounded()
            let rise = (1 - shown.entrance) * e.height * 0.3
            let y = project.shortcuts.position == .bottom ? margin - rise : canvas.height - margin - e.height + rise
            let placed = pill.transformed(by: CGAffineTransform(translationX: ((canvas.width - e.width) / 2).rounded() - e.minX,
                                                                y: y - e.minY))
            out = Self.withAlpha(placed, shown.opacity).composited(over: out)
        }
        return out.cropped(to: canvasRect)
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

    static func arrowSprite() -> Sprite {
        let cursor = NSCursor.arrow
        var rect = NSRect(origin: .zero, size: NSSize(width: cursor.image.size.width * 2, height: cursor.image.size.height * 2))
        let cg = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        let image = cg.map { CIImage(cgImage: $0) }.map { prerender($0, extent: $0.extent) } ?? CIImage.empty()
        return Sprite(image: image, size: cursor.image.size, hotSpot: cursor.hotSpot)
    }
}
