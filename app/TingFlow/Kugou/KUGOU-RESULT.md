# KuGou adapter — current result, 2026-11-26

The authoritative complete report is the source-root `KUGOU-RESULT.md`. This notice replaces the earlier partial worker report and its obsolete profile/RSA narrative.

Current adapter intentionally has only four official HTTPS operations: QR registration/checking and read-only account playlists/tracks. QR registration uses Web appid=1014; QR checking and standard cloud reads use appid=1005/clientver=20489. Exact Web/Android signatures match the supplied local reference in offline synthetic Node and independent Python checks.

Profile is deliberately ID-only from the authorized QR response, or from a valid credential restored from SecureVault. Restoration is not an independent live identity/session verification. No profile network endpoint, RSA portrait code or older HTTP user_info is called. New login requires an actual status-4 QR response and successful credential persistence; a failed replacement preserves the old account.

MainActor integration signatures:
```swift
@StateObject private var kugou = KugouStore()
KugouAccountView(store: kugou)
KugouPlaylistsView(store: kugou, library: library, onPlay: { songs, index in
    guard let scope = kugou.accountScope,
          songs.allSatisfy({ $0.accountScope == scope }) else { return }
    player.play(songs, at: index)
})
KugouPlaylistView(store: kugou, library: library, playlist: playlist, onPlay: onPlay)
```

Methods: `await restore()`, `await refresh()`, `try await tracks(in:)`, `startQRCodeLogin()` (explicit button only), `cancelQRCodeLogin()`, `setForeground(_:)`, `signOut()`. Forward root ScenePhase while the shared store lives; merge/remove `accountScope` in `library.activateScopes(_:)` without replacing other provider scopes. Stop/recheck pending playback on scope change. Credentials and signed requests must never reach scripts/LX. These views no longer depend on another provider's EnvironmentObject.

Single default offline check command from source root:
```sh
python3 scripts/check_kugou.py
```
Default checks pass without building or networking. `--native` explicitly opts into compiling/running a standalone synthetic macOS Swift runner after separate authorization. It was NOT run here: no Swift/Apple SDK, native runtime/typecheck, app build, live account/API call, publication or branch push occurred. Source-policy assertions and reference vectors are not Swift runtime or live compatibility proof.

The full report lists every touched file, four exact routes, bounded transport/state limits, injection APIs, local reference digests and owner integration/release gates. MIT reference attribution is in `KUGOU-NOTICE.md`.
