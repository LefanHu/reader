#!/usr/bin/env python3
"""Build a registered-device IPA and publish a QR installer, never the repository."""
import argparse
from datetime import datetime, timezone
from functools import partial
import html
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
import shlex
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import quote, urlsplit
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OTA = ROOT / "build" / "ota"
PUBSPEC = ROOT / "pubspec.yaml"
# `version: <name>+<build>`; the number after `+` is the persisted iOS CFBundleVersion.
_VERSION = re.compile(r"^(version:\s*\d+\.\d+\.\d+\+)(\d+)[ \t]*$", re.MULTILINE)


def current_build_number(pubspec_text):
    """pubspec.yaml is the single persisted source of the last issued build number."""
    match = _VERSION.search(pubspec_text)
    if not match:
        raise ValueError("pubspec.yaml version must look like 1.0.0+1")
    return int(match.group(2))


def with_build_number(pubspec_text, number):
    """Rewrite only the build number so the version name and other lines are untouched."""
    current_build_number(pubspec_text)
    return _VERSION.sub(lambda match: f"{match.group(1)}{number}", pubspec_text, count=1)


def mark_dependencies_current(root):
    """Keep pub's lock and package config newer than a build-number-only pubspec edit.

    Flutter skips `pub get` only while pubspec.yaml is older than both files, and pub
    never rewrites them when nothing changed, so without this every later flutter
    command re-resolves against pub.dev while holding the SDK startup lock.
    """
    for path in (root / "pubspec.lock", root / ".dart_tool" / "package_config.json"):
        if path.exists():
            os.utime(path)


def https_base(value):
    """Require a plain HTTPS hosting URL; credentials must not enter QR codes."""
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username
            or parsed.password or parsed.query or parsed.fragment):
        raise ValueError("base URL must be HTTPS without credentials, query, or fragment")
    return value.rstrip("/")


def validate_profile(profile):
    """Only unexpired, device-limited distribution profiles support this installer."""
    if (not profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices")
            or profile.get("Entitlements", {}).get("get-task-allow", False)):
        raise ValueError("IPA must use Ad Hoc distribution, not development or App Store signing")
    expiration = profile.get("ExpirationDate")
    if isinstance(expiration, datetime) and expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    if not isinstance(expiration, datetime) or expiration <= datetime.now(timezone.utc):
        raise ValueError("IPA provisioning profile has expired or has no expiration")


def ipa_metadata(ipa):
    """Read the exported app rather than guessing its bundle ID or Flutter version."""
    with zipfile.ZipFile(ipa) as archive:
        infos = [name for name in archive.namelist()
                 if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(infos) != 1:
            raise ValueError("IPA must contain exactly one top-level app")
        info = plistlib.loads(archive.read(infos[0]))
        profile_path = infos[0].rsplit("/", 1)[0] + "/embedded.mobileprovision"
        # Decode outside the served tree: pairing/device information is not a web artifact.
        with tempfile.TemporaryDirectory(prefix="reader-profile-") as temporary:
            profile_file = Path(temporary) / "profile.mobileprovision"
            profile_file.write_bytes(archive.read(profile_path))
            result = subprocess.run(["security", "cms", "-D", "-i", str(profile_file)],
                                    check=True, capture_output=True)
            profile = plistlib.loads(result.stdout)
    validate_profile(profile)
    for field in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString"):
        if not isinstance(info.get(field), str) or not info[field]:
            raise ValueError(f"IPA is missing {field}")
    return info


def installer_contents(info, base_url, build_id):
    """Bind the stable landing page and manifest to one immutable exported IPA.

    The landing page, manifest and QR stay at the same URLs for every build, so the
    printed QR never changes; only the IPA path carries the unique build ID.
    """
    landing = f"{https_base(base_url)}/"
    manifest_url = landing + "manifest.plist"
    install_url = "itms-services://?action=download-manifest&url=" + quote(manifest_url, safe="")
    title = info.get("CFBundleDisplayName") or info.get("CFBundleName") or "Reader"
    manifest = {
        "items": [{
            "assets": [{"kind": "software-package", "url": f"{landing}{build_id}/reader.ipa"}],
            "metadata": {
                "bundle-identifier": info["CFBundleIdentifier"],
                "bundle-version": info["CFBundleVersion"],
                "kind": "software",
                "title": title,
            },
        }],
    }
    title = html.escape(title)
    version = html.escape(info["CFBundleShortVersionString"])
    build = html.escape(info["CFBundleVersion"])
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Install {title}</title>
<style>
:root {{ color-scheme: light dark; font-family: system-ui, sans-serif; }}
body {{ max-width: 36rem; margin: 3rem auto; padding: 0 1.25rem; line-height: 1.6; }}
a {{ display: inline-block; padding: .8rem 1.2rem; border: 1px solid; border-radius: .6rem; }}
img {{ display: block; width: min(100%, 18rem); height: auto; margin: 1.5rem 0; }}
</style></head><body>
<h1>{title}</h1><p>Version {version} · Build {build}</p>
<p><a href="{html.escape(install_url, quote=True)}">Install on iPhone</a></p>
<img src="qr.svg" alt="QR code linking to this installation page">
<p>This page always offers the latest build. Scan with your iPhone camera and open
in Safari. For private Tailscale hosting, connect Tailscale first. Only devices
included in this build's provisioning profile can install it.</p>
<p>Keep the Mac awake and the installer server running until installation finishes.</p>
</body></html>
"""
    return landing, plistlib.dumps(manifest), page


def build_ipa(defines, profile_file, build_number):
    """Apply manual signing to Runner only, then remove the private build override."""
    result = subprocess.run(["security", "cms", "-D", "-i", str(profile_file)],
                            check=True, capture_output=True)
    profile = plistlib.loads(result.stdout)
    validate_profile(profile)
    # Xcode matches the signed identifier verbatim, including its original casing.
    profile_id = profile["UUID"]
    uuid.UUID(profile_id)
    team = profile["TeamIdentifier"][0]
    bundle = profile["Entitlements"]["application-identifier"].removeprefix(team + ".")
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or not re.fullmatch(r"[A-Za-z0-9.-]+", bundle):
        raise ValueError("Profile must contain an explicit app identifier and team")
    profiles = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    profiles.mkdir(parents=True, exist_ok=True)
    (profiles / f"{profile_id}.mobileprovision").write_bytes(profile_file.read_bytes())
    signing = ROOT / ".credentials" / "ios-signing.xcconfig"
    signing.parent.mkdir(mode=0o700, exist_ok=True)
    settings = (
        "// Temporary headless signing; removed after this build.\n"
        "CODE_SIGN_STYLE = Manual\n"
        "CODE_SIGN_IDENTITY = Apple Distribution\n"
        f"DEVELOPMENT_TEAM = {team}\n"
        f"PRODUCT_BUNDLE_IDENTIFIER = {bundle}\n"
        f"PROVISIONING_PROFILE_SPECIFIER = {profile_id}\n"
    )
    # Exclusive creation avoids overwriting a user's configuration or another build.
    descriptor = os.open(signing, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(settings)
        output = ROOT / "build" / "ios" / "ipa"
        previous = {path: path.stat().st_mtime_ns for path in output.glob("*.ipa")}
        OTA.mkdir(parents=True, exist_ok=True)
        options = OTA / "ExportOptions.plist"
        # Xcode 27 names Ad Hoc exports release-testing. Manual signing needs no login.
        options.write_bytes(plistlib.dumps({
            "method": "release-testing", "signingStyle": "manual", "teamID": team,
            "signingCertificate": "Apple Distribution",
            "provisioningProfiles": {bundle: profile_id},
        }))
        command = ["flutter", "build", "ipa", "--release", f"--build-number={build_number}",
                   f"--export-options-plist={options}"]
        if defines:
            command.append(f"--dart-define-from-file={Path(defines).resolve()}")
        subprocess.run(command, cwd=ROOT, check=True)
        # Flutter can finish an archive even when export fails; never publish an old IPA.
        exported = [path for path in output.glob("*.ipa")
                    if previous.get(path) != path.stat().st_mtime_ns]
        if len(exported) != 1:
            raise ValueError("No unique fresh IPA exported. Check distribution certificate/profile setup.")
        return exported[0]
    finally:
        signing.unlink()


def publish(ipa, base_url):
    """Stage every asset, then switch the stable entry points to the new build.

    The IPA directory is renamed into place first so the stable manifest can never
    reference a missing build; the landing page is replaced last.
    """
    info = ipa_metadata(ipa)
    build_id = uuid.uuid4().hex
    landing, manifest, page = installer_contents(info, base_url, build_id)
    site = OTA / "site"
    site.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".publish-", dir=OTA) as temporary:
        staging = Path(temporary)
        (staging / build_id).mkdir()
        shutil.copyfile(ipa, staging / build_id / "reader.ipa")
        (staging / "manifest.plist").write_bytes(manifest)
        (staging / "index.html").write_text(page, encoding="utf-8")
        subprocess.run(["qrencode", "-t", "SVG", "-o", str(staging / "qr.svg"), landing], check=True)
        (staging / build_id).rename(site / build_id)
        # Same filesystem as the site, so each replace is atomic for in-flight requests.
        for name in ("qr.svg", "manifest.plist", "index.html"):
            os.replace(staging / name, site / name)
    print(f"\nBuild {info['CFBundleShortVersionString']}+{info['CFBundleVersion']} published.")
    print(f"Installation page (stable): {landing}")
    print(f"QR image: {site / 'qr.svg'}")
    subprocess.run(["qrencode", "-t", "ANSIUTF8", landing], check=True)
    print("\nKeep this server running on the Mac:")
    print(f"python3 {shlex.quote(str(ROOT / 'tool' / 'build_ios_ota.py'))} --serve")
    print("\nFor Tailscale HTTPS on port 8443, run in another terminal:")
    print("/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg --https=8443 http://127.0.0.1:8765")
    print("Only use that command if --base-url is your Tailscale hostname on port 8443.")


class InstallerHandler(SimpleHTTPRequestHandler):
    """Use Apple's OTA MIME types while serving only the generated installer tree.

    The landing page and manifest live at fixed URLs and change per build, so
    responses must never be cached by Safari or iOS's installer.
    """
    extensions_map = {
        **SimpleHTTPRequestHandler.extensions_map,
        ".plist": "text/xml",
        ".ipa": "application/octet-stream",
    }

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def serve_site():
    """Bind loopback only; private HTTPS and tailnet access are owned by Tailscale."""
    site = OTA / "site"
    if not site.is_dir():
        raise ValueError("Build an installer before starting its server")
    handler = partial(InstallerHandler, directory=str(site))
    with ThreadingHTTPServer(("127.0.0.1", 8765), handler) as server:
        print("Installer server listening on 127.0.0.1:8765", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


def unlock_build_keychain():
    """Unlock the dedicated OTA keychain without GUI prompts or password logging.

    Its generated password persists only in an ignored owner-only credential file.
    Other manually configured signing keychains remain the caller's responsibility.
    """
    password_file = ROOT / ".credentials" / "ios-build-keychain.password"
    if not password_file.exists():
        return
    attributes = password_file.stat()
    if attributes.st_mode & 0o077 or attributes.st_uid != os.getuid():
        raise ValueError("OTA keychain password file must be owned by this user and owner-only")
    keychain = Path.home() / "Library/Keychains/reader-ota-build.keychain-db"
    result = subprocess.run(
        ["security", "unlock-keychain", "-p", password_file.read_text(), str(keychain)],
        capture_output=True,
    )
    # CalledProcessError would expose the password-bearing argument list.
    if result.returncode:
        raise ValueError("Could not unlock the dedicated OTA build keychain")


def main():
    """Build by default; --ipa republishes an existing Ad Hoc export without rebuilding."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", help="HTTPS URL serving build/ota/site")
    parser.add_argument("--serve", action="store_true", help="Serve generated installers on loopback port 8765")
    parser.add_argument("--defines", help="Optional ignored Dart defines JSON for cloud features")
    parser.add_argument("--ipa", type=Path, help="Use an existing Ad Hoc IPA instead of building")
    parser.add_argument("--profile", type=Path, help="Ad Hoc .mobileprovision for headless manual signing")
    args = parser.parse_args()
    try:
        if args.serve:
            serve_site()
            return 0
        base_url = https_base(args.base_url or "")
        if not args.ipa and not args.profile:
            raise ValueError("Provide --profile for a headless build, or --ipa for an existing export")
        for executable in ("security", "qrencode") + (() if args.ipa else ("flutter",)):
            if not shutil.which(executable):
                raise ValueError(f"Missing {executable}; install Xcode, Flutter, and brew install cocoapods qrencode")
        # Do not change the system developer directory; select installed Xcode for this build.
        os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
        if not args.ipa:
            unlock_build_keychain()
            build_number = current_build_number(PUBSPEC.read_text()) + 1
            ipa = build_ipa(args.defines, args.profile, build_number)
            # The number is consumed once an IPA carrying it exists, even if publishing fails.
            PUBSPEC.write_text(with_build_number(PUBSPEC.read_text(), build_number))
            mark_dependencies_current(ROOT)
        else:
            ipa = args.ipa
        publish(ipa, base_url)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"OTA build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
