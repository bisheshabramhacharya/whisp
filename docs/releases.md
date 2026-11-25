# Desktop releases

The **Installers** workflow stages a macOS arm64 disk image and a Windows x64
setup executable on pull requests. Pull-request builds do not get signing
credentials or publish anything. The workflow mounts the disk image, checks
and runs the copied app, runs Windows Setup in silent mode, and checks the
installed binary and update package.

To release, set the version in `Resources/Info.plist` (both version keys) and
`windows/Directory.Build.props`. Merge the PR after CI and Installers pass.
Push a matching `vMAJOR.MINOR.PATCH` tag from main. The workflow checks the tag
is reachable from main before packaging; publishing requires both platform jobs to pass. The workflow
creates a draft with all assets, then publishes it as the latest release.
Restrict creation of release tags to trusted maintainers in repository rules:
a workflow from an arbitrary tagged commit can change its own checks.

## Repository setup

| GitHub Actions secrets | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate and private key export |
| `MACOS_CERTIFICATE_PASSWORD` | Password for that certificate export |
| `APPLE_NOTARY_API_KEY` | Contents of the App Store Connect API key’s `.p8` file |
| `SPARKLE_PRIVATE_KEY` | Export from Sparkle’s `generate_keys -x` |

| GitHub Actions variables | Value |
|---|---|
| `MACOS_DEVELOPER_ID` | Developer ID Application identity name or fingerprint |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer ID |
| `SPARKLE_PUBLIC_KEY` | Public EdDSA key printed by Sparkle’s `generate_keys` |

Keep the Sparkle private key backed up and reuse the same key for later
releases. Sparkle reads the signed `appcast.xml` from the latest GitHub
release and authenticates the notarized DMG. Velopack reads
`releases.win.json` and its matching `.nupkg` from GitHub; the installer and
package are not Authenticode-signed.
