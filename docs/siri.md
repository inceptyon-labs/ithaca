# Siri

"Hey Siri, play Brooklyn Nine-Nine in Ithaca" plays the movie, or the next
episode of the show, from the user's Plex libraries. Everything lives in
`Ithaca/Sources/Siri/`. It uses App Intents only, so there is no Siri
entitlement, no Intents extension and no permission prompt.

## Routes

| Route | What Siri hears | How the title is resolved |
| --- | --- | --- |
| `PlayTitleIntent` (App Shortcut) | "Play/Watch/Resume/Continue *title* in/on Ithaca" | Siri matches *title* against the titles Ithaca registered beforehand (`SiriTitleCatalog`) and hands over a `PlexTitleEntity`. |
| `PlayInIthacaIntent` (`PlayVideoIntent`, a system intent) | Siri's own "play *video* in *app*" | Siri passes the spoken text as `term`; Ithaca searches Plex. |
| `PlayInIthacaIntent` (App Shortcut) | "Play/Watch something in/on Ithaca", "Find something to watch in Ithaca" | Siri asks "What would you like to watch?" and Ithaca searches the free-form answer. |
| `PickSomethingIntent` (App Shortcut) | "Pick a movie/show in/on Ithaca", "Help me pick a movie in Ithaca", "Pick something to watch in Ithaca", "What should I/we watch in Ithaca" | No title. `kind` is an `AppEnum` (`PickSomethingKind`, default movie); the intent opens Pick Something on Home. |

App Shortcut phrases only match parameter values that were registered in
advance (`suggestedEntities()` → `updateAppShortcutParameters()`). A title that
is not in the catalog goes through the free-form routes. Whether Siri sends a
bare "Play X in Ithaca" to `PlayVideoIntent` for an unregistered title is up to
Siri and has not been verified on a device.

All three intents run in the app and open it first (`openAppWhenRun` on iOS 18+,
`supportedModes = .foreground(.immediate)` on tvOS 26+). Only the foreground app
connects its servers (`ServerConnectionCoordinator`), so a background intent
would have nothing to search.

`PickSomethingIntent` only records the request in `PickSomethingLauncher`;
`MainTabView` consumes it once the tab shell exists (switches to Home and pushes
the route), and not while the player is on screen: it waits for the player to
close. A request not shown within 60s (a profile had to be picked first) is
dropped. The screen waits for servers on its own.

## Flow

`SiriPlaybackService` (registered with `AppDependencyManager` in `IthacaApp.init`):

1. Waits up to 15s for the session and the pool. It gives other servers 1.5s
   once the first one answers. Signed out, profile picker, every server off and
   unreachable each get their own spoken reply. It never proceeds before Plex
   Home is verified (`isSessionReady`), not even at the deadline: until then the
   pool can hold the previous profile's restored server tokens.
2. `SiriTitleQuery` strips "the movie/show" and a trailing year, and keeps the
   restored forms (`fullText`, `spokenText`). A candidate that equals one of them
   exactly gets a +0.05 bonus (more than `tieTolerance`), so "Blade Runner 2049"
   and "Movie 43" beat "Blade Runner" and "43", and it is kept even when it is not
   of the stripped kind. Plex search
   runs for the spoken text, the unstripped text, the text with digits spelled out ("brooklyn 99" →
   "brooklyn nine nine"; Plex matches words), and the longest word. It runs on
   every connected server and is merged with `SearchMerge`, which registers
   alternates for playback fallback. Catalog titles are added as candidates too.
3. `SiriTitleMatcher` scores and resolves:
   - Folding: case, accents and punctuation are ignored; number words and
     sequel numerals become digits; a leading "the" and "(US)"-style
     qualifiers are dropped.
   - Scoring: an exact match beats a title the query starts, which beats a
     title containing all of its words, which beats an edit-distance near-miss.
   - Ties (within 0.04) are broken by the year hint, then by in-progress, then
     by any watch history. Whatever is still tied is `.ambiguous`, and on iOS
     and tvOS 26+ Siri asks "Which one did you mean?" via `requestChoice`.
4. A movie resumes from its offset. A show plays `SiriNextEpisodePicker`'s
   episode from `/allLeaves`, using Plex's On Deck rule: the episode in progress,
   else the one after the last watched, else the first unwatched, else start
   over; specials are skipped. Playback starts through
   `PlaybackCoordinator.play` without awaiting it, so the player cover and its
   error UI take over and Siri replies straight away.

## Catalog

`SiriTitleCatalog` holds up to 300 movies/shows: recently watched (each
library's `lastViewedAt:desc`) first, then recently added. It is refreshed from
`MainTabView` 5s after servers connect or the app becomes active, at most every
30 minutes. It is stored in UserDefaults and cleared in
`tearDownServerSessions` (sign-out, Plex Home switch), like the Top Shelf.
Entities carry synonyms ("Brooklyn 99", "The Office" for "The Office (US)").

## Traps

- The App Shortcut "Play" tile is hidden in the Shortcuts app until the catalog
  has titles. That is expected when signed out.
- tvOS builds get the App Shortcut definitions but no flexible-matching NLU
  assets (`Metadata.appintents` has no `nlu/`). Expect exact phrases only on
  Apple TV, if tvOS Siri runs App Shortcuts at all. Device check pending.
- `requestChoice` options are not Sendable: `choose(among:)` must stay off the
  main actor.

## Verification

- Unit tests: `IthacaTests/SiriTitleMatchingTests.swift` (query parsing,
  folding, resolution, next-episode rule) on iOS and tvOS.
- iOS simulator: Shortcuts app → Ithaca → "Play by Name" runs the intent end to
  end (prompt, app opens, spoken reply). There is no way to trigger intents
  programmatically on the tvOS simulator.
- Device only: real Siri speech on iPhone and Apple TV, signed-in playback.
