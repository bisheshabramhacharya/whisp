#!/usr/bin/env bash
set -euo pipefail

whisp="$(realpath -- "${1:?Pass the packaged whisp executable}")"
setup="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/whisp-setup-hyprland"
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

mkdir -p "$scratch/bin" "$scratch/config/hypr"
printf '# Personal Hyprland configuration\n' > "$scratch/config/hypr/hyprland.conf"
cat > "$scratch/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == '-j activewindow' ]]; then
    cat "$WHISP_SMOKE/window"
else
    [[ "$*" == 'reload' ]]
fi
EOF
cat > "$scratch/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WHISP_SMOKE/systemctl"
EOF
cat > "$scratch/bin/pw-record" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == '--raw --format s16 --rate 16000 --channels 1 -' ]] || exit 2
cat "$WHISP_SMOKE/clip.raw"
touch "$WHISP_SMOKE/recorded"
EOF
cat > "$scratch/bin/wtype" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == '-' ]] || exit 2
cat > "$WHISP_SMOKE/typed"
EOF
cat > "$scratch/bin/wl-copy" <<'EOF'
#!/usr/bin/env bash
cat > "$WHISP_SMOKE/clipboard"
EOF
chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH"
export WAYLAND_DISPLAY=wayland-test HYPRLAND_INSTANCE_SIGNATURE=test XDG_CONFIG_HOME="$scratch/config"

bash "$setup"
bash "$setup"
config="$XDG_CONFIG_HOME/hypr"
[[ "$(grep -Fxc "source = $config/whisp.conf" "$config/hyprland.conf")" == 1 ]]
grep -Fq 'bindi = , F9, exec,' "$config/whisp.conf"
grep -Fq 'bindri = , F9, exec,' "$config/whisp.conf"
grep -Fxq -- '--user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE' "$scratch/systemctl"
grep -Fxq -- '--user restart whisp.service' "$scratch/systemctl"
echo 'PASS: Hyprland setup is idempotent'

printf '{"address":"0x1"}\n' > "$scratch/window"
"$whisp" daemon > "$scratch/daemon.log" 2>&1 &
daemon=$!
wait_for() {
    for ((i = 0; i < 200; i++)); do
        if "$@"; then return; fi
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
echo 'PASS: press/release records and types the transcript into the original window'

rm -- "$scratch/recorded" "$scratch/typed"
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
