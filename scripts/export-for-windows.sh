#!/bin/sh
# Packs this Mac's Whisp data into ~/Desktop/whisp-export.zip for Whisp on Windows
# (tray icon → Import from Mac…): dictionary, history, recordings and menu settings.
#
#   curl -fsSL https://raw.githubusercontent.com/bisheshabramhacharya/whisp/main/scripts/export-for-windows.sh | sh
#
# Set WHISP_EXPORT_RECORDINGS=0 to leave the recordings out (about 1 MB per 30 s).

set -eu

DATA="$HOME/Library/Application Support/Whisp"
OUT="${WHISP_EXPORT_DIR:-$HOME/Desktop}"
STAGE="$(mktemp -d)/whisp-export"

if [ ! -d "$DATA" ]; then
    echo "No Whisp data at $DATA — has Whisp run on this Mac?" >&2
    exit 1
fi

mkdir -p "$STAGE"
for f in dictionary.json history.jsonl; do
    if [ -f "$DATA/$f" ]; then cp "$DATA/$f" "$STAGE/"; fi
done
if [ "${WHISP_EXPORT_RECORDINGS:-1}" != "0" ] && [ -d "$DATA/recordings" ]; then
    cp -R "$DATA/recordings" "$STAGE/recordings"
fi
if defaults export com.bishesha.whisp "$STAGE/settings.plist" 2>/dev/null; then
    plutil -convert xml1 "$STAGE/settings.plist"
fi

rm -f "$OUT/whisp-export.zip"
(cd "$(dirname "$STAGE")" && zip -qr "$OUT/whisp-export.zip" whisp-export)
rm -rf "$(dirname "$STAGE")"

echo "Saved $OUT/whisp-export.zip"
echo "Copy it to your PC, then pick Import from Mac… in the Whisp tray menu."
