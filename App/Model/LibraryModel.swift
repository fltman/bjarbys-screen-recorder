import Foundation
import SwiftUI
import RecorderKit

/// Inspelningarna i biblioteket. Filsystemet är sanningen; listan läses om när något
/// har ändrats.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var items: [RecordingLibrary.Item] = []
    let directory = RecordingLibrary.defaultDirectory
    /// Sökningen i biblioteket ("" = allt).
    @Published var query = ""
    /// Det som sades i varje transkriberad inspelning, för sökningen (läses i bakgrunden).
    @Published private(set) var transcripts: [URL: String] = [:]

    init() { reload() }

    func reload() {
        items = RecordingLibrary.scan(directory)
        let bundles = items.map(\.bundle)
        Task.detached(priority: .utility) {
            var texts: [URL: String] = [:]
            for b in bundles {
                if let t = b.readTranscript() { texts[b.url] = t.words.map(\.text).joined(separator: " ") }
            }
            let found = texts
            await MainActor.run { self.transcripts = found }
        }
    }

    /// Inspelningarna som matchar sökningen, med citatet om träffen var i talet.
    var filtered: [(item: RecordingLibrary.Item, match: LibrarySearch.Match)] {
        items.compactMap { item in
            let titles = [item.meta?.name ?? "", item.meta?.source.title ?? "", RecordingCard.title(for: item)]
            return LibrarySearch.match(query: query, titles: titles, transcript: transcripts[item.bundle.url]).map { (item, $0) }
        }
    }

    /// Ger inspelningen ett eget namn i biblioteket (tomt = datumet igen).
    func rename(_ item: RecordingLibrary.Item, to name: String) {
        guard var meta = try? item.bundle.readMeta() else { return }
        meta.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? item.bundle.writeMeta(meta)
        reload()
    }

    /// Räddar inspelningar som aldrig stoppades (krasch, strömavbrott). Körs vid start.
    func recoverUnfinished(excluding active: URL?) async -> Int {
        let unfinished = Recovery.unfinished(in: directory, excluding: active)
        for bundle in unfinished {
            _ = try? await Recovery.recover(bundle)
            if !FileManager.default.fileExists(atPath: bundle.thumbnailURL.path) {
                await CaptureSession.makeThumbnail(for: bundle, at: 1)
            }
        }
        if !unfinished.isEmpty { reload() }
        return unfinished.count
    }

    func moveToTrash(_ item: RecordingLibrary.Item) {
        try? FileManager.default.trashItem(at: item.bundle.url, resultingItemURL: nil)
        reload()
    }

    func revealInFinder(_ item: RecordingLibrary.Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.bundle.url])
    }
}
