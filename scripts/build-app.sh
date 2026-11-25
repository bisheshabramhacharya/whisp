#!/bin/bash
# build-app.sh — build Whisp in release mode and package it as dist/Whisp.app.
#
#   scripts/build-app.sh [--install]
#
# Environment overrides:
#   SCRATCH   SwiftPM scratch/build directory        (default: .build)
#   PRODUCT   SwiftPM executable product to package  (default: Whisp)
#   APP_NAME  Name of the produced .app              (default: Whisp)
#   DIST      Output directory for the .app          (default: dist)
#   IDENTITY  Code-signing identity name             (default: "Whisp Local Signing";
#             pass IDENTITY=- to force ad-hoc signing)
#   SPARKLE_DIR         Sparkle distribution root (enables release bundle layout)
#   DEVELOPER_ID        Developer ID Application signing identity (release only)
#   RELEASE_KEYCHAIN   Keychain containing the Developer ID certificate
#   SPARKLE_PUBLIC_KEY  Public EdDSA key (signed release only)
#
# Signing notes
# -------------
# macOS privacy grants (Microphone, Accessibility, Input Monitoring) are bound
# by TCC to the app's code signature. Ad-hoc signatures change every build, so
# TCC re-prompts after every rebuild. This script therefore prefers a stable
# self-signed identity named "Whisp Local Signing" in the login keychain. If it
# does not exist, the script tries to create it non-interactively: openssl
# self-signed cert (CA:FALSE, keyUsage digitalSignature, EKU codeSigning),
# PKCS12 exported with legacy PBE-SHA1-3DES + SHA1 MAC (macOS `security import`
# cannot read OpenSSL 3's default AES PKCS12), and `security import -T
# /usr/bin/codesign` (pre-authorizes codesign on the key's partition list).
# The cert is deliberately NOT trusted for code signing: `codesign --sign`
# works fine with an untrusted self-signed identity (verified), while a
# codeSign-trusted local key would make anything signed with it pass signature
# validation on this Mac. If the keychain is locked or any step fails, the
# script falls back to ad-hoc signing instead of hanging — see README.md for
# the equivalent manual commands.
#
# Resource-bundle notes (verified empirically, see README "Packaging")
# -------------------------------------------------------------------
# SwiftPM's generated resource_bundle_accessor.swift for FluidAudio resolves
# Bundle.module as:
#     Bundle.main.bundleURL.appendingPathComponent("FluidAudio_FluidAudio.bundle")
# Inside an .app, Bundle.main.bundleURL is the app wrapper ROOT (Whisp.app/),
# NOT Contents/Resources. But codesign refuses to seal ANY content at the app
# root ("unsealed contents present in the bundle root") — files, dirs and
# symlinks alike. Resolution, verified with a probe binary wrapped as an .app:
#   1. copy each SwiftPM *.bundle into Contents/Resources (sealed content)
#   2. codesign the app normally -> fully valid signature
#   3. THEN add Whisp.app/<name>.bundle as a symlink into Contents/Resources
# Bundle(path:) resolves the symlink fine. Consequence: `codesign --verify
# --deep --strict` afterwards reports "unsealed contents present in the bundle
# root" — expected and harmless for a local self-signed app; the executable's
# signature (what TCC binds) is fully valid. The accessor's buildPath fallback
# points at this machine's scratch dir and would mask a missing bundle in local
# testing — that is why the fix was proven with a standalone probe .app.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCRATCH="${SCRATCH:-.build}"
PRODUCT="${PRODUCT:-Whisp}"
APP_NAME="${APP_NAME:-Whisp}"
DIST="${DIST:-dist}"
IDENTITY="${IDENTITY:-Whisp Local Signing}"
SPARKLE_DIR="${SPARKLE_DIR:-}"
DEVELOPER_ID="${DEVELOPER_ID:-}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

SWIFT_FLAGS=()
if [ -n "$SPARKLE_DIR" ]; then
    SPARKLE_DIR="$(cd "$SPARKLE_DIR" && pwd)"
    [ -d "$SPARKLE_DIR/Sparkle.framework" ]
    SWIFT_FLAGS+=(-Xswiftc -DWHISP_RELEASE_UPDATER -Xswiftc -F -Xswiftc "$SPARKLE_DIR")
    SWIFT_FLAGS+=(-Xlinker -F -Xlinker "$SPARKLE_DIR" -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi
if [ -n "$DEVELOPER_ID$SPARKLE_PUBLIC_KEY" ]; then
    [ -n "$SPARKLE_DIR" ] && [ -n "$DEVELOPER_ID" ] && [ -n "$SPARKLE_PUBLIC_KEY" ] ||
        { echo "error: signing a release requires Sparkle, Developer ID and the public update key" >&2; exit 1; }
fi

echo "==> swift build -c release --arch arm64 --product $PRODUCT (scratch: $SCRATCH)"
swift build -c release --arch arm64 --scratch-path "$SCRATCH" --product "$PRODUCT" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}

BIN_DIR="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" --product "$PRODUCT" --show-bin-path)"
BIN="$BIN_DIR/$PRODUCT"
[ -x "$BIN" ] || { echo "error: built product not found at $BIN" >&2; exit 1; }

APP="$DIST/$APP_NAME.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
if [ "$PRODUCT" != "Whisp" ] || [ "$APP_NAME" != "Whisp" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $PRODUCT" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist" || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist" || true
fi
[ -f "Resources/AppIcon.icns" ] && cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [ -n "$SPARKLE_DIR" ]; then
    ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
fi
if [ -n "$DEVELOPER_ID" ]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/bisheshabramhacharya/whisp/releases/latest/download/appcast.xml" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" "$APP/Contents/Info.plist"
fi

# SwiftPM resource bundles -> Contents/Resources (sealed). Root-level symlinks
# for Bundle.module are added AFTER signing (codesign rejects root content).
BUNDLES="$(find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -print)"
BUNDLE_NAMES=()
if [ -n "$BUNDLES" ]; then
    echo "$BUNDLES" | while IFS= read -r b; do
        echo "    bundling resource: $(basename "$b")"
        cp -R "$b" "$APP/Contents/Resources/$(basename "$b")"
    done
    while IFS= read -r b; do BUNDLE_NAMES+=("$(basename "$b")"); done <<< "$BUNDLES"
else
    echo "    (no SwiftPM *.bundle resources found)"
fi

# Dynamic dependencies: embed any non-system dylib/framework into
# Contents/Frameworks and rewrite the load commands to @rpath.
echo "==> checking dynamic dependencies"
NONSYS="$(otool -L "$APP/Contents/MacOS/$PRODUCT" | tail -n +2 | awk '{print $1}' \
    | grep -v '^/usr/lib/' | grep -v '^/System/Library/' | grep -v '^@' || true)"
if [ -n "$NONSYS" ]; then
    echo "$NONSYS" | while IFS= read -r dep; do
        echo "    embedding: $dep"
        base="$(basename "$dep")"
        cp "$dep" "$APP/Contents/Frameworks/$base"
        install_name_tool -change "$dep" "@rpath/$base" "$APP/Contents/MacOS/$PRODUCT"
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$PRODUCT" 2>/dev/null || true
    done
else
    echo "    none (system frameworks only)"
fi

# ---- Signing ---------------------------------------------------------------
KEYCHAIN=~/Library/Keychains/login.keychain-db

identity_valid() {
    # Presence check only: `find-identity` (no -v) lists every cert+key pair,
    # trusted or not — `find-identity -p codesigning -v` would hide the
    # identity unless it were codeSign-trusted, which we deliberately avoid.
    security find-identity | grep -q "\"$IDENTITY\""
}

try_create_identity() {
    # Returns 0 if "$IDENTITY" is usable afterwards. Non-interactive:
    # `security import -T` never pops a GUI prompt; a locked keychain fails
    # fast instead of hanging.
    security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1 || return 1
    local tmp; tmp="$(mktemp -d)"
    (
        set -e
        # Leaf cert (CA:FALSE) + digitalSignature keyUsage + codeSigning EKU —
        # the exact extension shape macOS accepts as a codesigning identity.
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=$IDENTITY/O=Whisp Local Development/C=US" \
            -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
            -addext "basicConstraints=critical,CA:FALSE" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
        # macOS SecPKCS12Import rejects OpenSSL 3's default AES PKCS12
        # ("MAC verification failed") — use the legacy PBE/SHA1 algorithms.
        openssl pkcs12 -export -password pass:whisp-tmp \
            -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
            -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" 2>/dev/null
        # -T /usr/bin/codesign pre-authorizes codesign on the key's partition
        # list, avoiding a per-sign GUI ACL prompt.
        security import "$tmp/id.p12" -k "$KEYCHAIN" \
            -P whisp-tmp -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1
    )
    local rc=$?
    rm -rf "$tmp"
    [ $rc -eq 0 ] && identity_valid
}

sign_app() {
    local sign_id="$1"
    if [ "$sign_id" = "-" ]; then
        echo "==> signing: ad-hoc (TCC permissions will need re-granting after each rebuild)"
        codesign --force --sign - --timestamp=none \
            --identifier com.bishesha.whisp "$APP"
    else
        echo "==> signing: stable identity '$sign_id'"
        codesign --force --sign "$sign_id" --timestamp=none \
            --identifier com.bishesha.whisp "$APP"
    fi
    # Verify BEFORE adding the app-root bundle symlinks — they are required by
    # SwiftPM's Bundle.module lookup but can never be part of the seal.
    codesign --verify --deep --strict "$APP" && echo "    signature verifies (pre-bundle-symlink)"
}

SIGN_ID="-"
if [ -n "$SPARKLE_DIR" ]; then
    FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
    RELEASE_SIGN_FLAGS=(--sign - --timestamp=none)
    if [ -n "$DEVELOPER_ID" ]; then
        RELEASE_SIGN_FLAGS=(--sign "$DEVELOPER_ID" --options runtime --timestamp)
        if [ -n "${RELEASE_KEYCHAIN:-}" ]; then
            RELEASE_SIGN_FLAGS+=(--keychain "$RELEASE_KEYCHAIN")
        fi
    fi
    while IFS= read -r -d '' helper; do
        codesign --force "${RELEASE_SIGN_FLAGS[@]}" "$helper"
    done < <(find -H "$FRAMEWORK/Versions/Current" -depth \( -name '*.app' -o -name '*.xpc' -o -name Autoupdate \) -print0)
    codesign --force "${RELEASE_SIGN_FLAGS[@]}" "$FRAMEWORK"
    for library in "$APP/Contents/Frameworks/"*.dylib; do
        [ -f "$library" ] || continue
        codesign --force "${RELEASE_SIGN_FLAGS[@]}" "$library"
    done
    codesign --force "${RELEASE_SIGN_FLAGS[@]}" --entitlements Resources/Release.entitlements "$APP"
    codesign --verify --deep --strict "$APP"
elif [ "$IDENTITY" != "-" ]; then
    if identity_valid; then
        SIGN_ID="$IDENTITY"
        echo "==> found existing signing identity '$IDENTITY'"
    else
        echo "==> '$IDENTITY' not in keychain; attempting non-interactive creation"
        if try_create_identity; then
            SIGN_ID="$IDENTITY"
            echo "    created self-signed identity '$IDENTITY'"
        else
            echo "    could not create identity non-interactively; falling back to ad-hoc."
            echo "    (see README.md -> 'Code signing' for the one-time fix)"
        fi
    fi
else
    echo "==> IDENTITY=- : ad-hoc signing requested"
fi
if [ -z "$SPARKLE_DIR" ]; then
    sign_app "$SIGN_ID"
    # Local builds retain the SwiftPM resource links. Releases omit them to
    # keep the signature intact; FluidAudio uses these resources only for TTS.
    for name in "${BUNDLE_NAMES[@]:-}"; do
        [ -n "$name" ] || continue
        ln -sfn "Contents/Resources/$name" "$APP/$name"
        echo "    app-root link: $name -> Contents/Resources/$name"
    done
    [ ${#BUNDLE_NAMES[@]} -gt 0 ] && echo "    (note: 'codesign --verify' will now report unsealed bundle-root contents — expected; see script header)"
fi

echo "==> done: $APP"

# ---- Install ---------------------------------------------------------------
if [ "$INSTALL" = 1 ]; then
    DEST="/Applications"
    [ -w "$DEST" ] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    echo "==> installing to $DEST/$APP_NAME.app"
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    pkill -x "$PRODUCT" 2>/dev/null || true
    sleep 0.5
    rm -rf "$DEST/$APP_NAME.app"
    ditto "$APP" "$DEST/$APP_NAME.app"   # preserves symlinks, unlike cp -R edge cases
    xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" 2>/dev/null || true
    open "$DEST/$APP_NAME.app"
    echo "==> installed and launched $DEST/$APP_NAME.app"
fi
