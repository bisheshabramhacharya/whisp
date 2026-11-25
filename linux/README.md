# Whisp for Linux (Omarchy / Hyprland)

Hold **Right Ctrl**, talk, and release. Whisp transcribes on your CPU using the same
Parakeet Unified int8 model and text cleanup as Whisp for Windows. The first run
downloads and verifies about 660 MB of model files; recognition works offline
afterwards. Whisp only records during a hold and does not save audio or history.

## Install

Download the x86-64 Linux package and its checksum from the build or release.
Run the setup commands from a terminal **inside Hyprland**, as your normal user.

**Omarchy / Arch (recommended):**

```sh
sha256sum -c Whisp-arch.sha256
sudo pacman -U ./whisp-*.pkg.tar.zst
whisp-setup-hyprland
```

**Other x86-64 distributions running Hyprland:** Install PipeWire (`pw-record`),
`wtype`, `wl-clipboard`, and the system libraries for .NET 8 (glibc, libgcc,
libstdc++, OpenSSL, and zlib). The archive includes the .NET runtime.

```sh
sha256sum -c Whisp-linux-x64.tar.gz.sha256
tar -xzf Whisp-linux-x64.tar.gz
./Whisp-linux-x64/install.sh
```

Setup creates `~/.config/hypr/whisp.lua` for Lua Hyprland configs (including
Omarchy 4.5+) or `whisp.conf` for legacy configs. It adds one include to your
user config and enables the systemd user service. It does not edit
Omarchy defaults. To watch model setup, run `journalctl --user -fu whisp`;
wait for `Ready` before dictating. If the model fails to download,
`systemctl --user restart whisp` retries it.

The service starts with the systemd graphical session. On a standalone Hyprland
session that does not start `graphical-session.target`, run
`whisp-setup-hyprland --start` after logging in or add it to your session's
startup commands.

Right Ctrl is not consumed, so ordinary Ctrl shortcuts still reach Hyprland
and your apps; Left Ctrl does not trigger Whisp. To change the dictation key,
run `whisp-setup-hyprland --key F9` (or pass `--key F9` to the archive installer).
Setup replaces the bindings in its own generated file, not your other shortcuts.
Uninstall or quit another dictation app using the same key before starting Whisp.

The generated Lua bindings look like this:

```lua
hl.bind("Control_R", hl.dsp.exec_cmd("whisp press"), { ignore_mods = true, non_consuming = true })
hl.bind("Control_R", hl.dsp.exec_cmd("whisp release"), { ignore_mods = true, non_consuming = true, release = true, transparent = true })
```

For legacy Hyprland configs:

```ini
bindin = , Control_R, exec, whisp press
bindrint = , Control_R, exec, whisp release
```

Use a key that isn't already bound in Hyprland. `r` dispatches on release,
`i` ignores held modifiers, and `t` keeps release from being shadowed by another
shortcut. To configure a different Hyprland config manually,
add the corresponding bindings (use absolute paths if necessary).
`whisp cancel` can be bound separately to discard a take.

The transcript is typed with `wtype` only if the same window is still focused.
If focus changes or typing fails, Whisp copies it to the Wayland clipboard for
manual paste. This build targets Hyprland, not X11 or other Wayland compositors.
It has no tray icon or history UI. Dictionary overrides use Whisp's existing
`dictionary.json` format in `${XDG_DATA_HOME:-~/.local/share}/whisp`.

## Development

```sh
bash linux/build.sh --arch     # also create the Arch package (makepkg or Docker)
dotnet run --project windows/WhispTests -c Release
bash linux/setup-test.sh
bash linux/smoke-test.sh /path/to/extracted/Whisp-linux-x64/app/whisp
```

Build outputs are in `dist/linux/`. Omit `--arch` for just the tarball.
`whisp --transcribe clip.wav` prints a transcript of a 16 kHz mono 16-bit PCM
WAV without a Wayland session or microphone. `WHISP_HOME` and `WHISP_MODELS`
override the data and model directories.
