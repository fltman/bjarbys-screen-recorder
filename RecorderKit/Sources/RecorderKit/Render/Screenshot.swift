import Foundation
import AppKit
import CoreImage
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Polerade skärmdumpar: ett fönster, en skärm eller ett område på samma bakgrund, med samma
/// marginal, hörn och skugga som filmerna. Ett fönster tas utan systemets skugga och med sina
/// egna rundade hörn (genomskinliga), så att vår skugga följer formen.
public enum Screenshot {
    public struct Style: Sendable, Equatable {
        public var background: EditProject.Background
        /// Marginal som andel av bildens kortaste sida.
        public var padding: Double
        /// Hörnradie som andel av kortaste sidan (0 för fönster: de har egna hörn).
        public var cornerRadius: Double
        public var shadow: Double

        public init(background: EditProject.Background = .default, padding: Double = 0.08,
                    cornerRadius: Double = 0.012, shadow: Double = 0.6) {
            self.background = background; self.padding = padding; self.cornerRadius = cornerRadius; self.shadow = shadow
        }

        public init(project: EditProject) {
            self.init(background: project.background, padding: project.padding,
                      cornerRadius: project.cornerRadius, shadow: project.shadow)
        }
    }

    // MARK: - Ta bilden

    /// Ett fönster utan systemets skugga, i full upplösning.
    public static func capture(window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        config.capturesShadowsOnly = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Det som valts i systemets väljare (ett fönster tas utan systemets skugga).
    public static func capture(filter: SCContentFilter) async throws -> CGImage {
        let config = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// En skärm (eller ett område på den, i skärmens punkter), utan markör och utan appens egna fönster.
    public static func capture(display: SCDisplay, area: CGRect? = nil, excluding apps: [SCRunningApplication] = []) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        if let area {
            config.sourceRect = area
            config.width = Int(area.width * scale)
            config.height = Int(area.height * scale)
        } else {
            config.width = Int(Double(display.width) * scale)
            config.height = Int(Double(display.height) * scale)
        }
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Polera

    /// Bilden på bakgrunden. `isWindow`: bilden har egna (genomskinliga) hörn och ska inte rundas.
    public static func polish(_ image: CGImage, style: Style, isWindow: Bool) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pad = (min(w, h) * style.padding).rounded()
        let canvas = CGSize(width: w + 2 * pad, height: h + 2 * pad)
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let rect = CGRect(x: pad, y: pad, width: w, height: h)

        var shot = CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: pad, y: pad))
        if !isWindow && style.cornerRadius > 0 {
            let mask = RenderPlan.roundedRect(rect, radius: style.cornerRadius * min(w, h), color: .white)
            shot = shot.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                       kCIInputMaskImageKey: mask])
        }
        var out = RenderPlan.makeBackground(style.background.kind == .blur ? .default : style.background, canvas: canvas)
            ?? CIImage(color: .white).cropped(to: canvasRect)
        if style.shadow > 0.01 && pad > 2 {
            // Skuggan efter bildens egen form (alfa), förskjuten nedåt och suddig.
            let silhouette = shot.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.7 * style.shadow)])
            let blur = max(6, min(w, h) * 0.03)
            let shadow = silhouette.transformed(by: CGAffineTransform(translationX: 0, y: -min(w, h) * 0.015))
                .clampedToExtent().cropped(to: rect.insetBy(dx: -blur * 3, dy: -blur * 3))
                .applyingGaussianBlur(sigma: blur).cropped(to: canvasRect)
            out = shadow.composited(over: out)
        }
        out = shot.composited(over: out).cropped(to: canvasRect)
        return RenderContext.shared.createCGImage(out, from: canvasRect, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// PNG till fil.
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Mappen där skärmdumparna sparas.
    public static var directory: URL { RecordingLibrary.defaultDirectory.appendingPathComponent("Skärmdumpar", isDirectory: true) }

    public static func newURL(name: String) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "sv_SE")
        f.dateFormat = "yyyy-MM-dd 'kl.' HH.mm.ss"
        let safe = name.replacingOccurrences(of: "/", with: "-").prefix(60)
        return directory.appendingPathComponent("\(safe) \(f.string(from: Date())).png")
    }
}
