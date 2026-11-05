import Foundation
import AVFoundation
import CoreImage
import Vision

/// Var ansiktet är i kamerabilden över tiden, så att bubblans utsnitt kan hålla det i mitten
/// (kamerabilden är bredare än bubblan; den som sitter lite åt sidan hamnar annars i kanten).
///
/// Räknas fram en gång ur kameraspåret (Vision, fyra gånger i sekunden, nedskalat) och sparas i
/// `derived/camera-faces.json`. Punkterna är normaliserade i kamerabilden med origo nere till
/// vänster (som Core Image och Vision), i källtid, och redan utjämnade.
public struct FaceTrack: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double
        /// Ansiktets höjd som andel av bildens.
        public var h: Double
        public init(t: Double, x: Double, y: Double, h: Double) { self.t = t; self.x = x; self.y = y; self.h = h }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            t = c.value(.t, 0); x = c.value(.x, 0.5); y = c.value(.y, 0.5); h = c.value(.h, 0)
        }
    }

    public var samples: [Sample]

    public init(samples: [Sample]) { self.samples = samples }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = c.value(.samples, [])
    }

    /// Ansiktets mitt vid källtiden `s` (linjärt mellan proven), eller nil utan ansikte.
    public func center(at s: Double) -> CGPoint? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if s <= first.t { return CGPoint(x: first.x, y: first.y) }
        if s >= last.t { return CGPoint(x: last.x, y: last.y) }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= s { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let k = b.t > a.t ? (s - a.t) / (b.t - a.t) : 0
        return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }

    /// Hur ofta kameran provas, och utjämningens bredd (prov åt varje håll).
    static let rate = 4.0
    static let smoothingRadius = 3

    /// Råa fynd (nil = inget ansikte) till en jämn bana: luckor fylls med närmaste fynd, sedan
    /// glidande medelvärde (±0,75 s), så att utsnittet inte darrar med huvudet.
    static func smooth(_ raw: [(t: Double, face: CGRect?)]) -> [Sample] {
        let found = raw.compactMap { r in r.face.map { (r.t, $0) } }
        guard !found.isEmpty else { return [] }
        var filled: [Sample] = []
        var j = 0
        for r in raw {
            while j + 1 < found.count && abs(found[j + 1].0 - r.t) <= abs(found[j].0 - r.t) { j += 1 }
            let f = r.face ?? found[j].1
            filled.append(Sample(t: r.t, x: f.midX, y: f.midY, h: f.height))
        }
        let n = smoothingRadius
        return filled.indices.map { i in
            let lo = max(0, i - n), hi = min(filled.count - 1, i + n)
            let part = filled[lo...hi]
            let c = Double(part.count)
            return Sample(t: filled[i].t, x: part.map(\.x).reduce(0, +) / c, y: part.map(\.y).reduce(0, +) / c,
                          h: part.map(\.h).reduce(0, +) / c)
        }
    }

    /// Analyserar kameraspåret från `start` (kamerans första ruta) till `end`. `progress` 0–1.
    public static func analyze(_ asset: AVAsset, from start: Double, to end: Double,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> FaceTrack {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 0.5 / rate, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var times: [CMTime] = []
        var t = start
        while t < end { times.append(CMTime(seconds: t, preferredTimescale: 600)); t += 1 / rate }
        guard !times.isEmpty else { return FaceTrack(samples: []) }
        var raw: [(t: Double, face: CGRect?)] = []
        for await result in generator.images(for: times) {
            let requested = result.requestedTime.seconds
            var face: CGRect?
            if let image = try? result.image {
                let request = VNDetectFaceRectanglesRequest()
                try? VNImageRequestHandler(cgImage: image).perform([request])
                // Det största ansiktet (den som sitter närmast kameran).
                face = request.results?.max { $0.boundingBox.height < $1.boundingBox.height }?.boundingBox
            }
            raw.append((requested, face))
            progress(Double(raw.count) / Double(times.count))
            try Task.checkCancellation()
        }
        raw.sort { $0.t < $1.t }
        return FaceTrack(samples: smooth(raw))
    }
}

extension RecordingBundle {
    public var faceTrackURL: URL { derivedDir.appendingPathComponent("camera-faces.json") }

    public func readFaceTrack() -> FaceTrack? {
        try? BundleJSON.read(FaceTrack.self, from: faceTrackURL)
    }

    public func saveFaceTrack(_ track: FaceTrack) throws {
        try FileManager.default.createDirectory(at: derivedDir, withIntermediateDirectories: true)
        try BundleJSON.write(track, to: faceTrackURL)
    }
}
