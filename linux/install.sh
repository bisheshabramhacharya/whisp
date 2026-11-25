#!/usr/bin/env bash
set -euo pipefail

src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
config="${XDG_CONFIG_HOME:-$HOME/.config}"

if [[ ! -x "$src/app/whisp" ]]; then
    echo 'Run this installer from the extracted Whisp-linux-x64 archive.' >&2
    exit 1
fi

"$src/whisp-setup-hyprland" --check "$@"
install -d "$HOME/.local/lib" "$HOME/.local/bin"
files=("$HOME/.local/lib/whisp" "$HOME/.local/bin/whisp" "$HOME/.local/bin/whisp-setup-hyprland" "$config/systemd/user/whisp.service")
backup="$(mktemp -d)"
active=false
systemctl --user is-active --quiet whisp.service && active=true
rollback() {
    local result=$?
    if (( result )); then
        for i in "${!files[@]}"; do
            rm -rf -- "${files[i]}"
            if [[ -e "$backup/$i" || -L "$backup/$i" ]]; then
                cp -a -- "$backup/$i" "${files[i]}"
            fi
        done
        systemctl --user daemon-reload || true
        if "$active"; then systemctl --user restart whisp.service || true; fi
    fi
    rm -rf -- "$backup"
    exit "$result"
}
for i in "${!files[@]}"; do
    if [[ -e "${files[i]}" || -L "${files[i]}" ]]; then cp -a -- "${files[i]}" "$backup/$i"; fi
done
trap rollback EXIT
if "$active"; then systemctl --user stop whisp.service; fi
install -d "$HOME/.local/lib/whisp"
cp -a --remove-destination "$src/app/." "$HOME/.local/lib/whisp/"
ln -sfn -- ../lib/whisp/whisp "$HOME/.local/bin/whisp"
install -m755 "$src/whisp-setup-hyprland" "$HOME/.local/bin/whisp-setup-hyprland"
install -Dm644 "$src/whisp.service" "$config/systemd/user/whisp.service"
systemctl --user daemon-reload
"$HOME/.local/bin/whisp-setup-hyprland" "$@"
