#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d)"
MOUNT="$WORK/mount"
KEYCHAIN="$WORK/release.keychain-db"
cleanup() {
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    if [ -f "$KEYCHAIN" ]; then
        security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

SPARKLE_VERSION=2.10.1
SPARKLE_DIR="$WORK/sparkle"
mkdir -p "$SPARKLE_DIR" "$MOUNT" dist/release
curl -fsSL --retry 3 -o "$WORK/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27  $WORK/sparkle.tar.xz" | shasum -a 256 -c
tar -xJf "$WORK/sparkle.tar.xz" -C "$SPARKLE_DIR"

if [ "${PUBLISH:-false}" = true ]; then
    : "${MACOS_CERTIFICATE_P12:?}" "${MACOS_CERTIFICATE_PASSWORD:?}" "${DEVELOPER_ID:?}"
    : "${APPLE_NOTARY_API_KEY:?}" "${APPLE_NOTARY_KEY_ID:?}" "${APPLE_NOTARY_ISSUER_ID:?}"
    : "${SPARKLE_PUBLIC_KEY:?}" "${SPARKLE_PRIVATE_KEY:?}" "${GITHUB_REF_NAME:?}"
    umask 077
    printf '%s' "$MACOS_CERTIFICATE_P12" | base64 -D > "$WORK/release.p12"
    printf '%s' "$APPLE_NOTARY_API_KEY" > "$WORK/notary.p8"
    KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$WORK/release.p12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    export RELEASE_KEYCHAIN="$KEYCHAIN"
    umask 022
fi

SPARKLE_DIR="$SPARKLE_DIR" DIST=dist bash scripts/build-app.sh
APP=dist/Whisp.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
test "$VERSION" = "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="dist/release/Whisp-$VERSION-macos-arm64.dmg"

notarize() {
    xcrun notarytool submit "$1" --wait --key "$WORK/notary.p8" \
        --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID"
}

if [ "${PUBLISH:-false}" = true ]; then
    test "$GITHUB_REF_NAME" = "v$VERSION"
    ditto -c -k --keepParent "$APP" "$WORK/Whisp.zip"
    notarize "$WORK/Whisp.zip"
    xcrun stapler staple "$APP"
fi

mkdir "$WORK/image"
ditto "$APP" "$WORK/image/Whisp.app"
ln -s /Applications "$WORK/image/Applications"
hdiutil create -ov -srcfolder "$WORK/image" -volname Whisp -fs APFS -format ULFO "$DMG"

if [ "${PUBLISH:-false}" = true ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_DIR/bin/generate_appcast" \
        --ed-key-file - --maximum-deltas 0 \
        --download-url-prefix "https://github.com/bisheshabramhacharya/whisp/releases/download/$GITHUB_REF_NAME/" \
        -o dist/release/appcast.xml dist/release
    python3 - "$DMG" "$VERSION" "$WORK/signature" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

dmg = Path(sys.argv[1])
version = sys.argv[2]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
item = ET.parse("dist/release/appcast.xml").find("./channel/item")
assert item is not None and item.findtext("sparkle:version", namespaces=ns) == version
enclosure = item.find("enclosure")
assert enclosure is not None
assert enclosure.attrib["url"] == f"https://github.com/bisheshabramhacharya/whisp/releases/download/v{version}/{dmg.name}"
assert int(enclosure.attrib["length"]) == dmg.stat().st_size
signature = enclosure.attrib[f"{{{ns['sparkle']}}}edSignature"]
Path(sys.argv[3]).write_text(signature)
PY
    swift -e '
import CryptoKit
import Foundation
let args = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[1])!)
let signature = Data(base64Encoded: try String(contentsOfFile: args[2], encoding: .utf8))!
let dmg = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
exit(key.isValidSignature(signature, for: dmg) ? 0 : 1)
' "$SPARKLE_PUBLIC_KEY" "$WORK/signature" "$DMG"
fi

hdiutil verify "$DMG"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
test "$(readlink "$MOUNT/Applications")" = /Applications
INSTALLED="$WORK/installed/Whisp.app"
mkdir "$WORK/installed"
ditto "$MOUNT/Whisp.app" "$INSTALLED"
codesign --verify --deep --strict "$INSTALLED"
test "$(lipo -archs "$INSTALLED/Contents/MacOS/Whisp")" = arm64
if [ "${PUBLISH:-false}" = true ]; then
    xcrun stapler validate "$INSTALLED"
    spctl --assess --type execute "$INSTALLED"
fi
"$INSTALLED/Contents/MacOS/Whisp" > "$WORK/whisp.log" 2>&1 &
APP_PID=$!
sleep 5
if ! kill -0 "$APP_PID"; then
    tail -30 "$WORK/whisp.log"
    exit 1
fi
kill "$APP_PID"
wait "$APP_PID" 2>/dev/null || true
echo "Verified $DMG and the installed Whisp $VERSION bundle."
