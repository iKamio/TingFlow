import Foundation

@MainActor enum KugouRootStore {
    static func make() -> KugouStore {
        #if DEBUG
        if UIPolishFixture.enabled {
            return KugouStore(client: KugouOfflineNavigationClient(), vault: KugouOfflineNavigationVault())
        }
        #endif
        return KugouStore()
    }
}

#if DEBUG
/// Navigation-only synthetic fixture. Never reads Keychain or makes an HTTP request.
private final class KugouOfflineNavigationVault: KugouCredentialVault {
    private var data: Data?
    private var failRemove = false
    init() {
        if ProcessInfo.processInfo.arguments.contains("-TingFlowKugouRemovalFixture") {
            let device = KugouDevice(mid: "123456789012345678", dev: String(repeating: "A", count: 32))
            data = try? JSONEncoder().encode(KugouCredential(userID: "99942", token: "synthetic-navigation-token", device: device))
            failRemove = true
        }
    }
    func read() throws -> Data? { data }
    func save(_ data: Data) throws { throw KugouError.storage }
    func remove() throws {
        if failRemove { failRemove = false; throw KugouError.storage }
        data = nil
    }
}
private struct KugouOfflineNavigationClient: KugouServing {
    func qrKey(device: KugouDevice) async throws -> String { throw KugouError.unavailable }
    func checkQR(_ key: String, device: KugouDevice) async throws -> KugouQRResult { throw KugouError.unavailable }
    func playlists(_ credential: KugouCredential, page: Int, size: Int) async throws -> KugouPage<KugouPlaylist> { throw KugouError.unavailable }
    func tracks(_ credential: KugouCredential, listID: String, page: Int, size: Int) async throws -> KugouPage<Song> { throw KugouError.unavailable }
}
#endif
