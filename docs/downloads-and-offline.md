# Downloads And Offline Playback

## Boundaries

Core state is in `Ithaca/Sources/Downloads/`; UI is in
`Ithaca/Sources/Features/Downloads/`. Detail screens consume injected
`DownloadManager` and `OfflinePlaybackSyncManager`; they should not touch files
directly. Playback stays in `PlaybackCoordinator`; offline playback swaps only
the URL/source and timeline reporting path. Plex remains the source of truth,
and `DownloadsFeature.isVisible` hides downloads on tvOS.

## DownloadManager Responsibilities

`DownloadManager` is the public facade for download behavior. It loads and
persists profile-scoped `DownloadedMediaRecord` values; queues movie, episode,
season, and show
downloads; expands seasons/shows into episode records; aggregates state;
controls transfer lifecycle; selects the download media version through
`StreamResolver`; validates free-space reserve; caches Plex metadata/artwork;
exposes local playback/artwork URLs only when files exist; and reconciles
background `URLSession` tasks after relaunch.

New user-facing download behavior usually starts as a manager method, then gets
wired into `DownloadActionButton`, `DownloadsView`, or settings.

## File Store Layout

`DownloadFileStore` owns all paths under:

```text
Application Support/Ithaca/Downloads/
  downloads.json
  playback-sync.json
  Metadata/Profiles/<profile-id>/<server-id>/<endpoint-hash>.json
  Artwork/<path-hash>.jpg
  ResumeData/<global-key-hash>.resume
  Profiles/<profile-id>/Movies/<Title>/<Title>.<ext>
  Profiles/<profile-id>/TV Shows/<Show>/Season NN/S<season>E<episode> - <Episode>.<ext>
  Profiles/<profile-id>/Other/<Title>/<Title>.<ext>
```

Invariants: the root is excluded from backup; video paths in records are
relative; `absoluteURL(for:)` rejects paths outside the root; file names are
sanitized, a file extension is used only when it is 1–10 lowercase letters or
digits (else `mp4`), and `targetVideoURL` throws unless the standardized path
stays under `Profiles/`; artwork/metadata/resume names are SHA-256 hashes. Delete All removes
the active profile's records, then its `Profiles/<id>` video folder and
`Metadata/Profiles/<id>` cache (orphaned files and empty folders included) once
no record of that profile remains, and `Artwork/`, `ResumeData/` and the rest of
`Metadata/` once no record of any profile remains. `downloads.json` and
`playback-sync.json` are never removed (a file that fails to decode is moved to
`<name>.unreadable`, replacing an older one, and logged as an error; the app then
starts empty), and Delete All drops only synced watch
actions: pending ones stay and still sync. The removal bumps `storageRevision`,
which `storageUsageBytes` reads, so Settings shows the freed space. It runs
synchronously on the main actor right after those checks, and is skipped while a queue request is in
flight (it may have cached metadata for a record it has not stored yet).
The removal bumps `cacheGeneration`. Queueing, preparation and completion run
inside `withCacheGeneration`, which stamps the value they started with in a
task-local; metadata writes (`fetchAndCacheDetails`, `fetchAndCacheChildren`)
throw `CancellationError` and artwork writes stop when the stamp is older, so
work in flight for deleted downloads cannot recreate the caches.

## Queue Lifecycle

Normal single-item flow:

```text
DownloadActionButton
  -> DownloadManager.queueDownload(id:type:)   // id = PlexItemID
  -> create DownloadedMediaRecord(.queued)
  -> processQueue()
  -> fetch/cache Plex metadata (prepare always refetches; the cache is only a fallback when the fetch fails, and stale resume data is dropped if the part id changed)
  -> startDownload(.preparing)
  -> URLSessionDownloadTask(.downloading)
  -> completeDownload(.completed + relativeVideoPath)
```

Every queue API is keyed by `PlexItemID`, and `DownloadScope` carries it too:
rating keys collide across servers, so a record is only ever matched by server +
rating key. `DownloadManager.record(for:)` is strict about this: an id without a
server resolves only when exactly one record carries that rating key, never by
picking the first match — the answer feeds `localPlaybackURL` and
`downloadedMediaVersion`, where a wrong match plays a different file. Season and
show downloads fetch hierarchy metadata on the season's
or show's own server, then call the same
single-item queue path for each episode, which inherits that server. The
season listing's `PlexEpisode` seeds each queued record's title, artwork and
season/show keys, so `relatedRecords(.season/.show)` and the season and show
Pause/Cancel controls see episodes that have not started yet. A single item
seeds from `PlexService.recentMediaDetails` when the detail page fetched it.

Records and pending sync actions written before servers were identified by
machine identifier can carry the server's base URL in `serverID`. Those match no
connection and would wait forever, so `DownloadManager` and
`OfflinePlaybackSyncManager` re-key them once
(`plexService.serverID(forLegacyConnectionURI:)`, which matches the URL against
each known server's endpoints); the record's cached metadata directory moves
with it (`DownloadFileStore.relocateMetadata`). An address that resolves to no
known server is left untouched — the record stays listed and its file stays
playable offline.

The queue only starts records whose server is currently connected; the others
stay `queued` rather than failing, and `DownloadManager` observes the pool so a
server coming back re-runs the queue on its own. Such a record must say why it
is idle: `DownloadManager.queueWaitReason(for:)` turns `pool.state(for:)` into
the queue row's status text ("Waiting for <server>", "<server> is turned off"),
so a download parked behind a disabled or unreachable server never looks like a
stuck "Queued". Single movie/episode requests should
return after writing the queued record; expensive metadata fetch, media version
selection, episode context caching, and storage validation belong in queue
processing. Aggregate controls use `DownloadScope` and `relatedRecords(for:)`;
do not add separate season/show transfer records unless the product model
changes.

Status rules: `queued`/`preparing`/`downloading` are active. `paused` and
`failed` are resumable. User-facing cancel removes a non-completed queue record
and its partial/resume data; pause is the non-destructive stop. Pause All also
holds the queue (`isQueuePaused`); resuming, retrying or queueing any download
lifts that hold, unless it came from Wi-Fi Only or a profile switch. Delete is
reserved for completed local files. Completed is playable only when the local
file exists; launch-time `reconcileCompletedFiles()` removes stale completed
records and marks invalid completed files failed.

Completion must validate the transfer before a record becomes playable. Reject
non-2xx HTTP responses, text/JSON/XML error payloads, zero-byte files, and
files smaller than Plex's selected part size when that size is known. Keep the
URLSession temporary file separate from the final video path until validation
passes, then replace the final file and mark the record `completed`. A failed
validation must leave the record `failed`, not `completed`.

## Background Transfers

`DownloadTransferController` owns `URLSessionDownloadDelegate`. iOS uses
background session id `com.inceptyon.ithaca.downloads.background`; `IthacaAppDelegate`
stores completion handlers in `DownloadBackgroundSessionRegistry`, and
`urlSessionDidFinishEvents` calls them, but only once every finished transfer
has been recorded: `DownloadTransferController` counts `.finished` events and
`DownloadManager` calls `finishedTransferWasRecorded()` once per event. Completion
persists `.completed` and the video path before awaiting artwork, so a
suspension after the handler cannot leave a finished file behind a
`.downloading` record. Other platforms use a default session.
Progress is throttled in the delegate and persisted less frequently by
`DownloadManager`. Pause uses `cancel(byProducingResumeData:)`; a failed transfer
(lost connection, or a force quit reported on the next launch as a cancelled
task) carries resume data in its error, and `.failed` passes it on. Resume data
is saved under `ResumeData/` and deleted after reuse. A force-quit cancellation
with resume data goes back to `.queued` and continues by itself; other failures
stay `.failed`, and Retry continues from the resume data when there is some
(also when a season or show is queued again: `queueSingleDownload` retries an
existing failed episode record, and resumes a paused one, in place instead of
replacing it; `upsert` deletes the resume file of a record it replaces).
Resume data replays its original request, so `DownloadTransferController.start`
rewrites it to the current request first (`DownloadResumeData.retargeted`: the
current address, token and Wi-Fi Only flags, keeping URLSession's Range and
If-Range). The format is undocumented: CFNetwork archives a dictionary under the
literal key `NSKeyedArchiveRootObjectKey` (older systems: a plain property
list), and each request inside only decodes through secure coding. On anything
unexpected the data is used unchanged. Launch reconciliation runs before the
Plex Home bootstrap knows who is signed in; until `homeBootstrapCompleted`, a
live background task keeps running (`.downloading`), and
`completeProfileActivation` pauses any running task whose record belongs to a
profile other than the active one. A background relaunch without a scene leaves
transfers running. Task descriptions carry the record
`globalKey`; use them for relaunch reconciliation instead of task ids.

Network constraints are split between URLSession configuration and
`DownloadManager`'s `NWPathMonitor`. When Wi-Fi Only is enabled and the network
is expensive or constrained, the manager pauses the queue and later resumes only
if that pause was network-driven. A running task keeps the Wi-Fi Only flags it
started with, so turning Wi-Fi Only off restarts each running transfer that can be resumed
(`DownloadTransferController.isResumable`: no response yet, or 200/206 with
`Accept-Ranges: bytes` and an ETag or Last-Modified). It is paused into resume
data and requeued (unless the user pauses it meanwhile), and the restart picks
up the new flags. Other transfers keep running with the old flags, since a
restart would start them over; they pick up the setting on their next start. `evaluateNetworkConstraints` detects the
change. Raising Simultaneous Downloads re-runs the queue
(`processQueueIfNeeded`) from `SettingsIOSView`. The free-space check counts
only the bytes still to come: a resumed transfer's downloaded bytes are already
on disk, and the remaining bytes of transfers already running are reserved.

## Metadata And Artwork Cache

`PlexMetadataCache` stores raw Plex payloads by server id and endpoint:
`/library/metadata/{ratingKey}` and
`/library/metadata/{ratingKey}/children`.

Queueing fills cache progressively: movies cache their own details; episodes
cache details plus season/show context; seasons cache details, episodes, show
details, and sibling seasons; shows cache show details, seasons, and every
season's episodes.

Artwork is separate: `DownloadManager.cacheArtwork` fetches image bytes through
`PlexService` and stores hashed jpgs. Detail view models call
`localArtworkURL(for:)` first, then fall back to Plex image URLs.

Pitfall: cached metadata is profile- and server-scoped. Use the active profile
with `serverID(for:)` or `preferredServerIDs`; do not assume a rating key is
unique across profiles or servers — with several servers connected at once, it
is routinely not. Legacy cache/video paths remain readable and are adopted only
by the originally linked profile.

Plex Home adds a second identity boundary: downloaded records, offline metadata
lookups, playback-sync actions, and their global keys include `activeProfileID`
in addition to server id and rating key. A profile must never see or mutate
another profile's records merely because both can access the same server.
Signing out pauses the active profile's transfers the way a profile switch does
(`PlexService.willSignOut` calls `prepareForProfileSwitch`), so nothing keeps
downloading with the outgoing account's token. They resume when that account
signs in again; its finished downloads stay on disk.

## Offline Playback Route

`PlaybackCoordinator+Session.startPlaybackSession` owns the route. It prefers
cached media details when the rating key is playable offline; otherwise it
fetches live Plex details and falls back to cache on failure. It resolves media
normally, then uses `localPlaybackURL(for:selectedMediaID:)` when present or a
Plex direct-play URL otherwise. Engine selection still goes through
`StreamResolver` and `PlaybackEngineFactory`. Only local downloads use
`OfflinePlaybackSyncManager` for the effective resume offset.

Keep engines and player views source-agnostic; offline-specific playback logic
belongs in the coordinator or presentation/debug models.

For local playback, resolve the engine from the downloaded record's stored
`mediaID` and `partID`. Do not reselect a media version from normal playback
quality preferences after choosing a local file, because that can pair the
downloaded container with the wrong engine.

## Offline Watch-State Sync

`OfflinePlaybackSyncManager` persists pending actions to `playback-sync.json`.
Action kinds are `progress` (offset, duration, Plex state, optional watched
mark), `watched` (scrobble), and `unwatched` (unscrobble).

`PlaybackCoordinator+Timeline` reports every 10 seconds. Live streams report to
Plex directly. Local downloads record progress locally and opportunistically
sync. Finalization records stopped progress; crossing 90 percent queues a
watched/scrobble effect. Detail watch/unwatch actions also queue locally when
using cached data or a local file.

Sync considers actions for `plexService.activeProfileID`, and routes each action
to **its own** server: a pending action is syncable when that server is
currently connected (`pool.connection(for:)`), and actions for servers that are
offline or disabled simply wait. It starts
on launch and active scene phase, stops its retry loop outside active phase, and
uses per-action backoff. A 404 on the pre-send item fetch means the item is gone
from the server, so the action is dropped (logged at notice level); any other
error keeps retrying. A pending `.progress` action that crossed 90 percent keeps
`shouldMarkWatched` through later progress writes; only an explicit unwatched
action clears it. `markSynced` preserves newer local edits when an older
sync attempt completes late.

Synced actions are kept as the offline view of the item, but they never
override Plex once Plex has seen them. `PlexService.watchStateObserver` passes
the watch state of every live metadata fetch (`fetchMetadata`,
`getMediaDetails`) to the manager, which stores it on the matching action as
`plexWatchState` with the time the request was sent. The rules live on
`OfflinePlaybackSyncAction`:

- Plex wins once a fetch sent after the action's `writtenAt` comes back and the
  action has no unsent write (`isSupersededByPlex`). Offline, that stored Plex
  state replaces the metadata saved at download time, which is never refreshed.
- An unsent write wins until it is sent, unless Plex's `lastViewedAt` is more
  than `clockSkewAllowance` (5 minutes) later than `writtenAt`. Then another
  device changed the item after it, and the write is dropped.
- Before sending each action, sync fetches the item first, so a write older
  than another device's change is dropped instead of moving Plex's resume
  point backwards.

`writtenAt` moves forward whenever the write reaches Plex (`markSynced`, and
after the timeline half of a progress-plus-scrobble action), so Plex's
`lastViewedAt` from that write is never mistaken for another device's change.

Actions recorded before Plex Home support are adopted by the original linked
profile during the one-time migration; they must not be left as unscoped
actions. Switching users pauses the outgoing profile's queue and leaves failed
sync actions attached to that profile until it becomes active again.

## Smart Downloads

`SmartDownloads` (iOS only; `DownloadManager.smartDownloads`, set in
`IthacaApp`, nil on tvOS) runs while `smartDownloadsEnabled` is on. A pass
takes every show the active profile has an episode record of (any status, not
being deleted, grouped by server + `grandparentRatingKey`), skips shows whose
server is not connected, and fetches the show's episodes in viewing order with
`PlexService.getAllEpisodes` (`allLeaves`). That fetch feeds
`OfflinePlaybackSyncManager`, so each episode's state is
`effectiveWatched` / `effectiveViewOffsetMs`. `SmartDownloadsPlan` (pure,
`IthacaTests/SmartDownloadsTests.swift`) then decides:

- Remove every record of an episode watched since it was downloaded (Plex's
  `lastViewedAt` after the record's `addedAt`; without either date it goes)
  through `deleteDownload(id:)` — queued ones too, so nothing downloads only to
  be removed. An episode watched only before its download is a rewatch the
  viewer asked for and stays. Local files and records only; no Plex endpoint
  that deletes media is ever called.
- Keep the next `smartDownloadEpisodeCount` episodes after the last watched
  one (in viewing order) on the device: those without a record are queued with
  `queueDownload(episode:liftsPauseAll: false)`, so Wi-Fi Only, quality,
  concurrency and Keep Free apply and a user's Pause All stays. Episodes
  already on the device count toward the number; a paused or failed record is
  left for the user to resume or retry.
- A pass removes nothing while the player is showing or Picture in Picture is
  active (`isPlayerShowing` in `IthacaApp`), so the episode being watched stays.
- Watched means watched and not started again: a first watch or a rewatch
  stopped before 90 percent counts as unwatched and is kept. Specials
  (season 0) are removed once watched but never queued.

Nothing is removed while the player is up (`PlaybackCoordinator.showPlayer`):
it may be reading a downloaded file, or about to while it loads. A later pass
removes what was held back.

Queueing waits for watching to move on. Each show's window remembers the
furthest finished episode it was last filled after (`smartDownloadsWindows`
in UserDefaults, by profile, server and show), and a pass queues only when that
changes, so a download the viewer cancelled or deleted isn't fetched again. A
show seen for the first time fills its window; turning the setting on or
changing the count refills every window (`run(refills: true)`); a show that
leaves the device forgets its window. A show whose fetch fails is
skipped whole (logged, category `SmartDownloads`) and the others continue; with
no network the pass does nothing.

Triggers: `OfflinePlaybackSyncManager.didFinishSync` (every forced sync —
launch, becoming active, Sync Watch Progress Now — and every sync that sent
something), the Downloads screen appearing, the setting turning on or the count
changing, and `run()` from `PlaybackCoordinator.finalizeCurrentPlaybackSession` once an
episode was scrobbled and the final writes reached Plex. One pass at a time; requests
during a pass become one more pass after it. `prepareForProfileSwitch` stops
the pass, and every step re-checks the profile, the setting and
`isProfileSwitching` after each suspension, so one profile's plan never touches
another's records.

## UI Hooks

`DownloadActionButton` is the inline download/delete/pause/resume/retry control.
For a season or show, the detail screen passes `expectedEpisodeCount` (the
`leafCount`); when fewer episodes are downloaded the completed button reads
"Download Remaining" and queues the scope again, which skips finished episodes.
`DownloadsView` owns the downloaded movie/show grid, queue sheet, queue awake
hint, pending sync banner, transfer-rate and ETA display, and the
queue-sheet-only idle timer hold while active downloads exist. Queue rows
dismiss the sheet before appending the media destination to the Downloads tab
navigation path, so detail screens are shown in the full tab stack rather than
inside the sheet.
`MainTabView` shows the Downloads tab only when visible and records exist.
`SettingsIOSView` owns quality, Wi-Fi Only, concurrency, storage reserve, Smart
Downloads and its Keep Ready count, usage, manual sync, and delete-all. `MediaDetailDestinationView` passes managers into
detail view models and marks routes from Downloads with
`prefersOfflineAvailability`.

Detail view models load cached data before live Plex where useful, disable play
when cached data is unavailable offline, prefer local artwork, and use
`effectiveWatched` / `effectiveViewOffsetMs`, which apply the rules in
Offline Watch-State Sync above.

## Extension Points

New preference: `UserPreferences`, settings UI, then `DownloadManager` at queue
or start time. New queue action: public manager API plus `DownloadScope`
aggregate behavior, then `DownloadContextMenuContent`. New cached metadata type:
typed accessor in `PlexMetadataCache`; keep storage raw and endpoint-keyed. New
offline playback behavior: `PlaybackCoordinator+Session` or
`PlaybackCoordinator+Timeline`, not engine views. New path rule:
`DownloadFileStore`; verify relative paths, containment, deletion, and migration.

## Pitfalls

Do not key persisted records by rating key alone; use
`profileID:serverID:ratingKey`. Route every download action — token, URL,
connectivity guard — by the record's or item's own `serverID`, never by the
primary server. A download whose server has since been disabled stays listed and
plays offline; only new network work needs the server back. Do
not casually delete shared metadata/artwork; show/season browsing and up-next may
reuse it. Do not trust `downloadTaskIdentifier` across relaunch. Do not report
Plex timeline directly for local downloads. Do not make Downloads always visible
or add a generic provider abstraction unless product scope changes.

## Safe-Change Checklist

Locate the layer: storage, queue, delegate, metadata cache, playback route, sync
queue, or UI. Preserve root containment, relative paths, server-scoped keys,
completion validation, and per-server sync routing. Keep views on
managers/view models, not files or network calls. Exercise movie, episode,
season, and show scopes; check pause, resume, cancel, retry, delete, delete-all,
Wi-Fi Only, and relaunch behavior. For offline-route changes, check cached
detail loading, local artwork, local playback, downloaded-version engine
selection, and pending sync banners. For Swift source changes, run the
compile-only `xcodebuild` command from `CONTRIBUTING.md`; docs-only changes do not
need a build.
