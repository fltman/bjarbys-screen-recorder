import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Finder och Quick Look läser en `QuickLook/`-mapp i ett dokumentpaket, utan något tillägg
/// (uppmätt med `qlmanage` på macOS 26): `Thumbnail.png` blir ikonen och `Preview.mov` det som
/// spelas med mellanslag. Förhandsvisningen är en symbolisk länk till skärmspåret — ingen extra
/// diskplats; den saknar markör och ljud (det är rådata), men visar vad inspelningen är.
extension RecordingBundle {
    public var quickLookDir: URL { url.appendingPathComponent("QuickLook", isDirectory: true) }

    /// Skriver (eller skriver om) Quick Look-mappen ur miniatyren och skärmspåret.
    public func writeQuickLook() {
        let fm = FileManager.default
        try? fm.createDirectory(at: quickLookDir, withIntermediateDirectories: true)
        if let source = CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let dest = CGImageDestinationCreateWithURL(quickLookDir.appendingPathComponent("Thumbnail.png") as CFURL,
                                                      UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        let preview = quickLookDir.appendingPathComponent("Preview.mov")
        try? fm.removeItem(at: preview)
        if fm.fileExists(atPath: trackURL(.screen).path) {
            // Relativ länk, så att paketet kan flyttas.
            try? fm.createSymbolicLink(atPath: preview.path, withDestinationPath: "../recording/" + Self.fileName(for: .screen))
        }
    }

    /// Sant om paketet saknar Quick Look-mappen (äldre inspelningar).
    public var needsQuickLook: Bool {
        !FileManager.default.fileExists(atPath: quickLookDir.appendingPathComponent("Thumbnail.png").path)
            && FileManager.default.fileExists(atPath: thumbnailURL.path)
    }
}
