#!/bin/bash
# make-icon.sh — regenerate Resources/AppIcon.icns and docs/icon.png from the
# AppKit renderer in scripts/make-icon.swift.
#
#   scripts/make-icon.sh
#
# Produces Resources/AppIcon.icns next to Info.plist and docs/icon.png for the
# README, both from the same render.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
cp "$ICONSET/icon_512x512.png" "$ROOT/docs/icon.png"
echo "wrote $ROOT/Resources/AppIcon.icns and $ROOT/docs/icon.png"
