import Foundation

/// Persistent state that must survive a restart.
///
/// `fileOffsets` stops a relaunch re-reading multi-megabyte transcripts from
/// zero; `notifiedKeys` stops it re-firing banners for events already shown.
public struct Checkpoint: Codable, Sendable, Equatable {
    public var fileOffsets: [String: UInt64]
    public var notifiedKeys: [String: Date]

    public init(fileOffsets: [String: UInt64] = [:], notifiedKeys: [String: Date] = [:]) {
        self.fileOffsets = fileOffsets
        self.notifiedKeys = notifiedKeys
    }

    public func pruned(before cutoff: Date) -> Checkpoint {
        Checkpoint(fileOffsets: fileOffsets,
                   notifiedKeys: notifiedKeys.filter { $0.value >= cutoff })
    }
}

/// Reads and writes the checkpoint at `~/.agentmenu/state.json`.
///
/// `load` never throws: a corrupt or missing checkpoint means "start fresh",
/// which is degraded but correct. Refusing to launch over it would not be.
public struct CheckpointStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> Checkpoint {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Checkpoint.self, from: data) else {
            return Checkpoint()
        }
        return c
    }

    public func save(_ checkpoint: Checkpoint) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(checkpoint)
        let tmp = url.appendingPathExtension("agentmenu-tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
