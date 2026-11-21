# Ithaca UI Feature Layer

Operational notes for agents changing SwiftUI screens, feature view models, and shared UI
in Ithaca. Read this with `docs/codebase-map.md`, `STYLE.md`, and `docs/data-and-plex.md`.

## App And Navigation Shell

- `IthacaApp` creates the long-lived app services and injects them into the SwiftUI
  environment: `PlexService`, `PlaybackCoordinator`, `DownloadManager`,
  `OfflinePlaybackSyncManager`, `SeerrService`, and `UserPreferences`.
- App-wide color scheme comes from `UserPreferences.appearanceMode`. There is no
  root `.tint`: the global `AccentColor` asset is the label colour, so system
  controls, navigation buttons and the tab bar selection are neutral and adapt
  over both artwork and light content backgrounds.
- `ContentView` is the account-bootstrap root gate: unauthenticated users see
  `SignInView`; signed-in Plex Home accounts are checked and, when needed, show
  `HomeUserPickerView`; an active Home identity enters `MainTabView`. **There is
  no server step in onboarding.**
- Connecting is not a gate. `ServerConnectionCoordinator` (injected into the
  environment by `ContentView`) connects every enabled server in parallel while
  the shell is already on screen; each server's content appears as it answers.
  Keep connection logic there — do not spread `connectAllServers()` calls into
  feature screens; call the coordinator's `refresh()` for a retry instead.
- A connect pass runs on first mount, on a profile switch, on return to the
  foreground, and on a network-path change. Passes are deduplicated and a fresh
  one is skipped for a minute unless the pool has nothing usable.
- Home selection precedes connecting because each Home identity can expose a
  different resource list. A successful switch reconstructs the main shell so
  navigation paths and feature view models cannot retain the previous user's data.
- Server trouble is never a modal or a full-screen blocker. All servers off is a
  distinct empty state; nothing reachable is an inline error with Retry and a way
  into Server Priority; a partial outage is an unobtrusive inline note. Downloads
  stay reachable in every case. A pool that never got as far as producing server
  states (discovery itself failed: no internet, fresh install) shows the same
  inline error once the coordinator's first pass has finished — `unknown` is only
  a spinner while a pass is actually running.
- `MainTabView` owns one `NavigationPath` per tab so tab stacks stay independent.
- Re-selecting the active tab pops that tab to root.
- Available tabs are data-driven: every present and user-visible library type
  (Movies, TV Shows, Videos) plus Live TV when discovered gets its own tab in
  the user's preferred order, and
  Downloads appears only when visible and populated. Library-tab visibility and
  order are local `UserPreferences`; missing preferences preserve the original
  all-visible Movies / TV Shows / Videos / Live TV order.
- iOS/iPadOS use the modern native `Tab` API with SF Symbols and open Search
  from a circular trailing toolbar action on Home and immediately before Browse
  on each library root, leaving Search out of the tab bar. iPadOS keeps every
  remaining destination flat. On iPhone, Home plus the first three visible
  content destinations stay flat and overflow content, Downloads, and Settings
  move into `MoreView` so the tab bar stays at five items. tvOS remains flat
  with a Search tab and no Downloads tab.
- While Seerr is connected for the current profile, tvOS adds a Discover tab
  before Search, and iOS/iPadOS add a Discover action (`sparkles`) beside
  Search in Home's toolbar. See `docs/seerr-integration.md` → Discover.
- If a preference or availability change crosses the iPhone five-tab limit,
  keep the currently selected flat destination or `MoreView` mounted until the
  user selects another tab. Replacing the active container immediately tears
  down its `NavigationStack` mid-push; defer the new flat/folded layout and clear
  the retired path when leaving it. The same holds for a selected Downloads tab
  whose last record is deleted or cancelled from inside it (iPad, or iPhone
  without More): it stays until the next tab change.
- The tvOS tab shell forces monochrome symbols and a label-color tab bar tint
  (`Color.ithacaTVTabBarTint`: `TextPrimary` in Dark mode, black in Light mode).
  tvOS draws the selected, unfocused item's icon and title in the bar's tint, so
  a dark tint in Dark mode reads as black-on-black; the focused item's contrast
  against the focus plate is handled by the system, not by the tint.
- That tint is pinned on the real `UITabBar`, at launch through the appearance
  proxy and again from the shell on every update (`IthacaTVTabBarTintPin`), and a
  zero-size sentinel subview inside the bar re-pins on every `tintColorDidChange`
  UIKit reports. SwiftUI's `.tint` on a tvOS `TabView` is not sticky: a bar that
  falls back to the inherited window tint picks up the global accent color
  after returning from a detail screen or the player. That accent
  (`AccentColor`) is the same label colour, so a fallback looks identical. The
  shell clears the bar's tint off the tab content (`.tint(nil)`): an inherited
  explicit tint makes tvOS system glass buttons go white-on-white on focus.
- tvOS Back (Siri Remote Menu) at a tab root goes to Home, and on Home
  scrolled down it returns focus to the hero; only Home at its top leaves the
  app. `MainTabView.rootBackAction` decides, `IthacaTVRootBackInterceptor` (a
  Menu-only tap recognizer on the `UITabBarController`'s view) catches the
  press with focus in the content or on the tab bar. The recognizer refuses
  the press whenever the selected tab has a pushed screen, checked on the real
  `UINavigationController` because Settings rows push with
  `NavigationLink(destination:)`, outside the tab's `NavigationPath`.
  `onExitCommand` cannot do this: it never sees Back with focus on the tab bar.
- tvOS Select on the current tab in the tab bar pops that tab to its root, as a
  tap on the current tab does on iPhone. tvOS's `TabView` never reports that
  press, so the same interceptor adds a Select recognizer that claims it only
  with focus on the tab bar (in the shell, outside the selected tab's content)
  and only when `MainTabView.reselectAction` has a path to pop.
- `AppNavigationRoute` is the shared route enum. Add new top-level destinations there
  only when multiple features need to navigate to them.
- Use `NavigationLink(value:)` with `AppNavigationRoute` for media/person/library flows.
- Attach `.ithacaAppNavigationDestinations()` inside each tab `NavigationStack`; it maps
  routes to concrete destination views with environment services.
- Detail routing enters through `MediaDetailDestinationView`, which dispatches by
  `PlexMediaType` and passes download/offline context through.
- Playback presentation is centralized in `MainTabView` through
  `PlaybackCoordinator.showPlayer` and `PlayerView`; feature screens should call
  `playback.play(...)` or `playback.playVersion(...)`, not present the player.

## Shared UI Primitives

- Prefer shared primitives before adding feature-local copies.
- Loading, empty, and retry states belong to `FeatureLoadingView`,
  `FeatureEmptyStateView`, and `FeatureErrorView`.
- `FeatureErrorView` shows Retry for ordinary failures. Messages that mean the
  Plex account session is dead (`PlexServiceError.unauthorized` /
  `.notAuthenticated`) replace Retry with Sign In, which calls `signOut()` so
  `ContentView` presents `SignInView`. Do not add a local retry button for those
  errors. Successful re-auth is a new session; it does not resume the failed
  screen or playback.
- Poster UI is layered: `PosterArtwork`, `PosterCardText`, `PosterCard`,
  `PosterNavigationCard`, and `PosterActionCard`.
- Fully watched items (e.g. fully watched seasons) pass `isWatched` to the poster
  card to add a small checkmark to the subtitle line, in the subtitle's own colour
  (never a colour — a fully watched row must not become a wall of badges);
  suppress the progress bar in that case (pass `progress: nil`) so completion
  reads as the checkmark, not a full bar. Partial progress still renders the bar
  (`IthacaPosterMetrics.posterProgressBarHeight`), white on a dark track like the
  TV app, everywhere.
- Use `PlexItemPosterCarouselSection` for horizontal shelves and
  `PlexItemPosterGrid` for grids. They already handle image sizing, context menus,
  progress, and route creation. Both take `imageAspectRatio` (default 2:3); pass
  `16.0/9.0` for clip content so the requested transcode size matches the display
  aspect — a 2:3 request would be cropped server-side. Image sizes passed to
  `imageURL` / `posterImageURL` are **points**: `PlexService` multiplies by the
  display scale, so never pre-multiply (Search did, and asked for 4× the pixels).
  `PlexItemPosterGrid` wraps each card in an Equatable cell (the item's watch state
  plus what the card shows), so a grid pass skips unchanged cards; a kept cell keeps
  the closures of the render that built it, so a caller's `posterURL` / context menu
  closures must capture only its view model.
- Clip rendering is item-driven: `PlexItem.isClip` (item `subtype == "clip"`) and
  the `Collection.isAllClips` helper decide when a row/grid renders 16:9 with
  `IthacaPosterMetrics.videoCarouselWidth`/`videoGridPreferredWidth`. Clip card
  subtitles show the full localized upload date and compact duration via the
  clip-aware `standardPosterSubtitle`; uploads from the last week also prefix
  relative context (for example, `2 days ago · 17 Jul 2026 · 12 min`).
- Context menus for partially watched playable items should expose both watch-state
  endpoints: mark watched and mark unwatched. Do not collapse partial progress into
  a single toggle action.
- Use `MediaCarousel` for generic horizontal sections. It renders only the section
  title; it has no header accessory slot, so do not reintroduce buttons beside the
  title. Its horizontal padding can be overridden when a page needs its shelves to
  share the system navigation title's leading edge.
- A shelf's "Show all" destination is `ShowAllCarouselTile`, rendered by
  `PlexItemPosterCarouselSection` / `PlexItemActionCarouselSection` as the **last
  card** of the shelf on **every** platform — a dashed card sized like the shelf's
  artwork (`imageAspectRatio` aware), so the destination reads as content instead of
  a cramped header button. Pass `showAllRoute` only when the shelf is actually
  truncated; a nil route simply omits the tile.
- Use `AdaptivePosterGridLayout.make(...)` for responsive poster grids. Do not hand-roll
  column math in feature files.
- Use `IthacaPosterMetrics` for platform-sensitive poster widths, grid spacing,
  horizontal padding, and detail padding. Its `titleFont` / `subtitleFont` are thin
  forwards to `IthacaFont.cardTitle` / `IthacaFont.cardSubtitle`, so card text is styled
  by the type scale, not by the metrics struct.
- Use `IthacaFont` (`Shared/IthacaTypography.swift`) for **all** type. tvOS views go
  through `IthacaFont` and never use raw semantic text styles (`.headline`, `.title3`,
  `.caption`, …), which resolve 2.1–2.7× larger on tvOS than on iOS. Each token takes
  the call site's current iOS style — `IthacaFont.sectionHeader(ios: .title3.bold())` —
  and returns it unchanged off tvOS, so iOS rendering never moves. tvOS-only paths use
  `IthacaFont.TV.<token>`; layout structs that store point sizes use
  `IthacaFont.TV.Size.<token>`; sites where iOS deliberately applies no font use
  `.ithacaFont(tvOnly:)`. The full token table lives in `STYLE.md` §3.1.
- Use `MediaTextFormatter` for duration, season/episode labels, counts, progress,
  media type icons, air dates, and playback version labels.
- Use `PlexItemPresentation` helpers for standard poster subtitles, continue-watching
  labels, poster progress, and image URL selection.
- Use `IthacaAsyncImage` for Plex artwork. It integrates app image caching and can route
  Plex image requests through `PlexService` when needed. The decoded memory cache
  (`IthacaImageLoader`) empties on a memory warning and when the player opens
  (`purgeMemory()`, from the Home hero); views keep the images they show and the
  rest reload from disk.
- Use `DetailHeroBackdrop` with `IthacaHeroBackdropOverlay` for full-bleed hero artwork,
  and always apply `ithacaHeroBackdropBottomFade()` to the backdrop + overlay stack.
  The overlay owns the shared top and leading scrims; the bottom fade into the page
  is platform-split: on iOS the overlay paints a `Color.ithacaBackground` gradient and
  cap, on tvOS the modifier instead masks the hero to fully transparent so the page
  background underneath is the only fill at the hero boundary. The modifier's style
  picks the tvOS mask curve: `.standard` (the default) for detail heroes, `.compact`
  for a shorter, lighter fade that reveals more of the backdrop, and `.fullBleed` for
  a hero that owns the whole display — it holds full strength to ~86% and only
  vignettes across the last stretch. Every case must still reach, and hold, zero
  alpha before the hero's bottom edge; that is what makes the HDR seam impossible.
  On iOS the overlay's own scrim strength is selectable via its `style`: the iPhone home
  hero keeps the default `.standard`, the regular-width iPad home hero uses `.cinematic`
  (short top band for the status bar/toolbar, nearly clear middle, darkening and the
  `ithacaBackground` fade held to the lower third), while the movie/show/season/episode detail heroes pass
  `.soft` to hold the darkening and bottom fade off until the lower third so more of the
  backdrop reads through behind the title block. `.standard` and `.soft` differ on iOS
  only — on tvOS both render the long-standing full-strength vertical scrim. The one
  overlay style that changes tvOS is `.cinematic` (0.10 → 0.20@55% → 0.62@82% →
  0.88), used **only** by the home hero (full-screen on tvOS, near-full-screen on iPad) so the artwork stays nearly
  unscrimmed above the title block; the shared leading ramp is unchanged. Do not
  repoint the detail heroes at it.
  Never paint `Color.ithacaBackground` (gradient or solid) inside a hero subtree on
  tvOS: real Apple TV HDR output resolves hero-subtree fills and the plain page
  background through different color pipelines, so two stacked fills of the same
  color still meet with a visible seam and gray mismatch on hardware even though
  every simulator renders them identically. Fading the hero to zero alpha is the
  only seam-proof topology.
  When a detail hero swaps artwork from focus changes, opt into retaining the previous
  backdrop while the next one loads instead of clearing the image.
- When the iOS Home cinematic hero is visible, keep the tab bar color scheme dark.
  The floating iPad tab bar can sit over hero artwork, so its selected label must
  resolve against the tab bar material instead of the page's light appearance.
- On tvOS, poster, episode, and cast artwork controls should use
  `ithacaSuppressTVOSButtonChrome()` plus `ithacaTVOSFocusEffectShape`. Avoid SwiftUI's
  `.plain`, `.borderless`, `.glass`, and `.card` button styles directly here because
  real Apple TV hardware can draw gray/white system focus plates. When a poster card
  has labels below the artwork, keep the artwork as the actual control but apply
  `ithacaTVOSFocusedScale` to the outer card so the full poster container grows with
  a tight neutral white glow and without gaining a button background.
- On tvOS every view that owns a `@FocusState` re-runs on each focus move anywhere
  on the screen, so cards keep it to one at most. `PosterNavigationCard` /
  `PosterActionCard` and `ShowAllCarouselTile` own one and hand it to
  `carouselLeadingFocusTarget(_:)`, which answers Home's leading-focus request
  through that binding instead of a second state. They apply it on every screen,
  so any new Home row built from them takes part without extra wiring.
  `ActorCreditCard` and the tvOS show page's `SeriesEpisodeCard` own no
  focus state: they mirror the control's focus into `@State` with `FocusMirror`
  (`View+Platform.swift`), placed inside the label.
- Use platform helpers in `View+Platform.swift` instead of scattering `#if os(tvOS)`:
  `ithacaNavigationTitle`, title display modes, list background/separator suppression,
  status-bar helpers, tvOS button chrome suppression, and tvOS focus effect shape.

## Home

- `HomeView` is the tab root. It owns `HomeViewModel`, handles loading/error state,
  refreshes on appear, scene activation, and player dismissal, then delegates layout to
  `HomeIOSView` or `HomeTVView`.
- The cinematic hero always resets to its first item after player dismissal, app
  activation, Home-tab re-entry, or a change to the hero item order. Keep the explicit
  reset revision flowing from `HomeView` through both platform shells so a Plex refresh
  cannot preserve a stale selection after Continue Watching reorders.
- `HomeViewModel` owns ordinary Plex Home calls. The separate shared
  `LiveTVViewModel` owns the optional, non-blocking Live TV Home shelf.
- `HomeView` keeps one `HomeViewModel` and calls `load()` from a task keyed by
  `plexService.serverContentRevision` (servers, priority and profile). The model
  drops `lastPayloads` and the first-paint gate when `activeProfileID` changes, so
  a Home user sharing a server ID with the previous profile never sees its rows;
  a profile switch also rebuilds the tab shell.
- Home data combines global hubs from `getHubs()`, continue watching from
  `getContinueWatching()`, and personalized shelves: taste shelves from
  `TasteRecommender` first, then genre shelves from `HomeRecommendationEngine`
  without the titles the taste shelves already show
  (`HomePersonalizedShelf.combining`).
- Taste shelves (`Shared/TasteRecommendations.swift`) need Seerr, which supplies
  TMDB's recommendations; without it Home has only genre shelves.
  - Seeds are the profile's own Plex ratings (Loved It, Liked It, Not for Me;
    `PlexTasteRating`) and, unrated, movies finished and shows with two or more
    episodes seen in the last 90 days. A rating fades to 30% of its weight over
    two years, so recent viewing outweighs an old rating. Up to 8 likes and 4
    dislikes.
  - Each like brings two pages of TMDB recommendations, a dislike one. A title's
    score sums its positions on every list (a dislike's list subtracts). It goes
    on the shelf of the like that recommends it most strongly: "Because You
    Liked X" for a rating, "Because You Watched X" otherwise, at most three such
    shelves of at least three titles. What is left forms "Top Picks for You".
  - Only titles in the profile's libraries that it has not watched, started or
    rated. The library is read in one slim listing per movie/TV library
    (`getTasteLibraryItems`) and matched by `tmdb://` GUID, because Seerr's
    `mediaInfo.ratingKey` is missing for most titles Radarr or Sonarr marked
    available.
  - One pass serves Home and Discover and is kept for ten minutes, keyed on the
    profile, the connected servers, `plexService.tasteRevision`,
    `seerrService.requestRevision` and the Seerr server. A caller that joins a
    running pass, or owns one, re-checks the key when it ends and moves on to
    the current pass if a rating or request landed meanwhile. Closing the
    player and pull to refresh re-read the library. A rating made in the app
    bumps `tasteRevision` once every copy is written, and
    `HomeViewModel.refreshTasteShelves()` replaces only the taste shelves,
    combining them with the genre engine's own last answer (`genreShelves`).
  - Genre shelves leave out rated titles: the engine skips them, and
    `combining` drops any the taste pass reports rated since
    (`TasteHomeShelves.ratedItemIDs`, matched by Plex item id because genre
    listings carry no GUIDs).
- Settings › Home › Ask for Ratings (`UserPreferences.asksForRatings`, on by
  default) controls the "How was it?" alert after playback, which only shows
  while Seerr is connected (`docs/playback.md` → Rating prompt).
- Settings › Home › Personalized shelves is a device-local switch, on by default.
  `HomeView` passes it into `HomeViewModel` and applies changes immediately: off
  clears generated shelves, cancels their task and skips recommendation loading
  on subsequent refreshes; on reloads them. Cancellation and a publication guard
  prevent an old request from restoring shelves after they were disabled. Plex
  hubs, Continue Watching, and library-tab recommendations are unaffected.
- `HomeHubArrangement` places library rows in Library Order even when PMS omits
  the hub's section ID: it uses the paging URL, numeric identifier suffix, or
  consistent item section IDs from the representative server. Unscoped Recently
  Added rows can also use the only matching library type on that server. Ambiguous
  rows remain global; mixed/global rows such as Continue Watching keep their place.
- `LiveTVHomeShelf` adds currently airing channels when Live TV is available and
  `UserPreferences.showsLiveTVOnHome` (Settings › Home › Show Live TV, off by
  default) is on. When off, Home neither renders the shelf nor requests the
  now-playing lineup; the Live TV navigation tab is unaffected. Its
  discovery/load failure must not replace or delay normal Home content.
- Home publishes the base hub and continue-watching payload first, then expands
  Recently Added hubs and loads personalized shelves through cancellable follow-up
  tasks. Keep this two-phase behavior so expensive recommendation work does not block
  the first visible home content.
- Continue-watching items drive `HomeCinematicHero`.
- Home filters playlist/music/unknown content and hides Plex "continue watching/on deck"
  hubs so the custom continue-watching flow is not duplicated. That rule lives in
  `HomeHubFilter` (`HomeHubFilter.swift`).
- Home's arrangement is fixed and identical on both platforms: the cinematic hero,
  the Live TV shelf (when enabled), the Pick Something row, Your Requests (Seerr
  requests, only while Seerr is connected and something is listed), the Plex hubs,
  then the personalized shelves. Settings › Home turns rows on or off (Show Live TV,
  Show Pick Something, Show Your Requests: `showsPickSomethingOnHome`,
  `showsRequestsOnHome`, both on by default); `isShown(in:preferences:)` includes
  the switch, so tvOS lands the hero's down-press on the right shelf. `HomeIOSView` and
  `HomeTVView` each render that sequence directly. There is no user-editable Home
  layout; do not reintroduce one.
- Home is **merged across every connected server**. `HomeViewModel.load()` fans
  `/hubs` and `/hubs/continueWatching` out to all of them. **The first paint is gated
  by `HomeFirstPaintGate`** (`HomeFirstPaintGate.swift`): painting the first server's
  answer at once made Home jump when a later server brought Continue Watching, and so
  the cinematic hero, along with it. Once there is content, the loading view stays up for a short
  grace (`settleGrace`, 500 ms) so the other servers, including ones the pool is still
  connecting, and the library order can catch up. Only while a server that had
  hero items the last time Home settled (`HomeContinueWatchingMemory`, per profile in
  UserDefaults) is still missing *and* nothing in hand has any does it wait longer.
  Nothing is held past `patience` (3 s from when Home started waiting; the gate
  survives a load superseded by a server connecting). After the first paint, late
  servers fold in as they answer. The memory is a hint: it is rewritten on every
  settled merge, so a server that stops answering stops being waited for. No skeleton
  is shown, on purpose. **Once there is content on screen (a tab return, a
  pull-to-refresh, another server connecting) the merge is published in one go
  instead.** A merge missing the servers that have not answered yet is a *smaller*
  screen than the one already there, and swapping between the two is what made
  pull-to-refresh look like content jumping between servers. The merge (`HubMerge`, `ContinueWatchingMerge`) is a
  pure function of the per-server answers in priority order, so each publish refines the
  same list. With one server both merges return their input verbatim. Every merge
  registers its findings in `plexService.alternates` for playback fallback.
- Initial load, tab return, scene activation, player dismissal and pull-to-refresh all
  go through the **same** `load()`. It bumps `loadGeneration`, supersedes the previous
  load, and runs the work in an unstructured task the view model owns, awaiting only its
  value. That last part is load-bearing: `.refreshable` runs its action in a task SwiftUI
  cancels freely, and a load cut off half way would leave Home on the merge of whichever
  servers answered first — and skip the library-order pass, the Recently Added expansion
  and the personalized shelves. `LibraryRecommendationsViewModel.load()` is built the
  same way for the same reason.
- A server that *fails* a Home request is not a server that answered with nothing.
  `HomeServerPayload` carries `nil` for a failed request and the view model keeps that
  server's previous answer (`lastPayloads`, dropped when the server leaves the pool or
  the Plex Home profile changes), so a timeout during a refresh cannot make one server's
  rows blink out and back.
- Home reloads on `plexService.serverContentRevision` (`.task(id:)`), never on a single
  server identifier: the tab shell mounts before anything is connected.
- Home never labels a row with the server it came from — with every server merged into
  one screen that is noise. The only server wording is `ServerOutageNote`, a quiet line
  naming enabled servers that are currently offline. The old server-name subtitle
  (iPhone) and tvOS header subtitle are gone.
- Within the hubs, `HomeHubArrangement.arrange(hubs:libraryOrder:)` regroups the rows
  so each library's hubs appear in the order the account gives that library.
  `libraryOrder` is a list of **`PlexLibrary.id`** (`"<serverID>|<key>"`), and a row is
  placed by `PlexHub.representativeLibraryID` — its own server, or the highest-priority
  source of a merged row. Never key this on the bare section key: two servers' "3"
  sections would share a block. It is a pure permutation — global rows first, then one
  block per library in library order, then rows whose section is unknown. `libraryOrder`
  must be built from *every* section, including music and photo, or the blocks drift.
- Recently Added hubs are expanded through `PlexService.mergedHubItems(for:size:)`,
  which pages **each contributing server's** hub key and re-merges, so shelf limits are
  intentional and "Show all" (`.hub`) shows the whole merged row rather than the
  primary server's share of it. `PlexHub.isPageable` / `hasMoreOnAnySource` /
  `totalSourceSize` are the merged-row equivalents of `key` / `more` / `size`.
- `HomeCinematicHero` owns hero rotation, drag navigation on iOS, tvOS focus-driven
  paging, image preloading, title-logo fallback, pager state, and motion
  reduction. iOS enables automatic rotation (`autoRotates: true`): the hero advances
  every 7s and the pager pills animate a fill that tracks the timer. The hero pauses
  rotation while `PlaybackCoordinator.showPlayer` is true and restarts it fresh on
  return, so opening the player no longer advances the hero in the background.
  Rotation also respects Reduce Motion, scene phase, and drag interaction, and
  on iOS it holds while the hero is scrolled out of view (`HomeIOSView` reports it
  with `onScrollVisibilityChange`), restarting fresh when the hero is back.
  The hero is Home's only Continue Watching surface (iOS shows every item, tvOS
  caps at 10), so the pager is a `UIPageControl`-style sliding window
  (`HomeHeroPagerWindow`): at most `pagerMaxVisibleItems` pills (iPhone 7,
  iPad 9, tvOS 10), the current one centred, the outer two shrunk on a side with
  more items beyond. On iOS it is one adjustable accessibility element. The
  pager is an `.overlay` of the hero so it can never size it: as a `ZStack`
  sibling, one pill per item once widened the hero past the screen.
  **tvOS pages natively, through focus.** On tvOS every hero item
  is a full-width page of one horizontal `ScrollView` (`HomeCinematicHero.tvPages`,
  a plain `HStack`: the page focus moves to must exist before it is on screen), and
  every page has its own play button. Left/right is an ordinary focus move to the
  neighbouring page's button; the focus engine scrolls it into view, and
  `HomeHeroTVPaging` snaps that reveal-scroll to whole pages (the proposed rect
  always contains the new button whole and never another page's). Clicks and
  touch-surface swipes are therefore handled like any row of cards, and the pager
  pills follow the scroll offset. Past either end page the engine has no move, so
  the hero's `onMoveCommand` wraps around to the other end by moving focus there
  (`onFocusItem`). That command fires for every move, also after the engine has
  moved focus, and `focusedItemKey` may or may not have caught up yet (both seen
  in the simulator); only a move on an end page that is also at rest on screen
  (`currentHeroIndex`, which follows the scroll) wraps. Rotation is on
  (`autoRotates: true`, the same 7s as iOS) and advances the same way, by moving
  focus to the next page's button, so it is always the engine's own move and
  scroll. It only runs while a play button has focus (`focusedItemKey`): focus in
  the shelves, on the tab bar, in another tab or in the player holds it, and focus
  coming back to a play button, or any left/right move, starts a fresh interval.
  Playback, scene phase, Reduce Motion and the context menu pause it as on iOS.
  This replaced a single
  slide paged by `onMoveCommand`: with nothing focusable left or right of the only
  play button, the engine had no horizontal move to make, and the arc of a sideways
  swipe on a real remote ended as a move down into the shelves, which no gesture
  threshold fixed. Rotation was off on tvOS from 2026-05 to 2026-10 because the
  old single slide tore down the focused button on every advance. On iOS discrete hero moves still use the two-slot slide
  model: mount the incoming slide at its off-screen offset before advancing
  animation progress, and queue overlapping moves behind the in-flight slide.
  Backdrops are decoded off the main thread during prefetch (by
  `IthacaImageLoader`, which prepares every image it returns) so the first frame
  of a page never stalls on a JPEG decode. The prefetched backdrops are held
  outside the image cache's limit (up to 33 MB each at 4K), so while the player
  is up only the page on screen keeps its own (`releaseOffscreenHeroBackdrops`);
  the other pages load nothing behind the player, and the prefetch runs again
  from disk when it closes. Publish
  prefetched artwork as each request completes; waiting for the entire batch lets
  one slow image make other pages pop in late. Extend it carefully; it is stateful
  and timing-sensitive.
- On iPad (regular width) the home hero uses `HomeCinematicHeroLayout.iPad`: it fills
  the scroll viewport down to the bottom inset (`heroHeightFactor: 1`), so at rest only
  the first shelf's header and poster tops peek in below it — that peek is iPad's
  scroll affordance. Portrait is capped at a square (`maxHeightToWidthRatio: 1`) so a
  16:9 backdrop isn't cropped to a sliver. iPhone and compact-width iPad multitasking
  keep `.ios`. `HomeIOSView.heroLayout` makes the choice.
- On tvOS, `HomeCinematicHero` pixel-aligns its render size and caps image dynamic
  range to standard to avoid real-device HDR/SDR seams between the backdrop fade and
  the shelves below.
- **On tvOS the home hero is full-bleed: it occupies the entire display and nothing
  else is on screen at rest.** This replaces the older "leave the first shelf peeking"
  rule — discoverability now comes from an explicit scroll hint plus fold snapping,
  not from a cropped shelf.
  - `HomeCinematicHeroLayout.fillsContainerHeight` (set only by `.tv`) makes the hero
    take the container height verbatim, with no `topInset` addition — the caller has
    already sized the container to the whole display. `HomeTVView` builds that size
    from `fullDisplayWidth` / `fullDisplayHeight`, floored at
    `geometry.size + safeAreaInsets.top + .bottom`. While there is a hero, the scroll
    view itself ignores the top safe area (no top content inset, no negative content
    padding): that is what puts the artwork at screen y = 0, and it makes content y
    equal the scroll offset, which the fold snapping relies on. Keep the explicit
    frame/offset width handling and `.contentMargins(.zero…)` — do not swap either
    for `containerRelativeFrame`.
  - The `.tv` paddings are measured from the real display edges: the text block
    sits just above the pager (124pt of bottom padding; the hint is bottom-centre
    and the block's lowest element is the narrow leading play button, so only the
    pills need clearing), the pager sits at
    60pt overscan + ~18pt so its pills share a baseline with the hint, and the logo
    caps grow to 640×150 for a 1920-wide frame. The backdrop is centre-aligned
    because 16:9 artwork now lands in a 16:9 box.
  - `HomeTVScrollHint` (tvOS-only, defined in `HomeTVView.swift`) is the "More" +
    `chevron.down` affordance, attached as an `.overlay(alignment: .bottom)` on the
    hero **after** the width frame and **before** the x-offset, so it moves with the
    hero and centres on the true screen, and padded 60pt off the bottom. An offset
    only moves what is drawn: attached after it, the hint centred on the un-offset
    frame, one leading safe-area inset (80pt) right of centre (measured). It is decoration: non-focusable, `allowsHitTesting`
    off, `accessibilityHidden`, with a gentle chevron bounce that is skipped under
    Reduce Motion, faded out (0.25s) whenever focus is not on a hero play button,
    and omitted entirely when there is nothing below the hero. Keep it out of
    `HomeCinematicHero`'s pages so it does not scroll away with them.
  - **Hero focus.** `HomeTVView.FocusTarget.heroPrimaryAction(storageKey)` names a
    page's play button. `heroPrimaryKey(in:)` is the focused page while a play button
    has focus, otherwise the page on screen (`visibleHeroKey`, reported by the hero
    from its page scroll through `onVisibleItemChange`). Every other page's button
    is `.disabled` unless a play button has focus, so coming in from the shelves or
    the tab bar lands on the page on screen rather than whichever button is nearest
    a page away. That is not the fencing warned against below: the hero's focus
    section always keeps one enabled item. **Never key that button on a remembered
    page.** It used to be the page last focused, reset to the first page whenever
    Home appeared again (its `.task` reruns after a detail page). With the hero on
    any other page, the only enabled button was then a page or more to the side,
    and up from the shelves did nothing (reproduced in the simulator: down, into an
    item, back, up). A hero reset (`heroSelectionResetRevision`, new hero items)
    sends the page to the start, and a play button that had focus hands it to the
    first page's. New hero items only pull focus up from the shelves when the hero
    was empty before (a late hero) or Home is appearing again with the same items;
    a hero that changes while focus is in the shelves (Mark Watched, a server
    folding in or dropping) leaves it there.
  - **Hero → shelves: the focus engine's move is overruled, never fenced**
    (`HomeTVView.beginHeroExit`). Measured in the tvOS simulator with a replica of
    this screen (SwiftUI hero + rows of lazy `NavigationLink` cards, driven by
    `XCUIRemote`, UIKit focus logged through `UIFocusSystem.didUpdateNotification`):
    - `onMoveCommand(.down)` on the hero fires on **every** down-press, also when
      the engine already moved focus to a card (card focus first, then the
      command). It is not a "no target" fallback.
    - A region with nothing focusable in it — every card `.disabled`, or a lazy
      row with nothing realised yet — is stood in for by a focusable
      `UIKitFocusableFillerItem`. A down-press moves focus into that filler, the
      play button's `@FocusState` drops to nil, and UIKit then re-resolves focus
      on its own. That re-resolution is the "third card" / "fifth row, first
      column" landing. Three rounds of `.disabled` fences (other shelves, then
      other cards, then everything) each fed it. **Never disable shelves or cards
      to steer the focus engine.**
    - The engine's pick is geometric (play button over card 3 → card 3), so a
      pick that does not match the layout is a filler re-resolution.
    So the press is left alone and its result replaced:
    - `beginHeroExit` starts from either the hero's `onMoveCommand(.down)`, or
      from a shelf card taking focus while
      the latch is closed (`CarouselItemFocusedKey`), whichever comes first (the
      simulator shows both orders). It pins the page to the fold (`pinsToFold`)
      and sets `carouselLeadingItemRequest = .focus`
      on `firstShelfID`'s shelf (`.landing`). That shelf's first item takes focus
      through its own `@FocusState` (`carouselLeadingFocusTarget`), after the
      row is rewound so the lazy stack has it. It reports through
      `CarouselLeadingItemFocusedKey`, which opens the latch once; the landing
      stays open 250ms more (a one-shot deadline), and if a further move of the
      same gesture pulls focus off the item in that time, Home asks it again by
      bumping `carouselLeadingFocusGeneration` — Home, not the item, so a request
      Home has just withdrawn (focus went back up to the play button) is never
      answered by a stale re-assertion. If nothing answers within 1.5s focus
      returns to the hero: the page was pinned to the fold throughout, so whatever
      card the engine picked may be off screen. The landing shelf is fixed when
      the exit starts (`heroExitShelf`); Back, a hero focus reset, focus returning
      to the play button, and Home disappearing go through `cancelHeroExit`, and
      `requestHeroPrimaryFocusIfNeeded` suppresses the card-focus trigger while it
      runs (`isReturningToHero`).
    - **Down from the hero is the focus engine's call**, touch-surface moves
      included; there is no gesture gate. The one exception is
      `HomeTVHeroPressGuard`: while Select / Play-Pause is held on a play button,
      or for 300ms after (a thumb rolling on the clickpad as it clicks Play), a
      down move is refused, focus goes back through
      `requestHeroPrimaryFocusIfNeeded`, and `HomeTVFoldSnapping` holds the page at
      the hero meanwhile so it does not dip to the fold and back. The guard is fed
      by `HeroPressObserver`, a never-recognizing recognizer on the **window**:
      recognizers next to the play button never see remote presses (measured in
      the simulator). An earlier catch strip under the play button plus a
      touch-travel/velocity gate (35c8427, f3b2cea) were removed with the move to
      native paging: sideways swipes were the moves they misjudged.
    - `shelvesUnlocked` is **latched**: it means "focus has settled below the
      hero". It drops when focus is back on the play button and stays open while
      there is no hero. It drives `settleFold`, the engine-driven trigger above,
      the landing's re-assertion and the guards in `beginHeroExit` /
      `finishHeroExit`, and the rule that a hero changing under focus in the
      shelves leaves focus there (`.task(id: heroItemIDs)`), so changing when it
      opens or closes changes all of those. Nothing draws from it, so it lives
      in a reference rather than `@State` (opening it mid-landing re-rendered
      Home for nothing).
    - A carousel that can be Home's first shelf must apply
      `carouselLeadingFocusLock(leadingInset:)` to its scroll view,
      `carouselItemFocusLock(isLeadingItem:)` to each item, and
      `carouselLeadingFocusTarget()` (or the binding form, for an item with its
      own `@FocusState`) to each item's focusable view.
      `MediaCarousel` + the poster cards, `ShowAllCarouselTile`, `LiveTVHomeShelf`,
      `ServerOutageNote`'s Retry button and the Pick Something button do. A new
      kind of Home row needs it on its items too, or its cards neither take the
      landing focus nor report `CarouselItemFocusedKey`.
      `firstShelfID` must mirror `shelvesStack(hasHero:)`, including `LiveTVHomeShelf`'s
      "nothing on now" check, `PickSomethingHomeRow.isShown(in:)` and
      `SeerrRequestsHomeRow.isShown(in:)`.
  - **Shelves → hero is the focus engine's own scroll, bent by a
    `ScrollTargetBehavior`** (`HomeTVFoldSnapping`, Apple's fold-snapping pattern
    from the "Creating a tvOS media catalog app in SwiftUI" sample). On tvOS the
    offset the focus engine is about to scroll to when it reveals a newly focused
    item goes through `updateTarget` first. From below the fold, a target short of
    the fold either reveals the whole hero (it would show more than half of it, i.e.
    focus is going back to the low play button) or stays at the fold (the focus
    engine nudging the first shelf). From above the fold every real scroll goes
    to the fold, including a target past it: that target is the engine revealing
    its own pick, which the hero exit replaces with the first card at the fold.
    During a hero exit every target is pinned to the fold (`pinsToFold`).
    Past the fold the same behavior lines shelves up: a move that scrolls puts
    the focused shelf's top at `shelfTopPadding` from the top of the display,
    where the first shelf sits at the fold, instead of the engine's
    just-enough reveal (a short nudge one move, most of a shelf the next, the
    heading cut off going up). Shelves report their frames in the page's
    content coordinates (`homeTVShelfFrame` → `HomeTVPageGeometry`); the focused
    shelf is read from the proposal (going down, the last shelf starting above
    its bottom edge; going up, the first ending below its top edge). A result
    that would reverse the move or go less far than the engine's own target is
    dropped, and the engine's target stands; so does a move that scrolls
    nothing. Only moves that start with the page at rest are lined up
    (`HomeTVPageGeometry.isScrolling`, from `onScrollPhaseChange`): mid-scroll
    the live offset is not where the engine measured from, and a quick down then
    up was read the wrong way round. If a scroll still carries the focused shelf
    mostly off screen, `settleFold` lines that shelf up once the page is still
    (`focusedShelfRealignment`, using the focused shelf each shelf reports
    through `CarouselItemFocusedKey`).
  - **Never add a programmatic scroll on a focus change the engine made.** It
    stacks on top of the engine's reveal scroll instead of replacing it; that threw
    the page several rows past the first shelf. The hero exit used to start with a
    `scrollTo` of its own, on the theory that pinning both to the fold left nothing
    to stack with. Measured per frame in the simulator, it did stack: when the card
    took focus first the curve bent mid-way, and when `onMoveCommand` came first
    the page cut from the hero to the shelves in a single frame (the "jumpy" exit
    on device). The exit now scrolls nothing; the engine's reveal of whichever
    card takes focus is the one scroll, both ways.
  - `settleFold` runs 200ms after the page stops moving, never during a hero exit.
    Latch closed → the page rests on the full hero; open → at or past the fold,
    never on a sliver of hero. Normally it does nothing.
  - The top of the shelf stack is a plain `VStack` on tvOS: with the hero filling
    the screen the first shelf starts exactly at the fold, and an unmaterialised
    lazy stack turns the down-press into a dead end. It holds the fixed rows
    (outage note, Live TV, Pick Something, Your Requests) and the first two content rows
    (`eagerContentRowCount`), so the landing shelf always exists. The content rows
    after that sit in a `LazyVStack`. A row keeps the container it was first
    built in (`eagerContentRowPrefix`), because moving between the two rebuilds
    it, losing its sideways position and any focus in it. So a late server
    adding a row above, or a server dropping out, moves no row across. A new
    row is eager only in the first two places with eager rows above it, and the
    first row is always eager. Every poster card carries `@FocusState`, and
    SwiftUI re-runs every card on the page on each focus change anywhere: with
    every row built, a press on the hero re-ran ~350 cards. Each row coming into
    view loads the posters of the next two rows into the image memory cache
    (`prefetchArtwork(after:in:)`), so a lazy row is built with its artwork
    instead of filling in during the scroll; `HomeTVContentRow.posterURLs` must
    request exactly what the cards request (`PlexItemPosterCarouselSection.imagePixelSize`).
    `shelfTopPadding` is derived from the measured top safe area because it is what
    keeps the first shelf header clear of the floating tab bar at the fold.
  - **Keep Home's update passes few and cheap on tvOS.** On an Apple TV 4K (2nd
    generation) the down-press from the hero used to stall the main thread for
    230–260 ms before the page moved: six `HomeTVView` passes over a ~350-card
    tree, nearly all of it SwiftUI's attribute graph and the focus system rather
    than app code (Time Profiler, 2026-10). Now about 50–70 ms. What keeps it
    there:
    - Values that flip during a move and that nothing draws from live in
      references, not `@State`: `pageGeometry` (offset and shelf frames, read
      live by `HomeTVFoldSnapping`), the `shelvesUnlocked` latch, and the
      scrolled-off-top flag (`HomeScrollPosition`, read only by
      `MainTabView.rootBackAction` when Back is pressed; the shell asks for
      the action per press). As tab-shell `@State` that flag re-rendered every
      tab. Don't pass it down as a get/set `Binding` either: SwiftUI counts such
      a binding as changed on every update and re-runs `HomeTVView` for nothing
      (measured while fixing this).
    - The page's `ScrollPosition` lives in the `HomeTVPageScroll` modifier: the
      focus engine writes it when it starts a scroll, and as `HomeTVView` state
      that re-rendered Home. `settleFold` scrolls through
      `HomeTVPageScrollRequests`.
    - `HomeTVHero` wraps the hero as an Equatable view so Home's passes do not
      rebuild its ten pages. A kept hero keeps that render's closures, so its
      `==` compares every value they captured (focus keys, `LandingInputs`).
  - Unchanged and still load-bearing: both `.focusSection()`s, the focus
    scope / `defaultFocus` / `requestHeroPrimaryFocusIfNeeded` dance.
  - `HomeViewModel.heroItems()` caps the rotation at 10 items **on tvOS only**, since
    every backdrop is now fetched and decoded at the display resolution (3840×2160
    pixels at 4K output) and the whole set is prefetched eagerly. iOS keeps the unbounded list.
- On iOS the home hero play button uses `homeHeroNativeButtonStyle()` (prominent,
  `Color.primary`-tinted Liquid Glass that contrasts the artwork) with
  `HomeHeroActionButtonLabel(fillsWidth: true)`, sized as a wide, short pill
  (≈240pt iPhone / ≈300pt iPad). Keep it consistent with the detail primary button
  (`STYLE.md` §3.3); never a coloured fill.
- `HomeIOSView` and `HomeTVView` should stay composition shells. Keep Plex data rules in
  `HomeViewModel`, not in platform views.
- Use `HomeItemContextMenu` for hero context actions. It already exposes mark watched,
  details, season, and show routes when available (on tvOS `contextMenuSeasonRoute` /
  `contextMenuShowRoute` are nil, because the details route already opens the one
  show page). Its optional
  `onRemoveFromContinueWatching` adds Plex's "Remove from Continue Watching" action
  (server `PUT /actions/removeFromContinueWatching`); the hero supplies it because its
  items are always the Continue Watching hub. `HomeViewModel.removeFromContinueWatching`
  drops the item optimistically, then reloads to reconcile.
- `HomeHubItemsView` is the full "show all" grid for hub contents. It has its own small
  view model and uses the shared poster grid; all-clip hubs render it 16:9. It pages
  every contributing source (50 per source per page, a cursor per source) through
  `PlexService.hubItemsPages`, interleaves each batch with `PlexItemMerge.interleave`,
  and appends what the grid does not already show; a source that returns other than
  the page size asked is exhausted. A failed source contributes nothing and is asked
  again with the next page. The Retry error UI appears only when every source fails on
  the first page; a later page shows the load-more retry when a source failed and
  nothing new arrived.

### Pick Something

- `Features/PickSomething/`: three titles that fit the filters, and "Pick Again".
  Reached from the Home row (`PickSomethingHomeRow`, plain Liquid Glass, hidden
  without a movie or TV library) and from Siri (`docs/siri.md`). Route:
  `AppNavigationRoute.pickSomething(kind)`, pushed on the Home stack, so a pick
  opens its detail page on the same stack.
- Filters (`PickSomethingCriteria`): Movies or TV Shows (only kinds with a library),
  length (movie running time; a show's typical episode length), genre (the union of
  the kind's libraries' genres, matched per library by normalized title), and
  Unwatched (on by default). Changing any filter or who's watching starts a fresh
  sample; old picks stay on screen, dimmed, until the new ones arrive. The chips
  are the shared `FilterMenuChipLabel` / `FilterToggleChip` (`Shared/FilterChips.swift`),
  the same ones as the library grid.
- `PickSomethingEngine` samples each library of the kind on every connected
  server: the whole library when it has at most 150 matches, otherwise two random
  50-item windows of the filtered list. Results are de-duplicated by
  `RecommendationSeenTitles` (one title on two servers is one pick; every copy is
  registered with `registerAlternates`, so Seen It and playback fallback reach the
  dropped ones), checked with
  `PickSomethingCriteria.matches` (Plex ignores a filter it does not know, and a
  show's unwatched filter keeps part-watched shows), and shuffled. One library
  failing never sinks a pick; all failing shows the error.
- Unwatched means never started: no plays and no position for a movie, no watched
  episode for a show. Half-watched titles belong to Continue Watching.
- "Pick Again" takes the next three from the queue, refilling it with new samples
  (an empty random window is not the end; only libraries read whole are). When
  fewer than three new titles are left it starts over for the rest, leaving out the
  cards on screen, and says so. The button stays enabled while picking (presses are
  ignored) so tvOS focus stays on it. The avatar buttons do the same while a member
  joins (a spinner badge, no `.disabled`), and the tvOS cards are keyed by slot, so
  focus stays put when a card is swapped.
  "Seen It" (context menu) marks the title watched on every server and swaps that
  card. Replacements run one at a time and never place a title that is already on
  screen. Leaving the screen cancels any pick under way (`stop()`).
- Describe It (Ithaca Pro, `IthacaStore.hasPro`; without it the row opens
  `ProSheet`): a text field above the chips; on tvOS, Select opens the system
  keyboard with dictation. A submitted description makes every pick come from it
  until the text is cleared (tvOS: Clear). `DescribeItPicker` sends it to Athena
  when one is set up and the viewer said yes (`UserPreferences.athenaConsent`,
  asked in an alert before the first request because the text and titles go on
  to Anthropic, App Review guideline 5.1.2(i); Settings → Athena turns it off),
  and otherwise answers on the device, with or without Athena.
- On the device: Apple's on-device model (`DescribeItAppleModel`, iOS 26 and
  later with Apple Intelligence; never tvOS, whose SDK has no Foundation Models)
  reads the request into a `DescribeItQuery` (the library's own genre names,
  subject words, cast and directors, "like <title>", years, length, minimum
  scores, for children or not), and `DescribeItPhrases`, a fixed word and phrase
  list, reads it too; the list's numbers win, and alone it covers Apple TV and
  devices without the model. Both readings are kept per text for the screen's
  life. `DescribeItRanker` then drops what breaks a hard limit (a ruled-out
  genre, years, length, a children's request on a title rated for adults, a
  minimum score, which needs a known score) and ranks the rest on genre, subject
  words in the title and summary, cast and directors, likeness to a named title,
  reviews and the viewer's genre taste, with a little randomness so the same
  text varies. A pick only carries a reason for a cast, director or "like"
  match; otherwise the summary shows. Words the list doesn't know ("sharks")
  decide only when nothing else in the request does. The listing's summaries,
  directors and top three cast come from `getTasteLibraryItems`.
- With Athena (`PickSomethingAthena.swift`; the server is `inceptyon-labs/athena`: Jev
  for library picks, in about a quarter of a second, and Claude Haiku for
  suggestions): Ithaca sends the description, the profile's taste
  (`TasteRecommender.catalog` seeds: loved, liked, not for me, watched lately) and
  every title of the kind that fits the chips (`PickSomethingAthenaOptions`): one
  entry per title (the highest-priority copy), Unwatched judged across every copy.
  Listings carry only two genres per title, so the Genre chip asks each library
  for its members with Plex's own genre filter (`PickSomethingEngine.genreMemberIDs`,
  kept per genre for the screen's life). Ids are positions in a title-sorted list,
  so the same filters send the same list and Athena's prompt cache is reused.
  Titles without a TMDB guid are not in the catalog. Each title carries its
  review scores (`ReviewScores(item:)`: Rotten Tomatoes critics and audience,
  IMDb or TMDB, whichever sources Plex's agent lists), so a request like "over 8
  on Rotten Tomatoes" can be judged. Values are clamped to Athena's limits (5,000
  titles, a 500-character description), because one value over them rejects the
  whole request.
- Athena answers up to nine ids, best fit first (not shuffled). Claude's picks
  each carry a one-line reason; Jev's carry an empty one, which shows as none
  (the summary on iOS). They fill the queue like a sample, so Pick Again shows the next
  three without asking again; a refill asks again with what was shown excluded,
  at most twice per pick. When Pick Again runs out it starts over on Athena's
  earlier picks rather than ask Claude the same question. The room check and Seen
  It work as for random picks; Seen It bumps `tasteRevision`, so the catalog is
  read again before the next request. The reason shows under each tvOS card and
  in place of the summary on iOS. The same text submitted again only retries after
  an error, and without Ithaca Pro the picks are random again.
  Athena also returns any minimum rating the request set (`AthenaMinimums`); a
  pick whose listed score falls below it is dropped, because Claude sometimes
  fills the count with one. Cards show the Rotten Tomatoes critics score (else
  IMDb) after the running time.
- To Request (Describe It with Seerr connected and allowed to request the kind):
  a row below Pick Again of up to six titles outside the library, each opening
  its Seerr request page. On the device, `DescribeItRanker` ranks Seerr's recent
  list (below) against the same reading, and the cards show the overview. With
  Athena, a second request goes out beside the picks
  (`count: 0`, eight suggestions asked for), so the picks never wait for it:
  Haiku thinks before it answers, and either request takes 5 to 12 seconds. It
  sends the library with watched titles too (so nothing owned is suggested), the
  taste, the chips' length and genre as text, and
  Seerr's trending and past-year popular titles of the kind
  (`PickSomethingRequestFinder.feed`: two pages each, released, unrequested and
  not on any server, at most 60, kept per kind for the screen's life when every
  page arrived, and read again after a request is sent), because Haiku doesn't
  know the newest releases. A suggestion from that list comes back by its id,
  used only when that entry's title is the one named; any other is searched on
  Seerr by name and kept only for the same kind and title, in its year or one
  either side (`match`). Owned, requested and unreleased titles are dropped,
  Seerr's Rotten Tomatoes and IMDb scores are read for the rest
  (`SeerrService.reviewScores`), and a known score below the minimum drops it.
  A new request, kind, length or genre starts the row over; who's watching,
  Unwatched and Pick Again leave it. Submitting the same text after the row
  failed asks again without touching the picks, and so does coming back after
  leaving mid-search. Back from a request sent elsewhere (a card's page), the
  cards are read again and the requested ones drop out
  (`PickSomethingRequestFinder.stillRequestable`). Suggestions skip the room
  check, as Discover does.
- Who's watching (Plex Home only): the active profile is always in; other members'
  avatars join and leave. A protected member asks for their PIN first
  (`TVHomeUserPINView` / `IOSHomeUserPINView`, shared with the profile picker).
  With others watching, a title must be visible to every one of them (no library
  access or a content restriction rules it out for the room) and, with Unwatched on,
  unseen by all of them. A title ruled out only because a member cannot see it on its server (no
  token, no library access, a failed check) is retried on its copies on other
  servers in one more batched round, and the copy that works for the room is the
  one shown; a member who has watched it on any copy still rules it out. Otherwise a
  member's check that fails on one server rules out that server's candidates for
  the round; only every check failing is an error. The
  checks (member by server, up to 40 titles each) run concurrently. Their
  tokens live only in the view model
  (`PlexHomeViewerAccess`, `docs/data-and-plex.md`). The selection is not
  remembered: each visit starts with just the active profile.
- tvOS: header, a row of chips with the Watching avatars on the right, three 280pt
  poster cards and the Pick Again button. iOS/iPadOS: the chips scroll
  horizontally, and each pick is a row with poster, facts, genres and summary.
- The screen reloads its libraries on `serverContentRevision` and when
  `pool.isConnecting` settles, because Siri can open it before any server answers
  and a server can connect after the first pick. Once loaded, a changed set of
  libraries is picked up without touching the picks on screen. Genres load after
  the first pick starts (the Genre chip appears when they arrive). With no server
  connected the screen shows the error state with Retry, not "No Movies or TV
  Shows". A newer or cancelled load changes nothing.

### Server Priority

- `Settings › Navigation › Server Priority` opens `ServerPrioritySettingsView` on
  every platform. It answers two questions and nothing else: in which order the
  servers rank, and which of them Ithaca uses at all.
- Each row shows the server name, its ownership ("Your server" / "Shared by X"),
  and its live status from `pool.state(for:)` — Local, Remote, Relay, Connecting…,
  Offline, Not authorized, Disabled. The words come from `ServerStatusText` so the
  rest of the app says the same thing.
- Every edit is written immediately through `ServerPriorityStore`; there is no
  save step and nothing to lose by leaving. Enabling a server reconnects it
  straight away (the row reads "Connecting…" until it resolves); disabling calls
  `pool.markDisabled`, which drops the session so the rest of the app forgets that
  server. Both bump `serverPriority.revision`, which Home, Libraries, and Search
  observe to reload.
- "Check Again" re-runs the whole connect pass through
  `ServerConnectionCoordinator.refresh()` — use it after bringing a server online
  or accepting a new share.
- Disabling the last enabled server is allowed but never silent: the screen shows
  what it costs ("Ithaca has nothing to show; downloads still play"). Do not replace
  this with a blocking alert — the user may be deliberately going offline-only.
- A single-server account sees a plain one-row screen: no reorder affordances, no
  talk of priority. Ordering language only appears once there are two servers.
- iOS/iPadOS use `EditButton` + `onMove` plus a per-row toggle; tvOS gives each
  server its own section with a position menu and a "Use This Server" toggle. The
  same tvOS rule as Library Order applies: **no focus-driven drag**.
- The visible rows are not the stored list — a server that has gone missing keeps
  its slot in `ServerPriorityStore`. Reordering therefore goes through
  `reorder(visible:)`, which re-applies the new order to the visible slots only.

### Library Order

- `Settings › Navigation › Library Order` opens `LibraryOrderSettingsView` on every
  platform. It edits the order of *your* libraries across every enabled server,
  which is an
  account-level Plex setting rather than a Ithaca preference: the same order drives the
  Plex Web sidebar and the other Plex apps signed in as this user.
- A row carries its server name only when another library of the same type has the
  same title. The server name disambiguates; it is never decoration.
- The screen lists **every** section, music and photo included, even
  though Ithaca cannot browse those. They occupy slots in the account's order, so
  omitting them would silently move them when the list is written back.
- iOS/iPadOS use native list editing (`EditButton` + `onMove`). tvOS uses a position
  menu per row (`TVSettingsMenuRow`), the same pattern as Navigation Tabs, with
  formatted ordinal labels so the list is not capped at a handful of names.
  **The previous focus-driven pick-up (the old Home layout editor) was removed and
  must not come back.** It was unusable on a real remote: directional commands only
  reach an `onMoveCommand` handler when the focus engine finds no candidate, and the
  tvOS tab bar sits above this screen, so a row moved down but not up.
- Writes are debounced 1s and coalesced, so walking a library through six slots is one
  account write, not six. `onDisappear` flushes a debounce that is still counting down.
- The screen loads once. tvOS re-runs the view's `.task` after every option-list pop, so
  the load is skipped once `libraries` is filled, and `load()` never overwrites the list
  while an edit is pending or a write is in flight. A successful last write re-syncs the
  list to `PlexService.libraryOrder.orderedSections`.
- A failed write reverts the list to `PlexService.libraryOrder.orderedSections` and
  shows an inline message; showing the rejected order would lie about what the other
  Plex apps will do. A failed load shows `FeatureErrorView` with Retry.
- The order is read and written through `PlexService`; the view model never talks to
  plex.tv itself. Entries for disabled servers, cloud providers, and servers whose
  sections failed to load are carried through untouched — never write an order for a
  server Ithaca could not read. Storage format and traps: `docs/data-and-plex.md`.
- Clips never enter the cinematic hero rotation (`HomeViewModel.heroItems()` filters
  `isClip` — frame grabs read poorly full-bleed). They stay visible in hub rows, where
  an all-clip hub (`isVideoHub`) renders as a 16:9 carousel.

## tvOS Top Shelf

- The `IthacaTopShelf` app extension (tvOS only, bundle id
  `com.inceptyon.ithaca.topshelf`) shows Continue Watching in the Top Shelf when
  Ithaca sits in the Home Screen's top row: sectioned content, 16:9 tiles, one
  "Continue Watching" section that is Home's merged list as-is (started items
  with progress and next episodes mixed, `ContinueWatchingMerge` order), at
  most 10 items. No separate "Up Next" section; the app never splits them.
- **The extension never talks to Plex.** `TopShelfPublisher`
  (`Ithaca/Sources/TopShelf/`) is called from `HomeViewModel.publish` on every
  Continue Watching publish; it caches each tile's artwork with the app's own
  session and writes `TopShelfSnapshot` (titles, artwork file names, deep links)
  into the App Group `group.com.inceptyon.ithaca`, then calls
  `TVTopShelfContentProvider.topShelfContentDidChange()`. The extension only
  reads that snapshot (`TopShelfSnapshot.swift` is compiled into both). No
  snapshot → the static Top Shelf image.
- `PlexService.tearDownServerSessions` clears the snapshot (sign-out, Plex Home
  switch): the shelf must never show another identity's items. In a Plex Home
  with Automatically Sign In off, the next person at the TV picks a profile, so
  nothing is published and the snapshot is cleared whenever the app goes to the
  background (`TopShelfPublisher.isAllowed`).
- Deep links: `ithaca://play?server=…&item=…&type=…&profile=…[&clip=1]`
  resumes, `ithaca://open?…` opens the detail page on Home. Any app can open
  `ithaca://`, so `item` must be ASCII digits (it goes into a server request
  path). `IthacaApp` hands the URL to `TopShelfLinkRouter`; `MainTabView` acts
  on it once the item's server is connected (a cold launch delivers it first),
  drops it after 30 s, and drops it when `profile` is not the active profile.
  Play re-reads the server's `viewOffset` instead of trusting the snapshot.
- iOS is untouched: everything is `#if os(tvOS)`, the URL scheme is only in
  `Info-tvOS.plist`, and only the tvOS app uses `Ithaca-tvOS.entitlements` (App
  Group added); iOS keeps `Ithaca.entitlements`.

## Libraries

- `LibrariesViewModel` groups Plex libraries by `PlexLibraryType`. Its `libraries`
  reads through `PlexService.libraryOrder.orderedSections`, which now spans **every
  connected server** in the account's cross-server order, not raw `/library/sections`
  order. Libraries are never merged into virtual ones: two servers' "Movies" sections
  hold different files and page independently, so they stay two rows.
- A library shows its server name **only** when another library of the same type has
  the same title (`ServerLabeling`, shared with the Library Order settings screen). A
  single-server account never sees one.
- `MainTabView` reuses a single `LibrariesViewModel` to decide tabs and feed library
  screens, and reloads it on `plexService.serverContentRevision` because the available
  tabs derive from the merged library list. Avoid each tab independently discovering
  libraries.
- `LibrariesView` is the direct Movies/Shows/Videos tab wrapper. The tab always lands
  on `LibraryRecommendationsView` for **all** libraries of that type; with more than
  one, a "Libraries" toolbar link opens `LibraryTypeListView` (the list of them). With
  exactly one library it is the screen it has always been. (The old combined
  `LibrariesHubView` tab is retired; every type gets its own tab.)
- `LibraryRecommendationsViewModel` takes `libraries: [PlexLibrary]` and is the
  library-scoped home equivalent: `getLibraryHubs(...)` per library (fanned out, each
  routed to its own server), `HubMerge` across them, continue-watching hub extraction,
  recently-added expansion, and personalized shelves from `LibraryRecommendationEngine`
  merged per genre (`LibraryRecommendationLoadResult.merging`). A merged personalized
  row has no "Show All" because no single library list is behind it.
- A failing server never blanks the others: the sections load commits per server and
  only throws when every server failed.
- `.video` libraries never run the genre engine. Their shelves come from
  `LibraryVideoShelfLoader`: per-channel rows (first ~6 collections via
  `getLibraryCollections`, items sorted by release date) and a day-seeded
  "Rediscover" row of unwatched items. Row order: Continue Watching, prioritized
  hubs, secondary hubs, channel rows, Rediscover — all 16:9.
- `LibraryItemsView` is the browse grid for a concrete library, genre, or collection
  route; `.video` libraries use the 16:9 grid metrics.
- `LibraryItemsViewModel` handles pagination, sort, genre selection, optional local
  genre filtering, and optional collection scoping (`LibraryCollectionItemsView`
  delegates to it). A shelf's "Show All" genre is a tag name, so the
  model swaps it for the library's real genre filter id when the library lists that genre
  and lets Plex filter; only an unlisted genre is matched locally (detail lookups 8 at a
  time, scan progress kept across "load more"). A failed "load more" keeps the grid, keeps
  `hasMoreItems`, and shows an inline Retry. Sort options are per-kind via `LibrarySortOption.options(for:)`;
  video libraries default to Release Date (newest).
- Use `LibraryGenreSupport` for Plex genre filter discovery, normalization, URL
  parameter extraction, and fallback matching. Do not compare genre strings ad hoc.
- The grid's **Unwatched** chip (between Genre and Sort) is a one-tap filter, remembered
  per library (`LibraryUnwatchedFilterStore`, keyed on `PlexLibrary.id`) and applied to
  that library's genre and collection grids too. `LibraryUnwatchedFilter` sends
  `unwatched=1` for movie/video sections (in-progress titles stay) and
  `unwatchedLeaves=1` for shows (listed while any episode is unwatched). Active = inverted
  `TextPrimary` fill with a filled checkmark (STYLE.md selected treatment).
- `LibraryItemsViewModel` uses a `queryGeneration` guard so stale async page loads do
  not mutate current results. Preserve this pattern when adding filters.
- Library and "show all" grids refresh whenever they reappear (back from a detail
  page or the player) and when the app becomes active. Both refresh
  through `refreshLoadedItems`, which keeps their length and scroll position and is
  capped: the library grid re-fetches a three-page window around the last card that
  appeared (the item just opened) and replaces changed items in place, and the show-all
  grid does the same once a source is past three pages (smaller grids re-fetch each
  source up to its offset). Nothing is published when the window is unchanged. Mark
  Watched uses the same refresh.
- Infinite scroll is triggered from `PlexItemPosterGrid.onItemAppear`; keep pagination
  logic in the view model.

## Detail Screens

- Detail entry is split by domain: movie, show, season, episode, video (clip), and
  actor detail views each have their own `@Observable` model. tvOS is the exception
  for TV content: it has no separate show/season/episode screens. `MediaDetailDestinationView`
  sends all three routes to `SeriesDetailView`, and `ShowDetailView`, `SeasonDetailView`,
  `EpisodeDetailView` (+ its model) are compiled out of tvOS (`#if !os(tvOS)`).
- Clips route to `VideoDetailView` via `.video`/`.downloadedVideo` routes
  (`AppNavigationRoute.destination(for:)` branches on `item.isClip`) — never to
  `MovieDetailView`. It is a trimmed movie page: hero metadata line is
  "channel · upload date · duration", no cast/ratings sections, plus a
  "More from {channel}" 16:9 row resolved from the item's first Collection tag.
- Detail views own screen layout; detail view models own Plex fetches, offline fallback,
  watch-state mutations, image URL selection, and computed display state.
- Movie and Show pages (on tvOS, the series page, which rates the show) end the
  hero's action row with `TasteRatingMenu`: Loved It, Liked It, Not for Me, and
  Clear Rating once rated. Choosing the current answer clears it. The model's
  `rate(_:)` shows the answer at once (`PendingTasteRating`), writes it with
  `setRatingAcrossServers` and re-reads the details. A failure is an action
  alert. Plex's own 3-star rating reads as unrated here.
- Detail pages never open on a bare spinner when the app already knows the item:
  - `AppNavigationRoute.destination(for:)` remembers the card's `PlexItem` in
    `DetailSeeds`. Every detail page draws `DetailSeedHero` from it (art, clear logo,
    title, summary, year · rating · duration, and the show title above a season or
    episode) until `details` arrive; the tvOS series page draws its banner the same
    way. Routes built from a `PlexSeason`/`PlexEpisode` (the iOS show page's season
    grid, the season page's episode rows, the Go to Season/Episode menu links) go
    through `detailRoute(season:)` / `detailRoute(episode:)`, which seed the row
    first (`DetailSeeds.remember(_:)` re-decodes it as a `PlexItem`), so Show →
    Season → Episode draws its hero at once. The seed hero uses the loaded hero's geometry
    and the model's own artwork URL builders, so the backdrop request is the one
    the page makes and is cached when it appears.
  - Every detail model's first load starts from this profile's metadata of the last
    5 minutes (`PlexService.recentMediaDetails`, `recentSeasons`, `recentEpisodes`)
    before the offline cache, then revalidates. The tvOS series page goes further:
    a show or season whose details and children are all recent goes on screen with
    no request (`seedFromRecent()`) and refreshes in place, so reopening a show or
    switching back to a season is instant. Any timeline report, scrobble or Continue
    Watching removal clears these caches (`invalidateRecentMetadata()`), so a cached
    resume point is never one the app has since moved; a revalidation that fails
    falls back to the offline rules. A movie or video page drawn from recent
    metadata whose revalidation fails keeps it only when the item is downloaded;
    otherwise it falls back like a first load (the download-time copy, else the
    error with Retry), so tvOS never shows a page with a dead Play button.
  - Play and version menus still need `details.media`, so the seed hero shows a
    progress indicator in the action row.
- Shared detail UI lives in `DetailSharedViews.swift` only when reused across detail
  screens.
- Use `DetailHeroSection` for cinematic detail headers. It owns the backdrop
  gradient/scrim, title artwork, supertitle/subtitle/action slots, an optional
  `descriptionText`, and safe-area offset. There is **no poster on any platform**:
  iPhone centers one column (title, metadata, actions); iPad uses two columns
  (left: title + actions, right: marker/metadata + `descriptionText`); tvOS is a
  left-aligned column with the action row beneath. Use
  `detailHeroContentAlignment(for:)` / `detailHeroTextAlignment(for:)` to center
  hero text on iPhone, and `detailShowsSynopsisBelowHero(for:)` to drop the
  below-hero synopsis section on iPad (the hero's right column shows it there).
- Detail hero actions share one button system across all platforms (see
  `STYLE.md` §3.3). The primary uses `detailHeroNativePrimaryButtonStyle()` —
  prominent, `Color.primary`-tinted Liquid Glass for contrast (dark-on-light /
  light-on-dark) with a `Color.ithacaPrimaryActionLabel` label; on Show/Season it
  reads just "Play" / "Resume" (`playButtonShortLabel`), never the target episode.
  Secondary actions (download, watched, go-to-show/season) are **icon-only**
  everywhere via `DetailHeroSecondaryIconLabel` + `detailHeroNativeSecondaryButtonStyle()`
  with an `.accessibilityLabel` (capsule pills on iOS, circles on tvOS). On iOS wrap
  the action block in `detailHeroActionStackFrame(isCompactPhone:)` (iPhone ≈60%
  centered, iPad fills the hero's left column); tvOS lays the icons out to the right
  of the primary. Movie/Show/Season/Episode all expose a watched toggle; Show/Season
  toggle the whole show/season. Never fill or tint primary actions with a colour.
- On tvOS, keep focusable detail rows in separate `.focusSection()` groups. Hero
  actions, expandable summaries, season/episode grids, and cast shelves should move
  vertically to the next visible row instead of letting the focus engine skip to a
  lower but more horizontally aligned item.
- Detail screens use hidden inline navigation bars over hero artwork. Keep
  `.toolbarColorScheme(.dark, for: .navigationBar)` and hidden toolbar backgrounds unless
  the screen is no longer hero-led.
- Detail screens refresh after player dismissal and scene activation to pick up watch
  progress. The dismissal refresh first awaits `PlaybackCoordinator.awaitFinalWrites()`,
  so it never reads the item before the final stopped timeline and scrobble land.
  The iOS show and season pages also reload when they reappear after a watch-state
  write since their last load (a child page's Mark Watched): `load()` compares the
  recent-metadata cache generation, which every write moves, with the one the last
  load started from.
- Movie and show pages (iOS `MovieDetailView`/`ShowDetailView`, tvOS
  `MovieDetailView`/`SeriesDetailView`) show an "Extras" row (`DetailExtrasSection`,
  16:9 cards) when Plex has trailers, featurettes, deleted scenes and the like.
  The models load them in the background after each successful refresh until one
  load succeeds (`startExtrasLoad()`), so they never hold up the page and a Retry
  or offline data coming back online picks them up; never from offline data. Selecting one plays it from the start on its own server
  (`playFromStart(restrictToItemServer: true)`); extras have no cross-server copies.
- tvOS trailer previews (`TrailerPreview.swift`): after 4 seconds on a movie or
  show page, the main trailer (`previewTrailer`) fades in, muted, over the hero
  backdrop and under its scrim (`DetailHeroSection(backdropAccessory:)`), and fades
  back to the artwork when it ends. `TrailerPreviewGate` stops it as soon as the
  page leaves the screen, the hero scrolls out of view, the app goes inactive, a
  playback session (or Picture in Picture) exists, Settings → Trailer Previews is
  off, or the system's Auto-Play Video Previews setting is off. On the show page
  it also stops for the rest of the visit once the viewer moves along the episode
  row or picks another season, since the banner then follows their episodes.
  The movie page also holds it while the Download Subtitles cover is up (the page
  stays on screen under a full-screen cover). Direct play when AVPlayer can open the
  file; otherwise the AirPlay-safe Plex HLS (stopped on teardown), but only for
  H.264 video, which the server copies: that route has no bitrate or resolution
  cap, so any other codec would be a full re-encode. No preview runs when the
  trailer's server is reached over the WAN or Plex Relay (unknown locality counts
  as local), or while another app is playing audio: starting the item would
  activate tvOS's non-mixable `.playback` session even muted and stop that music.
  Previews never report timelines or touch watch state. The video sits inside the
  hero's bottom-fade mask, so Core Animation redoes the masked group every video
  frame. To keep that pass small, the backdrop image stops drawing while the
  faded-in video covers it (`coversBackdrop`, `DetailHeroSection.backdropHidden`),
  and the title logo is flattened with its shadow (`drawingGroup`). The video
  can't leave the mask: masking it and the scrim separately darkens the fade band
  behind the title less, and a fill instead of the mask brings back the HDR seam.
- `MovieDetailViewModel` handles movie metadata, media info, resume position, watched
  state, and offline movie metadata banners.
- `ShowDetailViewModel` loads show details, seasons, next-episode metadata, season
  availability badges, and show-level offline messaging.
- `SeasonDetailViewModel` loads season details and episodes, computes the next episode,
  sorts offline-available episodes first when appropriate, and records offline watch
  mutations.
- `SeriesDetailView` (tvOS only) is the one page per show. `SeriesDetailViewModel`
  composes a `ShowDetailViewModel` (seasons, Seerr gaps, show watch state) with a
  `SeasonDetailViewModel` for the season on screen; it does not re-implement either.
  The route decides where it opens: a show opens on its first regular season with
  something unwatched (Specials only when nothing else exists), a season on itself,
  and an episode on its season with that episode in the banner and the row scrolled
  to it. The entry episode holds the banner only until playback ends
  (`playbackDidEnd()`); after that the page follows the season's next-up episode
  like a show route, and when that playback finished the season on screen (Up Next
  went on), it opens the next season with something left to watch. Scene
  activation keeps the entry episode. For season/episode routes the season paints first and the show (pills)
  loads after it; the pills share a fixed-height slot with the plain "Episodes"
  header so the row never jumps. Season pills sit above the horizontal episode row
  (only when there are 2+ seasons); picking one loads that season and swaps it in
  only once loaded (the row dims meanwhile), so the page never blanks. A Seerr-only
  season pill opens its request page. Hero buttons and season pills are system
  `.glass` with no tint (the selected season is
  bold and full-opacity, the rest dimmed, so it never looks focused), and
  progress bars are neutral. Each episode card shows the title with a
  "Season X · Episode N" subtitle plus a quiet watched checkmark
  (`PosterCardText`); the
  hero's clear-logo title, focused-episode name/metadata/summary, backdrop, and the
  "Episode Cast" row follow the focused card inside stable-height regions, with the
  focus commit debounced so rapid remote navigation does not shift the scroll
  position. The committed episode lives in an `@Observable` holder
  (`SeriesEpisodeFocus`) that only the banner and the cast row read, each inside an
  `EpisodeFocusScope`, so a settled focus (and the episode details landing after it)
  re-renders those two and not the page, its pills or its episode row. Keep reads of
  the focused episode and `focusedEpisodeDetails` inside those scopes.
  `SeriesEpisodeCard` mirrors its focus with `FocusMirror` and is Equatable on its
  values (its closures look the season up when called), so a page pass skips
  unchanged cards. Selecting a card, or the hero Play/Resume, plays the focused episode;
  the eye button toggles the season on screen. The row is only scrolled
  programmatically when the season changes — never on focus or next-up changes.
- `SeasonDetailView` (iOS/iPadOS) keeps the vertical episode list with per-episode
  detail navigation.
- `EpisodeDetailViewModel` (iOS/iPadOS) handles single-episode metadata, parent
  show/season links, watch toggles, and offline availability.
- `ActorDetailViewModel` loads a person and filmography from Plex's
  `/library/people/{id}` and `/library/people/{id}/media`, fetched concurrently. Only a
  credit with no person id falls back to searching Plex for exact role matches; keep that
  search local to actor detail.
- Use `PlayVersionContextMenu` for alternate media versions; it filters out unplayable
  versions with no parts.
- "Download Subtitles" (Plex-proxied OpenSubtitles) is a secondary action on movie,
  episode (iOS/iPadOS only — tvOS has no episode page; the player covers it), and
  video detail. iOS/iPadOS put it in the Play button's `.contextMenu`
  next to Play Version; tvOS gets a `captions.bubble` icon button in the hero action
  row, because context menus are awkward there. It is gated on
  `<Model>.canDownloadSubtitles` — `PlexService.canDownloadSubtitles(serverID:)` (owner of
  *that item's* server,
  non-restricted Home user; anything else would 403) plus a real playable part and
  no cached/offline metadata. The detail models own the flow
  (`makeSubtitleSearchViewModel(preferredLanguageCode:)`), so the views never touch
  `PlexService`; a successful install re-reads the item so the new stream shows up in
  media info, and the next playback session mounts it. Presentation goes through
  `detailSubtitleSearchPresentation(isPresented:viewModel:)` (sheet on iOS, full-screen
  cover on tvOS).
- Use `DownloadActionButton` and `DownloadContextMenuContent` from the downloads
  feature for download actions. Do not duplicate download state UI in detail screens.
- Offline-capable detail models may show cached metadata before network refresh. Preserve
  `isUsingCachedData`, offline-fallback state, `offlineStateVersion`, and
  `OfflinePlaybackSyncManager` checks when changing watched/progress behavior.
  Mark Watched on a downloaded item takes the offline-record path only when the page
  shows cached data or the item's server has no connection; online it uses the
  cross-server write and re-reads the details like any other item.
- Some show/season loading is intentionally sequential to avoid async-let runtime aborts
  during transient context-menu navigation lifetimes. Do not "optimize" it back to
  `async let` without reproducing that scenario.

## Live TV

- `MainTabView` owns one shared `LiveTVViewModel` for availability, the tab,
  `MoreView`, and the Home shelf. Do not discover providers independently per
  surface.
- `LiveTVView` offers yesterday through seven days ahead, channel/program
  artwork, current-program progress, schedule details, and Watch actions only
  for currently airing programs. Past entries remain inspectable but are not
  presented as recordings.
- The player gear menu exposes channel switching on iOS/iPadOS and tvOS. The
  live seek bar shows LIVE or the time behind live and provides Go Live; all
  forward movement is clamped to the HLS edge.

## Search And Settings

- `SearchView` is a thin tab-root wrapper (`NavigationStack` + destinations) around
  `SearchRootContent`, which owns the view model, searchable field, and results; the
  split lets iPhone/iPad toolbar actions push Search without a nested stack.
  Settings and Downloads follow the same wrapper/`*RootContent` pattern.
  All-clip result groups render 16:9.
- Search is debounced in the view model with a cancellable `Task`; views only bind the
  query and render grouped results.
- Search is **fanned out to every connected server** (`PlexService.streamSearch`) and the
  merged groups are republished as each server answers (`SearchMerge`), so results stream
  in instead of waiting for the slowest server. Groups are matched on their type, items
  deduplicated by content key and round-robin interleaved in priority order, and the
  copies registered in `plexService.alternates`. It is an error **only** when every
  server failed and there is nothing to show; one unreachable server shows
  `ServerOutageNote` above the results. A server connecting or dropping re-runs the
  current query (`.task(id: serverContentRevision)` → `rerunIfServersChanged()`).
  That task also runs whenever Search reappears (Back from a result, the tvOS tab),
  so the view model re-runs only when the revision differs from the one the results
  came from. A re-run of the query on screen publishes once, after every server has
  answered, and keeps the previous Seerr cards until Seerr answers: streaming partial
  merges would pull slower servers' hits and the Seerr cards out from under focus.
- Poster sizes go to `SearchViewModel.imageURL` in points, the same size
  `PlexItemPosterCarouselSection` requests, so Search and Home share cache entries.
  Seerr's TMDB size bucket is picked from the display-scaled pixel width.
- `SearchMediaResult.id` carries the server (`PlexItemID.storageKey`): merged results can
  hold the same rating key twice, and duplicate `ForEach` ids drop rows.
- When Seerr is connected, search also performs an additive Seerr discovery
  request. Plex groups publish first; external movies/shows are deduplicated and
  appended with request-state badges. A Seerr failure stays silent and never
  breaks Plex search.
- Presentation is platform-adaptive so search feels native everywhere. tvOS and iPad
  (`userInterfaceIdiom == .pad`) render each result group as a
  `PlexItemPosterCarouselSection` (the same poster carousels Home uses for hubs); iPhone
  renders each group as a titled `PlexItemPosterGrid` section (matching the library grid).
  Plex `/hubs/search` returns one hub per media type, which maps cleanly onto a carousel
  row or a grid section.
- All platforms reuse the shared `FeatureStateViews` for empty/loading/error/no-result
  states through one `searchResults(_:content:)` wrapper, so state reporting stays uniform.
- Search results route through `AppNavigationRoute.destination(for:)` so people, movies,
  shows, seasons, and episodes stay consistent with the rest of the app.
- Seerr cards instead use dedicated request-only routes. Never put them through
  Plex detail routes, playback, downloads, or watch-state actions.
- `SettingsView` selects the platform shell. Shared sheet/navigation chrome is in
  `SettingsContainer`.
- The Integrations section links to `SeerrSettingsView`. Both platforms accept
  only a server URL and connect using the active Plex identity; tvOS uses native
  keyboard/Remote input rather than a browser login. It also links to
  `AthenaSettingsView`: Athena's address (`UserPreferences.athenaURL`, plain HTTP
  when typed without a scheme), a status row from `GET /healthz` (ready, no
  API key on the server, or unreachable), and Use Athena for Describe It
  (`athenaConsent`). Every pick carries `X-Plex-Token`: the active profile's plex.tv
  account token (`PlexService.activeAccountToken`, the Home user's token when a
  Home profile is active; never a server access token). Athena asks plex.tv
  whether that account can reach its own Plex server (`/healthz` `server`
  names it, informational for the app). A 401 reads "Athena at <host> only
  answers people with access to its Plex server."
- A shared link sets Athena's address: `ithaca://athena?url=<https address>`
  (`AthenaShareLink`), from Athena's Share page as a link or a QR code. iOS
  declares the `ithaca` scheme for it; tvOS already had it for Top Shelf, and
  `IthacaApp`'s `onOpenURL` tries `AthenaLinkInbox` first. Only an HTTPS
  address and nothing else in the link is accepted. Nothing is saved until the
  viewer answers an alert that names the host and says the request and their
  Plex sign-in go there; "Use Athena" saves the address and counts as the
  consent (`athenaConsent = .allowed`), so Pick Something doesn't ask again.
- Ithaca Pro, above Integrations, opens `ProView`: the trial, the one-time
  purchase and Restore Purchase (`IthacaStore`, StoreKit 2: the free
  `com.inceptyon.ithaca.trial` and `com.inceptyon.ithaca.pro`, both
  non-consumable; one purchase covers every platform). The entitlement is kept
  in the Keychain so the state shows before StoreKit answers. Debug builds have
  Pro on unless launched with `-IthacaPaywall YES`.
- Neither needs an address typed in when it runs on the Plex machine
  (`HomeServerFinder`). The candidates are the LAN addresses of the connected
  servers, in priority order, skipping servers reached from outside the home.
  Athena is looked for on port 8800 each time the connected servers change
  (`MainTabView`) and must answer `/healthz` with `service: "athena"` (older servers say `"mentor"`, also accepted). The last
  one found is kept (`UserPreferences.foundAthenaURL`), so it still works away
  from home, and a typed address always wins (`athenaAddress`). Seerr is looked
  for on ports 5055 and 5056 when its screen opens with nothing configured, and
  must answer `api/v1/settings/public` as initialized with Plex sign-in. The
  field is filled in and each profile still taps Connect with Plex once.
  Probes time out after 3 seconds.
- `SettingsViewModel` is for transient settings UI state: Home-user picker
  presentation, image cache status, and app version. Server state belongs to
  `ServerPrioritySettingsViewModel`.
- Persistent settings live in `UserPreferences`, not `SettingsViewModel`.
- Settings → Navigation holds three ordering screens, deliberately different in
  scope. Navigation Tabs controls the visibility and order of Movies, TV Shows,
  Videos, and Live TV; it is device-local `UserPreferences`. Library Order controls
  the order of your individual libraries across servers; it is stored on the Plex
  account (see "Library Order"). Server Priority controls which servers Ithaca uses
  at all and which one wins for a title that exists on several; it is device-local
  (see "Server Priority"). All three use native list editing on iOS/iPadOS and
  position menus on tvOS.
- For Navigation Tabs, hidden types stay in the saved order so restoring one puts it
  back where the user placed it.
- `UserPreferences` is `@Observable`, environment-injected, and backed by `UserDefaults`.
  Add new device-local user-facing preferences there with a key, default loading, and
  persistence. A setting Plex already models for the account belongs in `PlexService`
  instead, like library order.
- `forceAVPlayer` and `forceVLCKit` are mutually exclusive in `UserPreferences`; do not
  bypass those setters.
- `subtitleFontSize` (Playback Defaults › Subtitle Size, Extra Small/Small/
  Medium/Large, Medium = the previous fixed size) scales locally rendered
  subtitles on both engines. It is also editable from the in-player gear menu
  (a `PlayerSelectionSheet` on iOS/iPadOS, a nested `Menu` on tvOS); the player
  writes the same `UserPreferences` value, so it is one preference and not a
  per-session override. It is disabled for AirPlay sessions, whose subtitles are
  burned in by Plex. See `playback.md` for how each engine applies it.
- Subtitle Background (See-Through Box, Solid Box, None), Subtitle Color (White,
  Yellow, Cyan) and Subtitle Position (Bottom, Raised: a tenth of the picture
  higher) sit under Subtitle Size, Settings only (`SubtitleStyle`, built by
  `UserPreferences.subtitleStyle`). They apply from the next session; the player
  has no picker for them. Subtitles burned in by a transcode can't be styled.
- Play Starts (Playback Behavior; `playbackStartBehavior`: Where You Left Off,
  the default, Ask Each Time, From the Beginning) is decided in
  `PlaybackCoordinator.startFollowingPlayStarts`, which `play` and `playVersion`
  both go through. From the Beginning plays from the start, and Play buttons say
  Play instead of Resume (`UserPreferences.playTitle`). Ask Each Time sets
  `resumeChoice` and loads nothing until `MainTabView`'s dialog answers (Resume
  from …, Start Over, Cancel; cleared synchronously so the dialog's dismissal
  doesn't cancel the answer). It goes by the position playback would use, so a
  download watched offline asks too (`effectiveViewOffsetMs`). With the player
  up nothing could show the dialog, so Ask resumes there, and Previous and Next
  Episode inside the player pass `asksToResume: false`. Siri passes
  `followsPlayStarts: false`, since its reply has already said whether it
  resumes. Up Next and SharePlay start their own way and are unaffected.
- Hide Spoilers (Appearance; `hidesEpisodeSpoilers`, off by default) blurs the
  still and hides the summary of an episode this profile hasn't started
  (`UserPreferences.hidesSpoilers(for:)`, `View.spoilerBlurred`,
  `EpisodeSpoilers.hiddenSummary`): season episode rows and the tvOS series
  page (cards, hero summary, and the focused episode's still as backdrop), the
  episode page (summary and backdrop, its loading hero too), the full-screen and corner Up Next, the
  Home hero's summary, and library Continue Watching (the show's art instead of
  the still). `PosterArtwork`/`PosterCard`/`PosterNavigationCard` take
  `hidesImage`. A started episode shows normally; season pages judge that from
  their own state (`hidesSpoilers(isStarted:)`), which counts offline watching. Seerr's TMDB episode lists
  and downloads are left as they are.
- `SettingsSupport` owns shared settings copy, URLs, language options, and bindings.
  Subtitle and audio pickers share `CommonLanguage`; adding an ISO 639-1 case there
  is enough for both platforms. Playback matching then canonicalizes Plex/VLCKit
  ISO 639-2 codes (`rum`/`ron` → `ro`) in `PlayerViewModel.normalizedLanguageCode`.
- Both settings pages lead with Plex Home when applicable. There is no "Plex Server" section and no
  server picker: servers are managed in Navigation › Server Priority. Everyday playback
  and appearance settings follow, while engine overrides, storage, About, and
  Account stay lower on the page. Playback Advanced is reserved for forced
  engine selection. The About section
  links the GitHub repository.
- Player Quality lives in the in-player gear menu, not global Settings. It is a
  per-session manual action and must not create a persisted default that starts
  future sessions transcoded.
- "Download Subtitles" also lives in the in-player gear menu (iOS item below
  Subtitle Size, tvOS button beside the Subtitles menu), behind
  `PlayerControlsContext.canDownloadSubtitles` — `PlexService.canDownloadSubtitles(serverID:)`
  and not Live TV. It opens `SubtitleSearchView` (sheet on iOS with
  `[.medium, .large]` detents, full-screen cover on tvOS) via
  `PlayerViewModel.showSubtitleSearch`, which must stay in both controls auto-hide
  suppression lists (`PlayerView`'s keyboard bridge and
  `PlayerViewModel.canAutoHideControls`) like the other player sheets. The flow
  defaults to `UserPreferences.defaultSubtitleLanguage`, then the device language
  when it is a `CommonLanguage`, then English, and auto-searches on appear and on
  every language / Hearing Impaired change. A successful install calls
  `PlaybackCoordinator.refreshSubtitleStreamsAfterDownload()` and then dismisses,
  so the track is mounted and selected without restarting the session by hand
  (see `playback.md`).
- iOS settings use `List`, `Section`, `Picker`, `Toggle`, `Link`, Safari sheet, and
  confirmation dialogs.
- tvOS settings use `ScrollView` plus `TVSettingsSection`, `TVSettingsMenuRow`,
  `TVSettingsToggleRow`, and action/link row components. The page leads with a
  `.title` "Settings" header (tvOS has no nav-bar title). Shared spacing lives in
  `TVSettingsMetrics` (`contentInset`, `cardVerticalPadding`, `sectionSpacing`) so
  the header, section labels, card content, and footers stay aligned. Keep tvOS
  rows focus-friendly and avoid iOS list-only affordances there. Each focusable row
  shows focus with `tvSettingsRowFocusHighlight(_:)` — a neutral background band
  driven by a per-row `@FocusState` (rows can't use the scale+glow effect because
  they sit inside a shared card). Any new tvOS settings row must carry that band, or
  it will be invisible when focused (`.ithacaSuppressTVOSButtonChrome()` strips the
  system focus effect, leaving no indicator on its own).
- `TVSettingsMenuRow` pushes its own option list (`TVSettingsOptionList`) through a
  plain `NavigationLink`. Do not switch it back to `Picker` with
  `.pickerStyle(.navigationLink)`: on tvOS 27 that style pushes an empty list with
  nothing focusable, so focus drops to the tab bar and Back exits the app with a
  black screen left over Settings (1.6.2 fix).
- When the signed-in account has multiple Plex Home members, both settings
  platforms show a Plex Home section with the current user, `Switch User`, and
  `Automatically Sign In`. The switch action reuses the startup picker as a
  sheet on iOS and a full-screen flow on tvOS. Picking the current user there
  only applies the Remember toggle and closes; it is not a switch. The startup
  picker leaves Menu to the system (exit) unless PIN entry is open. The toggle is device-local:
  turning it off removes the persisted active-session token but keeps the
  current in-memory session until the app ends.

## Platform Differences

- Prefer separate platform composition files for large differences:
  `HomeIOSView`/`HomeTVView`, `SettingsIOSView`/`SettingsTVView`.
- Prefer shared modifiers/helpers for small differences.
- tvOS often needs larger poster metrics, explicit focus sections, `scrollClipDisabled`,
  explicit page backgrounds, plain/custom poster focus, glass button styles for primary
  actions, and default focus restoration.
- For tvOS detail pages, use focus sections as vertical row boundaries when a row's first
  focusable item may be horizontally offset from the current control.
- iOS often needs navigation title display modes, searchable placement tuning, status bar
  behavior, refreshable lists, Safari sheets, and compact action stacks.
- tvOS should not rely on iOS-only `List` styling, context menu behavior, or touch drag
  gestures without a remote/focus alternative.
- When a view measures full-bleed hero artwork on tvOS, account for safe-area leading and
  trailing insets so backdrops span the visual screen.

## Design And Style Rules

- `STYLE.md` is authoritative: native vibes, not orange. Use `Color.ithacaBackground`,
  `ithacaSurface`, `ithacaTextPrimary`, and `ithacaTextSecondary`; `ithacaAccent` is brand
  only (logo/icon).
- Root feature screens should paint `Color.ithacaBackground.ignoresSafeArea()`.
- Elevated rows/cards use `Color.ithacaSurface` and subtle 1pt strokes.
- Primary action buttons use neutral contrasting Liquid Glass (`Color.primary`-tinted
  prominent glass on iOS, untinted `.glass` on tvOS). Progress, ratings, active
  states, selection, links and loading are neutral too. Do not introduce ad-hoc colors.
- Posters use 16pt corners. Sheets/cards use the larger rounded style already present in
  settings and library rows.
- Prefer system materials for overlays and hero controls where existing UI does.
- Use SF Symbols for iconography and keep labels concise.
- Keep content-first layouts: artwork leads, text supports, chrome recedes.
- Preserve progress indicators on posters and rows where watch state exists.
- Do not duplicate formatting logic in views. Add to `MediaTextFormatter` or an existing
  presentation helper.
- Do not make views call `PlexService` directly unless the file is already a small bridge
  around image URL construction. Feature data loading belongs in `@Observable` view models.

## Safe Change Checklist

- Read the relevant view, view model, shared primitive, and route code before editing.
- Confirm whether the change belongs in a platform shell, shared primitive, view model,
  route enum, or settings preference.
- Keep edits scoped; other agents may be working in nearby files.
- Reuse `AppNavigationRoute` and `.ithacaAppNavigationDestinations()` for navigation.
- Reuse shared poster/grid/carousel/state/formatting helpers before adding new UI.
- Keep Plex API calls in view models or `PlexService`, not view bodies.
- Preserve refresh-on-player-dismiss behavior on screens showing watch state.
- Preserve offline fallback paths and pending sync recording on downloaded media flows.
- Check tvOS focus and iOS compact layout when touching shared view code.
- If adding/removing/renaming source files under `Ithaca/Sources`, run `xcodegen generate`.
- After code changes, run the compile-only `xcodebuild` command from `CONTRIBUTING.md`.
- Documentation-only changes do not require an Xcode build.
