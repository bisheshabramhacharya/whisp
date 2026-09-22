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
# cannot read OpenSSL 3's default AES PKCS12), `security import -T
# /usr/bin/codesign` (pre-authorizes codesign to use the key — no GUI ACL
# prompt), and `security add-trusted-cert -r trustRoot -p codeSign` in the user
# domain (also silent — required for `find-identity -p codesigning` to list a
# self-signed identity as valid). If the keychain is locked or any step fails,
# the script falls back to ad-hoc signing instead of hanging — see README.md
# for the equivalent manual commands.
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
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

echo "==> swift build -c release --arch arm64 --product $PRODUCT (scratch: $SCRATCH)"
swift build -c release --arch arm64 --scratch-path "$SCRATCH" --product "$PRODUCT"

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
    # find-identity appends "(Invalid Key Usage for policy)" etc. for unusable
    # identities — a valid identity's line ENDS with the quoted name.
    security find-identity -p codesigning -v | grep -q "\"$IDENTITY\"[[:space:]]*$"
}

try_create_identity() {
    # Returns 0 if "$IDENTITY" is usable afterwards. Fully non-interactive:
    # user-domain trust settings and `security import -T` never pop a GUI
    # prompt; a locked keychain fails fast instead of hanging.
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
        # User-domain trust for the codeSign policy — silent, and required for
        # `find-identity -p codesigning` to list a self-signed identity.
        security add-trusted-cert -r trustRoot -p codeSign \
            -k "$KEYCHAIN" "$tmp/cert.pem" >/dev/null 2>&1
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
if [ "$IDENTITY" != "-" ]; then
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
            echo "    (see README.md -> 'Stable signing identity' for the one-time fix)"
        fi
    fi
else
    echo "==> IDENTITY=- : ad-hoc signing requested"
fi
sign_app "$SIGN_ID"

# Post-sign: app-root symlinks so SwiftPM's Bundle.module (which resolves
# Bundle.main.bundleURL + "/<name>.bundle") finds the sealed copies.
for name in "${BUNDLE_NAMES[@]:-}"; do
    [ -n "$name" ] || continue
    ln -sfn "Contents/Resources/$name" "$APP/$name"
    echo "    app-root link: $name -> Contents/Resources/$name"
done
[ ${#BUNDLE_NAMES[@]} -gt 0 ] && echo "    (note: 'codesign --verify' will now report unsealed bundle-root contents — expected; see script header)"

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
