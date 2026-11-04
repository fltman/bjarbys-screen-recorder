import Foundation
import SwiftUI
import RecorderKit

/// Inspelningarna i biblioteket. Filsystemet är sanningen; listan läses om när något
/// har ändrats.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var items: [RecordingLibrary.Item] = []
    let directory = RecordingLibrary.defaultDirectory

    init() { reload() }

    func reload() {
        items = RecordingLibrary.scan(directory)
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
