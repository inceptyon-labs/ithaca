<p align="center"><img src=".github/logo.png" width="128" alt="Ithaca icon"></p>

# Ithaca

[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE) [![gitleaks](https://github.com/inceptyon-labs/ithaca/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/inceptyon-labs/ithaca/actions/workflows/gitleaks.yml)

A Plex app for Apple TV, iPhone and iPad, written in Swift and SwiftUI. It plays the original file from your Plex server, with Dolby Vision, Dolby Atmos and every subtitle track, and stays out of the way: no ads, no promoted shows, no tracking.

Ithaca is coming to the App Store as **Ithaca for Plex**. Support and the privacy policy are at [inceptyon.io/ithaca](https://inceptyon.io/ithaca/support).

## What it does

- **Plays the file as it is.** MKV, HEVC, HDR10, HDR10+, Dolby Vision (profile 7 converted to 8.1 on the device), Dolby Atmos, TrueHD, DTS, and PGS, SRT and ASS subtitles, straight from the server. When a file can't play directly, Plex takes over on its own, and you can always choose a quality for one session.
- **Feels like an Apple app.** System controls and Liquid Glass. On Apple TV: Top Shelf and the Siri Remote. On iPhone and iPad: downloads for offline viewing, AirPlay and Picture in Picture. Siri plays a title or the next episode, and SharePlay watches together.
- **Your servers, merged.** Several Plex servers show as one library, with Plex Home profiles, ratings and watch state kept in your Plex account. Plex Live TV with its guide.
- **Requests.** Connect [Seerr](https://docs.seerr.dev) (or Overseerr or Jellyseerr) to search for what you don't have, request it, browse what's trending, and get a notice on iPhone and iPad when it arrives.
- **Help choosing.** Rate what you watch for rows of similar titles. Pick Something chooses from your library by length, genre and who's watching.

### Ithaca Pro

Pro unlocks **Describe It**: type what you're in the mood for ("a heist movie under two hours") and Ithaca picks from your library, with titles to request when Seerr is connected. It runs on the device: Apple's on-device model reads the request where Apple Intelligence is on, and Ithaca's own matching does everywhere else. With [Athena](https://github.com/inceptyon-labs/athena), an optional server you run beside Plex, Claude answers instead.

Pro is a one-time purchase after a free 7-day trial, with no subscription, and covers iPhone, iPad and Apple TV. Everything else is free. Buying it is how the App Store version, and the work on this repository, is paid for.

## Requirements

A Plex Media Server, your own or one shared with you. iOS and iPadOS 18 or later, tvOS 26 or later.

## Build it yourself

You need Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [rustup](https://rustup.rs).

```bash
./ci_scripts/install_vlckit.sh        # VLCKit frameworks into Frameworks/
./ci_scripts/install_ithaca_dovi.sh   # the Dolby Vision 7 to 8.1 Rust library
xcodegen generate
open Ithaca.xcodeproj
```

The default VLCKit is VideoLAN's stock 3.7.3, which can't decode TrueHD, so Plex converts TrueHD audio. The App Store version uses Ithaca's own VLCKit build with the TrueHD decoder turned on; its patches and build script are in [inceptyon-labs/ithaca-vlckit](https://github.com/inceptyon-labs/ithaca-vlckit) and in `ci_scripts/`. Read "Dolby TrueHD decoding" in [`docs/playback.md`](docs/playback.md) before shipping it.

```bash
./ci_scripts/build_vlckit.sh          # about an hour per platform
ITHACA_VLCKIT_CACHE_DIR=.build/vlckit/out ./ci_scripts/install_vlckit.sh
```

[`docs/README.md`](docs/README.md) explains the architecture, the playback rules and where things live.

## Privacy

Ithaca sends nothing to Inceptyon Labs: no analytics, no crash reporting, no accounts. It talks to Plex and to the servers you connect it to. Details are in the [privacy policy](https://inceptyon.io/ithaca/privacy).

## Contributing

Fixes are welcome, especially for files that don't play right. Read [CONTRIBUTING.md](CONTRIBUTING.md). Every pull request needs the [contributor agreement](CLA.md) line, which lets Inceptyon Labs ship your change in the App Store version as well. Report security problems privately, as [SECURITY.md](SECURITY.md) describes, and see the [code of conduct](CODE_OF_CONDUCT.md).

## License

Ithaca's code is under the [GNU Affero General Public License v3.0](LICENSE). The name "Ithaca", the icon, the logo and the App Store artwork are not covered by it; see [TRADEMARKS.md](TRADEMARKS.md). A fork you distribute needs its own name and icon.

Ithaca began as a fork of [Dusk for Plex](https://github.com/marvinvr/dusk-player) by Marvin von Rappard (MIT). Dusk's license and every other third-party notice, including VLCKit (LGPL-2.1) and the Dolby Vision conversion crates, are in [`Ithaca/Resources/ThirdPartyNotices.txt`](Ithaca/Resources/ThirdPartyNotices.txt).

Plex is a trademark of Plex, Inc. Ithaca is an independent app and is not made or endorsed by Plex.
