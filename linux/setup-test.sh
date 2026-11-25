#!/usr/bin/env bash
set -euo pipefail

src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
export WHISP_SETUP_TEST="$scratch"
export WAYLAND_DISPLAY=wayland-test HYPRLAND_INSTANCE_SIGNATURE=test
export XDG_RUNTIME_DIR="$scratch/run"
mkdir -p "$scratch/bin" "$scratch/archive/app"
install -d -m700 "$XDG_RUNTIME_DIR"
for name in install.sh whisp-setup-hyprland whisp.service; do
    ln -s "$src/$name" "$scratch/archive/$name"
done
ln -s /usr/bin/true "$scratch/archive/app/whisp"
cat > "$scratch/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WHISP_SETUP_TEST/systemctl"
case "$2" in
    is-active|is-enabled) exit 1 ;;
    restart) [[ ! -e "$WHISP_SETUP_TEST/fail-restart" ]] ;;
esac
EOF
cat > "$scratch/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == reload ]]
EOF
chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH"

for extension in conf lua; do
    export HOME="$scratch/$extension" XDG_CONFIG_HOME="$scratch/$extension/.config"
    dir="$XDG_CONFIG_HOME/hypr"
    mkdir -p "$dir"
    config="$dir/hyprland.$extension"
    bindings="$dir/whisp.$extension"
    touch "$config"
    "$scratch/archive/install.sh"
    setup="$HOME/.local/bin/whisp-setup-hyprland"
    "$setup"
    if [[ "$extension" == lua ]]; then
        [[ "$(grep -Fxc "dofile(\"$bindings\")" "$config")" == 1 ]]
        grep -F 'hl.bind("Control_R"' "$bindings" | grep -F 'ignore_mods = true, non_consuming = true'
        grep -Fq 'release = true' "$bindings"
        if [[ "${WHISP_VERIFY_HYPRLAND:-}" == "$extension" ]]; then
            Hyprland --verify-config --config "$config"
        fi
    else
        [[ "$(grep -Fxc "source = $bindings" "$config")" == 1 ]]
        grep -Fq 'bindin = , Control_R, exec,' "$bindings"
        grep -Fq 'bindrin = , Control_R, exec,' "$bindings"
        if [[ "${WHISP_VERIFY_HYPRLAND:-}" == "$extension" ]]; then
            Hyprland --verify-config --config "$config"
        fi
    fi
    "$setup" --key F9
    [[ "$(grep -Fc F9 "$bindings")" == 2 ]]
    if grep -Fq Control_R "$bindings"; then exit 1; fi
    grep -Fxq -- 'WantedBy=graphical-session.target' "$XDG_CONFIG_HOME/systemd/user/whisp.service"
    echo "PASS: $extension installer defaults to Right Ctrl, is idempotent, and replaces the key"
done

grep -Fxq -- '--user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE' "$scratch/systemctl"
grep -Fxq -- '--user enable whisp.service' "$scratch/systemctl"
grep -Fxq -- '--user restart whisp.service' "$scratch/systemctl"

export HOME="$scratch/fail" XDG_CONFIG_HOME="$scratch/fail/.config"
dir="$XDG_CONFIG_HOME/hypr"
mkdir -p "$dir"
if "$scratch/archive/install.sh"; then exit 1; fi
[[ ! -e "$HOME/.local" ]]
printf '%s\n' '-- User config' > "$dir/hyprland.lua"
touch "$scratch/fail-restart"
if "$scratch/archive/install.sh"; then exit 1; fi
[[ ! -e "$dir/whisp.lua" && ! -e "$HOME/.local/bin/whisp" ]]
[[ ! -e "$XDG_CONFIG_HOME/systemd/user/whisp.service" ]]
[[ "$(cat "$dir/hyprland.lua")" == '-- User config' ]]
echo 'PASS: failed setup leaves no partial bindings or installation'
