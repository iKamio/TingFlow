// macOS: concatenate Models.swift, PlaybackResource.swift, EmbyClient.swift, then this file.
import Foundation
var embyChecks = 0
func embyCheck(_ condition: Bool, _ label: String) {
    precondition(condition, label); embyChecks += 1
}
func embyReject(_ value: String) {
    do { _ = try EmbyAddress.base(value); fatalError("Accepted unsafe base") } catch { embyChecks += 1 }
}
let embyBase = try EmbyAddress.base("https://EXAMPLE.invalid:443/proxy/emby/")
embyCheck(embyBase.absoluteString == "https://example.invalid/proxy/emby", "canonical prefix")
for value in ["http://example.invalid", "https://u:p@example.invalid/emby", "https://example.invalid/?api_key=x",
              "https://example.invalid/#token", "https://example.invalid/a/%2e%2e", "https://example.invalid/a/%2f"] { embyReject(value) }
let embyURL = try EmbyAddress.endpoint(embyBase, ["Audio", "opaque ?#", "stream"], [
    URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "MediaSourceId", value: "a&b")])
embyCheck(embyURL.path.hasPrefix("/proxy/emby/Audio/"), "prefix survives")
embyCheck(embyURL.absoluteString.contains("opaque%20%3F%23"), "opaque segment encoded")
embyCheck(!embyURL.absoluteString.lowercased().contains("api_key"), "no URL credentials")
embyCheck(!EmbyAddress.validID("../escape") && !EmbyAddress.validID("%2e") && !EmbyAddress.validID("\"\r\n"), "ID injection rejected")
embyCheck(!EmbyAddress.validToken("secret\nheader"), "header injection rejected")
let embyScope = EmbyAddress.scope(base: embyBase, server: "s", user: "u")
embyCheck(embyScope != EmbyAddress.scope(base: embyBase, server: "s", user: "other"), "user partition")
embyCheck(embyScope != EmbyAddress.scope(base: try EmbyAddress.base("https://other.invalid/emby"), server: "s", user: "u"), "origin partition")
let embyItemsJSON = #"{"Items":[{"Id":"1","Type":"Audio","Name":"A","PlaylistItemId":"entry1","RunTimeTicks":10000000},{"Id":"1","Type":"Audio","Name":"A","PlaylistItemId":"entry2"}],"TotalRecordCount":2}"#
let embyItems = try JSONDecoder().decode(EmbyPage.self, from: Data(embyItemsJSON.utf8))
let embyQueue = embyItems.Items!.compactMap { $0.song(scope: embyScope) }
embyCheck(embyQueue.count == 2 && embyQueue[0].id == embyQueue[1].id, "playlist duplicates retained")
embyCheck(embyQueue[0].duration == 1 && embyQueue[0].accountScope == embyScope, "ticks and namespace")
let embyFixture = #"{"Id":"m","Protocol":"File","Container":"m4a","SupportsDirectStream":true,"MediaStreams":[{"Type":"Audio","Codec":"aac"}]}"#
func embySource(_ json: String) throws -> EmbySource { try JSONDecoder().decode(EmbySource.self, from: Data(json.utf8)) }
embyCheck(try embySource(embyFixture).progressiveMIME == "audio/mp4", "M4A MIME")
embyCheck(try embySource(embyFixture.replacingOccurrences(of: "aac", with: "opus")).progressiveMIME == nil, "codec rejection")
embyCheck(try embySource(embyFixture.replacingOccurrences(of: "File", with: "Http")).progressiveMIME == "audio/mp4", "HTTP metadata accepted only for server-proxied audio")
embyCheck(try embySource(embyFixture.replacingOccurrences(of: "true", with: "false")).progressiveMIME == nil, "transcode-only rejection")
embyCheck(EmbyFailure.transcodingRequired.localizedDescription.contains("当前尚不支持转码"), "safe LocalizedError")
print("PASS: \(embyChecks) Emby contract checks; no server requests")
