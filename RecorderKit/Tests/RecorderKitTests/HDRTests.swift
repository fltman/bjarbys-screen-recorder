import Testing
import Foundation
import CoreImage
import CoreVideo
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
