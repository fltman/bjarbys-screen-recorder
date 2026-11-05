import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import RecorderKit

@Suite struct WatermarkTests {
    /// En 400×160 PNG i en tillfällig fil.
    func logo() throws -> URL {
        let ctx = CGContext(data: nil, width: 400, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 160))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("logo-\(UUID().uuidString).png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        return url
    }

    @Test func sitsInItsCornerWithAMargin() throws {
        let url = try logo(); defer { try? FileManager.default.removeItem(at: url) }
        let w = EditProject.Watermark(visible: true, file: url.path, corner: .topRight, size: 0.1, opacity: 1)
        let image = try #require(RenderPlan.makeWatermark(w, canvas: CGSize(width: 1920, height: 1080), avoid: nil))
        // Höjd 108 (10 % av 1080), bredd 270, marginal 38.
        #expect(image.extent == CGRect(x: 1612, y: 934, width: 270, height: 108))
    }

    @Test func movesBesideTheCameraInTheSameCorner() throws {
        let url = try logo(); defer { try? FileManager.default.removeItem(at: url) }
        let w = EditProject.Watermark(visible: true, file: url.path, corner: .bottomLeft, size: 0.1, opacity: 1)
        let image = try #require(RenderPlan.makeWatermark(w, canvas: CGSize(width: 1920, height: 1080), avoid: (.bottomLeft, 259)))
        #expect(image.extent.minX > 259 + 38)
        #expect(RenderPlan.makeWatermark(w, canvas: CGSize(width: 1920, height: 1080), avoid: (.topLeft, 259))?.extent.minX == 38)
    }

    @Test func hiddenOrMissingGivesNothing() throws {
        #expect(RenderPlan.makeWatermark(.init(visible: false, file: "/finns/inte.png"), canvas: CGSize(width: 100, height: 100), avoid: nil) == nil)
        #expect(RenderPlan.makeWatermark(.init(visible: true, file: "/finns/inte.png"), canvas: CGSize(width: 100, height: 100), avoid: nil) == nil)
        let w = try BundleJSON.decoder.decode(EditProject.Watermark.self, from: Data("{}".utf8))
        #expect(!w.visible && w.file.isEmpty && w.corner == .topRight)
    }
}
