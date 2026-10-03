#!/usr/bin/env python3
"""Stage the installer, signed Sparkle feed, and website release metadata together.

Never pushes or deploys. The signing key stays in the login Keychain.
"""
import argparse
import hashlib
import html
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from sign_release_app import expected_team, verify_release_app

ROOT = Path(__file__).resolve().parents[1]
SITE_URL = "https://spoken-web-v2.pages.dev"
ACCOUNT = "com.moss.spoken.updates"
NS = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def release_number(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError(f"Invalid release number: {value}")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--website", type=Path, required=True)
    parser.add_argument("--installer", type=Path, required=True)
    parser.add_argument("--notes", type=Path, required=True)
    args = parser.parse_args()
    team = expected_team()
    website, installer = args.website.resolve(), args.installer.resolve()
    if not (website / "src/lib/product.ts").is_file():
        parser.error("--website must be the Spoken website checkout")
    notes = json.loads(args.notes.read_text())
    if not isinstance(notes.get("title"), str) or not notes["title"].strip() or not notes.get("notes"):
        parser.error("Release notes need a title and a nonempty notes list")
    if not isinstance(notes["notes"], list) or not all(isinstance(n, str) and n.strip() for n in notes["notes"]):
        parser.error("Each release note must be a nonempty string")
    sparkle = Path(run("bash", ROOT / "scripts/prepare_sparkle.sh", capture_output=True, text=True).stdout.strip())
    with tempfile.TemporaryDirectory(prefix="spoken-release-") as directory:
        stage = Path(directory)
        mount = stage / "mounted"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, installer, stdout=subprocess.DEVNULL)
        try:
            app = mount / "Spoken.app"
            run("codesign", "--verify", "--deep", "--strict", app)
            verify_release_app(app, team)
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
            release_number(version)
            release_number(build)
            if info.get("CFBundleIdentifier") != "com.moss.spoken" or info.get("SUFeedURL") != SITE_URL + "/updates/appcast.xml":
                raise ValueError("Installer does not target the Spoken production update feed")
            for setting in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"]:
                if info.get(setting) is not True:
                    raise ValueError(f"Installer must enable {setting}")
            public_key = run(sparkle / "bin/generate_keys", "--account", ACCOUNT, "-p", capture_output=True, text=True).stdout.strip()
            if public_key != info.get("SUPublicEDKey"):
                raise ValueError("Installer public key does not match the release signing key")
            arch = run("lipo", "-archs", app / "Contents/MacOS/Spoken", capture_output=True, text=True).stdout.strip()
            if arch != "arm64":
                raise ValueError("This website release currently supports arm64 installers only")
        finally:
            run("hdiutil", "detach", mount, stdout=subprocess.DEVNULL)
        filename = f"Spoken-{version}-{arch}.dmg"
        checksum = hashlib.sha256(installer.read_bytes()).hexdigest()
        updates = website / "public/updates"
        metadata_path = updates / "release.json"
        if metadata_path.exists():
            previous = json.loads(metadata_path.read_text())
            if release_number(build) < release_number(previous["build"]):
                raise ValueError("Refusing to publish an older build")
            if build == previous["build"] and checksum != previous["sha256"]:
                raise ValueError("Build number already published with different bytes; increment the build")
        target = website / "public" / filename
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() != checksum:
            raise ValueError("Installer URL already exists with different bytes; use a new version")
        archives = stage / "archives"
        archives.mkdir()
        shutil.copy2(installer, archives / filename)
        (archives / f"{Path(filename).stem}.html").write_text(
            "<h2>" + html.escape(notes["title"]) + "</h2><ul>" +
            "".join("<li>" + html.escape(note) + "</li>" for note in notes["notes"]) + "</ul>\n")
        if (updates / "appcast.xml").exists():
            shutil.copy2(updates / "appcast.xml", archives / "appcast.xml")
        run(sparkle / "bin/generate_appcast", "--account", ACCOUNT,
            "--download-url-prefix", SITE_URL + "/", "--link", SITE_URL,
            "--embed-release-notes", "--maximum-deltas", "0", archives, timeout=120)
        feed = archives / "appcast.xml"
        run(sparkle / "bin/sign_update", "--account", ACCOUNT, "--verify", feed)
        items = ET.parse(feed).getroot().findall("./channel/item")
        item = next(i for i in items if i.findtext("sparkle:version", namespaces=NS) == build)
        enclosure = item.find("enclosure")
        if enclosure.attrib["url"] != SITE_URL + "/" + filename:
            raise ValueError("Generated download URL does not match the website installer")
        signature = enclosure.attrib["{" + NS["sparkle"] + "}edSignature"]
        run(sparkle / "bin/sign_update", "--account", ACCOUNT, "--verify", installer, signature)
        metadata = dict(version=version, build=build, title=notes["title"], notes=notes["notes"],
                        download="/" + filename, checksum="/" + filename + ".sha256",
                        sha256=checksum, size=installer.stat().st_size, publicKey=public_key,
                        developerTeamID=team, appSigning="developer-id")
        # Only update the checkout after every artifact and signature has passed validation.
        updates.mkdir(parents=True, exist_ok=True)
        shutil.copy2(installer, target)
        (website / "public" / (filename + ".sha256")).write_text(f"{checksum}  {filename}\n")
        shutil.copy2(feed, updates / "appcast.xml")
        metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
        print(f"Staged Spoken {version} / {build}: installer, signed update feed, and release metadata.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.TimeoutExpired:
        sys.exit("Signing timed out. Unlock the Mac, allow the Sparkle signing tool to access its Keychain key, and retry. No release was published.")
