// Appended after Models.swift and executed using macOS Swift by CI.
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fatalError("FAIL: \(label)") }
}
let song = Song(platform: .netease, platformID: "123", title: "Test", artist: "Artist", album: "Album", duration: 180)
let other = Song(platform: .kugou, platformID: "123", title: "Test", artist: "Artist", album: "Album", duration: 180)
check(song.id == "wy:123", "opaque song identity")
check(song.id != other.id, "platform namespace")
let encoded = try JSONEncoder().encode(song)
let decoded = try JSONDecoder().decode(Song.self, from: encoded)
check(decoded == song, "song round trip")
let lines = LRCParser.parse("[00:02.10]second\n[00:01.5][00:03.050]repeat\n[ar:ignored]\n[00:04]four")
check(lines.count == 4, "all timestamp tags")
check(abs(lines[0].time - 1.5) < 0.00001, "tenths precision")
check(abs(lines[1].time - 2.1) < 0.00001, "hundredths precision")
check(abs(lines[2].time - 3.05) < 0.00001, "millisecond precision")
check(lines.map(\.id) == [0, 1, 2, 3], "stable lyric identities")
check(lines[0].text == "repeat" && lines[2].text == "repeat", "multiple timestamps")
check(LRCParser.parse("untimed text").isEmpty, "untimed input")
check(LRCParser.parse("[offset:500]\n[00:01]line").first?.time == 1.5, "offset application")
check(RepeatMode.sequential.next == .all && RepeatMode.all.next == .one && RepeatMode.one.next == .sequential, "repeat sequence")
var scoped = song
scoped.accountScope = "server-one:user-one"
var anotherUser = scoped
anotherUser.accountScope = "server-one:user-two"
check(scoped.id != anotherUser.id, "account isolation")
check(scoped.id != song.id, "anonymous isolation")
let legacy = Data("{\"platform\":\"wy\",\"platformID\":\"1\",\"title\":\"Legacy\",\"artist\":\"A\",\"album\":\"B\",\"duration\":1}".utf8)
let legacySong = try JSONDecoder().decode(Song.self, from: legacy)
check(legacySong.accountScope == nil, "legacy optional scope")
check(MusicPlatform.emby.title == "Emby", "server source")
print("PASS: 16 model checks")
