import Testing
import Foundation
@testable import RecorderKit

@Suite struct MatroskaTests {
    @Test func vintUsesTheShortestLength() {
        #expect(Matroska.vint(0) == Data([0x80]))
        #expect(Matroska.vint(126) == Data([0xFE]))
        #expect(Matroska.vint(127) == Data([0x40, 0x7F]))   // 0x7F i en byte betyder "okänd"
        #expect(Matroska.vint(300) == Data([0x41, 0x2C]))
    }

    @Test func elementsAreIdSizePayload() {
        #expect(Matroska.uint(0xD7, 1) == Data([0xD7, 0x81, 0x01]))
        #expect(Matroska.string(0x86, "A_AAC") == Data([0x86, 0x85]) + Data("A_AAC".utf8))
        #expect(Matroska.uint(0x2AD7B1, 1_000_000) == Data([0x2A, 0xD7, 0xB1, 0x83, 0x0F, 0x42, 0x40]))
    }

    @Test func audioSpecificConfigFromAnEsDescriptor() {
        // ES_Descriptor (0x03) → DecoderConfig (0x04, 13 byte) → DecoderSpecificInfo (0x05) = 11 90.
        let esds = Data([0x03, 0x19, 0x00, 0x00, 0x00,
                         0x04, 0x11, 0x40, 0x15, 0x00, 0x00, 0x00, 0x00, 0x02, 0xEE, 0x00, 0x00, 0x02, 0xEE, 0x00,
                         0x05, 0x02, 0x11, 0x90,
                         0x06, 0x01, 0x02])
        #expect(Matroska.audioSpecificConfig(esds) == Data([0x11, 0x90]))
        #expect(Matroska.audioSpecificConfig(Data([0x11, 0x90])) == Data([0x11, 0x90]))
        #expect(Matroska.audioSpecificConfig(Data()) == nil)
    }
}
