import Foundation

/// Tails an append-only file by byte offset.
///
/// Agents append to their transcripts while we read, so reads land mid-line
/// constantly. A trailing fragment is buffered and prepended to the next read
/// rather than emitted — emitting it would hand the parsers malformed JSON on
/// essentially every poll.
public struct IncrementalFileReader: Sendable {
    public let url: URL
    public private(set) var offset: UInt64 = 0
    private var carry = Data()

    public init(url: URL) { self.url = url }

    public mutating func readNewLines() -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {          // truncated or replaced — start over
            offset = 0
            carry.removeAll()
        }
        guard size > offset else { return [] }

        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return [] }
        // Advance by what was ACTUALLY consumed, not by the earlier size probe.
        // `readToEnd()` reads to the real EOF at read time, so if the agent appended
        // between the probe and the read, `chunk` is longer than `size - offset`.
        // Trusting `size` here would re-read — and re-emit — those bytes next call.
        offset += UInt64(chunk.count)

        var buffer = carry
        buffer.append(chunk)
        carry.removeAll()

        var lines: [Data] = []
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<nl]
            if !line.isEmpty { lines.append(Data(line)) }
            start = buffer.index(after: nl)
        }
        if start < buffer.endIndex { carry = Data(buffer[start...]) }
        return lines
    }
}
