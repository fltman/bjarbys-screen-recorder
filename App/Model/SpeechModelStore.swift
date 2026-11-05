import Foundation
import SwiftUI
import RecorderKit

/// Nedladdningarna av talmodeller (för den nedladdade appen, som har whisper-verktygen men inga
/// modeller). En nedladdning i taget per modell; taldetekteringen hämtas med den första.
@MainActor
final class SpeechModelStore: ObservableObject {
    static let shared = SpeechModelStore()

    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    /// Ökar när en modell kommit eller tagits bort (vyerna läser filsystemet).
    @Published private(set) var revision = 0
    private var tasks: [String: Task<Void, Never>] = [:]

    func isInstalled(_ e: SpeechModels.Entry) -> Bool { SpeechModels.isInstalled(e) }

    func download(_ e: SpeechModels.Entry) {
        guard tasks[e.file] == nil else { return }
        errors[e.file] = nil
        progress[e.file] = 0
        tasks[e.file] = Task {
            do {
                if !SpeechModels.isInstalled(SpeechModels.vad) { try await SpeechModels.download(SpeechModels.vad) }
                try await SpeechModels.download(e) { p in
                    Task { @MainActor [weak self] in if self?.progress[e.file] != nil { self?.progress[e.file] = p } }
                }
            } catch {
                if !Task.isCancelled { errors[e.file] = error.localizedDescription }
            }
            progress[e.file] = nil
            tasks[e.file] = nil
            revision += 1
        }
    }

    func cancel(_ e: SpeechModels.Entry) {
        tasks[e.file]?.cancel()
    }

    func remove(_ e: SpeechModels.Entry) {
        try? FileManager.default.removeItem(at: SpeechModels.directory.appendingPathComponent(e.file))
        revision += 1
    }

    /// "1,5 GB", "488 MB" med gränssnittets decimaltecken.
    static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? AppLocale.format("%.1f GB", Double(bytes) / 1e9) : AppLocale.format("%.0f MB", Double(bytes) / 1e6)
    }
}

/// Modellerna att ladda ned, med förlopp. `entries` = vilka som visas.
struct SpeechModelsView: View {
    @ObservedObject private var store = SpeechModelStore.shared
    var entries: [SpeechModels.Entry] = SpeechModels.catalog
    var showsFootnote = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(entries) { e in row(e) }
            if showsFootnote {
                Text("Hämtas från Hugging Face och kontrolleras mot en kontrollsumma. Sparas i Application Support, inte i inspelningarna.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(store.revision)
    }

    @ViewBuilder private func row(_ e: SpeechModels.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: e.title).fontWeight(.semibold)
                    Text(verbatim: e.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let p = store.progress[e.file] {
                    ProgressView(value: p).frame(width: 110)
                    Button("Avbryt") { store.cancel(e) }.controlSize(.small)
                } else if store.isInstalled(e) {
                    Label("Nedladdad", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    Button("Ta bort") { store.remove(e) }.controlSize(.small)
                } else {
                    Button("Ladda ned (\(SpeechModelStore.size(e.size)))") { store.download(e) }
                        .controlSize(.small)
                }
            }
            if let error = store.errors[e.file] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// Fönstret Talmodeller.
struct SpeechModelsSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Talmodeller").font(.title2.bold())
            Text("Transkriberingen och översättningen görs på datorn med whisper.cpp, som följer med appen. Modellerna laddas ned en gång.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SpeechModelsView()
        }
        .padding(20)
        .frame(width: 500)
    }
}
