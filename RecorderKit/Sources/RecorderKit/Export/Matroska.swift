import Foundation
import AVFoundation

/// En liten Matroska-skrivare (.mkv): packar om en färdig MP4 rakt över (ingen omkodning) —
/// H.264 eller HEVC och AAC, med kapitel och sökpunkter (Cues). AVAssetWriter kan inte skriva
/// Matroska, och ett ffmpeg-beroende för en omkodning bara av behållaren vore onödigt.
///
/// Elementen (EBML): id, storlek som VINT, data. Segmentets storlek skrivs i efterhand; blocken
/// läggs i kluster (nytt vid varje nyckelbild, högst ~5 s), tider i millisekunder.
public enum Matroska {
    public enum MatroskaError: LocalizedError {
        case unsupported(String)
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .unsupported(let s): String(localized: "MKV: \(s) stöds inte.")
            case .failed(let s): String(localized: "MKV: \(s)")
            }
        }
    }

    public struct Chapter: Sendable { public var start: Double; public var end: Double; public var title: String
        public init(start: Double, end: Double, title: String) { self.start = start; self.end = end; self.title = title } }

    /// Packar om `source` (MP4/MOV) till `destination` (.mkv). `progress` 0–1.
    public static func remux(_ source: URL, to destination: URL, chapters: [Chapter] = [],
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        var outputs: [(output: AVAssetReaderTrackOutput, number: UInt64, video: Bool)] = []
        var entries: [Data] = []
        var number: UInt64 = 1
        for track in try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio) {
            guard let format = try await track.load(.formatDescriptions).first else { continue }
            let isVideo = track.mediaType == .video
            entries.append(try trackEntry(number: number, format: format, video: isVideo,
                                          frameRate: isVideo ? Double(try await track.load(.nominalFrameRate)) : 0))
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            outputs.append((out, number, isVideo))
            number += 1
        }
        guard outputs.contains(where: \.video) else { throw MatroskaError.failed(String(localized: "inget videospår")) }
        guard reader.startReading() else { throw MatroskaError.failed(reader.error?.localizedDescription ?? "läsningen startade inte") }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let file = try? FileHandle(forWritingTo: destination) else { throw MatroskaError.failed("kan inte skriva \(destination.lastPathComponent)") }
        defer { try? file.close() }
        var w = Writer(file: file)

        // EBML-huvudet.
        w.write(element(0x1A45DFA3, [
            uint(0x4286, 1), uint(0x42F7, 1), uint(0x42F2, 4), uint(0x42F3, 8),
            string(0x4282, "matroska"), uint(0x4287, 4), uint(0x4285, 2),
        ].joined()))
        // Segmentet med okänd storlek tills vidare (8 byte, skrivs om på slutet).
        w.write(id(0x18538067))
        let segmentSizeAt = w.offset
        w.write(Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        let segmentStart = w.offset
        w.write(element(0x1549A966, [
            uint(0x2AD7B1, 1_000_000),                      // tider i millisekunder
            string(0x4D80, "Bjarbys skärminspelare"), string(0x5741, "Bjarbys skärminspelare"),
            float(0x4489, duration * 1000),
        ].joined()))
        w.write(element(0x1654AE6B, entries.joined()))
        if !chapters.isEmpty {
            let atoms = chapters.enumerated().map { i, c in
                element(0xB6, [
                    uint(0x73C4, UInt64(i + 1)),
                    uint(0x91, UInt64(max(0, c.start) * 1e9)), uint(0x92, UInt64(max(0, c.end) * 1e9)),
                    element(0x80, [string(0x85, c.title), string(0x437C, "und")].joined()),
                ].joined())
            }
            w.write(element(0x1043A770, element(0x45B9, uint(0x45BC, 1) + atoms.joined())))
        }

        // Blocken: ett väntande prov per spår, det med lägst tid skrivs först (sammanflätat).
        var pending: [Int: [(ms: Int64, data: Data, key: Bool)]] = [:]
        var finished = Set<Int>()
        var cluster = Data()
        var clusterTime: Int64 = -1
        var cues: [(ms: Int64, position: UInt64)] = []
        func flushCluster() {
            guard clusterTime >= 0 else { return }
            let position = UInt64(w.offset - segmentStart)
            w.write(element(0x1F43B675, uint(0xE7, UInt64(clusterTime)) + cluster))
            cues.append((clusterTime, position))
            cluster = Data(); clusterTime = -1
        }
        // Läsaren ger bildens tider utan MP4:ns redigeringslista: med B-bilder ligger första
        // bilden 2 rutor in (uppmätt 0,033 s vid 60 bilder/s), och filmen blev ljudet efter.
        // Videotiderna räknas därför från första bilden.
        var videoOffset: Int64?
        func next(_ i: Int) {
            guard pending[i, default: []].isEmpty, !finished.contains(i) else { return }
            guard let sb = outputs[i].output.copyNextSampleBuffer() else { finished.insert(i); return }
            var list = packets(sb, video: outputs[i].video)
            if outputs[i].video, !list.isEmpty {
                if videoOffset == nil { videoOffset = list[0].ms }
                list = list.map { ($0.ms - videoOffset!, $0.data, $0.key) }
            }
            pending[i] = list
            if pending[i]!.isEmpty { next(i) }
        }
        for i in outputs.indices { next(i) }
        while true {
            let ready = outputs.indices.filter { !(pending[$0]?.isEmpty ?? true) }
            guard let i = ready.min(by: { pending[$0]![0].ms < pending[$1]![0].ms }) else { break }
            let p = pending[i]!.removeFirst()
            if pending[i]!.isEmpty { next(i) }
            guard p.ms >= 0 else { continue }  // AAC:s förrulle (före filmens början)
            // Nytt kluster vid en nyckelbild i bilden, eller efter 5 s (tiden i blocket är 16 bitar;
            // en B-bild kan ligga lite före klustrets tid, det ryms som negativt).
            if clusterTime < 0 || (outputs[i].video && p.key && p.ms - clusterTime > 500) || p.ms - clusterTime > 5000 {
                flushCluster()
                clusterTime = p.ms
            }
            var block = vint(outputs[i].number)
            let rel = Int16(clamping: p.ms - clusterTime)
            block.append(contentsOf: [UInt8(UInt16(bitPattern: rel) >> 8), UInt8(UInt16(bitPattern: rel) & 0xFF)])
            block.append(p.key ? 0x80 : 0x00)
            block.append(p.data)
            cluster.append(element(0xA3, block))
            if duration > 0 { progress(min(1, Double(p.ms) / 1000 / duration)) }
        }
        flushCluster()
        if reader.status == .failed { throw MatroskaError.failed(reader.error?.localizedDescription ?? "läsningen misslyckades") }
        // Sökpunkterna, så att spelare kan hoppa direkt.
        let videoTrack = outputs.first(where: \.video)!.number
        w.write(element(0x1C53BB6B, cues.map { c in
            element(0xBB, uint(0xB3, UInt64(c.ms)) + element(0xB7, uint(0xF7, videoTrack) + uint(0xF1, c.position)))
        }.joined()))
        // Segmentets verkliga storlek.
        let size = UInt64(w.offset - segmentStart)
        var sized = Data([0x01])
        for shift in stride(from: 48, through: 0, by: -8) { sized.append(UInt8((size >> UInt64(shift)) & 0xFF)) }
        try file.seek(toOffset: UInt64(segmentSizeAt))
        file.write(sized)
        progress(1)
    }

    // MARK: - Spår

    static func trackEntry(number: UInt64, format: CMFormatDescription, video: Bool, frameRate: Double) throws -> Data {
        let sub = CMFormatDescriptionGetMediaSubType(format)
        var parts: [Data] = [uint(0xD7, number), uint(0x73C5, number), uint(0x9C, 0)]
        if video {
            let codec: String, atom: String
            switch sub {
            case kCMVideoCodecType_H264: codec = "V_MPEG4/ISO/AVC"; atom = "avcC"
            case kCMVideoCodecType_HEVC: codec = "V_MPEGH/ISO/HEVC"; atom = "hvcC"
            default: throw MatroskaError.unsupported(fourCC(sub))
            }
            guard let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
                  let config = atoms[atom] as? Data else { throw MatroskaError.failed("\(atom) saknas") }
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            parts += [uint(0x83, 1), string(0x86, codec), binary(0x63A2, config)]
            if frameRate > 0 { parts.append(uint(0x23E383, UInt64(1e9 / frameRate))) }
            parts.append(element(0xE0, uint(0xB0, UInt64(dims.width)) + uint(0xBA, UInt64(dims.height))))
        } else {
            guard sub == kAudioFormatMPEG4AAC, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                throw MatroskaError.unsupported(fourCC(sub))
            }
            var size = 0
            let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &size)
            let raw = cookie.map { Data(bytes: $0, count: size) } ?? Data()
            guard let asc = audioSpecificConfig(raw) else { throw MatroskaError.failed("AAC-inställningarna saknas") }
            parts += [uint(0x83, 2), string(0x86, "A_AAC"), binary(0x63A2, asc),
                      element(0xE1, float(0xB5, asbd.mSampleRate) + uint(0x9F, UInt64(asbd.mChannelsPerFrame)))]
        }
        return element(0xAE, parts.joined())
    }

    /// AAC:s AudioSpecificConfig ur en magisk kaka: antingen den själv (2–5 byte), eller ur en
    /// ES-deskriptor (`esds`): DecoderSpecificInfo, tagg 0x05.
    static func audioSpecificConfig(_ cookie: Data) -> Data? {
        let b = [UInt8](cookie)
        guard !b.isEmpty else { return nil }
        if b.count <= 5 && b[0] != 0x03 { return cookie }
        var i = 0
        while i < b.count {
            let tag = b[i]; i += 1
            var len = 0
            for _ in 0..<4 {
                guard i < b.count else { return nil }
                let v = b[i]; i += 1
                len = len << 7 | Int(v & 0x7F)
                if v & 0x80 == 0 { break }
            }
            switch tag {
            case 0x05: return i + len <= b.count ? Data(b[i..<(i + len)]) : nil
            case 0x03: i += 3            // ES_ID + flaggor; sedan underdeskriptorerna
            case 0x04: i += 13           // objekttyp, strömtyp, buffert, bitrater
            default: i += len
            }
        }
        return nil
    }

    /// Proven i en buffert: (tid i ms, data, nyckelbild). Ljudbuffertar delas per paket.
    static func packets(_ sb: CMSampleBuffer, video: Bool) -> [(ms: Int64, data: Data, key: Bool)] {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return [] }
        let count = CMSampleBufferGetNumSamples(sb)
        guard count > 0 else { return [] }
        var all = Data(count: CMBlockBufferGetDataLength(block))
        all.withUnsafeMutableBytes { p in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: p.count, destination: p.baseAddress!) }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if video {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
            let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
            return [(Int64((pts.seconds * 1000).rounded()), all, key)]
        }
        var out: [(Int64, Data, Bool)] = []
        var offset = 0
        let frameDuration = CMSampleBufferGetDuration(sb).seconds / Double(count)
        for i in 0..<count {
            let size = CMSampleBufferGetSampleSize(sb, at: i)
            guard size > 0, offset + size <= all.count else { break }
            let t = pts.seconds + Double(i) * frameDuration
            out.append((Int64((t * 1000).rounded(.down)), all.subdata(in: offset..<(offset + size)), true))
            offset += size
        }
        return out
    }

    // MARK: - EBML

    struct Writer {
        let file: FileHandle
        var offset: Int = 0
        mutating func write(_ d: Data) { file.write(d); offset += d.count }
    }

    static func id(_ v: UInt32) -> Data {
        var bytes: [UInt8] = []
        var x = v
        while x > 0 { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 }
        return Data(bytes)
    }

    /// Storlek som VINT: kortast möjliga (1–8 byte).
    static func vint(_ v: UInt64) -> Data {
        for length in 1...8 {
            let max = (UInt64(1) << (7 * UInt64(length))) - 1
            if v < max {
                var bytes = [UInt8](repeating: 0, count: length)
                var x = v
                for i in stride(from: length - 1, through: 0, by: -1) { bytes[i] = UInt8(x & 0xFF); x >>= 8 }
                bytes[0] |= UInt8(0x80 >> (length - 1))
                return Data(bytes)
            }
        }
        return Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    static func element(_ i: UInt32, _ payload: Data) -> Data { id(i) + vint(UInt64(payload.count)) + payload }
    static func uint(_ i: UInt32, _ v: UInt64) -> Data {
        var bytes: [UInt8] = []
        var x = v
        repeat { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        return element(i, Data(bytes))
    }
    static func float(_ i: UInt32, _ v: Double) -> Data {
        let bits = v.bitPattern
        return element(i, Data((0..<8).map { UInt8((bits >> UInt64(56 - 8 * $0)) & 0xFF) }))
    }
    static func string(_ i: UInt32, _ s: String) -> Data { element(i, Data(s.utf8)) }
    static func binary(_ i: UInt32, _ d: Data) -> Data { element(i, d) }

    static func fourCC(_ v: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }, encoding: .ascii) ?? "\(v)"
    }
}

extension Array where Element == Data {
    func joined() -> Data { reduce(into: Data()) { $0.append($1) } }
}
