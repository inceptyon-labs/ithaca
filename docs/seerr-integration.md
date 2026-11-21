# Seerr Integration

Seerr is an optional discovery-and-request companion to Plex. It never provides
playback, watch state, downloads, or library ownership; Plex remains the source
of truth for all playable media.

## Ownership

- `SeerrService/` owns URL validation, Plex-token sign-in, cookie sessions,
  endpoint calls, request status mapping, and Seerr image-proxy URLs.
- `Models/SeerrModels.swift` mirrors only the Seerr response fields Ithaca uses.
- `Features/Settings/SeerrSettings*` owns opt-in setup.
- `Features/Search/SearchMediaResult.swift` is the presentation union used to
  place Plex and Seerr cards in the same search groups.
- `Features/Seerr/` owns request-only movie, show, and season screens.
- `Features/Discover/` owns the Discover screen (Seerr's discover lists).
- `Features/Seerr/SeerrRequestTracker` owns Your Requests: Home's row, arrival
  bookkeeping and, on iOS, notifications and background refresh
  (`SeerrRequestNotifications`).
- `ShowDetailViewModel` may add missing Seerr seasons to an online Plex show.

Do not introduce a generic media-provider abstraction. Seerr is not a playback
backend and must stay a focused optional integration.

## Connection Flow

The user enters one Seerr base URL in Settings. An address without a scheme is
probed over HTTPS first and HTTP second; an explicit `https://` or `http://`
address is used exactly as entered. Ithaca resolves the public endpoint before
asking the user to confirm that it may send the active Plex credential to the
resolved host. Ithaca then:

1. fetches `/api/v1/settings/public`;
2. requires an initialized Plex-backed Seerr with media-server login enabled;
3. posts the active Plex Home account token to `/api/v1/auth/plex`;
4. stores the returned session cookies in Keychain;
5. verifies/restores sessions through `/api/v1/auth/me`.

There is no browser, local Seerr password, or API-key mode. This keeps tvOS setup
to URL entry using the system keyboard (including iPhone Remote keyboard input).
HTTP URLs are allowed for local deployments only: a private IP, `localhost`, a
`.local` name or a single-label name (`LocalNetwork.isLocalHost`). Every request
goes through `perform`, which refuses plain HTTP to any other host with
`SeerrServiceError.insecureServerURL` before anything is sent, because sign-in
posts the Plex token (this also covers URLs saved by earlier versions). App
Transport Security blocks public plain HTTP as well; its -1022 error maps to the
same message. Probing never sends a Plex credential, and the confirmation still
warns when the resolved local transport is unencrypted. A local name or address
belongs to whoever answers on the current network, so over plain HTTP the Plex
token is only ever posted by that confirmed manual connect: an expired HTTP
session is dropped rather than re-signed in, and Settings offers Connect again. On tvOS the URL editor is a flat settings row with
appearance-aware text and the shared row focus treatment. Selecting it opens a
system text-entry alert and keyboard. Do not put a live `TextField` back inside
the section card: tvOS forces focused inline text fields into a white editing
capsule that conflicts with the grouped settings layout.

Request confirmations are attached to the request control so iPad presents them
from that button. Once an item is no longer requestable, the action is replaced
by a noninteractive, appearance-aware status capsule rather than a disabled
primary button. On tvOS the capsule is still a focus stop (a movie or season
page may have nothing else to focus, and focus would fall to the tab bar), and
the request button stays enabled while "Requesting…" for the same reason; its
action ignores presses until the request ends. Seerr movie, show, and season detail scroll views support native
pull-to-refresh so request and availability state can be fetched on demand.

Sessions are partitioned by normalized Seerr URL, active Plex profile ID, and a
Plex server ID. A Seerr instance is configured against one Plex server, so the
binding is `plexService.seerrBindingServerID`: the first **enabled** entry of
Server Priority (falling back to the first entry). That value is persisted, so
it is already known at launch before any server has answered and it does not
move when the top server is offline — unlike `pool.primary?.serverID`, which
would flip the binding and make an existing session look unconfigured. Seerr is
deliberately not merged across servers.

Session matching is tolerant on purpose: the bound server wins, but a stored
session recorded against any other server this account knows still counts as
connected, so an upgrade never forces the user to re-link the same Seerr
instance. Sessions whose stored id is a pre-multi-server base URL are re-keyed
once through `plexService.serverID(forLegacyConnectionURI:)` when it resolves.
Changing Plex Home identity never reuses another profile's Seerr session, and
signing out of Plex clears stored Seerr sessions. Disconnect signs out only the
active profile and forgets the URL with the last session for it; connecting
prunes only that profile's sessions for other servers, plus any session for a
different URL.

## Search And Detail Flow

Search starts Plex and Seerr work together but publishes Plex results as soon as
they arrive. A Seerr timeout or error is silent and cannot replace a successful
Plex result set with an error. Supported Seerr movie/show hits are appended to
the native Movies/Shows groups and deduplicated by TMDB GUID, with normalized
title/type/year only as a fallback.

External cards use the standard poster primitive with a small request-state
badge. Their routes open dedicated request-only details: no play, download,
watched, or context-menu actions are present. Status is resolved from Seerr's
media, request, and per-season records and is refreshed after a request and when
returning to the foreground. Seerr lists requests unordered, so a live request
outranks a declined or failed one, then the user's own, then the newest.
Search suppresses media Seerr marks fully available or blocklisted; partial,
pending, processing, and otherwise requestable records remain visible.

TV requests respect Seerr's partial-request setting. A season route requests
only that season when partial requests are enabled; otherwise it requests all
missing seasons. Whole-show detail always offers all missing seasons.

## Discover

Discover shows Seerr's discover lists as poster rows: Trending, Popular Movies,
Upcoming Movies, Popular TV and Upcoming TV (`SeerrDiscoverList`, one page each,
loaded side by side; one list failing still shows the others). It exists only
while Seerr is connected for the current profile: a tvOS tab, and a pushed page
from Home's toolbar on iOS/iPadOS (`AppNavigationRoute.discover`).

- Cards carry the request-state badge except plain "Request", which would sit
  on nearly every card.
- A title Seerr marks available or partially available opens its Plex page,
  where it plays and a show offers its missing seasons. With a Seerr rating key
  that is a direct route on the bound server. Seerr often has none (a title
  marked available through Radarr or Sonarr), so `DiscoverPlexTitleView`
  searches Plex by title and accepts only an item of the same type whose
  `tmdb://` GUID equals the TMDB id. No exact match opens the Seerr page.
- Everything else opens the request-only Seerr page.
- Badges reload when Discover reappears after ten minutes; iOS also has
  pull to refresh.
- "Recommended for You" leads the page when the profile's taste finds
  anything: the `TasteRecommender` candidates the library does not have and
  nobody has requested (no Seerr status, unknown or deleted), up to 20. See
  `docs/ui-features.md` → Home for how they are scored. The lists wait up to
  1.5 s for it so both appear together; a cold pass that takes longer adds the
  row when it is ready.
- `SeerrService.recommendations(type:tmdbID:page:refresh:)` reads
  `/api/v1/{movie|tv}/{id}/recommendations` (TMDB's list, 20 a page, with
  Seerr's `mediaInfo`). Pages are cached in memory for an hour and dropped on
  disconnect, on every context change and on every request sent from the app,
  which also bumps `requestRevision`. Discover reloads when it reappears after
  such a request; pull to refresh skips the cache.

## Your Requests

Home shows the signed-in user's requests, after Pick Something, while Seerr is
connected and there is something to show (`SeerrRequestsHomeRow`):

- **Source.** `GET /api/v1/request?requestedBy=<me>&sort=added&take=50`, also
  filtered by `requestedBy.id` on the device, and decoded per request so one
  unknown value drops only that request. Its media records carry no title or
  artwork, so each listed title's `/movie/{tmdbId}` or `/tv/{tmdbId}` is
  loaded once per launch (memory only); a title that fails keeps its previous
  card. 4K requests are left out, like everywhere else.
- **Phase** (`SeerrRequestPhase.resolve`): declined; ready when the request is
  completed (a TV request completes when its own seasons are in) or the media is
  available; downloading when `media.downloadStatus` has queue entries;
  partially available when some, not all, of the request's own seasons are
  completed (never from the media's status, which describes the whole show);
  pending approval; failed; otherwise requested. Media Seerr marks deleted is
  hidden.
- **Progress.** `downloadStatus` is the Radarr/Sonarr queue, refreshed by
  Seerr's Download Sync job every minute; it stays empty unless the server's
  Enable Scan (`syncEnabled`) is on. A show sums all its queued episodes; the
  estimate is the latest finish still ahead.
- **What is listed.** Everything still on its way, and a declined or ready
  request for Settings › Seerr › Keep Ready Titles
  (`UserPreferences.readyRequestShelfLife`, a day to a month, a week by
  default): a declined one after it was made, a ready one after the app saw it
  arrive (or after it was made, for one that finished before the app looked).
  Arrival dates are kept for the longest choice, so lengthening it later finds
  them.
  Ready, then downloading, then the rest; newest first within each; at most
  20 cards. An awaited request that falls out of the newest 50 is forgotten.
- **Routes.** Ready or partly here opens the Plex page (the bound server's
  rating key when Seerr has one, else `seerrInPlex`'s exact TMDB match);
  anything else opens the Seerr page.
- **Polling.** Only while Home is on screen (`HomeView`'s task, cancelled when a
  page is pushed): every minute while something downloads, five minutes while
  anything is on its way, fifteen otherwise, a minute after a failed refresh,
  never more than once per 20 seconds on reappear. A request sent from the app
  refreshes it at once. A Seerr context change (profile, binding, sign-out)
  clears the row before Seerr reconnects and restarts the polling; a refresh
  that a newer one or a context change overtook drops its result, and one
  cancelled mid-load publishes nothing.

Arrivals are announced once. `SeerrRequestWatchRecord`, stored in UserDefaults
per Seerr URL, Plex profile and Seerr user (`SeerrService.requestOwnerKey`),
holds the requests seen on their way, when each arrived and when it last
looked. A request already ready the first time it is seen is never an arrival,
so connecting Seerr does not announce old requests. After more than two days
without a refresh, arrivals are listed as ready but not announced. Disconnecting
Seerr clears that profile's records; signing out of Plex clears all of them.

iPhone and iPad post a local notification for each arrival; the system shows
it as a banner while the app is open too, and tapping it opens the title in
Home (`SeerrArrivalLinks`, consumed by `MainTabView` once Seerr's server is up
or after ten seconds). Permission is asked right after the first request sent
from the app. Background app refresh (`com.inceptyon.ithaca.seerr-requests`,
iOS's `fetch` mode) is scheduled when the app leaves the foreground and only
while one of this profile's requests is on its way; iOS decides when it runs,
so a notice can be late. Notifications are added before the refresh returns,
so iOS cannot suspend the app first. Apple TV has no notifications: its row is the announcement.
Settings › Seerr › Notify When Ready (`requestArrivalNotificationsEnabled`, on
by default) turns them off: arrivals are still recorded, so turning it back on
brings no backlog, and no background refresh is scheduled while it is off.
Turning it on asks for permission if it was never asked. Settings › Home › Show
Your Requests (`showsRequestsOnHome`) hides the row; the tracker still polls,
so notifications still come.

## Missing Seasons On Plex Shows

Online Plex show details request GUIDs. Missing-season enrichment runs only when:

- Seerr is connected for the current Plex profile and its bound server;
- live Plex metadata is in use, not cached offline metadata; and
- the Plex show has an exact `tmdb://` GUID.

Ithaca fetches that exact Seerr TV record, removes season numbers already present
in Plex, and sorts the remaining request-only seasons into the same grid.
Never use fuzzy title matching here: a false match could submit a request for the
wrong series. Seerr failures are ignored so Plex detail loading remains intact.

## Invariants And Traps

- Never send the Plex token before the user confirms the exact normalized host,
  and never automatically over plain HTTP.
- Redirects are accepted only within the same origin to prevent credential or
  session-cookie leakage.
- Keep session cookies in Keychain and the non-secret base URL/server binding in
  UserDefaults.
- A 401 refreshes the session once through Plex sign-in, over HTTPS only; a real
  403 remains a permission/quota error and must not be mistaken for an expired
  session.
- Never pass Seerr items into playback, download, offline-sync, or Plex
  watch-state code.
- Never let Seerr availability suppress a Plex item; Plex wins deduplication.
- Load artwork through Seerr's `/imageproxy/tmdb/...` when its public settings
  say `cacheImages` is on. With it off (Seerr's default) the proxy answers 404,
  so images come from `image.tmdb.org`, as Seerr's own web app does; until the
  public settings load, that is the default too.
- Never announce a request the app did not see on its way, and never poll Seerr
  from Home faster than its one-minute download sync.
- Preserve reverse-proxy subpaths when building endpoints.

## Verification

Compile both the iOS and tvOS schemes after changes. On-device checking should
cover a Plex-enabled Seerr, an unauthorized Plex Home member, reconnect after a
session expires, pending/approved/available states, partial TV requests, an
offline Plex show, and a show with an exact TMDB GUID plus missing seasons. For
Your Requests: a download's progress moving on Home, an arrival notification on
iPhone (foreground and background, and its tap), no notifications for old
requests after connecting, and tvOS Home landing focus with the row first under
the hero (no Pick Something).
