import Testing
import Foundation
@testable import RecorderKit

/// Mot AWS egna publicerade exempel — en riktig referens, inte vår egen uppfattning.
@Suite struct SigV4Tests {
    static let secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.date(from: s)!
    }

    /// "Examples of the complete Signature Version 4 signing process" (IAM ListUsers, 2015-08-30).
    @Test func iamListUsersExample() {
        let key = SigV4.signingKey(secret: Self.secret, day: "20150830", region: "us-east-1", service: "iam")
        let keyHex = key.withUnsafeBytes { SigV4.hex(Array($0)) }
        #expect(keyHex == "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")

        let url = URL(string: "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08")!
        let (canonical, signed) = SigV4.canonicalRequest(
            method: "GET", path: "/", query: [("Action", "ListUsers"), ("Version", "2010-05-08")],
            headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                      "Host": "iam.amazonaws.com", "X-Amz-Date": "20150830T123600Z"],
            payloadHash: SigV4.sha256(Data()))
        #expect(signed == "content-type;host;x-amz-date")
        #expect(SigV4.sha256(Data(canonical.utf8)) == "f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59")

        let headers = SigV4.sign(method: "GET", url: url,
                                 headers: ["content-type": "application/x-www-form-urlencoded; charset=utf-8"],
                                 payloadHash: SigV4.sha256(Data()), accessKey: "AKIDEXAMPLE", secret: Self.secret,
                                 region: "us-east-1", service: "iam", date: date("20150830T123600Z"))
        #expect(headers["Authorization"]?.hasSuffix("Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7") == true)
    }

    /// S3-dokumentationens "GET Object"-exempel (examplebucket, Range: bytes=0-9, 2013-05-24).
    @Test func s3GetObjectExample() {
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        let headers = SigV4.sign(method: "GET", url: url, headers: ["range": "bytes=0-9"],
                                 payloadHash: SigV4.sha256(Data()), accessKey: "AKIAIOSFODNN7EXAMPLE",
                                 // S3-dokumentationens exempelnyckel skiljer sig från IAM-exemplets ("/bPxR", inte "+bPxR").
                                 secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1", service: "s3",
                                 date: date("20130524T000000Z"))
        #expect(headers["Authorization"] == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func pathEncodingKeepsSlashesAndEncodesTheRest() {
        #expect(SigV4.encodePath("hink/skarminspelare/2026 film å.mp4") == "hink/skarminspelare/2026%20film%20%C3%A5.mp4")
    }

    @Test func keysAreSafeAndDated() {
        let k = S3Uploader.key(for: URL(fileURLWithPath: "/x/Inspelning 2026-11-05 kl. 02.04 – Export.MP4"), prefix: "/demos/",
                               date: Date(timeIntervalSince1970: 1_793_836_800))
        #expect(k.hasPrefix("demos/2026-11-0"))
        #expect(k.hasSuffix(".mp4") && !k.contains(" ") && !k.contains("–"))
    }

    @Test func configDecodesFromEmpty() throws {
        let c = try BundleJSON.decoder.decode(S3Config.self, from: Data("{}".utf8))
        #expect(c.region == "auto" && !c.isComplete)
    }
}
