import Foundation
import CoreGraphics

/// En gemensam palett för en hel GIF och ordnat gitter mot den.
///
/// ImageIO väljer en egen palett per ruta utan gitter: en bakgrundsgradient fick 11 färger över
/// 450 px, med band upp till 110 px (uppmätt). Här tas paletten fram en gång med median cut ur
/// stickprov från hela filmen, och varje ruta gittras med Bayers 8×8-mönster — deterministiskt,
/// så att det som står still ser likadant ut i varje ruta (inget flimmer). Uppmätt: längsta band
/// 22 px, filen 20 % större. Floyd–Steinberg gav jämnare yta men 6,5 gånger större fil (bruset
/// komprimeras dåligt) och enstaka avvikande prickar.
public struct GIFPalette: Sendable {
    /// RGB-tripplar, högst 256.
    public let colors: [(r: UInt8, g: UInt8, b: UInt8)]

    public init(colors: [(r: UInt8, g: UInt8, b: UInt8)]) { self.colors = colors }

    /// Gittrets bredd i nivåer (uppmätt: 10 tog bort banden i en bakgrundsgradient, 6 räckte inte).
    public static let spread = 10

    // MARK: - Median cut

    /// Paletten ur stickprov (RGB-tripplar packade som `0xRRGGBB`).
    public static func build(samples: [UInt32], maxColors: Int = 256) -> GIFPalette {
        guard !samples.isEmpty else { return GIFPalette(colors: [(0, 0, 0), (255, 255, 255)]) }
        var boxes: [[UInt32]] = [samples]
        while boxes.count < maxColors {
            // Lådan där omfång × antal pixlar är störst delas vid medianen, längs kanalen med störst
            // omfång. Bara omfånget lade färgerna på enstaka avvikande pixlar, och en stor gradient
            // fick för få (8 färger i stället för ImageIOs 11, uppmätt).
            var best = -1, bestScore = 0, bestShift: UInt32 = 0
            for (i, box) in boxes.enumerated() where box.count > 1 {
                var widest = 0, widestShift: UInt32 = 0
                for shift: UInt32 in [16, 8, 0] {
                    var lo: UInt32 = 255, hi: UInt32 = 0
                    for p in box { let v = (p >> shift) & 0xFF; lo = min(lo, v); hi = max(hi, v) }
                    if Int(hi) - Int(lo) > widest { widest = Int(hi) - Int(lo); widestShift = shift }
                }
                let score = widest * box.count
                if score > bestScore { bestScore = score; best = i; bestShift = widestShift }
            }
            guard best >= 0, bestScore > 0 else { break }
            let sorted = boxes[best].sorted { ($0 >> bestShift) & 0xFF < ($1 >> bestShift) & 0xFF }
            let mid = sorted.count / 2
            boxes[best] = Array(sorted[..<mid])
            boxes.append(Array(sorted[mid...]))
        }
        let colors = boxes.map { box -> (r: UInt8, g: UInt8, b: UInt8) in
            var r = 0, g = 0, b = 0
            for p in box { r += Int((p >> 16) & 0xFF); g += Int((p >> 8) & 0xFF); b += Int(p & 0xFF) }
            let n = max(box.count, 1)
            return (UInt8(r / n), UInt8(g / n), UInt8(b / n))
        }
        return GIFPalette(colors: colors)
    }

    /// Stickprov ur en BGRA-ruta: var `step`:e pixel i båda led.
    public static func samples(bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, step: Int = 4) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity((width / step) * (height / step))
        for y in stride(from: 0, to: height, by: step) {
            let row = bgra + y * bytesPerRow
            for x in stride(from: 0, to: width, by: step) {
                let p = row + x * 4
                out.append(UInt32(p[2]) << 16 | UInt32(p[1]) << 8 | UInt32(p[0]))
            }
        }
        return out
    }

    // MARK: - Gitter

    /// Närmaste palettfärg per 6-bitars RGB-låda (4 nivåer), uträknad när den behövs.
    public final class Mapper: @unchecked Sendable {
        let palette: GIFPalette
        private var cache = [Int16](repeating: -1, count: 64 * 64 * 64)

        public init(_ palette: GIFPalette) { self.palette = palette }

        @inline(__always) func nearest(_ r: Int, _ g: Int, _ b: Int) -> Int {
            let key = (r >> 2) << 12 | (g >> 2) << 6 | (b >> 2)
            let hit = cache[key]
            if hit >= 0 { return Int(hit) }
            // Mitten av lådan, så att alla i lådan får samma svar.
            let cr = (r & ~3) + 2, cg = (g & ~3) + 2, cb = (b & ~3) + 2
            var best = 0, bestD = Int.max
            for (i, c) in palette.colors.enumerated() {
                let dr = cr - Int(c.r), dg = cg - Int(c.g), db = cb - Int(c.b)
                // Viktat efter ögats känslighet (grönt mest).
                let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
                if d < bestD { bestD = d; best = i }
            }
            cache[key] = Int16(best)
            return best
        }

        /// Bayers 8×8-matris, 0–63.
        static let bayer: [Int] = [
            0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
            12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
            3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
            15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
        ]

        /// En indexerad bild med ordnat gitter (Bayer 8×8): samma mönster på samma ställe i varje
        /// ruta, och `spread` nivåer brett.
        public func orderedImage(bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                                 spread: Int = GIFPalette.spread) -> CGImage? {
            image(orderedIndices(bgra: bgra, width: width, height: height, bytesPerRow: bytesPerRow, spread: spread),
                  width: width, height: height)
        }

        public func orderedIndices(bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                                   spread: Int = GIFPalette.spread) -> [UInt8] {
            var indices = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                let row = bgra + y * bytesPerRow
                for x in 0..<width {
                    let p = row + x * 4
                    let d = (Self.bayer[(y & 7) * 8 + (x & 7)] * 2 - 63) * spread / 128
                    indices[y * width + x] = UInt8(nearest(min(255, max(0, Int(p[2]) + d)),
                                                           min(255, max(0, Int(p[1]) + d)),
                                                           min(255, max(0, Int(p[0]) + d))))
                }
            }
            return indices
        }

        func image(_ indices: [UInt8], width: Int, height: Int) -> CGImage? {
            var table = [UInt8]()
            for c in palette.colors { table += [c.r, c.g, c.b] }
            guard let space = CGColorSpace(indexedBaseSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           last: palette.colors.count - 1, colorTable: table),
                  let provider = CGDataProvider(data: Data(indices) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                           space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }
}
