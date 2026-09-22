# Whisp

Whisp is a free, fully local clone of [Willow Voice](https://willowvoice.com)
for macOS. Hold **Right Option**, talk, release — the text is transcribed
on-device with NVIDIA Parakeet (via
[FluidAudio](https://github.com/FluidInference/FluidAudio)) and pasted into
whatever app you're in. No audio ever leaves your Mac, no account, no
subscription.

- Menu-bar app — no Dock icon, no windows required
- Hold Right Option to dictate; **double-tap** Right Option to lock
  hands-free recording, press again to stop; **Esc** cancels
- Filler words ("um", "uh", …) and repeated-word stutters are removed.
  Whisp only ever *subtracts* — it never rewrites your words
- Personal dictionary for names, jargon and phrase replacements

> **Note:** quit Willow while using Whisp — both listen for Right Option and
> will fight over the hotkey.

## Requirements

- Apple Silicon Mac, macOS 14.0+
- Swift 6.x toolchain (Xcode Command Line Tools are enough)
- ~1 GB disk for the on-device Parakeet model (downloaded from HuggingFace on
  first launch; everything else is offline)

## Build & install

```sh
scripts/build-app.sh            # release build -> dist/Whisp.app (signed)
scripts/build-app.sh --install  # also installs to /Applications and launches
```

Useful env overrides: `SCRATCH` (SwiftPM build dir, default `.build`),
`PRODUCT`, `APP_NAME`, `DIST`, `IDENTITY` (`IDENTITY=-` forces ad-hoc signing).

## Permissions

Whisp asks for three macOS permissions (System Settings → Privacy & Security):

| Permission        | Why                                                             |
|-------------------|-----------------------------------------------------------------|
| **Microphone**        | capture your voice for transcription                        |
| **Accessibility**     | paste the transcript into the frontmost app (simulated ⌘V + AX reads) |
| **Input Monitoring**  | the listen-only event tap that watches Right Option           |

macOS binds these grants to the app's **code signature**. See the next
section — it matters every time you rebuild.

### Stable signing identity

`scripts/build-app.sh` signs with a self-signed identity named
**"Whisp Local Signing"** if it exists, and otherwise tries to create it
non-interactively. With a stable signature, your Microphone / Accessibility /
Input Monitoring grants survive rebuilds. With ad-hoc signing (the fallback),
TCC re-prompts after *every* rebuild.

If the script fell back to ad-hoc (locked keychain, CI shell, …), create the
identity once by hand:

```sh
cd "$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=Whisp Local Signing/O=Whisp Local Development/C=US" \
  -keyout key.pem -out cert.pem \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -password pass:whisp-tmp \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -inkey key.pem -in cert.pem -out id.p12
security import id.p12 -k ~/Library/Keychains/login.keychain-db \
  -P whisp-tmp -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db cert.pem
security find-identity -p codesigning -v   # should list "Whisp Local Signing"
```

(The legacy `PBE-SHA1-3DES`/`sha1` flags are required — macOS `security import`
cannot read OpenSSL 3's default AES-encrypted PKCS12. `add-trusted-cert` in the
user domain is silent and is what makes `find-identity` list the identity.)

## Usage

1. Launch Whisp — it lives in the menu bar (a waveform icon).
2. Click into any text field, **hold Right Option** and speak.
3. Release — the cleaned-up transcript is pasted at the cursor.
4. **Double-tap** Right Option to keep recording hands-free; press it again to
   stop. **Esc** cancels the current dictation.

### Text cleanup rules

Whisp removes hesitations (*um, uh, erm, hmm*), *like / you know / I mean* when
set off by commas (*"It was, like, huge"*), and word-level stutters
(*"the the"* → *"the"*; intentional doubles like *"that that"* or *"no no"* are
kept). The only other change is writing clock times with a colon
(*"at 5.30"* → *"at 5:30"*). It never paraphrases, reorders or rewrites — what
you said is what gets pasted, minus the noise.

### Personal dictionary

`~/Library/Application Support/Whisp/dictionary.json`:

```json
{
  "terms": [
    "Bishesha",
    "Kubernetes",
    "monorepo"
  ],
  "replacements": [
    { "from": ["bishesha", "be shesha"], "to": "Bishesha" },
    { "from": ["kate's", "cates"], "to": "K8s" }
  ]
}
```

- `terms` — fixes the spelling/casing of whole-word matches
  (*"kubernetes"* → *"Kubernetes"*).
- `replacements` — any whole-word transcript phrase in `from` is replaced by
  `to`. Matching is case-insensitive; `to` is emitted verbatim. Use this for
  words the model consistently mishears.
- Terms are not fed to the recognizer: FluidAudio's acoustic vocabulary
  rescoring measured 2–3× slower on an M1 without fixing more words
  (try it with `whisp-bench --vocab`).
- The file is created with an empty template on first launch; edit and save —
  Whisp picks up changes automatically.

## Data locations

| What                | Path                                                   |
|---------------------|--------------------------------------------------------|
| App data root       | `~/Library/Application Support/Whisp/`                 |
| Transcript history  | `…/Whisp/history.jsonl`                                |
| Saved recordings    | `…/Whisp/recordings/` (newest 200 kept, if enabled)    |
| Dictionary          | `…/Whisp/dictionary.json`                              |
| ASR models          | `~/Library/Application Support/FluidAudio/Models/`     |

Set `WHISP_DATA_DIR` to relocate the Whisp data root (dev/testing).

## Development

```sh
swift build                          # debug build
swift run -c release whisp-bench file.wav   # benchmark: latency, RTF, WER vs file.txt
swift run whisp-tests                # test harness
scripts/make-icon.sh                 # regenerate Resources/AppIcon.icns
```

`whisp-bench` prints model load time, per-file transcript, latency, RTF and
peak RSS; a sibling `<file>.txt` is used as the WER reference.
`whisp-bench --help` lists `--runs`, `--model`, `--itn`, `--vocab`.

### Packaging internals

SwiftPM's generated `resource_bundle_accessor.swift` for FluidAudio resolves
`Bundle.module` as `Bundle.main.bundleURL + "/FluidAudio_FluidAudio.bundle"`.
Inside an `.app`, `Bundle.main.bundleURL` is the **app wrapper root**
(`Whisp.app/`), not `Contents/Resources` — but `codesign` refuses to seal
anything placed at the root ("unsealed contents present in the bundle root").

`build-app.sh` therefore:

1. copies `*.bundle` into `Contents/Resources/` (sealed),
2. signs the app (fully valid signature — verified pre-symlink),
3. then adds `Whisp.app/<name>.bundle` symlinks for `Bundle.module`.

Consequence: `codesign --verify --deep --strict` reports *unsealed* root
contents afterwards. Expected — the executable signature (what TCC binds) is
valid; this is unverifiable-only-at-the-bundle-level and fine for local
self-signed distribution. There are no non-system dynamic dependencies to
embed (`NemoTextProcessing` is a static `.a` inside the xcframework; verified
with `otool -L`).

## Layout

```
Sources/WhispCore   ASR (Parakeet), mic capture, hotkey, paste, storage, text cleanup
Sources/Whisp       menu-bar app shell (AppDelegate, status bar, pill, onboarding)
Sources/whisp-bench benchmark CLI
Sources/whisp-tests test harness
Resources/          Info.plist, AppIcon.icns
scripts/            build-app.sh, make-icon.sh, make-icon.swift
```
