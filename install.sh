#!/bin/sh
# Whisp installer — clones the source, builds it, and installs the app.
#
#   curl -fsSL https://raw.githubusercontent.com/bisheshabramhacharya/whisp/main/install.sh | bash
#
# What it does: clones this repo to ~/.whisp (or updates an existing clone),
# builds Whisp in release mode with scripts/build-app.sh, installs it to
# /Applications and launches onboarding. Needs Apple Silicon, macOS 14+,
# and the Xcode Command Line Tools (xcode-select --install).

set -eu

REPO="https://github.com/bisheshabramhacharya/whisp.git"
SRC="${WHISP_SRC:-$HOME/.whisp}"

echo "==> Whisp installer"

if [ "$(uname -m)" != "arm64" ]; then
    echo "Whisp needs an Apple Silicon Mac: the speech model runs on the Neural Engine." >&2
    exit 1
fi

if ! git --version >/dev/null 2>&1; then
    echo "git not found. Install the Xcode Command Line Tools first:" >&2
    echo "    xcode-select --install" >&2
    echo "Then run this installer again." >&2
    exit 1
fi

if [ -d "$SRC/.git" ]; then
    echo "==> updating $SRC"
    git -C "$SRC" pull --ff-only
else
    echo "==> cloning $REPO into $SRC"
    git clone "$REPO" "$SRC"
fi

echo "==> building and installing (the first build takes a few minutes)"
exec bash "$SRC/scripts/build-app.sh" --install
