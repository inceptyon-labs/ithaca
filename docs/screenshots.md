# App Store Screenshots

The App Store slides are built in `docs/app-store/`: `capture.sh` takes the app's screens in the simulators, and `compose.py` turns each into a one-sheet slide (design rules in `DESIGN.md`). The release checklist is `docs/app-store-release.md`.

## Content

Captures show only the "Films" and "Series" demo libraries (sections 28 and 27): Blender Studio open movies (Creative Commons) and US public-domain films, with each file's source and license in a `SOURCES.txt` beside the media. They are shared with the App Review Plex account (sign-in in 1Password), which sees nothing else, so the same account is what App Review signs in with. Never capture with another account: its posters are other studios' artwork.

The demo account is also a Seerr user with request permission only (no auto-approve), so a request made in a capture or by App Review waits for approval instead of starting a download.

## App side: DEBUG screenshot mode

`Ithaca/Sources/App/ScreenshotMode.swift` is compiled out of Release builds and driven by launch arguments:

| Argument | Effect |
| --- | --- |
| `-IthacaScreenshotMode YES` | Turns the mode on; the Keychain sign-in is never read or written |
| `-IthacaScreenshotToken <token>` | Signs in as that Plex account (the demo account). Without it, a fake token for a mock plex.tv |
| `-IthacaScreenshotPlexTV <url>` | Replaces `https://plex.tv` (a mock server; none is in this repo) |
| `-IthacaScreenshotScreen <name>` | `home`, `movies`, `shows`, `library`, `detail`, `search`, `player`, `downloads`, `settings`, `serverPriority`, `pro`, `pickSomething`, `seerrMedia` |
| `-IthacaScreenshotDescribe <text>` | `pickSomething`: fills Describe It with that text and sends it once |
| `-IthacaScreenshotSeerrMedia movie:<tmdb id>` | `seerrMedia`: opens that Seerr title (`tv:<id>` for a show) |
| `-IthacaScreenshotItem <ratingKey>` / `-IthacaScreenshotItemType <type>` | Item for `detail` and `player`; the type also picks the `library` tab |
| `-IthacaScreenshotPlayOffset <seconds>` | Exact player start position |
| `-IthacaScreenshotKeepHUD YES` | Player controls never auto-hide |
| `-IthacaScreenshotSearch <query>` | Pre-filled search |
| `-IthacaScreenshotDownloads movie:<rk>,episode:<rk>` | Queues real downloads |
| `-IthacaScreenshotSeedDownloads movie:<rk>,season:<rk>` | Records finished downloads |
| `-IthacaScreenshotSeerr <url>` | Acts as signed in to that Seerr |
| `-IthacaScreenshotSeerrSession <connect.sid>` | The demo account's real Seerr session for that Seerr |
| `-IthacaScreenshotPlayerSheet audio\|subtitles` | iOS player: opens that picker |
| `-IthacaScreenshotUpNext <seconds>` | Episode player: raises Up Next, countdown frozen |
| `-IthacaScreenshotHeroIndex <n>` | iOS/iPadOS Home hero opens on item `n` |
| `-IthacaPaywall YES` | Turns the Ithaca Pro check on (Debug has Pro on); with `pro`, the page as a new user sees it |
| `-athenaConsent 2` | Describe It on the device even where an Athena is found (1 uses Athena) |

When changing routing, sign-in, the player HUD or Home loading, keep these hooks compiling; a broken hook only shows up when screenshots are regenerated.

## Traps

- iPhone Duo captures need the simulator unfolded, and only Device Hub's Controls menu can do that (`simctl` can't; Device Hub doesn't expose its menus to AppleScript either). Capture the inner screen with `DISPLAY_ID=primary-1`; it comes out 2853 × 2007 in landscape. The Home hero follows the demo account's Continue Watching, so playing anything with it reorders the hero; Sintel was index 1 for the 2026-11-21 Duo set. Folding and unfolding during playback is the other thing to check on the Duo (both engines kept playing on 2026-11-21).

- With Seerr's image caching off, Seerr artwork comes from TMDB's image server instead of the demo Seerr; either way the art is the same. Failed images stay in the app's image cache until it is reinstalled.
- Describe It on iPhone and iPad shows a To Request row from Seerr below the picks, with real studio posters; capture it without `ITHACA_DEMO_SEERR`.
- Downloads exists as a tab only once something is downloaded: seed downloads in one launch, capture the tab in the next.
- The tvOS Home hero follows Continue Watching order (no hero index on tvOS); send fresh progress for the title that should lead.
- A library rename shows in the app only after a reinstall (the app caches library names).
