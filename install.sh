#!/bin/sh
# Whisp installer — clones the source, builds it, and installs the app.
#
#   curl -fsSL https://raw.githubusercontent.com/bisheshabramhacharya/whisp/main/install.sh | bash
#
# What it does: clones the latest release tag of this repo to ~/.whisp (or
# updates an existing clone), builds Whisp in release mode with
# scripts/build-app.sh, installs it to /Applications and launches onboarding.
# Needs Apple Silicon, macOS 14+, and the Xcode Command Line Tools
# (xcode-select --install).

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

# Build the newest release tag, not whatever happens to be on main right now.
# Falls back to main when the repo has no v* tags (or ls-remote failed).
TAG="$(git ls-remote --tags --refs --sort=-v:refname "$REPO" 'v[0-9]*' 2>/dev/null \
    | head -1 | sed 's|.*refs/tags/||')"

if [ -d "$SRC/.git" ]; then
    echo "==> updating $SRC"
    if [ -n "$TAG" ]; then
        git -C "$SRC" fetch --depth 1 origin "refs/tags/$TAG"
        git -C "$SRC" checkout -q FETCH_HEAD
    else
        git -C "$SRC" pull --ff-only
    fi
else
    # A leftover dir without .git (e.g. an earlier clone that died mid-download)
    # would make git clone fail forever; move it aside instead of deleting it.
    if [ -e "$SRC" ]; then
        mv "$SRC" "$SRC.bak.$(date +%Y%m%d%H%M%S)"
    fi
    if [ -n "$TAG" ]; then
        echo "==> cloning $REPO@$TAG into $SRC"
        git clone --depth 1 --branch "$TAG" "$REPO" "$SRC"
    else
        echo "==> cloning $REPO into $SRC"
        git clone "$REPO" "$SRC"
    fi
fi

echo "==> building and installing (the first build takes a few minutes)"
exec bash "$SRC/scripts/build-app.sh" --install
