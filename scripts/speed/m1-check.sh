#!/bin/bash
# M1 check: one-command speed validation on the owner's Mac (Apple M1, 8 GB).
#
#   scripts/speed/m1-check.sh /path/to/wav-folder [engine,list]
#
# - Builds whisp-bench in a TEMP scratch dir (source tree untouched).
# - Downloads the latest `speed-models-*` draft-release assets if any exist
#   (≤ 1 GB total), exposes them via WHISP_MODEL_DIR for engines that use them.
# - Runs over the given WAV folder (recordings NEVER leave the Mac):
#     * stage profile (--profile)
#     * release replay waits per offset (--replay)
#     * interleaved engine compare: warm + 30 s idle + rewarm, WER vs .txt refs,
#       word agreement vs the first engine (--compare)
# - Runs a 50-file LibriSpeech test-clean subset for real WER (downloaded to
#   scratch, deleted after).
# - Prints ONE aggregate table, no transcripts, plus the exact `defaults write`
#   lines to enable each candidate engine in the real app.
# - Cleans up everything it downloaded. Target: < 30 min on an 8 GB M1.
set -euo pipefail

WAVDIR="${1:-}"
ENGINES="${2:-parakeet,profiled}"
if [ -z "$WAVDIR" ] || [ ! -d "$WAVDIR" ]; then
  echo "usage: $0 /path/to/wav-folder [engine,list]" >&2
  echo "  engines default to parakeet,profiled — add track engines as they land" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/whisp-m1check.XXXXXX)"
LOG="$TMP/m1-check.log"
trap 'rm -rf "$TMP"' EXIT
echo "scratch: $TMP (deleted on exit)" | tee "$LOG"

cd "$REPO_ROOT"
echo "==> building whisp-bench (scratch)" | tee -a "$LOG"
swift build -c release --scratch-path "$TMP/build" --product whisp-bench 2>&1 | tail -3 | tee -a "$LOG"
BENCH="$TMP/build/release/whisp-bench"

# --- candidate models from draft release -------------------------------------
DL=0
if command -v gh >/dev/null 2>&1; then
  TAG="$(gh release list -R bisheshabramhacharya/whisp --limit 50 2>/dev/null | awk '$1 ~ /^speed-models-/ {print $1; exit}')"
  if [ -n "$TAG" ]; then
    echo "==> downloading candidate models from draft release $TAG" | tee -a "$LOG"
    mkdir -p "$TMP/models"
    gh release download "$TAG" -R bisheshabramhacharya/whisp -D "$TMP/models" --clobber 2>&1 | tail -3 | tee -a "$LOG" || true
    for a in "$TMP/models"/*.zip; do
      [ -f "$a" ] && (cd "$TMP/models" && unzip -oq "$(basename "$a")" && rm "$(basename "$a")") || true
    done
    DL="$(du -sm "$TMP/models" | cut -f1)"
    echo "    downloaded ${DL} MB (limit 1000)" | tee -a "$LOG"
    if [ "$DL" -gt 1000 ]; then
      echo "!! model download exceeds 1 GB — aborting" | tee -a "$LOG"; exit 2
    fi
    export WHISP_MODEL_DIR="$TMP/models"
  else
    echo "==> no speed-models-* draft release found — engines using stock models only" | tee -a "$LOG"
  fi
fi

# --- input set: up to 40 files from the folder --------------------------------
find "$WAVDIR" -type f \( -name "*.wav" -o -name "*.flac" -o -name "*.aiff" -o -name "*.m4a" \) | sort | head -40 > "$TMP/files.txt"
N=$(wc -l < "$TMP/files.txt" | tr -d ' ')
echo "==> $N recordings under test" | tee -a "$LOG"
if [ "$N" -eq 0 ]; then echo "no audio files found in $WAVDIR"; exit 1; fi
FILES=$(cat "$TMP/files.txt" | tr '\n' ' ')

# --- 1. release replay --------------------------------------------------------
echo "==> release replay (engine $ENGINES)" | tee -a "$LOG"
FIRST_ENGINE="${ENGINES%%,*}"
"$BENCH" --replay --engine "$FIRST_ENGINE" $FILES 2>&1 | tee -a "$LOG" | grep -v "transcript:"

# --- 2. stage profile ----------------------------------------------------------
echo "==> stage profile (profiled engine)" | tee -a "$LOG"
"$BENCH" --profile --runs 3 $FILES 2>&1 | tee -a "$LOG" | grep -v "transcript:"

# --- 3. interleaved compare -----------------------------------------------------
echo "==> compare $ENGINES (20 runs/file, 30 s idle + rewarm)" | tee -a "$LOG"
"$BENCH" --compare "$ENGINES" --runs 20 --idle 30 $FILES 2>&1 | tee -a "$LOG"

# --- 4. LibriSpeech subset for real WER -----------------------------------------
echo "==> LibriSpeech WER subset (50 files, downloaded to scratch)" | tee -a "$LOG"
mkdir -p "$TMP/libri"
curl -sfL "https://www.openslr.org/resources/12/test-clean.tar.gz" -o "$TMP/libri/tc.tgz" 2>&1 | tail -1 | tee -a "$LOG" || echo "LibriSpeech fetch failed — skipping" | tee -a "$LOG"
if [ -s "$TMP/libri/tc.tgz" ]; then
  tar -tzf "$TMP/libri/tc.tgz" 2>/dev/null | grep '\.flac$' | head -50 | \
    tar -xzf "$TMP/libri/tc.tgz" -C "$TMP/libri" -T - 2>/dev/null || true
  find "$TMP/libri" -name "*.trans.txt" | head -1 | while read -r t; do
    d="$(dirname "$t")"
    python3 - "$t" "$d" <<'PYEOF'
import sys, os
trans, d = sys.argv[1], sys.argv[2]
for line in open(trans):
    k, _, v = line.strip().partition(' ')
    open(os.path.join(d, k + '.flac.txt'), 'w').write(v + '\n')
PYEOF
  done
  LIBRI_FILES=$(find "$TMP/libri" -name "*.flac" | sort | tr '\n' ' ')
  if [ -n "$LIBRI_FILES" ]; then
    "$BENCH" --compare "$ENGINES" --runs 3 --idle 0 $LIBRI_FILES 2>&1 | tee -a "$LOG"
  fi
  rm -f "$TMP/libri/tc.tgz"
fi

# --- summary --------------------------------------------------------------------
echo ""
echo "================ M1 CHECK SUMMARY ================" | tee -a "$LOG"
grep -A 20 "Compare (" "$LOG" | tail -40 || true
grep -A 12 "Release replay" "$LOG" | tail -13 || true
grep -A 5 "Mean stage profile" "$LOG" | tail -6 || true
echo ""
echo "To try each engine in the app:"
for e in ${ENGINES//,/ }; do
  [ "$e" = "parakeet" ] && echo "  defaults write com.bishesha.whisp asrEngine parakeet   # today's engine (default)"
  [ "$e" != "parakeet" ] && echo "  defaults write com.bishesha.whisp asrEngine $e"
done
echo "(quit + relaunch Whisp after changing)"
echo "=================================================="
