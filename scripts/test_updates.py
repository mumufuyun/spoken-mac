#!/usr/bin/env python3
"""Exercise real Sparkle updates against localhost using disposable apps and signing keys."""
import functools
import http.server
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append(self.path)
        super().do_GET()

    def log_message(self, *args):
        pass


def main():
    sparkle = Path(run("bash", ROOT / "scripts/prepare_sparkle.sh", capture_output=True, text=True).stdout.strip())
    with tempfile.TemporaryDirectory(prefix="spoken-update-integration-") as directory:
        stage = Path(directory)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(stage)))
        server.requests = []
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            # The throwaway private seed is never printed or added to the login Keychain.
            key_source = stage / "key.swift"
            key_source.write_text('''import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try key.rawRepresentation.base64EncodedData().write(to: url)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
print(key.publicKey.rawRepresentation.base64EncodedString())
''')
            private_key = stage / "test-key"
            public_key = run("swift", key_source, private_key, capture_output=True, text=True).stdout.strip()
            executable = stage / "UpdateIntegration"
            run("xcrun", "clang", "-fobjc-arc", "-F", sparkle, "-c", ROOT / "SpokenTests/Offline/UpdateIntegration.m", "-o", stage / "driver.o")
            run("xcrun", "swiftc", "-swift-version", "5", "-F", sparkle, "-framework", "Sparkle",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-import-objc-header", ROOT / "SpokenTests/Offline/UpdateIntegration.h",
                ROOT / "SpokenTests/Offline/UpdateIntegration.swift", ROOT / "Spoken/Services/AppUpdateService.swift", stage / "driver.o", "-o", executable)
            results = {}
            for scenario in ["valid", "tampered-archive", "tampered-feed", "up-to-date", "offline", "checks-disabled", "automatic-check"]:
                case = stage / scenario
                case.mkdir()
                result_file = case / "events.txt"
                bundle_id = "com.spoken.update-integration." + uuid.uuid4().hex
                source = case / "installed/Spoken Update Test.app"
                target = case / "target/Spoken Update Test.app"
                feed_url = base + f"/{scenario}/appcast.xml"
                for app, version in [(source, "1"), (target, "2")]:
                    (app / "Contents/MacOS").mkdir(parents=True)
                    (app / "Contents/Frameworks").mkdir()
                    shutil.copy2(executable, app / "Contents/MacOS/UpdateIntegration")
                    run("ditto", sparkle / "Sparkle.framework", app / "Contents/Frameworks/Sparkle.framework")
                    info = dict(CFBundleIdentifier=bundle_id, CFBundleExecutable="UpdateIntegration", CFBundleName="Spoken Update Test",
                                CFBundlePackageType="APPL", CFBundleVersion=version, CFBundleShortVersionString=version,
                                LSMinimumSystemVersion="14.0", LSUIElement=True, SUFeedURL=feed_url, SUPublicEDKey=public_key,
                                SUEnableAutomaticChecks=(scenario == "automatic-check"), SUAutomaticallyUpdate=False, SUVerifyUpdateBeforeExtraction=True,
                                SURequireSignedFeed=True, TestResultPath=str(result_file), TestScenario=scenario,
                                NSAppTransportSecurity=dict(NSAllowsLocalNetworking=True))
                    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                    run("codesign", "--force", "--sign", "-", "--timestamp=none", app, stderr=subprocess.DEVNULL)
                archive = case / "update.zip"
                run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", target, archive)
                run(sparkle / "bin/generate_appcast", "--ed-key-file", private_key, "--download-url-prefix", base + f"/{scenario}/",
                    "--maximum-deltas", "0", case, stdout=subprocess.DEVNULL)
                feed = case / "appcast.xml"
                run(sparkle / "bin/sign_update", "--ed-key-file", private_key, "--verify", feed, stdout=subprocess.DEVNULL)
                if scenario == "tampered-archive":
                    data = bytearray(archive.read_bytes()); data[len(data) // 2] ^= 1; archive.write_bytes(data)
                elif scenario == "tampered-feed":
                    feed.write_bytes(feed.read_bytes().replace(b"<title>", b"<title>tampered ", 1))
                elif scenario in ["up-to-date", "automatic-check"]:
                    feed.write_bytes(feed.read_bytes().replace(b"<sparkle:version>2</sparkle:version>", b"<sparkle:version>1</sparkle:version>"))
                    run(sparkle / "bin/sign_update", "--ed-key-file", private_key, feed, stdout=subprocess.DEVNULL)
                elif scenario == "offline":
                    feed.unlink()
                proc = subprocess.Popen([str(source / "Contents/MacOS/UpdateIntegration")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    proc.wait(timeout=55)
                    deadline = time.monotonic() + (20 if scenario == "valid" else 2)
                    while scenario == "valid" and time.monotonic() < deadline:
                        if result_file.exists() and "RELAUNCHED 2" in result_file.read_text():
                            break
                        time.sleep(0.25)
                    events = result_file.read_text() if result_file.exists() else ""
                    installed_version = plistlib.loads((source / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
                    if scenario == "valid":
                        assert installed_version == "2" and "RELAUNCHED 2" in events, events
                        assert "POSTPONE\nRESUME" in events, events
                    elif scenario in ["checks-disabled", "automatic-check"]:
                        requests = [p for p in server.requests if p.startswith(f"/{scenario}/")]
                        assert installed_version == "1", events
                        if scenario == "checks-disabled":
                            assert "AUTO_DISABLED" in events and not requests, (events, requests)
                        else:
                            assert "AUTO_CHECKED" in events and requests, (events, requests)
                    else:
                        assert installed_version == "1" and "RELAUNCHED" not in events and "READY" not in events, events
                        assert "TIMEOUT" not in events, events
                        assert "ERROR" in events or "NO_UPDATE" in events, events
                        if scenario in ["tampered-feed", "up-to-date", "offline"]:
                            assert "DOWNLOAD" not in events, events
                    results[scenario] = dict(passed=True, events=events.splitlines(), installed_version=installed_version)
                    print(f"PASS: {scenario}: {events.strip().replace(chr(10), ' → ')}", flush=True)
                finally:
                    if proc.poll() is None:
                        proc.terminate(); proc.wait(timeout=5)
                    run("defaults", "delete", bundle_id, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            (ROOT / "build/update-integration-results.json").write_text(json.dumps(results, indent=2) + "\n")
        finally:
            server.shutdown()


if __name__ == "__main__":
    main()
