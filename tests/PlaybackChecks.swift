// Concatenate after PlaybackPolicy.swift; run with macOS `swift` (no network).
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
}
func rejected(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}
let range = try AudioByteRange("bytes 12-20/21")
expect(range.start == 12 && range.end == 20 && range.total == 21 && range.length == 9, "range fields")
try range.validate(start: 12, end: 999, knownTotal: 21)
expect(rejected { try range.validate(start: 11, end: 20, knownTotal: 21) }, "wrong start")
expect(rejected { try range.validate(start: 12, end: 19, knownTotal: 21) }, "oversized response")
expect(rejected { try range.validate(start: 12, end: 20, knownTotal: 22) }, "changed total")
for invalid in ["bytes */21", "bytes 0-1/*", "bytes 2-1/3", "bytes 0-2/2", "bytes -1-2/4", "bytes +1-2/4", "bytes 0-0/0", "bytes 0-1/999999999999999999999", "bytes 0-1/3 trailing", "items 0-1/3"] {
    expect(rejected { _ = try AudioByteRange(invalid) }, "reject malformed range")
}
let edge = try AudioByteRange("bytes 9223372036854775806-9223372036854775806/9223372036854775807")
expect(edge.length == 1, "no Int64 overflow")
let ids = ["a", "b", "c", "d"]
let order = PlaybackPolicy.order(ids: ids, start: 2, shuffle: true)
expect(order.first == 2 && Set(order).count == ids.count, "shuffle visits each slot once")
expect(order == PlaybackPolicy.order(ids: ids, start: 2, shuffle: true), "stable shuffle")
expect(PlaybackPolicy.order(ids: [], start: -1, shuffle: true).isEmpty, "empty queue")
expect(PlaybackPolicy.finite(.infinity) == 0 && PlaybackPolicy.finite(.nan) == 0, "finite times")
expect(PlaybackPolicy.metadata("https://example.invalid/?token=secret") == "—", "URL not metadata")
try PlaybackPolicy.validateURL(URL(string: "https://example.invalid/audio")!)
for url in ["http://example.invalid/a.mp3", "https://u:p@example.invalid/audio", "https://example.invalid/a.m3u8", "file:///tmp/a.mp3"] {
    expect(rejected { try PlaybackPolicy.validateURL(URL(string: url)!) }, "unsafe source rejected")
}
try PlaybackPolicy.validateURL(URL(fileURLWithPath: "/tmp/audio.mp3"), local: true)
print("PASS: Playback range, shuffle, finite-time and source-policy checks")
