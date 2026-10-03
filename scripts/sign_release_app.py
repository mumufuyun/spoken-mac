#!/usr/bin/env python3
"""Sign distribution builds with a pinned Developer ID; never fall back to ad hoc.

Private keys remain in the macOS Keychain. This does not notarize or install apps.
"""
import argparse
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True)


def expected_team():
    team = os.environ.get("SPOKEN_TEAM_ID", "")
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Set SPOKEN_TEAM_ID to your 10-character Apple developer Team ID.")
    return team


def select_identity(listing, requested, team):
    if not requested or requested == "-":
        raise ValueError("Set SPOKEN_SIGNING_IDENTITY to a Developer ID Application certificate SHA-1 or exact name.")
    identities = re.findall(r'^\s*\d+\) ([A-Fa-f0-9]{40}) "([^"\n]+)"\s*$', listing, re.M)
    matches = [(fingerprint, name) for fingerprint, name in identities
               if requested.upper() == fingerprint.upper() or requested == name]
    if len(matches) != 1:
        raise ValueError("The pinned signing identity must match exactly one valid certificate with a private key in Keychain.")
    fingerprint, name = matches[0]
    if not name.startswith("Developer ID Application: ") or not name.endswith(f"({team})"):
        raise ValueError("The certificate must be Developer ID Application and belong to SPOKEN_TEAM_ID.")
    return fingerprint


def signing_identity():
    team = expected_team()
    listing = run("security", "find-identity", "-v", "-p", "codesigning").stdout
    return select_identity(listing, os.environ.get("SPOKEN_SIGNING_IDENTITY", ""), team)


def signing_targets(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.moss.spoken":
        raise ValueError("Expected the Spoken application bundle.")
    framework = app / "Contents/Frameworks/Sparkle.framework"
    current = framework / "Versions/Current"
    # Sparkle's documented inside-out signing order; never use --deep to sign.
    # https://sparkle-project.org/documentation/sandboxing/#code-signing
    targets = [current / "XPCServices/Installer.xpc", current / "XPCServices/Downloader.xpc",
               current / "Autoupdate", current / "Updater.app", framework, app]
    for target in targets:
        if not target.exists():
            raise ValueError(f"Required signing component missing: {target}")
        if app.resolve() not in target.resolve().parents and target.resolve() != app.resolve():
            raise ValueError(f"Signing component resolves outside the app: {target}")
    return targets


def verify_release_app(app, team=None):
    team = team or expected_team()
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Invalid developer Team ID.")
    requirement = ('anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
                   'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
                   f'and certificate leaf[subject.OU] = "{team}"')
    for target in signing_targets(app):
        details = run("codesign", "--display", "--verbose=4", target).stderr
        if ("Signature=adhoc" in details or f"TeamIdentifier={team}\n" not in details
                or "Timestamp=" not in details or not re.search(r"flags=.*\bruntime\b", details)):
            raise ValueError(f"Missing Developer ID, expected team, secure timestamp or Hardened Runtime: {target}")
        dr = run("codesign", "--display", "--requirements", "-", target)
        if "cdhash " in dr.stdout + dr.stderr:
            raise ValueError(f"Build-specific identity cannot preserve update permissions: {target}")
        required = requirement + (' and identifier "com.moss.spoken"' if target == app else "")
        # A leading '=' makes this an inline expression, rather than a requirements filename.
        run("codesign", "--verify", "--strict", "--all-architectures", "--test-requirement", "=" + required, target)
    run("codesign", "--verify", "--deep", "--strict", "--all-architectures", app)


def sign(app):
    identity = signing_identity()
    for target in signing_targets(app):
        command = ["codesign", "--force", "--sign", identity, "--timestamp", "--options", "runtime"]
        if target.name == "Downloader.xpc":
            command += ["--preserve-metadata=entitlements"]
        if target == app:
            command += ["--entitlements", ROOT / "Spoken/Spoken.entitlements"]
        run(*command, target)
    verify_release_app(app)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true", help="Check the pinned certificate without signing")
    action.add_argument("--sign", type=Path, metavar="APP")
    action.add_argument("--verify", type=Path, metavar="APP")
    args = parser.parse_args()
    if args.check:
        signing_identity()
        print("Pinned Developer ID Application identity is available.")
    elif args.sign:
        sign(args.sign.resolve())
        print("Developer ID signatures verified for Spoken and all update components; not notarized.")
    else:
        verify_release_app(args.verify.resolve())
        print("Developer ID signatures verified; notarization was not checked.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        sys.exit(str(error))
    except subprocess.CalledProcessError as error:
        sys.exit(error.stderr.strip() or str(error))
