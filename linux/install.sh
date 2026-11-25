#!/usr/bin/env bash
set -euo pipefail

src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
config="${XDG_CONFIG_HOME:-$HOME/.config}"

if [[ ! -x "$src/app/whisp" ]]; then
    echo 'Run this installer from the extracted Whisp-linux-x64 archive.' >&2
    exit 1
fi

if systemctl --user is-active --quiet whisp.service; then
    systemctl --user stop whisp.service
fi
install -d "$HOME/.local/lib/whisp" "$HOME/.local/bin"
cp -a --remove-destination "$src/app/." "$HOME/.local/lib/whisp/"
ln -sfn -- ../lib/whisp/whisp "$HOME/.local/bin/whisp"
install -m755 "$src/whisp-setup-hyprland" "$HOME/.local/bin/whisp-setup-hyprland"
install -Dm644 "$src/whisp.service" "$config/systemd/user/whisp.service"
systemctl --user daemon-reload
"$HOME/.local/bin/whisp-setup-hyprland"
