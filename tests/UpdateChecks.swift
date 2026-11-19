import Foundation

@main struct UpdateChecks {
    static func main() throws {
        func newer(_ remote: String, _ local: String, remoteBuild: Int = 1, localBuild: Int = 1) -> Bool {
            UpdateVersion.newer(version: remote, build: remoteBuild, than: local, currentBuild: localBuild)
        }
        precondition(newer("0.3.1", "0.3.0"), "patch upgrade")
        precondition(newer("0.10.0", "0.9.9"), "numeric not lexical")
        precondition(newer("v1.0.0", "0.99.9"), "v prefix")
        precondition(newer("0.3", "0.3.0", remoteBuild: 22, localBuild: 14), "same version build upgrade")
        precondition(!newer("0.3", "0.3.0", remoteBuild: 14, localBuild: 14), "same build")
        precondition(!newer("0.2.9", "0.3.0", remoteBuild: 99, localBuild: 1), "no downgrade")
        for bad in ["0..3", "1.beta", "a", "99999999", "0.3.0-rc1", "0/3"] {
            precondition(UpdateVersion.parse(bad) == nil, "invalid version")
        }
        for bad in ["http://example.invalid/update.json", "https://u:secret@example.invalid/update.json", "https://example.invalid/update.json?api_key=secret", "https://example.invalid/#fragment"] {
            precondition((try? UpdatePolicy.manifest(bad)) == nil, "unsafe manifest")
        }
        let good = UpdateManifest(bundleID: "com.ikamio.tingflow", version: "0.3.1", build: 99, notes: "Fixture", pageURL: URL(string: "https://github.com/iKamio/TingFlow-Public/actions")!)
        try good.validate(for: "com.ikamio.tingflow")
        do { try good.validate(for: "different.bundle"); preconditionFailure("wrong app accepted") } catch { }
        print("PASS: update version/build comparison, HTTPS credential exclusion and app identity")
    }
}
