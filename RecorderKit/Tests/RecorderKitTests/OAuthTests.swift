import Testing
import Foundation
import CryptoKit
@testable import RecorderKit

@Suite struct OAuthTests {
    @Test func pkceChallengeIsTheHashOfTheVerifier() {
        let (verifier, challenge) = OAuth.pkce()
        #expect(verifier.count == 43 && !verifier.contains("=") && !verifier.contains("+"))
        #expect(challenge == OAuth.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))))
        #expect(OAuth.pkce().verifier != verifier)
    }

    @Test func authorizeURLCarriesPkceAndRedirect() throws {
        let p = OAuthProvider.youtube(clientID: "id-1", clientSecret: "s")
        let url = OAuth.authorizeURL(p, challenge: "ch", state: "st", redirect: "http://127.0.0.1:5000/callback")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(q["code_challenge"] == "ch" && q["code_challenge_method"] == "S256" && q["state"] == "st")
        #expect(q["redirect_uri"] == "http://127.0.0.1:5000/callback" && q["access_type"] == "offline")
        let d = OAuth.authorizeURL(.dropbox(appKey: "k"), challenge: "c", state: "s", redirect: nil)
        #expect(!d.absoluteString.contains("redirect_uri") && d.absoluteString.contains("token_access_type=offline"))
    }

    @Test func formEncodingEscapesEverythingButUnreserved() {
        #expect(OAuth.formEncode(["b": "a b/c+d", "a": "x~y"]) == "a=x~y&b=a%20b%2Fc%2Bd")
    }

    @Test func dropboxHeaderIsAscii() {
        let bs = "\\"
        #expect(DropboxUploader.asciiJSON(#"{"path":"/Bjarbys skärminspelare/å.mp4"}"#) == "{\"path\":\"/Bjarbys sk" + bs + "u00e4rminspelare/" + bs + "u00e5.mp4\"}")
    }

    @Test func tokensDecodeFromEmptyAsExpired() throws {
        let t = try JSONDecoder().decode(OAuthTokens.self, from: Data("{}".utf8))
        #expect(t.isExpired && t.refreshToken == nil)
    }
}
