#!/usr/bin/env bash
set -euo pipefail

whisp="$(realpath -- "${1:?Pass the packaged whisp executable}")"
scratch="$(mktemp -d)"
daemon=
cleanup() {
    if [[ -n "$daemon" ]]; then
        kill "$daemon" 2>/dev/null || true
        wait "$daemon" || true
    fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT

export WHISP_HOME="$scratch/data"
export XDG_RUNTIME_DIR="$scratch"
export WHISP_SMOKE="$scratch"
expected='The quick brown fox jumps over the lazy dog.'
ffmpeg -nostdin -loglevel error -f lavfi -i "flite=text=$expected:voice=slt" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$scratch/clip.wav"
"$whisp" --transcribe "$scratch/clip.wav" > "$scratch/transcript"
grep -Fix "cleaned: $expected" "$scratch/transcript"
ffmpeg -nostdin -loglevel error -i "$scratch/clip.wav" -f s16le "$scratch/clip.raw"

mkdir -p "$scratch/bin"
cat > "$scratch/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == '-j activewindow' ]] && cat "$WHISP_SMOKE/window"
EOF
cat > "$scratch/bin/pw-record" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == --help ]]; then
    if [[ "${WHISP_SMOKE_PW_RAW:-}" == 1 ]]; then echo '  -a, --raw    RAW mode'; fi
    exit 0
fi
if [[ "${WHISP_SMOKE_PW_RAW:-}" == 1 ]]; then
    [[ "$1" == --raw ]] || exit 2
    shift
fi
[[ "$*" == '--format s16 --rate 16000 --channels 1 -' ]] || exit 2
cat "$WHISP_SMOKE/clip.raw"
touch "$WHISP_SMOKE/recorded"
EOF
cat > "$scratch/bin/wtype" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == '-M ctrl -k v -m ctrl' ]] || exit 2
cp "$WHISP_SMOKE/clipboard" "$WHISP_SMOKE/typed"
EOF
cat > "$scratch/bin/wl-copy" <<'EOF'
#!/usr/bin/env bash
cat > "$WHISP_SMOKE/clipboard"
if [[ -e "$WHISP_SMOKE/shift-after-copy" ]]; then
    printf '{"address":"0x2"}\n' > "$WHISP_SMOKE/window"
fi
EOF
chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH"

printf '{"address":"0x1"}\n' > "$scratch/window"
"$whisp" daemon > "$scratch/daemon.log" 2>&1 &
daemon=$!
wait_for() {
    for ((i = 0; i < 200; i++)); do
        if "$@" 2>/dev/null; then return; fi
        if ! kill -0 "$daemon" 2>/dev/null; then break; fi
        sleep 0.1
    done
    printf 'Timed out: %s\n' "$*" >&2
    cat "$scratch/daemon.log" >&2
    return 1
}
wait_for grep -Fxq 'Ready' "$scratch/daemon.log"
"$whisp" press
wait_for test -f "$scratch/recorded"
[[ ! -e "$scratch/typed" && ! -e "$scratch/clipboard" ]]
"$whisp" release
wait_for grep -Fixq "$expected" "$scratch/typed"
cmp -- "$scratch/clipboard" "$scratch/typed"
echo 'PASS: press/release records and types the transcript into the original window'

rm -- "$scratch/recorded" "$scratch/typed" "$scratch/clipboard"
"$whisp" press
wait_for test -f "$scratch/recorded"
"$whisp" cancel
"$whisp" release
rm -- "$scratch/recorded"
"$whisp" press
wait_for test -f "$scratch/recorded"
[[ ! -e "$scratch/typed" && ! -e "$scratch/clipboard" ]]
echo 'PASS: cancel discards audio and the next press can record'

printf '{"address":"0x2"}\n' > "$scratch/window"
"$whisp" release
wait_for grep -Fixq "$expected" "$scratch/clipboard"
[[ ! -e "$scratch/typed" ]]
echo 'PASS: focus change copies the transcript instead of typing into the new window'

kill "$daemon"
wait "$daemon"
daemon=
rm -- "$scratch/recorded"
WHISP_SMOKE_PW_RAW=1 "$whisp" daemon > "$scratch/daemon.log" 2>&1 &
daemon=$!
wait_for grep -Fxq 'Ready' "$scratch/daemon.log"
"$whisp" press
wait_for test -f "$scratch/recorded"
"$whisp" cancel
echo 'PASS: both legacy and modern pw-record arguments are supported'

rm -- "$scratch/recorded" "$scratch/clipboard"
long="$(printf '%01024d' 0)"
printf '{"replacements":[{"from":["quick brown fox"],"to":"%s"}]}' "$long" > "$WHISP_HOME/dictionary.json"
printf '{"address":"0x1"}\n' > "$scratch/window"
"$whisp" press
wait_for test -f "$scratch/recorded"
"$whisp" release
wait_for grep -Fxq "The $long jumps over the lazy dog." "$scratch/typed"
cmp -- "$scratch/typed" "$scratch/clipboard"
echo 'PASS: a 1,053-character transcript is pasted in full'

rm -- "$scratch/recorded" "$scratch/typed" "$scratch/clipboard"
printf '{}\n' > "$WHISP_HOME/dictionary.json"
touch "$scratch/shift-after-copy"
"$whisp" press
wait_for test -f "$scratch/recorded"
"$whisp" release
wait_for grep -Fq 'dictation copied; paste it where you want it.' "$scratch/daemon.log"
grep -Fxq "$expected" "$scratch/clipboard"
[[ ! -e "$scratch/typed" ]]
echo 'PASS: focus change after copying preserves the full transcript without pasting'
