import Foundation
import Combine

private final class UpdateNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class UpdateStore: ObservableObject {
    @Published private(set) var manifest: UpdateManifest?
    @Published private(set) var isChecking = false
    @Published private(set) var message: String?
    @Published var manifestAddress: String
    let currentVersion: String
    let currentBuild: Int
    private let bundleID: String
    private let session: URLSession
    init() {
        manifestAddress = UserDefaults.standard.string(forKey: "tingflow.updates.manifestURL") ?? ""
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        bundleID = Bundle.main.bundleIdentifier ?? "com.ikamio.tingflow"
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.httpCookieStorage = nil; c.urlCredentialStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 25
        session = URLSession(configuration: c, delegate: UpdateNoRedirects(), delegateQueue: nil)
    }
    var hasNewVersion: Bool {
        guard let manifest else { return false }
        return UpdateVersion.newer(version: manifest.version, build: manifest.build, than: currentVersion, currentBuild: currentBuild)
    }
    func saveAddress() {
        do {
            let value = manifestAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { UserDefaults.standard.removeObject(forKey: "tingflow.updates.manifestURL") }
            else { _ = try UpdatePolicy.manifest(value); UserDefaults.standard.set(value, forKey: "tingflow.updates.manifestURL") }
            manifestAddress = value; manifest = nil; message = nil
        } catch { message = UpdateFailure.address.localizedDescription }
    }
    func check() async {
        guard !isChecking else { return }
        isChecking = true; message = nil; manifest = nil
        defer { isChecking = false }
        do {
            guard !manifestAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UpdateFailure.notConfigured }
            let url = try UpdatePolicy.manifest(manifestAddress)
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            guard let http = response as? HTTPURLResponse, http.url == url, http.statusCode == 200,
                  response.expectedContentLength <= 128_000 else { throw UpdateFailure.network }
            var data = Data()
            for try await byte in bytes { guard data.count < 128_000 else { throw UpdateFailure.invalid }; data.append(byte) }
            try Task.checkCancellation()
            let parsed: UpdateManifest
            do { parsed = try JSONDecoder().decode(UpdateManifest.self, from: data) } catch { throw UpdateFailure.invalid }
            try parsed.validate(for: bundleID)
            manifest = parsed
            message = hasNewVersion ? "发现新版本 \(parsed.version)（\(parsed.build)）" : "当前版本已是清单中的最新版本。"
        } catch is CancellationError { }
        catch { message = (error as? UpdateFailure ?? .network).localizedDescription }
    }
}
