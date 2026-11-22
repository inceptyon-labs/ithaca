# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

People who run their own Plex Media Server and want to watch it on Apple devices: on the Apple TV in the living room first, then iPhone and iPad at home and away. Built first for Jason's household on Uranus; the App Store audience is other Plex owners, many with remux libraries (Dolby Vision, Atmos, TrueHD, PGS subtitles) that Plex's own app transcodes.

## Product Purpose

A native Plex client for Apple TV, iPhone and iPad: browse the library, pick something, and play it the way the file was made. Success is pressing play and getting the original picture and sound, with no transcoding by default, in an app that feels like Apple made it.

## Positioning

Four claims, all confirmed for the store listing:

- **Plays everything direct.** AVPlayer for standard files, VLCKit for the rest (MKV, DTS, PGS); Dolby Vision 7 converted to 8.1 on the device; Atmos and HDR remuxed losslessly through Plex; Plex transcoding only as a fallback or by choice.
- **Native Apple feel.** SwiftUI, Liquid Glass and system controls; Top Shelf on Apple TV, SharePlay, AirPlay, Siri.
- **Just your library.** No promoted content, ads, tracking or analytics. Plex holds the watch state; nothing goes anywhere else.
- **Smart picks.** Because You Liked from the viewer's ratings, Pick Something, Describe It (picks from the library on the device, or through Athena, an optional self-hosted server, when the viewer agrees), Seerr requests.

Plex's own app pushes its streaming service and transcodes these files; Infuse plays them but is a general file player. Ithaca is Plex-only and Plex-native (watch state, Live TV, ratings, Seerr).

## Operating Context

- Plex Media Server on the user's network or reached remotely through plex.tv; the app signs in with a Plex account.
- Optional companions: Seerr for requests, Athena (`inceptyon-labs/athena`) for Describe It. Both are self-hosted; without Seerr, requests stay hidden, and without Athena, Describe It runs on the device.
- Living-room Apple TV with a Siri Remote is the main screen; iPhone and iPad add downloads for offline viewing.

## Capabilities and Constraints

- Feature scope, privacy boundaries and dependency rules: `docs/product-and-scope.md`.
- Store name: "Ithaca for Plex". No Plex logo, nothing that reads as Plex's official app.
- Ithaca is derived from Dusk for Plex (MIT, on the App Store). The listing and screenshots must look clearly its own.
- Undecided: price (researching other players; a Pro tier for the AI features is being considered), whether App Review gets a demo Plex account or a built-in demo mode.

## Brand Commitments

- `STYLE.md` is binding for the app: "native vibes, not orange". System controls and Liquid Glass as they ship, neutral palette, no tint for UI state.
- Brand accent `#FF6B4A` belongs to the logo and icon only.

## Evidence on Hand

- The app itself, captured in the simulators in DEBUG screenshot mode (`Ithaca/Sources/App/ScreenshotMode.swift`).
- Demo library for screenshots and review: public-domain films and Blender Studio's open movies (CC BY) with their real art. Never titles from Jason's own library.
- No customers, reviews, ratings or usage numbers exist; don't invent any.

## Product Principles

1. The picture and sound as the file has them: direct play first, transcoding never automatic.
2. Content leads, the interface recedes.
3. Native before novel: Apple's controls, focus and gestures unless departing earns thanks.
4. Private by construction: Plex and the user's own servers, nothing else.
5. One app for the house: Apple TV first, iPhone and iPad equal partners.
