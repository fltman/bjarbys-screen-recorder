import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Ritar bildlagrets kort. Allt ritas med CoreText i exakt de pixlar det visas i (skarp text)
/// och läggs i IOSurface-backade buffertar (laddas upp till GPU:n en gång).
enum OverlayRenderer {
    /// Markeringens färg: indigo, samma som appens accent och standardbakgrunden.
    static let highlight = CGColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 1)

    struct Row { let text: String; let font: NSFont; let color: CGColor }

    /// Ett kort med rader text, radbrutna inom `maxWidth`. `accent`: en färgad list till vänster.
    static func card(_ rows: [Row], maxWidth: CGFloat, padding: CGFloat, radius: CGFloat,
                     background: CGColor, accent: CGColor? = nil, center: Bool = false) -> CIImage {
        let bar: CGFloat = accent == nil ? 0 : max(4, padding * 0.28)
        let textWidth = maxWidth - padding * 2 - bar
        // Varje rad som en CTFrame inom bredden; höjden mäts först.
        var frames: [(CTFramesetter, CGSize, NSAttributedString)] = []
        for row in rows where !row.text.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = center ? .center : .left
            style.lineSpacing = row.font.pointSize * 0.15
            let attributed = NSAttributedString(string: row.text, attributes: [
                .font: row.font, .foregroundColor: row.color, .paragraphStyle: style])
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                                     CGSize(width: textWidth, height: .greatestFiniteMagnitude), nil)
            frames.append((setter, CGSize(width: ceil(size.width), height: ceil(size.height)), attributed))
        }
        guard !frames.isEmpty else { return CIImage.empty() }
        let gap = padding * 0.35
        // Kortet följer texten (även centrerad), upp till största bredden.
        let contentW = min(textWidth, frames.map(\.1.width).max() ?? 0)
        let width = (contentW + padding * 2 + bar).rounded(.up)
        let height = (frames.map(\.1.height).reduce(0, +) + gap * CGFloat(frames.count - 1) + padding * 2).rounded(.up)
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(background)
        ctx.fillPath()
        if let accent {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            ctx.setFillColor(accent)
            ctx.fill(CGRect(x: 0, y: 0, width: bar, height: height))
            ctx.restoreGState()
        }
        var y = height - padding
        for (setter, size, _) in frames {
            y -= size.height
            let path = CGPath(rect: CGRect(x: padding + bar, y: y, width: contentW, height: size.height), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), ctx)
            y -= gap
        }
        guard let img = ctx.makeImage() else { return CIImage.empty() }
        let ci = CIImage(cgImage: img)
        return RenderPlan.prerender(ci, extent: ci.extent)
    }

    static func unit(_ canvas: CGSize) -> CGFloat { min(canvas.width, canvas.height) }

    /// Rubrikkort mitt i bilden: stor rubrik, valfri underrad.
    static func title(_ o: Overlay, canvas: CGSize) -> CIImage {
        let u = unit(canvas)
        var rows = [Row(text: o.title, font: .systemFont(ofSize: u * 0.075, weight: .bold), color: .white)]
        if let sub = o.lines.first { rows.append(Row(text: sub, font: .systemFont(ofSize: u * 0.034, weight: .medium),
                                                     color: CGColor(gray: 1, alpha: 0.82))) }
        return card(rows, maxWidth: canvas.width * 0.7, padding: u * 0.05, radius: u * 0.03,
                    background: CGColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 0.82), center: true)
    }

    /// Faktaruta: rubrik och upp till tre rader, med en indigo list.
    static func fact(_ o: Overlay, canvas: CGSize) -> CIImage {
        let u = unit(canvas)
        var rows = [Row(text: o.title, font: .systemFont(ofSize: u * 0.032, weight: .semibold), color: .white)]
        for line in o.lines.prefix(3) {
            rows.append(Row(text: line, font: .systemFont(ofSize: u * 0.025, weight: .regular), color: CGColor(gray: 1, alpha: 0.85)))
        }
        return card(rows, maxWidth: max(u * 0.55, canvas.width * 0.32), padding: u * 0.025, radius: u * 0.018,
                    background: CGColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 0.8), accent: highlight)
    }

    /// QR-kort: vit ruta med koden, rubrik och adress under.
    static func qr(_ o: Overlay, canvas: CGSize) -> CIImage {
        let u = unit(canvas)
        let side = (u * 0.2).rounded()
        let pad = (u * 0.018).rounded()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(o.url.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return CIImage.empty() }
        // Hela moduler, ingen utjämning: skarp kod som går att skanna även efter komprimering.
        let scale = (side / code.extent.width).rounded(.down)
        let crisp = code.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let qrSide = crisp.extent.width
        let label = o.title.isEmpty ? o.url : o.title
        let caption = card([Row(text: label, font: .systemFont(ofSize: u * 0.022, weight: .semibold), color: CGColor(gray: 0.1, alpha: 1))]
                           + (o.lines.first.map { [Row(text: $0, font: .systemFont(ofSize: u * 0.017), color: CGColor(gray: 0.35, alpha: 1))] } ?? []),
                           maxWidth: qrSide + pad * 2, padding: pad * 0.6, radius: 0, background: CGColor(gray: 1, alpha: 1), center: true)
        let width = qrSide + pad * 2
        let height = qrSide + pad + caption.extent.height
        let box = RenderPlan.roundedRect(CGRect(x: 0, y: 0, width: width, height: height), radius: u * 0.016,
                                         color: CIColor(red: 1, green: 1, blue: 1))
        let placedCode = crisp.transformed(by: CGAffineTransform(translationX: pad, y: caption.extent.height))
        let placedCaption = caption.transformed(by: CGAffineTransform(translationX: (width - caption.extent.width) / 2, y: 0))
        let composed = placedCode.composited(over: placedCaption.composited(over: box))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return RenderPlan.prerender(composed, extent: composed.extent)
    }

    /// Fri text: på en mörk platta, eller skuggad direkt på bilden.
    static func text(_ o: Overlay, canvas: CGSize) -> CIImage {
        let u = unit(canvas)
        let maxWidth = canvas.width * CGFloat(min(max(o.frame?.width ?? 0.6, 0.1), 0.95))
        let font = NSFont.systemFont(ofSize: u * 0.045 * o.size, weight: .bold)
        if o.background {
            return card([Row(text: o.title, font: font, color: .white)], maxWidth: maxWidth, padding: u * 0.022 * o.size,
                        radius: u * 0.016, background: CGColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 0.75), center: true)
        }
        // Utan platta: vit text med mjuk skugga, så att den syns mot både ljust och mörkt.
        let plain = card([Row(text: o.title, font: font, color: .white)], maxWidth: maxWidth, padding: u * 0.02,
                         radius: 0, background: CGColor(gray: 0, alpha: 0), center: true)
        let shadow = plain.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.75)])
            .applyingGaussianBlur(sigma: u * 0.006).transformed(by: CGAffineTransform(translationX: 0, y: -u * 0.003))
        let composed = plain.composited(over: shadow).cropped(to: plain.extent)
        return RenderPlan.prerender(composed, extent: composed.extent)
    }

    /// En bild ur media/, inpassad i sin ram (bibehållna proportioner), med rundade hörn och skugga.
    static func image(_ o: Overlay, mediaDir: URL?, canvas: CGSize) -> CIImage {
        guard let dir = mediaDir, let source = CIImage(contentsOf: dir.appendingPathComponent(o.file)),
              let f = o.frame else { return CIImage.empty() }
        let box = CGSize(width: canvas.width * f.width, height: canvas.height * f.height)
        let k = min(box.width / source.extent.width, box.height / source.extent.height)
        let size = CGSize(width: (source.extent.width * k).rounded(), height: (source.extent.height * k).rounded())
        let scaled = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        let u = unit(canvas)
        let rect = CGRect(origin: .zero, size: size)
        let radius = min(size.width, size.height) * 0.06
        let masked = scaled.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: RenderPlan.roundedRect(rect, radius: radius, color: .white)])
        let pad = u * 0.03
        // Skuggan efter bildens egen form (alfa): en PNG med genomskinlig marginal får annars
        // en grå fyrkant bakom sig.
        let shadow = masked.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.45)])
            .transformed(by: CGAffineTransform(translationX: 0, y: -u * 0.006))
            .applyingGaussianBlur(sigma: u * 0.012)
        let composed = masked.composited(over: shadow).cropped(to: rect.insetBy(dx: -pad, dy: -pad))
            .transformed(by: CGAffineTransform(translationX: pad, y: pad))
        return RenderPlan.prerender(composed, extent: composed.extent)
    }

    /// Etiketten till en markering.
    static func calloutLabel(_ text: String, canvas: CGSize) -> CIImage {
        let u = unit(canvas)
        return card([Row(text: text, font: .systemFont(ofSize: u * 0.026, weight: .semibold), color: .white)],
                    maxWidth: canvas.width * 0.5, padding: u * 0.014, radius: u * 0.014, background: highlight)
    }

    /// Kapitelraden: "2/5 · Exportera".
    static func chapterBanner(_ title: String, number: Int, of total: Int, canvas: CGSize) -> CIImage {
        let u = unit(canvas)
        return card([Row(text: "\(number)/\(total)  ·  \(title)", font: .systemFont(ofSize: u * 0.024, weight: .semibold), color: .white)],
                    maxWidth: canvas.width * 0.6, padding: u * 0.016, radius: u * 0.022,
                    background: CGColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 0.72), accent: highlight)
    }

    /// Markeringens ram runt målet (i bildytans koordinater), vit utanför och indigo innanför.
    static func calloutFrame(_ rect: CGRect, canvas: CGSize) -> CIImage {
        let u = unit(canvas)
        let radius = min(rect.height * 0.3, u * 0.02)
        func stroke(_ r: CGRect, width: CGFloat, color: CIColor) -> CIImage {
            let f = CIFilter.roundedRectangleStrokeGenerator()
            f.extent = r
            f.radius = Float(radius)
            f.width = Float(width)
            f.color = color
            return f.outputImage ?? CIImage.empty()
        }
        let w = max(3, u * 0.005)
        let outer = stroke(rect.insetBy(dx: -w * 0.6, dy: -w * 0.6), width: w * 2.2, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        let inner = stroke(rect, width: w, color: CIColor(cgColor: highlight))
        let fill = RenderPlan.roundedRect(rect, radius: radius, color: CIColor(red: 0.388, green: 0.4, blue: 0.945, alpha: 0.10))
        return inner.composited(over: outer.composited(over: fill))
    }
}
