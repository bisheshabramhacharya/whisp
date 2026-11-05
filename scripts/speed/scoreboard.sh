#!/bin/bash
# Whisp scoreboard: one command, the truth on this Mac.
#
#   scripts/speed/scoreboard.sh              # measure, print the table
#   scripts/speed/scoreboard.sh --record     # measure, print, write docs/speed/scoreboard/
#   scripts/speed/scoreboard.sh --force      # ignore the per-file cache
#   scripts/speed/scoreboard.sh --quick      # smoke test: seconds per bucket, no record
#
# What it measures, all on the owner's own recordings and public test sets:
#   * wait = key release -> text appearing, by real-time replay of the owner's
#     recordings through the app's own dictation path (whisp-bench --live),
#     bucketed by speech length: short 1-10 s, average 10-60 s, long 5+ min.
#   * WER on LibriSpeech test-clean and test-other, and on the `say`-generated
#     dictation set (the casual stand-in until a real casual set exists).
#   * last word kept vs a recorded baseline build, and new dropped last words.
#
# The table goes to stdout and nothing else does; progress and the reason for
# any `n/a` go to stderr. --record writes baseline-<engine sha>.json,
# latest.json and latest.md under docs/speed/scoreboard/. Recording names,
# audio and transcripts never leave this machine and never enter the repo.
#
# Env:
#   WHISP_DATA=~/whisp-data           recordings + history.jsonl (read in place)
#   WHISP_SCOREBOARD_CACHE=~/.whisp-scoreboard-cache   per-file result cache
#   WHISP_SCOREBOARD_ENGINE=short     engine under test (see `whisp-bench --help`)
#   WHISP_CASUAL_SET=<dir>            real casual set with <file>.wav + <file>.txt;
#                                     when set its WER prints above the stand-in row
#
# Sampling: each bucket replays recordings in a stable hash order until it has
# spent its audio budget, so a full run stays under 45 minutes. The numbers
# used and the rule are printed with the table.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

RECORD=0
FORCE=""
QUICK=""
for arg in "$@"; do
  case "$arg" in
    --record) RECORD=1 ;;
    --force) FORCE="--force" ;;
    --quick) QUICK=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "scoreboard: unknown argument $arg (try --help)" >&2; exit 1 ;;
  esac
done

# One benchmark at a time (CREW.md). Two benches on this 8 GB M1 give fake numbers.
LOCK=~/.whisp-bench.lock
mkdir "$LOCK" 2>/dev/null || { echo "benchmark busy: $(cat "$LOCK/owner" 2>/dev/null)"; exit 3; }
echo "$$ $(date -u +%FT%TZ) $(pwd)" > "$LOCK/owner"

TMP="$(mktemp -d /tmp/whisp-scoreboard.XXXXXX)"
START_EPOCH="$(date +%s)"
trap 'rm -rf "$TMP" "$LOCK"' EXIT

notify() { echo "scoreboard: $*" >&2; }

CACHE="${WHISP_SCOREBOARD_CACHE:-$HOME/.whisp-scoreboard-cache}"
DATA="${WHISP_DATA:-$HOME/whisp-data}"
ENGINE="${WHISP_SCOREBOARD_ENGINE:-short}"
CASUAL="${WHISP_CASUAL_SET:-}"
STATE="$TMP/state.json"
OUTDIR="$ROOT/docs/speed/scoreboard"
BENCH="$ROOT/.build/release/whisp-bench"

# Audio budgets per speed bucket, in seconds of recorded speech. Replay runs in
# real time, so this is the run's wall clock: 360 + 700 + 1000 s of audio plus
# per-file overhead plus the WER decodes stays under 45 minutes.
BUDGET_SHORT=300
BUDGET_AVERAGE=450
BUDGET_LONG=1300
MIN_SHORT=40
MIN_AVERAGE=16
MIN_LONG=3

# WER corpus caps (files decoded per set). Above ~400 the score barely moves.
CAP_CLEAN=300
CAP_OTHER=300
CAP_DICTATION=150
CAP_CASUAL=150

# --quick exists to prove the pipeline after touching it: a few seconds of audio
# per bucket. Never recorded, and its numbers are not the scoreboard.
if [ -n "$QUICK" ]; then
  if [ "$RECORD" = 1 ]; then echo "scoreboard: --quick and --record do not mix" >&2; exit 1; fi
  BUDGET_SHORT=20; BUDGET_AVERAGE=40; BUDGET_LONG=40
  MIN_SHORT=3; MIN_AVERAGE=2; MIN_LONG=1
  CAP_CLEAN=20; CAP_OTHER=20; CAP_DICTATION=10; CAP_CASUAL=10
fi

# --- build ------------------------------------------------------------------
notify "building whisp-bench (release)"
swift build -c release --product whisp-bench >"$TMP/build.log" 2>&1 || {
  tail -20 "$TMP/build.log" >&2; exit 2; }
[ -x "$BENCH" ] || { notify "no $BENCH after build"; exit 2; }

# --- test sets (one time) ---------------------------------------------------
if [ ! -d testdata/librispeech/LibriSpeech/test-clean ] ||
   [ ! -d testdata/librispeech/LibriSpeech/test-other ]; then
  notify "fetching LibriSpeech test-clean/test-other (one time, ~675 MB)"
  scripts/speed/fetch-librispeech.sh >/dev/null
fi
if [ "$(find testdata/dictation -name '*.wav' 2>/dev/null | wc -l | tr -d ' ')" -lt 300 ]; then
  notify "generating the dictation set with say (one time, ~300 clips)"
  scripts/speed/gen-dictation.sh >/dev/null
fi

# --- identify the build and the machine --------------------------------------
SHA="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" = "HEAD" ]; then
  BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  BRANCH="${BRANCH:-main}"
fi
# The engine basis: the last commit that changed app code, so bench-only commits
# (like the one adding --json) do not rename the baseline the numbers belong to.
ENGINE_SHA="$(git rev-list -1 HEAD -- Sources/WhispCore Sources/Whisp Resources | cut -c1-7)"
DIRTY=0
if [ -n "$(git status --porcelain)" ]; then DIRTY=1; fi
MODEL="$(sysctl -n hw.model)"
CHIP="$(sysctl -n machdep.cpu.brand_string | sed 's/^Apple //')"
MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
OS_VER="$(sw_vers -productVersion)"

# The recorded baseline: the newest baseline-*.json, unless this run records one.
BASELINE_FILE="$(ls -1t "$OUTDIR"/baseline-*.json 2>/dev/null | head -1 || true)"

# Env, not argv: macOS /bin/bash is 3.2, where "${arr[@]}" on an empty array
# is an unbound-variable error under `set -u`.
export WHISP_SB_BASELINE_FILE="$BASELINE_FILE"
export WHISP_SB_THIS_IS_BASELINE="$RECORD"

python3 "$ROOT/scripts/speed/scoreboard.py" init \
  --state "$STATE" --cache "$CACHE" --data "$DATA" --root "$ROOT" --started "$START_EPOCH" \
  --sha "$SHA" --engine-sha "$ENGINE_SHA" --branch "$BRANCH" --dirty "$DIRTY" \
  --model "$MODEL" --chip "$CHIP" --mem-gb "$MEM_GB" --os "$OS_VER" \
  --engine "$ENGINE" --gap 1 \
  --budget-short "$BUDGET_SHORT" --budget-average "$BUDGET_AVERAGE" --budget-long "$BUDGET_LONG" \
  --min-short "$MIN_SHORT" --min-average "$MIN_AVERAGE" --min-long "$MIN_LONG" \
  --cap-clean "$CAP_CLEAN" --cap-other "$CAP_OTHER" --cap-dictation "$CAP_DICTATION" \
  --cap-casual "$CAP_CASUAL" \
  --casual-set "$CASUAL"

# --- sample the owner's recordings ------------------------------------------
python3 "$ROOT/scripts/speed/scoreboard.py" sample --state "$STATE" --sample "$TMP/sample.json"
python3 "$ROOT/scripts/speed/scoreboard.py" plan --state "$STATE" --sample "$TMP/sample.json" \
  --out-dir "$TMP" ${FORCE:+--force}

# --- real-time replay, one process for every bucket --------------------------
# One process matters: loading the models costs seconds to minutes on this M1
# (Core ML recompiles each launch), and replay itself is real time.
NEED="$TMP/need-live.txt"
if [ -s "$NEED" ]; then
  notify "replaying $(wc -l < "$NEED" | tr -d ' ') recordings in real time"
  FILES=()
  while IFS= read -r line; do FILES+=("$line"); done < "$NEED"
  "$BENCH" --live --json --engine "$ENGINE" --gap 1 "${FILES[@]}" \
    > "$TMP/live.out" 2> "$TMP/live.err" || notify "the replay did not finish; keeping the rows it produced"
  grep -e '^{' "$TMP/live.out" > "$TMP/live.jsonl" || true
  if [ ! -s "$TMP/live.jsonl" ]; then
    notify "no replay rows; last lines of the bench's stderr:"
    tail -3 "$TMP/live.err" >&2 || true
  fi
  python3 "$ROOT/scripts/speed/scoreboard.py" merge-live --state "$STATE" \
    --sample "$TMP/sample.json" --rows "$TMP/live.jsonl"
else
  notify "every sampled recording is cached"
fi

# --- WER on the public sets, one process ------------------------------------
python3 "$ROOT/scripts/speed/scoreboard.py" wer-plan --state "$STATE" \
  --out "$TMP/wer-need.txt" --map "$TMP/wer-map.json" ${FORCE:+--force}
if [ -s "$TMP/wer-need.txt" ]; then
  FILES=()
  while IFS= read -r line; do FILES+=("$line"); done < "$TMP/wer-need.txt"
  notify "decoding $(wc -l < "$TMP/wer-need.txt" | tr -d ' ') corpus files for WER"
  "$BENCH" --compare "$ENGINE" --runs 1 --idle 0 --json "${FILES[@]}" \
    > "$TMP/wer.out" 2> "$TMP/wer.err" || notify "the WER decode did not finish; keeping what landed"
  grep -e '^{' "$TMP/wer.out" > "$TMP/wer.jsonl" || true
else
  notify "every corpus file is cached"
  : > "$TMP/wer.jsonl"
fi
python3 "$ROOT/scripts/speed/scoreboard.py" wer-merge --state "$STATE" \
  --rows "$TMP/wer.jsonl" --map "$TMP/wer-map.json"

# --- print, then record -----------------------------------------------------
python3 "$ROOT/scripts/speed/scoreboard.py" report --state "$STATE" --out "$TMP/table.txt"
cat "$TMP/table.txt"
if [ "$RECORD" = 1 ]; then
  python3 "$ROOT/scripts/speed/scoreboard.py" record --state "$STATE" \
    --dir "$OUTDIR" --table "$TMP/table.txt"
fi
