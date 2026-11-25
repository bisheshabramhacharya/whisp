#!/bin/sh
# Packs this Mac's Whisp data into ~/Desktop/whisp-export.zip for Whisp on Windows
# (tray icon → Import from Mac…): dictionary, history, recordings and menu settings.
#
#   curl -fsSL https://raw.githubusercontent.com/bisheshabramhacharya/whisp/main/scripts/export-for-windows.sh | sh
#
# Set WHISP_EXPORT_RECORDINGS=0 to leave the recordings out (about 1 MB per 30 s).

set -eu

if [ -n "${WHISP_DATA_DIR:-}" ]; then
    DATA="$WHISP_DATA_DIR"
elif [ -d "$HOME/whisp-data" ]; then
    DATA="$HOME/whisp-data"
else
    DATA="$HOME/Library/Application Support/Whisp"
fi
OUT="${WHISP_EXPORT_DIR:-$HOME/Desktop}"
STAGE="$(mktemp -d)/whisp-export"

if [ ! -d "$DATA" ]; then
    echo "No Whisp data at $DATA — has Whisp run on this Mac?" >&2
    exit 1
fi

mkdir -p "$STAGE"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT
if [ -f "$DATA/daily-data.json" ]; then
    WHISP_BIN="${WHISP_BIN:-/Applications/Whisp.app/Contents/MacOS/Whisp}"
    if [ ! -x "$WHISP_BIN" ]; then WHISP_BIN="$HOME/Applications/Whisp.app/Contents/MacOS/Whisp"; fi
    if [ ! -x "$WHISP_BIN" ]; then
        echo "Could not find Whisp.app to export edited data. Set WHISP_BIN to the installed Whisp executable." >&2
        exit 1
    fi
    WHISP_DATA_DIR="$DATA" "$WHISP_BIN" --export-daily-data "$STAGE"
else
    for f in dictionary.json history.jsonl; do
        if [ -f "$DATA/$f" ]; then cp "$DATA/$f" "$STAGE/"; fi
    done
fi
if [ "${WHISP_EXPORT_RECORDINGS:-1}" != "0" ] && [ -d "$DATA/recordings" ]; then
    cp -R "$DATA/recordings" "$STAGE/recordings"
fi
if defaults export com.bishesha.whisp "$STAGE/settings.plist" 2>/dev/null; then
    plutil -convert xml1 "$STAGE/settings.plist"
fi

rm -f "$OUT/whisp-export.zip"
(cd "$(dirname "$STAGE")" && zip -qr "$OUT/whisp-export.zip" whisp-export)

echo "Saved $OUT/whisp-export.zip"
echo "Copy it to your PC, then pick Import from Mac… in the Whisp tray menu."
