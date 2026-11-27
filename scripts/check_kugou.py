#!/usr/bin/env python3
"""Offline KuGou checks. Default never builds; --native explicitly compiles a synthetic macOS runner."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
KG = ROOT / "app/TingFlow/Kugou"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--native", action="store_true", help="Explicitly compile/run standalone synthetic Swift checks on macOS; never the app")
args = parser.parse_args()

def require(condition, label):
    if not condition:
        raise SystemExit("FAIL: " + label)

subprocess.run(["node", str(ROOT / "tests/KugouVectors.js")], cwd=ROOT, check=True)
vectors = json.loads((ROOT / "tests/fixtures/KugouSignatureVectors.json").read_text())
for v in vectors:
    salt = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt" if v["kind"] == "web" else "OIlwieks28dk2k092lksi2UIkp"
    p = v["parameters"]
    fields = sorted(f"{k}={val}" for k, val in p.items()) if v["kind"] == "web" else [f"{k}={p[k]}" for k in sorted(p)]
    require(hashlib.md5((salt + "".join(fields) + v["body"] + salt).encode()).hexdigest() == v["signature"], "independent Python vector " + v["name"])
files = ["KugouModels.swift", "KugouMapping.swift", "KugouCrypto.swift", "KugouTransport.swift", "KugouClient.swift", "KugouStore.swift", "KugouViews.swift"]
texts = {f: (KG / f).read_text() for f in files}
source = "\n".join(texts.values())
for forbidden in ["URLSession.shared", "HTTPCookieStorage.shared", "UserDefaults", "print(", "NSLog(", "Logger(", "os_log(", "http://", "get_my_info", "usercenter.kugou.com", "profilePortrait", "SecKey", "netease.native"]:
    require(forbidden not in source, "no production " + forbidden)
crypto = texts["KugouCrypto.swift"]
require("Insecure.MD5.hash(data: data)" in crypto, "native CryptoKit MD5")
require('parameters.map { "\\($0.key)=\\($0.value)" }.sorted()' in crypto, "Web sorts full field strings")
client = texts["KugouClient.swift"]
require('"appid": "1014"' in client and '"appid": "1005"' in client and '"clientver": "20489"' in client, "fixed web/standard app configuration")
require('index.html?appid=1005&' in client, "exact QR registration text including trailing ampersand")
require('private func request(' in client, "no exposed generic request builder")
transport = texts["KugouTransport.swift"]
for required in ["2 * 1024 * 1024", "maximumBytes - buffer.count", "completionHandler(nil)", "httpCookieStorage = nil", "httpShouldSetCookies = false", "urlCredentialStorage = nil", "urlCache = nil", "timeoutIntervalForRequest = 12", "timeoutIntervalForResource = 15", "c.percentEncodedPath == c.path"]:
    require(required in transport, "transport bound/privacy: " + required)
for route in ["/v2/qrcode", "/v2/get_userinfo_qrcode", "/v7/get_all_list", "/v4/get_list_all_file_v3"]:
    require(route in transport and route in client, "exact route " + route)
store = texts["KugouStore.swift"]
for required in ["kugou.native.standard1005.credential.v1", "SecureVault.read", "SecureVault.save", "SecureVault.remove", "2_500_000_000", "120_000_000_000", "trackTasks.count < 2", "self.trackCache = [list.id: all]", "cancelPoll: false"]:
    require(required in store, "bounded lifecycle: " + required)
require("checks < 48" in texts["KugouModels.swift"] and "addingTimeInterval(120)" in texts["KugouModels.swift"], "hard QR window")
views = texts["KugouViews.swift"]
require("CIFilter.qrCodeGenerator()" in views and "scenePhase" in views and "onDisappear" in views, "native QR and scene cancellation")
require("TrackRowView(" not in views, "no hidden other-provider environment dependency")
require("forceReload: Bool = false" in store and "if !forceReload, let cached" in store, "explicit reread can bypass complete cache")
require("store.tracks(in: playlist, forceReload: true)" in views, "playlist UI reread actually requests fresh tracks")
for required in ["generation = UUID(); cancelQRCodeLogin(); cancelReads()", "credential = nil; profile = nil; playlists = []; trackCache.removeAll()", "credentialRemovalPending = true"]:
    require(required in store, "logout cleanup: " + required)
require('Button("重试删除此机酷狗凭据"' in views, "failed credential removal remains user-retryable")
require('private let service' not in store, "reuse existing SecureVault rather than second storage service")
print("PASS: independent Python vectors and production source-policy assertions (not Swift execution).")
if args.native:
    require(shutil.which("xcrun") is not None, "--native requires macOS Xcode command-line tools")
    swift_files = [ROOT / "app/TingFlow/Core/Models.swift"] + [KG / f for f in files if f != "KugouViews.swift"]
    swift_files += [ROOT / "tests/KugouFixtures.swift", ROOT / "tests/KugouChecks.swift"]
    # Intentionally omit production SecureVault: fixtures fail fast if a real vault is attempted.
    with tempfile.TemporaryDirectory(prefix="tingflow-kugou-synthetic-") as directory:
        executable = str(Path(directory) / "KugouChecks")
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", *map(str, swift_files), "-o", executable], cwd=ROOT, check=True)
        subprocess.run([executable, str(ROOT / "tests/fixtures/KugouSignatureVectors.json")], cwd=ROOT, check=True)
else:
    print("SKIP: Swift runtime checks (not compiled; explicitly use --native on macOS when authorized).")
print("No official API or account request was made by this command.")
