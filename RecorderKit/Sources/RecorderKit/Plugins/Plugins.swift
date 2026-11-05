import Foundation

/// Insticksprogram: en mapp med `plugin.json` och ett körbart program, i vilket språk som helst.
/// Appen kör programmet vid händelser (`recording.finished`, `export.finished`) eller som en åtgärd
/// användaren väljer, med händelsen som JSON på stdin; programmet kan svara med JSON på stdout
/// (`message`, `url`, `file`). Nya insticksprogram är avslagna tills användaren slår på dem — de
/// är program som körs på datorn. Se `docs/PLUGINS.md`.
public struct Plugin: Identifiable, Sendable, Equatable {
    public struct Action: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        /// Var åtgärden finns: `export` (efter en export) eller `recording` (i biblioteket).
        public var on: String
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.value(.id, ""); title = c.value(.title, ""); on = c.value(.on, "export")
        }
    }

    struct Manifest: Codable {
        var name: String
        var version: String
        var description: String
        var run: String
        var hooks: [String]
        var actions: [Action]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.value(.name, ""); version = c.value(.version, ""); description = c.value(.description, "")
            run = c.value(.run, ""); hooks = c.value(.hooks, []); actions = c.value(.actions, [])
        }
    }

    /// Mappens namn (stabilt id).
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let directory: URL
    public let executable: URL
    public let hooks: [String]
    public let actions: [Action]

    public static func == (a: Plugin, b: Plugin) -> Bool { a.directory == b.directory && a.version == b.version }
}

public enum Plugins {
    public static let recordingFinished = "recording.finished"
    public static let exportFinished = "export.finished"
    public static let action = "action"

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Bjarbys skärminspelare/Plugins", isDirectory: true)
    }

    /// Insticksprogrammen i mappen (de som har ett läsbart manifest och ett körbart program).
    public static func discover(in dir: URL = directory) -> [Plugin] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            let manifestURL = folder.appendingPathComponent("plugin.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let m = try? JSONDecoder().decode(Plugin.Manifest.self, from: data), !m.run.isEmpty else { return nil }
            let exe = folder.appendingPathComponent(m.run).standardizedFileURL
            // Programmet måste ligga i insticksprogrammets egen mapp.
            guard exe.path.hasPrefix(folder.standardizedFileURL.path + "/"), fm.isExecutableFile(atPath: exe.path) else { return nil }
            return Plugin(id: folder.lastPathComponent, name: m.name.isEmpty ? folder.lastPathComponent : m.name,
                          version: m.version, description: m.description, directory: folder, executable: exe,
                          hooks: m.hooks, actions: m.actions.filter { !$0.id.isEmpty })
        }
    }

    /// Stoppar programmet och allt det startat (bara vår egen processträd). Underprocesserna samlas
    /// in först — annars hinner de flytta till launchd när föräldern dör — får SIGTERM, och de
    /// som lever efter en sekund SIGKILL. En underprocess som struntade i SIGTERM höll annars
    /// utdataröret öppet tills den var klar (uppmätt: 13 s i stället för tidsgränsen).
    static func stopTree(_ root: pid_t) async {
        var all: [pid_t] = []
        var queue = [root]
        while let pid = queue.popLast() {
            all.append(pid)
            var buffer = [pid_t](repeating: 0, count: 256)
            let n = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
            if n > 0 { queue += buffer.prefix(Int(n)).filter { $0 > 0 } }
        }
        for pid in all { kill(pid, SIGTERM) }
        try? await Task.sleep(for: .seconds(1))
        for pid in all where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Vad programmet svarade.
    public struct Reply: Sendable {
        public var status: Int32
        public var message: String?
        public var url: URL?
        public var file: URL?
        public var errorOutput: String
        public var ok: Bool { status == 0 }
    }

    /// Kör programmet med händelsen på stdin (JSON). Avbryts efter `timeout` sekunder.
    public static func run(_ plugin: Plugin, event: String, payload: [String: Any], timeout: Double = 600) async -> Reply {
        var body = payload
        body["event"] = event
        body["plugin"] = plugin.id
        body["appVersion"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let input = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        let process = Process()
        process.executableURL = plugin.executable
        process.currentDirectoryURL = plugin.directory
        var env = ProcessInfo.processInfo.environment
        env["SKARMINSPELARE_EVENT"] = event
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch {
            return Reply(status: -1, errorOutput: error.localizedDescription)
        }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        // Läs utdata medan programmet kör (annars kan ett fullt rör låsa det).
        async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
        async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning { await stopTree(process.processIdentifier) }
        }
        let (o, e) = await (out, err)
        process.waitUntilExit()
        watchdog.cancel()
        var reply = Reply(status: process.terminationStatus, errorOutput: String(decoding: e.prefix(4000), as: UTF8.self))
        if let json = (try? JSONSerialization.jsonObject(with: o)) as? [String: Any] {
            reply.message = json["message"] as? String
            reply.url = (json["url"] as? String).flatMap(URL.init(string:))
            reply.file = (json["file"] as? String).map { URL(fileURLWithPath: $0) }
        } else {
            let text = String(decoding: o.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { reply.message = text }
        }
        return reply
    }
}
