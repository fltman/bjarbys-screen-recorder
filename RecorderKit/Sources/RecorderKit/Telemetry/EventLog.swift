import Foundation

/// Skriver `events.jsonl` en rad i taget. Varje rad går direkt till filen med ett
/// `write`-anrop, så att en krasch eller `kill -9` bara kan förstöra den sista raden.
/// Läsaren kastar en sådan avbruten rad.
public final class EventLogWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "skarminspelare.eventlog", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    private var closed = false
    private var linesSinceSync = 0
    public private(set) var count = 0

    public init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func append(_ event: InputEvent) {
        queue.async { [self] in
            guard !closed, var line = try? encoder.encode(event) else { return }
            line.append(0x0A)
            try? handle.write(contentsOf: line)
            count += 1
            linesSinceSync += 1
            // Skydd mot strömavbrott, inte bara krascher: synka till disken då och då.
            if linesSinceSync >= 500 {
                try? handle.synchronize()
                linesSinceSync = 0
            }
        }
    }

    public func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            try? handle.synchronize()
            try? handle.close()
        }
    }
}

public enum EventLogReader {
    /// Läser alla hela rader. En rad som inte går att tolka (typiskt den sista efter en
    /// krasch) hoppas över utan att resten går förlorad.
    public static func read(_ url: URL) -> [InputEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }

    public static func parse(_ data: Data) -> [InputEvent] {
        let decoder = JSONDecoder()
        var events: [InputEvent] = []
        events.reserveCapacity(data.count / 40)
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let e = try? decoder.decode(InputEvent.self, from: Data(line)) {
                events.append(e)
            }
        }
        // Raderna skrivs från flera trådar via en kö och kan i sällsynta fall hamna
        // några millisekunder ur ordning. Sortera stabilt på tid.
        return events.enumerated().sorted {
            $0.element.t == $1.element.t ? $0.offset < $1.offset : $0.element.t < $1.element.t
        }.map(\.element)
    }
}
