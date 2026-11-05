import Testing
import Foundation
import CoreImage
@testable import RecorderKit

@Suite struct CaptionFitTests {
    /// Starkast vitt (rött kanalvärde 0–1) i de yttersta kolumnerna: vit text som klipps i
    /// kanten syns där; plattan, konturen och skuggan är mörka.
    func whiteAtEdges(_ image: CIImage, columns: Int = 6) -> (left: Double, right: Double, width: Int) {
        let r = image.extent.integral
        guard let cg = CIContext().createCGImage(image, from: r) else { return (1, 1, 0) }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let bm = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bm.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func red(_ xs: Range<Int>) -> Double {
            var m = 0.0
            for x in xs { for y in 0..<h { m = max(m, Double(px[(y * w + x) * 4]) / 255) } }
            return m
        }
        return (red(0..<columns), red((w - columns)..<w), w)
    }

    @Test(arguments: [EditProject.CaptionStyle.Look.outline, .box])
    func fullLinesFitASquareFrame(look: EditProject.CaptionStyle.Look) {
        let canvas = CGSize(width: 1080, height: 1080)
        // Två fulla rader (upp till 42 tecken), som Captions bryter dem.
        let text = "Hej och välkommen! I den här filmen visar\njag hur man exporterar en inspelning med"
        let e = whiteAtEdges(RenderPlan.makeCaption(text, canvas: canvas, size: 1, look: look))
        #expect(Double(e.width) <= canvas.width * 0.9 + 1)
        #expect(e.left < 0.5 && e.right < 0.5, "vitt i kanterna: \(e.left), \(e.right)")
    }

    @Test func wideFramesKeepTheirSize() {
        // I 16:9 ryms raderna: storleken ska inte ändras där.
        let wide = RenderPlan.makeCaption("Hej och välkommen! I den här filmen visar", canvas: CGSize(width: 1920, height: 1080),
                                          size: 1, look: .outline)
        let font = RenderPlan.captionFontSize(canvas: CGSize(width: 1920, height: 1080), size: 1) * 1.15
        #expect(wide.extent.height > font * 1.28)
    }
}
