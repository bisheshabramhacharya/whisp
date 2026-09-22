#!/bin/bash
# make-icon.sh — regenerate Resources/AppIcon.icns from the CoreGraphics
# renderer in scripts/make-icon.swift.
#
#   scripts/make-icon.sh
#
# Produces Resources/AppIcon.icns next to Info.plist.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "wrote $ROOT/Resources/AppIcon.icns"
