import Foundation
import AVFoundation
import Vision
import CoreImage

/// Läser texten i skärmspåret med Vision och gör masker av det känsliga.
///
/// En ruta i sekunden läses, varenda en (att hoppa över rutor som "ser likadana ut" missar en
/// ny rad text på en stor skärm). Där bilden ändras mellan två läsningar — scroll, nytt
/// fönster — läses fem rutor i sekunden, så att en mask hinner följa text som rör sig.
/// ⚠️ Uppmätt: med bara en ruta i sekunden syntes ett telefonnummer under en scroll, eftersom
/// masken stod kvar där texten senast lästes.
/// En mask sträcker sig till läsningen före första och efter sista träffen.
public enum MaskScanner {
    public static let interval = 1.0
    static let denseInterval = 0.2

    /// En träff i en ruta: vad, var (normaliserat, origo uppe till vänster) och texten.
    struct Hit: Sendable { let kind: SensitiveText.Kind; let rect: CGRect; let text: String }
    struct Sample: Sendable { let t: Double; let hits: [Hit]; let print: [UInt8] }

    public static func scan(_ rec: LoadedRecording, kinds: Set<SensitiveText.Kind>,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [EditProject.Mask] {
        guard let asset = rec.asset(.screen) else { return [] }
        let duration = rec.meta.duration
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let gen = UncheckedBox(generator)

        func read(_ times: [Double], share: Double, offset: Double) async throws -> [Sample] {
            var out: [Sample] = []
            for batch in stride(from: 0, to: times.count, by: 4) {
                try Task.checkCancellation()
                let slice = times[batch..<min(batch + 4, times.count)]
                let results = try await withThrowingTaskGroup(of: Sample?.self) { group in
                    for t in slice {
                        group.addTask {
                            guard let image = try? await gen.value.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
                            else { return nil }
                            return Sample(t: t, hits: try recognize(image).filter { kinds.contains($0.kind) },
                                          print: fingerprint(image))
                        }
                    }
                    var r: [Sample] = []
                    for try await s in group { if let s { r.append(s) } }
                    return r
                }
                out += results
                progress(offset + share * Double(min(batch + 4, times.count)) / Double(max(times.count, 1)))
            }
            return out.sorted { $0.t < $1.t }
        }

        let coarse = try await read(Array(stride(from: 0.0, through: duration, by: interval)), share: 0.6, offset: 0)
        // Tätare där bilden ändrats mellan två läsningar.
        var dense: [Double] = []
        for (a, b) in zip(coarse, coarse.dropFirst()) where changed(a.print, b.print) {
            dense += stride(from: a.t + denseInterval, to: b.t - 0.01, by: denseInterval)
        }
        let extra = try await read(dense, share: 0.4, offset: 0.6)
        progress(1)
        let all = (coarse + extra).sorted { $0.t < $1.t }
        return link(all.map { (t: $0.t, hits: $0.hits) }, duration: duration)
    }

    /// Samma text i följd blir en mask med nyckelrutor; upp till två läsningar utan träff
    /// (OCR missar ibland) överbryggas. Masken börjar vid läsningen före första träffen och
    /// slutar vid läsningen efter sista.
    static func link(_ samples: [(t: Double, hits: [Hit])], duration: Double) -> [EditProject.Mask] {
        struct Open { var kind: SensitiveText.Kind; var text: String; var frames: [EditProject.Mask.Keyframe]
                      var firstIndex: Int; var lastIndex: Int }
        var open: [Open] = []
        var done: [Open] = []
        for (i, sample) in samples.enumerated() {
            var used = Set<Int>()
            for h in sample.hits {
                if let j = open.indices.first(where: { !used.contains($0) && open[$0].text == h.text && open[$0].kind == h.kind }) {
                    open[j].frames.append(.init(t: sample.t, rect: Rect(h.rect)))
                    open[j].lastIndex = i
                    used.insert(j)
                } else {
                    open.append(Open(kind: h.kind, text: h.text, frames: [.init(t: sample.t, rect: Rect(h.rect))],
                                     firstIndex: i, lastIndex: i))
                    used.insert(open.count - 1)
                }
            }
            done += open.filter { i - $0.lastIndex > 2 }
            open = open.filter { i - $0.lastIndex <= 2 }
        }
        done += open
        return done.map { o in
            let start = o.firstIndex > 0 ? samples[o.firstIndex - 1].t : 0
            let end = o.lastIndex + 1 < samples.count ? samples[o.lastIndex + 1].t : duration
            return EditProject.Mask(start: start, end: min(duration, end), keyframes: o.frames,
                                    style: o.kind == .secret ? .solid : .blur, kind: o.kind,
                                    hint: SensitiveText.hint(o.kind, o.text))
        }
        .sorted { $0.start < $1.start }
    }

    /// 64×40 gråskala, bara för att se *att* något ändrats (då läses tätare). Ett falskt
    /// "ändrat" kostar tid, aldrig en miss.
    static func fingerprint(_ image: CGImage) -> [UInt8] {
        let w = 64, h = 40
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return pixels
    }

    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return true }
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 3 { return true }
        return false
    }

    static func recognize(_ image: CGImage) throws -> [Hit] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["sv-SE", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        var hits: [Hit] = []
        for obs in request.results ?? [] {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string
            for m in SensitiveText.matches(in: text) {
                guard let box = try? candidate.boundingBox(for: m.range)?.boundingBox else { continue }
                // Vision: origo nere till vänster. Vi: uppe till vänster.
                let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                hits.append(Hit(kind: m.kind, rect: rect, text: String(text[m.range])))
            }
        }
        return hits
    }

}

struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
