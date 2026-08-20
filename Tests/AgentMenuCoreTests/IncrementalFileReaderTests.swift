import Testing
import Foundation
@testable import AgentMenuCore

private func tempFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ifr-\(UUID().uuidString).jsonl")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func append(_ s: String, to url: URL) throws {
    let h = try FileHandle(forWritingTo: url)
    try h.seekToEnd()
    try h.write(contentsOf: Data(s.utf8))
    try h.close()
}

@Test func readsOnlyNewLinesAcrossCalls() throws {
    let url = try tempFile("a\nb\n")
    var r = IncrementalFileReader(url: url)
    #expect(r.readNewLines().map { String(decoding: $0, as: UTF8.self) } == ["a", "b"])
    #expect(r.readNewLines().isEmpty)
    try append("c\n", to: url)
    #expect(r.readNewLines().map { String(decoding: $0, as: UTF8.self) } == ["c"])
}

@Test func holdsBackPartialTrailingLineUntilComplete() throws {
    let url = try tempFile("full\npar")
    var r = IncrementalFileReader(url: url)
    // "par" has no newline yet — a half-written record, not data.
    #expect(r.readNewLines().map { String(decoding: $0, as: UTF8.self) } == ["full"])
    try append("tial\n", to: url)
    #expect(r.readNewLines().map { String(decoding: $0, as: UTF8.self) } == ["partial"])
}

@Test func restartsWhenFileIsTruncated() throws {
    let url = try tempFile("one\ntwo\n")
    var r = IncrementalFileReader(url: url)
    _ = r.readNewLines()
    try "short\n".write(to: url, atomically: true, encoding: .utf8)
    // File shrank below our offset: treat as new, re-read from zero.
    #expect(r.readNewLines().map { String(decoding: $0, as: UTF8.self) } == ["short"])
}

@Test func missingFileYieldsNothingRatherThanThrowing() {
    var r = IncrementalFileReader(url: URL(fileURLWithPath: "/nope/missing.jsonl"))
    #expect(r.readNewLines().isEmpty)
}

@Test func offsetAdvancesByBytesConsumedNotStaleSizeProbe() throws {
    // Concurrency test: agent appends between size probe and read.
    // Old code would set offset = size (stale probe), causing re-emission.
    // New code sets offset += chunk.count (actual bytes read), preventing duplication.
    let url = try tempFile("one\n")
    var r = IncrementalFileReader(url: url)

    // First read: consumes "one\n" (4 bytes)
    let first = r.readNewLines().map { String(decoding: $0, as: UTF8.self) }
    #expect(first == ["one"])
    #expect(r.offset == 4)

    // Append "two\n" (4 bytes) — file is now 8 bytes
    try append("two\n", to: url)

    // Second read: should consume only the new 4 bytes
    let second = r.readNewLines().map { String(decoding: $0, as: UTF8.self) }
    #expect(second == ["two"])
    #expect(r.offset == 8)

    // Critical: third read should return empty, not re-emit "two"
    // (Would fail with offset=4 bug: size(8) > offset(4), re-read bytes 4-8, emit "two" again)
    let third = r.readNewLines()
    #expect(third.isEmpty, "offset should have advanced by bytes consumed, not stale size probe")
}
