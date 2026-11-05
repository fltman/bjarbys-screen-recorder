import Testing
import Foundation
import CoreImage
import CoreVideo
import AVFoundation
@testable import RecorderKit

@Suite struct HDRTests {
    @Test func metaAndPresets() throws {
        let m = try BundleJSON.decoder.decode(RecordingMeta.self, from: Data("{}".utf8))
        #expect(!m.hdr)
        #expect(!ExportPreset.available(hdr: false).contains { $0.isHDR })
        #expect(ExportPreset.available(hdr: true).contains { $0.id == "mp4-4k-hdr" && $0.fileExtension == "mp4" })
    }

    /// En PQ-ruta som ScreenCaptureKits HDR10-förval: 20, 100 och 400 nits.
    private func pqImage() -> CIImage {
        func pq(_ nits: Double) -> Double {
            let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
            let y = pow(nits / 10000, m1); return pow((c1 + c2 * y) / (1 + c3 * y), m2)
        }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 30, 4, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!.assumingMemoryBound(to: UInt16.self)
        let yr = CVPixelBufferGetBytesPerRowOfPlane(pb!, 0) / 2
        for r in 0..<4 { for c in 0..<30 { y[r * yr + c] = UInt16((64 + pq([20.0, 100, 400][c / 10]) * 876).rounded()) << 6 } }
        let cb = CVPixelBufferGetBaseAddressOfPlane(pb!, 1)!.assumingMemoryBound(to: UInt16.self)
        let cr = CVPixelBufferGetBytesPerRowOfPlane(pb!, 1) / 2
        for r in 0..<2 { for c in 0..<30 { cb[r * cr + c] = 512 << 6 } }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        CVBufferSetAttachment(pb!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(pb!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(pb!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return CIImage(cvPixelBuffer: pb!)
    }

    private func plan(outputHDR: Bool) throws -> RenderPlan {
        var meta = RecordingMeta(source: .init(kind: .display, title: "", displayID: 0, windowID: nil,
                                               contentRect: Rect(x: 0, y: 0, width: 15, height: 2), pixelScale: 2,
                                               pixelWidth: 30, pixelHeight: 4), fps: 30, appVersion: "t")
        meta.hdr = true
        let project = try BundleJSON.decoder.decode(EditProject.self, from: Data("{}".utf8))
        return RenderPlan(canvas: CGSize(width: 30, height: 4), project: project, meta: meta, events: [],
                          cursors: CursorCatalog(), cursorsDir: FileManager.default.temporaryDirectory,
                          hasCamera: false, outputHDR: outputHDR)
    }

    private func linear(_ image: CIImage, x: Int) -> Float {
        var v = [Float](repeating: 0, count: 4)
        RenderContext.shared.render(image, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: x, y: 1, width: 1, height: 1),
                                    format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        return v[1]
    }

    /// SDR-vitt på 100 nits lyfts till Core Images 1,0; till HLG trycks 400 nits ihop men inget
    /// upp till vitt ändras; till SDR lämnas högdagern (klipps vid utritningen).
    @Test func screenIsLiftedToCoreImageWhite() throws {
        let hdr = try plan(outputHDR: true).prepareScreen(pqImage())
        #expect(abs(linear(hdr, x: 5) - 0.2) < 0.01)
        #expect(abs(linear(hdr, x: 15) - 1.0) < 0.01)
        #expect(abs(linear(hdr, x: 25) - 2.64) < 0.1)
        let sdr = try plan(outputHDR: false).prepareScreen(pqImage())
        #expect(abs(linear(sdr, x: 15) - 1.0) < 0.01)
        #expect(abs(linear(sdr, x: 25) - 4.0) < 0.1)
    }
}

@Suite struct MotionBlurTests {
    private func plan(segments: [EditProject.ClipSegment]) throws -> RenderPlan {
        var meta = RecordingMeta(source: .init(kind: .display, title: "", displayID: 0, windowID: nil,
                                               contentRect: Rect(x: 0, y: 0, width: 960, height: 540), pixelScale: 2,
                                               pixelWidth: 1920, pixelHeight: 1080), fps: 60, appVersion: "t")
        meta.duration = 8
        var project = try BundleJSON.decoder.decode(EditProject.self, from: Data("{}".utf8))
        project.segments = segments
        project.zooms = [.init(start: 1, end: 5, scale: 2, centerX: 0.3, centerY: 0.3, followsCursor: false)]
        project.motionBlur = true
        return RenderPlan(canvas: CGSize(width: 1920, height: 1080), project: project, meta: meta, events: [],
                          cursors: CursorCatalog(), cursorsDir: FileManager.default.temporaryDirectory, hasCamera: false)
    }

    /// Stilla före zoomen och mitt i den, rörelse under in- och utzoomningen, ingenting i ett snitt.
    @Test func motionFollowsTheCamera() throws {
        let p = try plan(segments: [.init(start: 0, end: 8)])
        func amount(_ t: Double) -> Double {
            guard let m = p.cameraMotion(t: t, s: p.timeMap.source(at: t)) else { return 0 }
            return hypot(m.shift.dx, m.shift.dy) + abs(m.zoomRatio - 1) * 1000
        }
        #expect(amount(0.5) < 0.01)
        let ramp = stride(from: 0.6, through: 2.5, by: 0.05).map(amount).max() ?? 0
        #expect(ramp > 1)
        #expect(amount(3.5) < 0.05)
        let cut = try plan(segments: [.init(start: 0, end: 2), .init(start: 4, end: 8)])
        #expect(cut.cameraMotion(t: 2.005, s: cut.timeMap.source(at: 2.005)) == nil)
    }
}

@Suite struct CameraLayoutTests {
    private func plan(_ layouts: [EditProject.CameraLayout?], visible: Bool = true) throws -> RenderPlan {
        var meta = RecordingMeta(source: .init(kind: .display, title: "", displayID: 0, windowID: nil,
                                               contentRect: Rect(x: 0, y: 0, width: 960, height: 540), pixelScale: 2,
                                               pixelWidth: 1920, pixelHeight: 1080), fps: 60, appVersion: "t")
        meta.duration = 6
        var project = try BundleJSON.decoder.decode(EditProject.self, from: Data("{}".utf8))
        project.camera.visible = visible
        project.segments = layouts.enumerated().map { i, l in
            var s = EditProject.ClipSegment(start: Double(i) * 2, end: Double(i) * 2 + 2); s.cameraLayout = l; return s
        }
        return RenderPlan(canvas: CGSize(width: 1920, height: 1080), project: project, meta: meta, events: [],
                          cursors: CursorCatalog(), cursorsDir: FileManager.default.temporaryDirectory, hasCamera: true)
    }

    @Test func layoutsAndTransitions() throws {
        let p = try plan([nil, .large, .split, .hidden])
        #expect(p.layoutFrame(at: 1).camera == p.cameraRect)                       // standard = bubblan
        #expect(p.layoutFrame(at: 3).camera == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(p.layoutFrame(at: 3).screenAlpha == 0)
        let mid = p.layoutFrame(at: 2.25)                                           // halvvägs in i bytet
        #expect(mid.camera.width > p.cameraRect.width && mid.camera.width < 1920)
        let split = p.layoutFrame(at: 5)
        #expect(split.camera.minX > split.screen.maxX && split.screenAlpha == 1)
        #expect(p.layoutTransform(at: 5) != nil && p.layoutTransform(at: 1) == nil)
        #expect(p.layoutFrame(at: 7).cameraAlpha == 0)
        // Dold som standard, men en del kan visa bubblan.
        let q = try plan([nil, .bubble], visible: false)
        #expect(q.layoutFrame(at: 1).cameraAlpha == 0 && q.layoutFrame(at: 3).cameraAlpha == 1)
    }
}

@Suite struct ClickSoundTests {
    @Test func clickIsShortAndClear() throws {
        let url = try #require(ClickSound.url())
        let file = try AVAudioFile(forReading: url)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - ClickSound.length) < 0.002)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let p = buffer.floatChannelData![0]
        let peak = (0..<Int(buffer.frameLength)).map { abs(p[$0]) }.max() ?? 0
        #expect(peak > 0.3 && peak < 1)
    }

    @Test func clickSoundDefaultsOff() throws {
        let c = try BundleJSON.decoder.decode(EditProject.CursorStyle.self, from: Data("{}".utf8))
        #expect(!c.clickSound && c.clickVolume == 0.5)
        let on = try BundleJSON.decoder.decode(EditProject.CursorStyle.self, from: Data(#"{"clickSound":true,"clickVolume":0.3}"#.utf8))
        #expect(on.clickSound && on.clickVolume == 0.3)
    }
}
