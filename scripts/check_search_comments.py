#!/usr/bin/env python3
"""Offline source/fixture checks for unified search and read-only comments.

Default mode is deterministic and requires no Swift SDK, account, or network.
--native opts into compiling/running three synthetic Swift comment checks plus
search policy and search-store executables on macOS (five jobs total).
"""
from __future__ import annotations

import argparse
import json
import platform
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def require(text: str, snippets: tuple[str, ...], label: str) -> None:
    absent = [snippet for snippet in snippets if snippet not in text]
    if absent:
        raise AssertionError(f"{label}: missing expected source contract: {absent!r}")


def offline_checks() -> int:
    checks = 0

    def ok(condition: bool, label: str) -> None:
        nonlocal checks
        if not condition:
            raise AssertionError(label)
        checks += 1

    policy = read("app/TingFlow/Core/SearchAggregationPolicy.swift")
    require(policy, (".netease, .kugou", "emby ? [.emby]", "subsonic ? [.subsonic]",
                    "seen.insert(song.id).inserted", "song.platform == platform",
                    "text.utf8.count <= 512", "CharacterSet.controlCharacters"), "search policy")
    checks += 1
    store = read("app/TingFlow/Core/Stores.swift")
    require(store, ("for platform in platforms", "catalog.search(text, platform: platform)",
                    "try await embySearch(text)", "try await subsonicSearch(text)",
                    "SearchAggregationPolicy.merged(buckets, platforms: platforms)",
                    "self.generation == token"), "search store")
    checks += 1
    require(store, ("catalogSearch = { _, platform in SearchPolishFixture.songs.filter { $0.platform == platform } }",),
            "search UI fixture filter changes cannot fall through to real catalog")
    checks += 1
    view = read("app/TingFlow/UI/LibraryPages.swift")
    require(view, ("emby.isSignedIn ? [SearchPlatformFilter(title: \"Emby\", platform: .emby)] : []",
                  "subsonic.isSignedIn ? [SearchPlatformFilter(title: \"音乐服\", platform: .subsonic)] : []",
                  "search.search(platforms: selected)", "private var visibleResults"), "search UI wiring")
    checks += 1

    art = read("app/TingFlow/Services/CatalogArtworkMapping.swift")
    require(art, ("CatalogArtworkMapping", "song.platform == .netease", "song.accountScope == nil",
                  "validID(song.platformID)", "seen.insert(song.platformID).inserted", ".prefix(30)",
                  "allowed.contains(id)", "let image = images[song.platformID] else { return song }"), "catalog artwork mapping")
    search_checks = read("tests/SearchPolicyChecks.swift")
    require(search_checks, ("unconnected servers omitted", "connected platforms appended",
                            "stable interleave and dedup", "no wrong ID or cross-platform image"), "search policy fixtures")
    checks += 2

    now_playing = read("app/TingFlow/UI/NowPlayingView.swift")
    require(now_playing, ("if let song = player.current, song.platform == .netease",
                          "SongCommentsView(song: song).environmentObject(netease)"), "now-playing comments entry")
    comments_view = read("app/TingFlow/Netease/SongCommentsView.swift")
    require(comments_view, (".task(id: RequestIdentity(song: song.id, account: netease.commentContextID, sort: sort))",
                            "netease.comments(for: song, sort: requestedSort, page: page, cursor: cursor)",
                            "model.cancel(clear: true)", ".onDisappear", "if $0 != .active { model.cancel() }",
                            "Text(verbatim: comment.content)", "仅供浏览；不支持发布、点赞或回复。"), "comments UI lifecycle")
    comment_models = read("app/TingFlow/Netease/SongCommentModels.swift")
    require(comment_models, ("case hot = 2, latest = 3", "pageSize = 20", "maximumPages = 50",
                             "normalHot#", "R_SO_4_", "CFGetTypeID", "text(row[\"content\"]"), "comment mapping")
    comment_store = read("app/TingFlow/Netease/SongCommentStore.swift")
    require(comment_store, ("private var ticket = UUID()", "worker?.cancel()", "deadline?.cancel()",
                            "SongCommentMapping.maximumPages", "requestedCursor", "seenCursors.insert(next).inserted",
                            "comments.append(contentsOf: additions.prefix", "private func stop"), "comment pagination store")
    netease_store = read("app/TingFlow/Netease/NeteaseStore.swift")
    require(netease_store, ("var commentContextID: String", "private func cancelCommentRequests()",
                            "song.accountScope == nil || (isSignedIn && song.accountScope == scopeID)",
                            "makeAnonymousCommentClient()", "context == commentContextID",
                            "if anonymous { reader.invalidate() }"), "account-scoped comment transport")
    client = read("app/TingFlow/Netease/NeteaseClient.swift")
    require(client, ("case comments = \"/api/v2/resource/comments\"", "endpoint == .comments ? 2_000_000",
                    "if endpoint != .comments { absorbResponseCookies(http, url: url) }"), "comment endpoint security")
    checks += 6

    require(policy, ("static func matches(_ raw: String, submitted: String)",
                     "!submitted.isEmpty && query(raw) == submitted"), "normalized search identity")
    require(view, ("guard matchesSubmittedQuery else", "selectedPlatform == nil || selectedPlatform == platform",
                   "!matchesSubmittedQuery", "SearchAggregationPolicy.matches(value, submitted: search.submittedQuery)",
                   ".frame(minHeight: 44)", ".accessibilityAddTraits(source == filter.title ? .isSelected : [])"), "search regression and accessibility wiring")
    if "source == platform.title" in view or "search.query == search.submittedQuery" in view:
        raise AssertionError("search UI must compare normalized query and platform identity, not display labels")
    require(search_checks, ("trimmed submission remains visible", "changed query hides old results",
                            "same metadata retains every platform and account candidate"), "search identity regression coverage")
    race_checks = read("tests/SearchStoreChecks.swift")
    require(race_checks, ("late old failure cannot replace a new search", "clear invalidates a non-cooperative result",
                         "failed provider preserves successful deduplicated bucket", "explicit retry resets failure",
                         "preconditionFailure(\"synthetic search must use an injected loader\")"), "offline search race coverage")
    require(read("tests/SongCommentStoreChecks.swift"), ("background cancel retains committed page and cursor",
            "explicit resume retries the uncommitted page", "late cancelled page failure cannot overwrite resumed results"), "comment cancellation retry coverage")
    require(read("app/TingFlow/Sources/SourceSelection.swift"), ("case .automatic: return enabled",
            "case .source(let id): return enabled.filter { $0.id == id }"), "manual parser source candidates remain selectable")
    checks += 6

    fixture = json.loads(read("tests/SongCommentSynthetic.json"))
    rows = fixture["data"]["comments"]
    ok(fixture["code"] == 200 and fixture["data"]["hasMore"] is False, "synthetic fixture response shape")
    ok([str(row["commentId"]) for row in rows] == ["9007199254740993", "42"], "fixture keeps exact mixed-form IDs")
    ok(all("example.invalid" in row["content"] for row in rows[:1]), "fixture uses inert example URL")
    ok("avatarUrl" in rows[0]["user"] and rows[0]["user"]["avatarUrl"].startswith("https://example.invalid/"),
       "fixture avatar is inert and should not be loaded")
    print(f"PASS: {checks} offline search/comment source and synthetic-fixture checks")
    print("No Swift compilation, account, credential, or network access was used.")
    return checks


def native_checks() -> None:
    if platform.system() != "Darwin" or not shutil.which("xcrun"):
        raise SystemExit("--native requires macOS with Xcode command-line tools (xcrun).")
    core = ["app/TingFlow/Core/Models.swift", "app/TingFlow/Core/PlaybackResource.swift",
            "app/TingFlow/Playback/ListeningSession.swift", "app/TingFlow/Core/ServerArtworkCache.swift",
            "app/TingFlow/Core/ServerArtworkDiagnostic.swift"]
    ncm = ["app/TingFlow/Netease/NeteaseModels.swift", "app/TingFlow/Netease/NeteaseAudioPolicy.swift",
           "app/TingFlow/Netease/NeteasePlaybackDiagnostic.swift", "app/TingFlow/Netease/NeteaseCloudPolicy.swift",
           "app/TingFlow/Netease/NeteaseHistoryPolicy.swift", "app/TingFlow/Netease/NeteaseCrypto.swift",
           "app/TingFlow/Netease/NeteaseXEAPI.swift", "app/TingFlow/Netease/NeteaseXEAPISession.swift",
           "app/TingFlow/Netease/NeteaseWire.swift", "app/TingFlow/Netease/NeteaseClient.swift",
           "app/TingFlow/Netease/SongCommentModels.swift"]
    common = ["xcrun", "swiftc", "-swift-version", "5"]
    with tempfile.TemporaryDirectory(prefix="tingflow-search-comments-") as temp:
        output = Path(temp)
        jobs = [
            ("search-policy", ["app/TingFlow/Core/Models.swift", "app/TingFlow/Core/SearchAggregationPolicy.swift",
                               "app/TingFlow/Services/CatalogArtworkMapping.swift", "tests/SearchPolicyChecks.swift"], []),
            ("search-store", ["app/TingFlow/Core/Models.swift", "app/TingFlow/Core/SearchAggregationPolicy.swift",
                              "app/TingFlow/Core/Stores.swift", "tests/SearchStoreChecks.swift"], []),
            ("song-comment-mapping", ["app/TingFlow/Core/Models.swift", "app/TingFlow/Netease/NeteaseModels.swift",
                                       "app/TingFlow/Netease/SongCommentModels.swift", "tests/SongCommentFixture.swift",
                                       "tests/SongCommentMappingChecks.swift"], []),
            ("song-comment-store", ["app/TingFlow/Core/Models.swift", "app/TingFlow/Netease/NeteaseModels.swift",
                                     "app/TingFlow/Netease/SongCommentModels.swift", "app/TingFlow/Netease/SongCommentStore.swift",
                                     "tests/SongCommentFixture.swift", "tests/SongCommentStoreChecks.swift"], []),
            ("song-comment-transport", core + ncm + ["app/TingFlow/Netease/NeteaseQRWindow.swift",
                  "app/TingFlow/Netease/NeteaseStore.swift", "tests/SongCommentFixture.swift",
                  "tests/SongCommentTransportFixture.swift", "tests/SongCommentTransportChecks.swift"], ["-lz"]),
        ]
        for name, sources, flags in jobs:
            binary = output / name
            command = common + [str(ROOT / source) for source in sources] + flags + ["-o", str(binary)]
            subprocess.run(command, cwd=ROOT, check=True)
            subprocess.run([str(binary)], cwd=ROOT, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true", help="also compile/run synthetic Swift checks on macOS")
    args = parser.parse_args()
    offline_checks()
    if args.native:
        native_checks()


if __name__ == "__main__":
    main()
