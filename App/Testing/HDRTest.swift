import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import QuartzCore
import RecorderKit

/// `--prov-hdr <mapp>`: HDR hela vägen, mätt på något som verkligen är HDR.
///
/// Ett eget fönster visar tre fält: grått (0,2 linjärt, för att se att mellantonerna inte
/// lyfts), SDR-vitt (1,0) och HDR-vitt (4 × SDR, med Core Animations EDR). Huvudskärmen spelas in i HDR i 2 s med fönstret synligt, och sedan
/// mäts fälten i inspelningen (PQ), i exporten "MP4 4K HDR" (HLG) och i "MP4 1080p" (SDR).
/// Paket och filer raderas efteråt.
@MainActor
enum HDRTest {
    static func run(out: URL) async -> Int32 {
        guard CGPreflightScreenCaptureAccess() else { print(#"{"fel":"Behörighet för skärminspelning saknas."}"#); return 2 }
        guard AppSettings.hdrAvailable else { print(#"{"fel":"Ingen HDR-skärm."}"#); return 3 }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String: Any] = [:]
        guard let screen = NSScreen.main else { return 3 }
        let frame = NSRect(x: screen.frame.minX + 160, y: screen.frame.maxY - 520, width: 640, height: 320)
        let window = makeWindow(frame: frame)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        report["edr_huvudrum_fore"] = screen.maximumExtendedDynamicRangeColorComponentValue
        try? await Task.sleep(for: .seconds(1.2))
        report["edr_huvudrum"] = screen.maximumExtendedDynamicRangeColorComponentValue

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw err("ingen skärm") }
            var options = CaptureOptions()
            options.systemAudio = false
            options.hdr = true
            let session = try CaptureSession(target: CaptureTarget.display(display, in: content, includingOwnApp: true),
                                             options: options, directory: out)
            try await session.start()
            try await Task.sleep(for: .seconds(2))
            let meta = await session.stop()
            window.orderOut(nil)
            defer { try? FileManager.default.removeItem(at: session.bundle.url) }

            // Fältens mitt i skärmspårets pixlar (origo uppe till vänster).
            let scale = screen.backingScaleFactor
            func pixel(_ x: CGFloat) -> CGPoint {
                CGPoint(x: (x - screen.frame.minX) * scale, y: (screen.frame.maxY - frame.midY) * scale)
            }
            let points = [("gra", pixel(frame.minX + frame.width / 6)), ("vit", pixel(frame.minX + frame.width / 2)),
                          ("hdr", pixel(frame.minX + frame.width * 5 / 6))]
            let source = CGSize(width: meta.source.pixelWidth, height: meta.source.pixelHeight)

            let raw = session.bundle.trackURL(.screen)
            if let px = try await readFrame(raw, at: 1.0, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
                var r: [String: Any] = ["fargegenskaper": attachments(px)]
                for (name, p) in points { r["nits_\(name)"] = pqNits(signal(luma10(px, at: p))) }
                report["inspelning"] = r
            }

            try await measureExports(session.bundle, points: points, source: source, out: out, into: &report)
        } catch {
            report["fel"] = error.localizedDescription
        }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
        return report["fel"] == nil ? 0 : 1
    }

    /// Exporterar paketet som "MP4 4K HDR" och "MP4 1080p" — bara skärmen, utan marginal, hörn,
    /// skugga, zoom och markör, så att fälten hamnar på samma ställe skalat — och mäter fälten.
    static func measureExports(_ bundle: RecordingBundle, points: [(String, CGPoint)], source: CGSize, out: URL,
                               into report: inout [String: Any]) async throws {
        let rec = try LoadedRecording.load(bundle)
        var project = rec.bundle.loadProject(duration: rec.meta.duration)
        project.padding = 0; project.cornerRadius = 0; project.shadow = 0
        project.aspect = .source; project.autoZoom = false; project.zooms = []
        project.cursor.visible = false
        for (id, format) in [("mp4-4k-hdr", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange), ("mp4-1080", kCVPixelFormatType_32BGRA)] {
            guard let preset = ExportPreset.all.first(where: { $0.id == id }) else { continue }
            let url = out.appendingPathComponent("hdr-prov-\(id).mp4")
            try await Exporter(recording: rec, project: project, preset: preset).run(to: url) { _ in }
            defer { try? FileManager.default.removeItem(at: url) }
            guard let px = try await readFrame(url, at: 1.0, format: format) else { continue }
            let canvas = CGSize(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
            func mapped(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * canvas.width / source.width, y: p.y * canvas.height / source.height)
            }
            var r: [String: Any] = ["fargegenskaper": attachments(px)]
            for (name, p) in points {
                if format == kCVPixelFormatType_32BGRA { r["rgb_\(name)"] = bgra(px, at: mapped(p)) }
                else { r["hlg_\(name)"] = signal(luma10(px, at: mapped(p))) }
            }
            report[id] = r
        }
    }

    /// `--prov-hdr-syntetisk <mapp>`: samma mätning utan skärm, på ett påhittat HDR-paket — en
    /// HEVC Main10-fil i BT.2020 PQ med tre band: 20 nits (grått), 100 nits (SDR-vitt som
    /// ScreenCaptureKit lägger det) och 400 nits (4 × SDR-vitt).
    static func synthetic(out: URL) async -> Int32 {
        var report: [String: Any] = [:]
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let bundle = try RecordingBundle.create(in: out)
            defer { try? FileManager.default.removeItem(at: bundle.url) }
            let (w, h) = (960, 540)
            let writer = try TrackWriter(kind: .screen, url: bundle.trackURL(.screen), settings: .screen(width: w, height: h, fps: 30, hdr: true))
            let bands = [20.0, 100, 400]
            for i in 0..<60 {
                guard let px = pqFrame(width: w, height: h, nits: bands),
                      let sb = sampleBuffer(px, at: CMTime(value: CMTimeValue(i), timescale: 30)) else { throw err("ruta") }
                writer.append(sb, at: CMTime(value: CMTimeValue(i), timescale: 30))
            }
            _ = await writer.finish()
            var meta = RecordingMeta(source: .init(kind: .display, title: "syntetisk", displayID: 0, windowID: nil,
                                                   contentRect: Rect(x: 0, y: 0, width: 480, height: 270), pixelScale: 2,
                                                   pixelWidth: w, pixelHeight: h), fps: 30, appVersion: "prov")
            meta.tracks = [.init(kind: .screen, file: RecordingBundle.fileName(for: .screen))]
            meta.duration = 2; meta.finished = true; meta.hdr = true
            try bundle.writeMeta(meta)
            let points = [("gra", CGPoint(x: w / 6, y: h / 2)), ("vit", CGPoint(x: w / 2, y: h / 2)), ("hdr", CGPoint(x: w * 5 / 6, y: h / 2))]
            if let px = try await readFrame(bundle.trackURL(.screen), at: 1.0, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
                var r: [String: Any] = ["fargegenskaper": attachments(px)]
                for (name, p) in points { r["nits_\(name)"] = pqNits(signal(luma10(px, at: p))) }
                report["inspelning"] = r
            }
            try await measureExports(bundle, points: points, source: CGSize(width: w, height: h), out: out, into: &report)
            // Miniatyren i biblioteket, och generatorns egen omvandling till SDR som jämförelse.
            await CaptureSession.makeThumbnail(for: bundle, at: 1)
            if let src = CGImageSourceCreateWithURL(bundle.thumbnailURL as CFURL, nil),
               let thumb = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let k = Double(thumb.width) / Double(w)
                report["miniatyr"] = points.map { "\($0.0) \(gray(thumb, at: CGPoint(x: $0.1.x * k, y: $0.1.y * k)))" }
            }
            let plain = AVAssetImageGenerator(asset: AVURLAsset(url: bundle.trackURL(.screen)))
            if let (img, _) = try? await plain.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
                report["generatorns_sdr"] = points.map { "\($0.0) \(gray(img, at: $0.1))" }
            }
        } catch {
            report["fel"] = error.localizedDescription
        }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
        return report["fel"] == nil ? 0 : 1
    }

    /// Grönt i en CGImage, ritad till 8-bitars sRGB.
    private static func gray(_ image: CGImage, at p: CGPoint) -> Int {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(image, in: CGRect(x: -p.x, y: -(CGFloat(image.height) - p.y), width: CGFloat(image.width), height: CGFloat(image.height)))
        return Int(px[1])
    }

    /// En x420-ruta i BT.2020 PQ med lodräta band, ett per ljusnivå (neutralt grått: Cb = Cr = 512).
    private static func pqFrame(width: Int, height: Int, nits: [Double]) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt16.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / 2
        for row in 0..<height { for col in 0..<width {
            let e = pqSignal(nits[min(nits.count - 1, col * nits.count / width)])
            y[row * yRow + col] = UInt16((64 + e * 876).rounded()) << 6
        } }
        let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt16.self)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) / 2
        for row in 0..<(height / 2) { for col in 0..<width { c[row * cRow + col] = 512 << 6 } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return pb
    }

    private static func sampleBuffer(_ px: CVPixelBuffer, at t: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: px, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: px, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }

    /// Nits → PQ-signal (SMPTE ST 2084).
    private static func pqSignal(_ nits: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let y = pow(nits / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "prov", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }

    /// Fönstret med fälten: en flyttalsbild i linjär sRGB, vänster 1,0 och höger 4,0, märkt med
    /// huvudrum 4 så att Core Animation visar den som EDR.
    private static func makeWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let w = 64, h = 32
        var pixels = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            pixels[(y * w + x) * 4 + c] = x < w / 3 ? 0.2 : (x < 2 * w / 3 ? 1 : 4)
        } } }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let data = Data(bytes: &pixels, count: pixels.count * 4) as CFData
        if let provider = CGDataProvider(data: data),
           let image = CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            view.layer?.contents = CGImageCreateCopyWithContentHeadroom(4, image) ?? image
            view.layer?.magnificationFilter = .nearest
        }
        view.layer?.preferredDynamicRange = .high
        window.contentView = view
        return window
    }

    private static func readFrame(_ url: URL, at t: Double, format: OSType) async throws -> CVPixelBuffer? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
        reader.add(output)
        reader.startReading()
        guard let sb = output.copyNextSampleBuffer() else { return nil }
        return CMSampleBufferGetImageBuffer(sb)
    }

    /// Medel av luma (10 bit, 64–940) i en 9×9-ruta.
    private static func luma10(_ px: CVPixelBuffer, at p: CGPoint) -> Double {
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(px, 0) else { return -1 }
        let row = CVPixelBufferGetBytesPerRowOfPlane(px, 0) / 2
        let ptr = base.assumingMemoryBound(to: UInt16.self)
        var sum = 0.0, n = 0.0
        for dy in -4...4 { for dx in -4...4 {
            sum += Double(ptr[(Int(p.y) + dy) * row + Int(p.x) + dx] >> 6); n += 1
        } }
        return (sum / n * 10).rounded() / 10
    }

    private static func bgra(_ px: CVPixelBuffer, at p: CGPoint) -> [Int] {
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return [] }
        let row = CVPixelBufferGetBytesPerRow(px)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let o = Int(p.y) * row + Int(p.x) * 4
        return [Int(ptr[o + 2]), Int(ptr[o + 1]), Int(ptr[o])]
    }

    private static func attachments(_ px: CVPixelBuffer) -> String {
        let keys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
        return keys.map { (CVBufferCopyAttachment(px, $0, nil) as? String) ?? "-" }.joined(separator: " / ")
    }

    /// 10-bitars luma i begränsat omfång → signal 0–1.
    private static func signal(_ y: Double) -> Double { ((y - 64) / 876 * 1000).rounded() / 1000 }

    /// PQ-signal → nits (SMPTE ST 2084).
    private static func pqNits(_ e: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(max(e, 0), 1 / m2)
        return (pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1) * 10000).rounded()
    }
}
