import Testing
import Foundation
@testable import RecorderKit

@Suite struct PluginTests {
    /// Ett insticksprogram i en tillfällig mapp: manifest och ett skalskript.
    func make(_ root: URL, _ name: String, run: String = "run.sh", script: String?, executable: Bool = true) throws {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = #"{"name":"\#(name)","version":"1","run":"\#(run)","hooks":["export.finished"],"actions":[{"id":"a","title":"Gör något","on":"export"}]}"#
        try manifest.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        if let script {
            let url = dir.appendingPathComponent("run.sh")
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
    }

    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)") }

    @Test func discoversOnlyRunnablePluginsInsideTheirFolder() throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        try make(r, "bra", script: "#!/bin/sh\necho hej\n")
        try make(r, "utan-korratt", script: "#!/bin/sh\n", executable: false)
        try make(r, "utbrytare", run: "../bra/run.sh", script: nil)
        let found = Plugins.discover(in: r)
        #expect(found.map(\.id) == ["bra"])
        #expect(found.first?.actions.map(\.title) == ["Gör något"])
        #expect(found.first?.hooks == ["export.finished"])
    }

    @Test func eventGoesInAsJsonAndTheReplyComesBack() async throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        // Skriptet plockar ut "file" ur JSON:en (utan beroenden) och svarar med meddelande och länk.
        try make(r, "eko", script: """
        #!/bin/sh
        input=$(cat)
        file=$(printf '%s' "$input" | sed -n 's/.*"file":"\\([^"]*\\)".*/\\1/p')
        printf '{"message":"fick %s (%s)","url":"https://example.com/x"}' "$file" "$SKARMINSPELARE_EVENT"
        """)
        let plugin = try #require(Plugins.discover(in: r).first)
        let reply = await Plugins.run(plugin, event: Plugins.exportFinished, payload: ["file": "/tmp/film.mp4"])
        #expect(reply.ok)
        #expect(reply.message == "fick /tmp/film.mp4 (export.finished)")
        #expect(reply.url?.absoluteString == "https://example.com/x")
    }

    @Test func failureGivesStatusAndErrorOutput() async throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        try make(r, "fel", script: "#!/bin/sh\necho 'det gick inte' >&2\nexit 3\n")
        let reply = await Plugins.run(try #require(Plugins.discover(in: r).first), event: Plugins.action, payload: [:])
        #expect(reply.status == 3 && !reply.ok)
        #expect(reply.errorOutput.contains("det gick inte"))
    }

    @Test func aHangingPluginWithAChildIsStoppedToo() async throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        // Underprocessen ärver utdataröret och struntar i SIGTERM: utan att den stoppas blir
        // läsningen hängande tills den är klar (12,5 s).
        try make(r, "barn", script: "#!/bin/sh\n(trap '' TERM; sleep 12.5) &\nwait\n")
        let started = Date()
        let reply = await Plugins.run(try #require(Plugins.discover(in: r).first), event: Plugins.action, payload: [:], timeout: 0.5)
        #expect(!reply.ok)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aHangingPluginIsStopped() async throws {
        let r = root(); defer { try? FileManager.default.removeItem(at: r) }
        try make(r, "hanger", script: "#!/bin/sh\nsleep 30\n")
        let started = Date()
        let reply = await Plugins.run(try #require(Plugins.discover(in: r).first), event: Plugins.action, payload: [:], timeout: 0.5)
        #expect(!reply.ok)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
