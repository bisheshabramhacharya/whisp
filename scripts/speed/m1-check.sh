#!/bin/bash
# M1 check: one-command speed validation on the owner's Mac (Apple M1, 8 GB).
#
#   scripts/speed/m1-check.sh /path/to/wav-folder [engine,list]
#
# - Builds whisp-bench in a TEMP scratch dir (source tree untouched).
# - Downloads the latest `speed-models-*` draft-release assets if any exist
#   (≤ 1 GB total), verifies each against the release's SHASUMS256.txt when
#   present, and exposes them via WHISP_MODEL_DIR for engines that use them.
# - Runs over the given WAV folder (recordings NEVER leave the Mac):
#     * stage profile (--profile)
#     * release replay waits per offset with per-bucket breakdown (--replay),
#       run for EVERY engine in the list
#     * interleaved engine compare: warm + 30 s idle + rewarm, WER vs .txt refs,
#       word agreement vs the first engine (--compare)
# - Generates ~30 hostile "edge" clips locally (tail-heavy takes where the last
#   word is at risk) and reports last-word misses per engine.
# - Runs a 50-file LibriSpeech test-clean subset for real WER (downloaded to
#   scratch, deleted after).
# - Reports peak memory footprint per engine replay run.
# - Prints ONE aggregate table, no transcripts, plus the exact `defaults write`
#   lines to enable each candidate engine in the real app.
# - Cleans up everything it downloaded. Target: < 30 min on an 8 GB M1.
set -euo pipefail

WAVDIR="${1:-}"
ENGINES="${2:-parakeet,short,split}"
if [ -z "$WAVDIR" ] || [ ! -d "$WAVDIR" ]; then
  echo "usage: $0 /path/to/wav-folder [engine,list]" >&2
  echo "  engines default to parakeet,short,split — e.g. parakeet,short,streaming,par2,profiled" >&2
  echo "  ('split' needs a checkout that ships the piecewise engine; older trees:" >&2
  echo "   pass parakeet,short explicitly)" >&2
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
# Engines that accept out-of-cache bundles honour $WHISP_MODEL_DIR (a scratch
# dir the trap deletes) — nothing lands in ~/Library/Application Support.
DL=0
if command -v gh >/dev/null 2>&1; then
  TAG="$(gh release list -R bisheshabramhacharya/whisp --limit 50 2>/dev/null | awk '$1 ~ /^speed-models-/ {print $1; exit}' || true)"
  if [ -n "$TAG" ]; then
    echo "==> downloading candidate models from draft release $TAG" | tee -a "$LOG"
    mkdir -p "$TMP/models"
    gh release download "$TAG" -R bisheshabramhacharya/whisp -D "$TMP/models" --clobber 2>&1 | tail -3 | tee -a "$LOG" || true
    # Verify every downloaded zip against the release's SHA-256 manifest when
    # one is published; without a manifest nothing is trusted enough to use.
    if [ -f "$TMP/models/SHASUMS256.txt" ]; then
      (cd "$TMP/models" && shasum -a 256 -c SHASUMS256.txt --ignore-missing 2>&1 | tee -a "$LOG") \
        || { echo "!! SHA-256 mismatch on a downloaded bundle — aborting" | tee -a "$LOG"; exit 2; }
    else
      echo "!! no SHASUMS256.txt in $TAG — discarding unverified assets" | tee -a "$LOG"
      find "$TMP/models" -name "*.zip" -delete
    fi
    for a in "$TMP/models"/*.zip; do
      [ -f "$a" ] && (cd "$TMP/models" && unzip -oq "$(basename "$a")" && rm "$(basename "$a")") || true
    done
    DL="$(du -sm "$TMP/models" 2>/dev/null | cut -f1 || echo 0)"
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
find "$WAVDIR" -type f \( -name "*.wav" -o -name "*.flac" -o -name "*.aiff" -o -name "*.m4a" \) | sort > "$TMP/files.txt"
head -40 "$TMP/files.txt" > "$TMP/files40.txt" && mv "$TMP/files40.txt" "$TMP/files.txt"
N=$(wc -l < "$TMP/files.txt" | tr -d ' ')
echo "==> $N recordings under test" | tee -a "$LOG"
if [ "$N" -eq 0 ]; then echo "no audio files found in $WAVDIR"; exit 1; fi
FILES=$(cat "$TMP/files.txt" | tr '\n' ' ')

# --- 1. release replay, per engine (per-bucket waits + peak memory) -----------
echo "==> release replay per engine (offsets 0,200,350 ms)" | tee -a "$LOG"
for e in ${ENGINES//,/ }; do
  echo "--- replay engine $e" | tee -a "$LOG"
  /usr/bin/time -l "$BENCH" --replay --engine "$e" --offsets 0,200,350 $FILES \
    > "$TMP/replay-$e.out" 2> "$TMP/replay-$e.time" || true
  grep -v "transcript:" "$TMP/replay-$e.out" | tee -a "$LOG" || true
  grep -E "maximum resident|peak memory" "$TMP/replay-$e.time" \
    | sed "s/^/    $e /" | tee -a "$LOG" || true
done

# --- 2. stage profile ----------------------------------------------------------
echo "==> stage profile (profiled engine)" | tee -a "$LOG"
"$BENCH" --profile --runs 3 $FILES 2>&1 | tee -a "$LOG" | grep -v "transcript:"

# --- 3. interleaved compare -----------------------------------------------------
echo "==> compare $ENGINES (20 runs/file, 30 s idle + rewarm)" | tee -a "$LOG"
"$BENCH" --compare "$ENGINES" --runs 20 --idle 30 $FILES 2>&1 | tee -a "$LOG" || \
  echo "!! compare failed — an engine name may be unknown to this build" | tee -a "$LOG"

# --- 4. edge set: last-word misses ----------------------------------------------
# Transforms the user's own clips into tail-heavy hostile takes (all local,
# deleted by the trap) and replays each engine over them.
echo "==> edge set (~30 clips): last-word survival per engine" | tee -a "$LOG"
mkdir -p "$TMP/edge-src" "$TMP/edge"
# Longest files give the tail transforms room to work (<2 s clips are skipped).
find "$WAVDIR" -type f -name "*.wav" -exec stat -f '%z %N' {} \; | sort -rn | head -10 | cut -d' ' -f2- | while read -r f; do cp "$f" "$TMP/edge-src/"; done
if "$REPO_ROOT/scripts/speed/gen-edge.sh" "$TMP/edge-src" "$TMP/edge" >>"$LOG" 2>&1; then
  EDGE_FILES=$(find "$TMP/edge" -name "*.wav" | sort | head -30 | tr '\n' ' ')
  if [ -n "$EDGE_FILES" ]; then
    for e in ${ENGINES//,/ }; do
      echo "--- edge replay engine $e" | tee -a "$LOG"
      "$BENCH" --replay --engine "$e" --offsets 0,100 $EDGE_FILES > "$TMP/edge-$e.out" 2>&1 || true
      grep -v "transcript:" "$TMP/edge-$e.out" | grep -E "last-word|ms:" | tee -a "$LOG" || true
    done
  else
    echo "edge set empty (source folder may need .wav files) — skipping" | tee -a "$LOG"
  fi
else
  echo "edge generation failed — skipping" | tee -a "$LOG"
fi

# --- 5. LibriSpeech subset for real WER -----------------------------------------
echo "==> LibriSpeech WER subset (50 files, downloaded to scratch)" | tee -a "$LOG"
mkdir -p "$TMP/libri"
if ! curl -sfL "https://www.openslr.org/resources/12/test-clean.tar.gz" -o "$TMP/libri/tc.tgz"; then
  echo "LibriSpeech fetch failed — skipping WER subset" | tee -a "$LOG"
fi
if [ -s "$TMP/libri/tc.tgz" ]; then
  # BSD tar can't read the inclusion list from stdin — write a manifest first.
  # The .trans.txt references ride along so WER has ground truth.
  { tar -tzf "$TMP/libri/tc.tgz" 2>/dev/null | grep '\.flac$' | head -50;
    tar -tzf "$TMP/libri/tc.tgz" 2>/dev/null | grep '\.trans\.txt$'; } \
    > "$TMP/libri/manifest.txt"
  tar -xzf "$TMP/libri/tc.tgz" -C "$TMP/libri" -T "$TMP/libri/manifest.txt" 2>/dev/null || true
  find "$TMP/libri" -name "*.trans.txt" | while read -r t; do
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
    "$BENCH" --compare "$ENGINES" --runs 3 --idle 0 $LIBRI_FILES 2>&1 | tee -a "$LOG" || true
  fi
  rm -f "$TMP/libri/tc.tgz"
fi

# --- summary --------------------------------------------------------------------
echo ""
echo "================ M1 CHECK SUMMARY ================" | tee -a "$LOG"
grep -A 20 "Compare (" "$LOG" | tail -40 || true
echo "--- per-engine replay (+0 ms row + leftover buckets + peak memory):" | tee -a "$LOG"
for e in ${ENGINES//,/ }; do
  echo "engine $e:" | tee -a "$LOG"
  grep -A 20 "Release replay" "$TMP/replay-$e.out" 2>/dev/null | grep -E "\+   0 ms|bucket|<5 s|5–10 s|10–15 s|>15 s" | head -14 | tee -a "$LOG" || true
  grep -E "maximum resident|peak memory" "$TMP/replay-$e.time" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG" || true
done
echo "--- edge-set last-word:" | tee -a "$LOG"
for e in ${ENGINES//,/ }; do
  [ -f "$TMP/edge-$e.out" ] || continue
  printf "engine %s: " "$e" | tee -a "$LOG"
  grep "last-word" "$TMP/edge-$e.out" | head -1 | sed 's/^  +   0 ms: //' | tee -a "$LOG" || true
done
grep -A 5 "Mean stage profile" "$LOG" | tail -6 | tee -a "$LOG" || true
echo ""
echo "To try each engine in the app:"
for e in ${ENGINES//,/ }; do
  [ "$e" = "parakeet" ] && echo "  defaults write com.bishesha.whisp asrEngine parakeet   # flat 15 s window (baseline)"
  [ "$e" != "parakeet" ] && echo "  defaults write com.bishesha.whisp asrEngine $e"
done
echo "(quit + relaunch Whisp after changing)"
echo "=================================================="
