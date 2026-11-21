# Contributing to Ithaca

Thanks for helping. Bug fixes, especially for media that doesn't play right, are the most useful contributions.

## Before you start

- For anything bigger than a fix, open an issue first and describe the change, so we can agree on it before you write it.
- Every pull request needs the Contributor License Agreement line in its description (see [CLA.md](CLA.md)). Ithaca is AGPL-3.0, and the agreement is what lets Inceptyon Labs also ship your change in the App Store version. You keep the copyright.
- Forks that ship need their own name and icon ([TRADEMARKS.md](TRADEMARKS.md)).

## Building

See [README.md](README.md#build-it-yourself). After cloning, turn on the versioned git hooks once; the pre-commit hook runs [gitleaks](https://github.com/gitleaks/gitleaks) (`brew install gitleaks`) on every commit:

```bash
git config core.hooksPath .githooks
```

After changing code, run a compile check for the platform you touched:

```bash
xcodebuild -project Ithaca.xcodeproj -scheme Ithaca -configuration Debug \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
xcodebuild -project Ithaca.xcodeproj -scheme Ithaca-tvOS -configuration Debug \
  -destination 'generic/platform=tvOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

Run `xcodegen generate` whenever you add, remove or rename a file under `Ithaca/Sources`.

## How the code is written

- Read [docs/README.md](docs/README.md) first. It and the docs it links describe the architecture, the playback rules, and the docs to update with each change.
- [STYLE.md](STYLE.md) is binding for UI: system controls, a neutral palette, and no accent colour for UI state.
- SwiftUI views backed by `@Observable` view models; view models call `PlexService`; views never touch the network.
- New third-party code needs its license added to `Ithaca/Resources/ThirdPartyNotices.txt`, and must be compatible with the AGPL and with App Store distribution.
- Keep a pull request to one change, and update the matching doc in `docs/` in the same pull request.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org) (`fix:`, `feat:`, `docs:`), written as a plain sentence about what changed for the viewer.

## Reporting a security problem

Use the private form described in [SECURITY.md](SECURITY.md), not an issue.

## Code of conduct

The project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
