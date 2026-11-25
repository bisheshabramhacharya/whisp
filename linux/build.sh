#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/dist/linux"
name=Whisp-linux-x64
mkdir -p "$out"
stage="$(mktemp -d "$out/.stage.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT

dotnet publish "$root/linux/Whisp" -c Release -r linux-x64 --self-contained true -o "$stage/$name/app"
install -m755 "$root/linux/install.sh" "$root/linux/whisp-setup-hyprland" "$stage/$name/"
install -m644 "$root/linux/README.md" "$root/linux/whisp.service" "$root/LICENSE" "$stage/$name/"
tar -C "$stage" -czf "$stage/$name.tar.gz" "$name"
mv -- "$stage/$name.tar.gz" "$out/"
(cd -- "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")

if [[ "${1:-}" == --arch ]]; then
    cp -- "$out/$name.tar.gz" "$stage/"
    read -r checksum _ < "$out/$name.tar.gz.sha256"
    sed "s/@TARBALL_SHA256@/$checksum/" "$root/linux/PKGBUILD" > "$stage/PKGBUILD"
    if command -v makepkg >/dev/null; then
        (cd -- "$stage" && makepkg --nodeps)
    else
        docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
            --volume "$stage:/build" --workdir /build archlinux:base-devel makepkg --nodeps
    fi
    mv -- "$stage/"*.pkg.tar.zst "$out/"
    (cd -- "$out" && sha256sum whisp-*.pkg.tar.zst > Whisp-arch.sha256)
fi
