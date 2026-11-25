# Whisp for Linux (Omarchy / Hyprland)

Hold **F9**, talk, and release. Whisp transcribes on your CPU using the same
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

Setup creates `~/.config/hypr/whisp.conf` (or uses your `XDG_CONFIG_HOME`),
adds a source line, and starts a systemd user service. It does not edit
Omarchy defaults. To watch model setup, run `journalctl --user -fu whisp`;
wait for `Ready` before dictating. If the model fails to download,
`systemctl --user restart whisp` retries it.

The config starts Whisp at future Hyprland logins. Edit these lines in
`whisp.conf` to change the key, keeping the key identical on both lines:

```ini
bindi = , F9, exec, whisp press
bindri = , F9, exec, whisp release
```

Use a key that isn't already bound in Hyprland. `r` dispatches on release and
`i` ignores held modifiers. To configure a different Hyprland
config manually, add those bindings and
`exec-once = whisp-setup-hyprland --start` (use absolute paths if necessary).
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
bash linux/smoke-test.sh /path/to/extracted/Whisp-linux-x64/app/whisp
```

Build outputs are in `dist/linux/`. Omit `--arch` for just the tarball.
`whisp --transcribe clip.wav` prints a transcript of a 16 kHz mono 16-bit PCM
WAV without a Wayland session or microphone. `WHISP_HOME` and `WHISP_MODELS`
override the data and model directories.
