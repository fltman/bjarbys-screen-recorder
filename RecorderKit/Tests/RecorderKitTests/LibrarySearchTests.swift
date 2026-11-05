import Testing
import Foundation
@testable import RecorderKit

@Suite struct LibrarySearchTests {
    let titles = ["Demo av exporten", "Safari", "Idag kl. 09.12"]
    let speech = "Hej och välkommen. Nu ska vi titta på hur man exporterar en film till YouTube med kapitel och allt."

    @Test func emptyQueryMatchesEverything() {
        #expect(LibrarySearch.match(query: "  ", titles: titles, transcript: nil) == .title)
    }

    @Test func titleMatchIgnoresCase() {
        #expect(LibrarySearch.match(query: "demo SAFARI", titles: titles, transcript: speech) == .title)
    }

    @Test func speechMatchGivesAQuoteAroundTheWord() throws {
        guard case .speech(let quote)? = LibrarySearch.match(query: "youtube", titles: titles, transcript: speech) else {
            Issue.record("ingen träff i talet"); return
        }
        #expect(quote.contains("YouTube"))
        // Början är avklippt (…), slutet når textens slut (inget …), och kanterna är hela ord.
        #expect(quote.hasPrefix("…") && quote.hasSuffix("allt."))
        let body = String(quote.dropFirst())
        let at = try #require(speech.range(of: body))
        #expect(speech[speech.index(before: at.lowerBound)] == " ")
    }

    @Test func allWordsMustBeFoundSomewhere() {
        #expect(LibrarySearch.match(query: "demo kapitel", titles: titles, transcript: speech) != nil)
        #expect(LibrarySearch.match(query: "demo vimeo", titles: titles, transcript: speech) == nil)
    }

    @Test func swedishLettersAreTheirOwn() {
        #expect(LibrarySearch.match(query: "valkommen", titles: titles, transcript: speech) == nil)
        #expect(LibrarySearch.match(query: "välkommen", titles: titles, transcript: speech) != nil)
    }

    @Test func metaNameDecodesFromOldFiles() throws {
        let m = try BundleJSON.decoder.decode(RecordingMeta.self, from: Data("{}".utf8))
        #expect(m.name.isEmpty)
    }
}
