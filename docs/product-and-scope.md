# Product And Scope

This is the long-lived product context for Ithaca. Keep implementation details in
the focused topic docs and keep this file to intent, constraints, and non-goals.

## Product Shape

Ithaca is a native Swift/SwiftUI Plex client for Apple platforms. It is built for
people who run their own Plex servers and want a focused client for browsing and
playing their libraries without promoted content or extra service layers.

This is a personal/small-audience project. Favor straightforward, maintainable
code over enterprise abstractions, broad plugin systems, or premature provider
boundaries.

## Core Principles

- Plex is the source of truth for metadata, watch state, library contents, and
  server identity.
- Persistence is limited to auth tokens, user preferences, explicit
  downloads/offline state, and caches that are documented in the relevant topic
  doc. Cross-device settings that Plex itself models (library order) are stored
  in the Plex account, not in a Ithaca-private sync store.
- Playback starts direct when using Plex-hosted media. Manual transcoding is a
  per-session player Quality action only; no stored quality setting may start
  video transcoding automatically. An explicitly selected AirPlay route may use
  Plex HLS to satisfy the receiver's format constraints; this is an output-route
  requirement, not a persisted playback-quality default.
- SwiftUI UI should be shared where practical and platform-aware where needed.
- Plex-specific service code is acceptable. Do not introduce generic provider
  abstractions until a second backend is actually being implemented.
- Dependencies should stay minimal. VLCKit is vendored manually; system
  frameworks and URLSession are preferred elsewhere.

## Platform Targets

`project.yml` is authoritative for build targets and deployment versions:

- `Ithaca`: iOS/iPadOS app target, currently iOS 18.0 minimum.
- `Ithaca-tvOS`: tvOS app target, currently tvOS 26.0 minimum.

macOS support should be checked against current project and App Store settings
before making implementation claims. There is no separate native macOS target in
`project.yml` today.

## Feature Scope

Current product pillars:

- Plex sign-in, server discovery, and server switching.
- Home hubs, library browsing, genre filtering, search, and detail screens.
- Plex Live TV discovery, program guide browsing, and time-shifted playback.
- Hybrid playback through AVPlayer and VLCKit.
- Subtitle and audio track selection.
- Manual player Quality selection for Plex transcoding.
- Timeline reporting, scrobble/unscrobble, resume, skip intro/credits,
  continuous playback, and passout protection.
- Offline downloads and delayed watch-state sync.
- Ratings stored as the viewer's Plex rating, and "Because You Liked" recommendations
  built from them with TMDB's lists through Seerr.
- Pick Something's Describe It (Ithaca Pro: a 7-day free trial, then a
  one-time purchase): picks from the viewer's library for what they type, and
  with Seerr suggests titles to request. It runs on the device (Apple's
  on-device model where there is one, a fixed phrase list elsewhere) or, when
  the viewer agrees, through Athena, an optional server on the home network that
  asks Claude and holds the API key (its own repo, `inceptyon-labs/athena`). The apps never
  call a cloud model directly.
- Native AirPlay from iPhone/iPad to AirPlay-enabled receivers, with Ithaca
  retaining playback control, Plex timeline reporting, and continuous playback.
- SharePlay watch-together sessions on iPhone, iPad, and Apple TV for Plex
  library video, with per-participant local streaming and synchronized transport.

Future ideas such as Jellyfin, collections, playlists, DVR scheduling,
native macOS work, or broader provider abstractions are not current architecture
requirements. Do not shape today's code around them without an explicit task.

## Dependency And Licensing Decisions

- VLCKit is checked in as dynamic xcframeworks under `Frameworks/` and linked
  dynamically for LGPL compliance.
- XcodeGen owns the generated Xcode project; edit `project.yml`, then regenerate
  when project structure changes.
- Image loading uses the app's Plex-aware image pipeline and URL caching rather
  than a third-party image dependency.
- Networking uses async/await and URLSession. Avoid Combine unless wrapping
  callback-driven APIs such as player engines.

## Privacy And Network Boundaries

Ithaca must never track users. No advertising identifiers, no third-party
analytics or crash-reporting SDKs, no profiles, and nothing shared with anyone.
The app sends no analytics at all.

Network traffic should be limited to Plex account/server
APIs, selected Plex servers, artwork and media URLs derived from Plex,
explicitly initiated Apple Group Activities sessions (which share only the
selected item's server-scoped identity and display metadata with participants),
and explicitly requested external links such as project/license pages.

`Ithaca/Resources/PrivacyInfo.xcprivacy` is the App Store privacy manifest for
both apps: no tracking, no collected data, and the reasons for the
required-reason APIs the app and the embedded VLCKit framework use. Update it
when a new one is used (UserDefaults, free disk space, file timestamps, system
uptime, active keyboards). The public policy is
`https://inceptyon.io/ithaca/privacy.html`, kept in the `inceptyon-website`
repo; change it whenever the app starts talking to a new kind of server.

Do not log raw token-bearing URLs. Playback and image URLs often include
`X-Plex-Token` because AVPlayer and VLCKit load media directly.
