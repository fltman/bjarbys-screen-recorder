import Foundation
import SwiftUI
import AppKit
import RecorderKit

/// Insticksprogrammen i appen: vilka som är påslagna (nya är avslagna), körningar vid händelser
/// och åtgärder, och en logg över de senaste svaren.
@MainActor
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    struct Run: Identifiable {
        let id = UUID()
        let plugin: String
        let event: String
        let date = Date()
        let reply: Plugins.Reply
    }

    @Published private(set) var plugins: [Plugin] = []
    @Published private(set) var log: [Run] = []
    @Published private var enabledIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "enabledPlugins") ?? [])

    private init() { reload() }

    func reload() {
        try? FileManager.default.createDirectory(at: Plugins.directory, withIntermediateDirectories: true)
        plugins = Plugins.discover()
    }

    func isEnabled(_ p: Plugin) -> Bool { enabledIDs.contains(p.id) }

    func setEnabled(_ p: Plugin, _ on: Bool) {
        if on { enabledIDs.insert(p.id) } else { enabledIDs.remove(p.id) }
        UserDefaults.standard.set(Array(enabledIDs).sorted(), forKey: "enabledPlugins")
    }

    var enabled: [Plugin] { plugins.filter(isEnabled) }

    /// Åtgärderna som passar platsen (`export` eller `recording`), från påslagna insticksprogram.
    func actions(on place: String) -> [(plugin: Plugin, action: Plugin.Action)] {
        enabled.flatMap { p in p.actions.filter { $0.on == place }.map { (p, $0) } }
    }

    /// Kör alla påslagna insticksprogram som lyssnar på händelsen (i bakgrunden).
    func fire(_ event: String, payload: [String: Any]) {
        reload()
        for p in enabled where p.hooks.contains(event) {
            let body = payload
            Task {
                let reply = await Plugins.run(p, event: event, payload: body)
                log.insert(Run(plugin: p.name, event: event, reply: reply), at: 0)
                log = Array(log.prefix(30))
            }
        }
    }

    /// Kör en åtgärd och returnerar svaret (länken läggs i urklipp).
    func run(_ p: Plugin, action: Plugin.Action, payload: [String: Any]) async -> Plugins.Reply {
        var body = payload
        body["action"] = action.id
        let reply = await Plugins.run(p, event: Plugins.action, payload: body)
        log.insert(Run(plugin: p.name, event: action.title, reply: reply), at: 0)
        if let url = reply.url {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        return reply
    }
}

/// Insticksprogram …: listan, påslagning och senaste körningarna.
struct PluginSettingsView: View {
    @ObservedObject var store = PluginStore.shared

    var body: some View {
        Form {
            Section {
                Text("Ett insticksprogram är en mapp med plugin.json och ett program i valfritt språk. Det körs när en inspelning eller export blir klar, eller som en åtgärd efter exporten. Nya insticksprogram är avslagna: slå bara på sådant du litar på — det körs på din dator.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Öppna mappen") { NSWorkspace.shared.open(Plugins.directory) }
                    Button("Läs om") { store.reload() }
                    Spacer()
                }
            }
            Section("Installerade") {
                if store.plugins.isEmpty {
                    Text("Inga insticksprogram i mappen.").foregroundStyle(.secondary)
                }
                ForEach(store.plugins) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle(isOn: Binding(get: { store.isEnabled(p) }, set: { store.setEnabled(p, $0) })) {
                            Text(verbatim: p.version.isEmpty ? p.name : "\(p.name) \(p.version)").font(.headline)
                        }
                        if !p.description.isEmpty { Text(verbatim: p.description).font(.caption).foregroundStyle(.secondary) }
                        let parts = p.hooks.map { $0 == Plugins.recordingFinished ? String(localized: "när en inspelning är klar")
                                                  : $0 == Plugins.exportFinished ? String(localized: "när en export är klar") : $0 }
                            + p.actions.map { "«\($0.title)»" }
                        if !parts.isEmpty {
                            Text(verbatim: parts.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if !store.log.isEmpty {
                Section("Senaste körningarna") {
                    ForEach(store.log) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(run.plugin) — \(run.event)").font(.callout)
                            Text(verbatim: run.reply.ok ? (run.reply.message ?? run.reply.url?.absoluteString ?? "OK")
                                                        : "kod \(run.reply.status): \(run.reply.errorOutput)")
                                .font(.caption).foregroundStyle(run.reply.ok ? Color.secondary : Color.orange).lineLimit(3)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
    }
}
