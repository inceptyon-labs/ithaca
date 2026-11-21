#if os(tvOS)
import SwiftUI

/// The tvOS show page. tvOS has no separate show, season, or episode screens:
/// every one of those routes opens this page, which browses one season at a time
/// (picked with the season pills above the episode row) under a banner that
/// follows the focused episode. Selecting an episode card plays it.
struct SeriesDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: SeriesDetailViewModel
    @State private var episodeFocus = SeriesEpisodeFocus()
    @State private var trailerPreview: TrailerPreviewController
    @State private var isHeroInView = true
    /// Set once the viewer moves along the episode row or picks another
    /// season. The banner then follows their episodes, so the show's trailer
    /// stops for the rest of the visit.
    @State private var hasBrowsedEpisodes = false

    private let horizontalPadding: CGFloat = IthacaPosterMetrics.detailHorizontalPadding
    /// The pills and the plain "Episodes" header share one fixed-height slot, so
    /// the episode row does not jump when the show (and its pills) finish loading
    /// after the season is already on screen.
    private let seasonHeaderHeight: CGFloat = 84

    // Both bands are fixed so the banner doesn't jump while zapping the episode
    // row, so they have to be re-derived whenever the type scale moves. With the
    // reduced tvOS scale the metadata band holds a 25pt meta line + 4pt gap + two
    // 23pt summary lines (~92pt), and the cast band a 33pt header + 10pt gap + a
    // 144pt avatar + 14pt gap + two 23pt text lines + 12pt vertical padding
    // (~288pt). Both used to clip their last line; they now fit it exactly.
    private let episodeHeroMetadataHeight: CGFloat = 92
    private let episodeCastSectionHeight: CGFloat = 288

    init(
        entry: SeriesDetailViewModel.Entry,
        id: PlexItemID,
        plexService: PlexService,
        seerrService: SeerrService? = nil,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        _viewModel = State(initialValue: SeriesDetailViewModel(
            entry: entry,
            id: id,
            plexService: plexService,
            seerrService: seerrService,
            downloadManager: downloadManager,
            offlinePlaybackSyncManager: offlinePlaybackSyncManager,
            prefersOfflineAvailability: prefersOfflineAvailability
        ))
        _trailerPreview = State(initialValue: TrailerPreviewController(plexService: plexService))
    }

    var body: some View {
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()

            if let season = viewModel.season, let details = season.details {
                contentView(season, details: details)
            } else if let error = viewModel.error, !viewModel.isLoading {
                FeatureErrorView(message: error) {
                    Task { await viewModel.retry() }
                }
            } else if let seedTitle = viewModel.seedTitle {
                // The banner's size, from the card that opened the page.
                DetailSeedHero(
                    title: seedTitle,
                    summary: viewModel.seed?.type == .show ? viewModel.seed?.summary : nil,
                    heroHeightFraction: 0.50,
                    heroHeightRange: 500...540,
                    titleLineLimit: 1,
                    backdropURL: viewModel.seedBackdropURL,
                    titleLogoURL: viewModel.seedTitleLogoURL
                )
            } else {
                FeatureLoadingView()
            }
        }
        .ithacaNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await viewModel.load()
        }
        .task(id: "\(viewModel.season?.ratingKey ?? "")|\(viewModel.anchorEpisode?.ratingKey ?? "")") {
            await loadAnchorEpisodeDetailsIfNeeded()
        }
        .onChange(of: viewModel.season?.ratingKey) { oldKey, _ in
            // A pending focus commit belongs to the previous season's row.
            episodeFocus.commitTask?.cancel()
            if oldKey != nil { hasBrowsedEpisodes = true }
        }
        .onAppear {
            hasBrowsedEpisodes = false
        }
        .onDisappear {
            episodeFocus.commitTask?.cancel()
        }
        .trailerPreview(
            trailerPreview,
            trailer: viewModel.show?.previewTrailer,
            isHeroInView: isHeroInView && !hasBrowsedEpisodes
        )
        .onChange(of: playback.showPlayer) { _, isShowing in
            if !isShowing {
                Task {
                    await playback.awaitFinalWrites()
                    await viewModel.playbackDidEnd()
                }
            }
        }
        .actionErrorAlert(viewModel.show?.actionError ?? viewModel.season?.actionError) {
            viewModel.show?.actionError = nil
            viewModel.season?.actionError = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, viewModel.season != nil else { return }
            Task { await viewModel.refresh() }
        }
    }

    @ViewBuilder
    private func contentView(_ season: SeasonDetailViewModel, details: PlexMediaDetails) -> some View {
        GeometryReader { geometry in
            let heroBackgroundWidth = geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
            let topInset = geometry.safeAreaInsets.top
            let containerHeight = geometry.size.height
            let leadingInset = geometry.safeAreaInsets.leading

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    EpisodeFocusScope {
                        heroSection(
                            season,
                            details: details,
                            topInset: topInset,
                            containerWidth: heroBackgroundWidth,
                            containerHeight: containerHeight,
                            backgroundLeadingInset: leadingInset
                        )
                    }
                    .focusSection()
                    .onScrollVisibilityChange(threshold: 0.5) { isHeroInView = $0 }

                    // The episode row sits directly under the banner so both stay
                    // on screen while zapping; the season summary moves below it
                    // (the banner already shows per-episode detail).
                    if let offlineBannerText = season.offlineBannerText {
                        OfflineMetadataBanner(message: offlineBannerText)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 24)
                    }

                    seasonHeader()
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 16)
                        .focusSection()

                    episodesSection(season, width: geometry.size.width)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                        .focusSection()

                    if let summary = details.summary, !summary.isEmpty {
                        ExpandableSummaryText(text: summary)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, 32)
                            .focusSection()
                    }

                    EpisodeFocusScope {
                        episodeCastSection(season)
                    }
                    .padding(.top, 8)

                    if let extras = viewModel.show?.extras, !extras.isEmpty {
                        DetailExtrasSection(extras: extras)
                            .padding(.top, 24)
                    }
                }
                .padding(.bottom, 56)
                .padding(.top, -geometry.safeAreaInsets.top)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .ithacaTVOSPageBackground()
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(
        _ season: SeasonDetailViewModel,
        details: PlexMediaDetails,
        topInset: CGFloat,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        backgroundLeadingInset: CGFloat
    ) -> some View {
        // Keep the banner compact so the episode row lands high enough that
        // focusing a card never scrolls the banner off-screen.
        let heroBase = min(max(containerHeight * 0.50, 500), 540)
        let heroHeight = heroBase + topInset
        let focusedEpisode = focusedEpisode(in: season)

        DetailHeroSection(
            backdropURL: season.backdropURL(
                width: Int(containerWidth.rounded(.up)),
                height: Int(heroHeight.rounded(.up)),
                focusedEpisode: focusedEpisode,
                focusedEpisodeDetails: focusedEpisodeDetails(in: season),
                hidesEpisodeStill: focusedEpisode.map { hidesSpoilers($0, in: season) } ?? false
            ),
            // The show's clear-logo is the hero title; the show name is only the
            // text fallback when Plex has no logo, kept to one line so the banner
            // height stays put.
            titleArtworkURL: season.showTitleLogoURL(
                width: Int((containerWidth * 0.45).rounded(.up)),
                height: 128
            ),
            title: season.showTitle ?? details.title,
            descriptionText: details.summary,
            topInset: topInset,
            containerWidth: containerWidth,
            backgroundLeadingInset: backgroundLeadingInset,
            heroBaseHeight: heroBase,
            keepsPreviousBackdropWhileLoading: true,
            titleLineLimit: 1,
            titleAccessory: AnyView(episodeTitleView(focusedEpisode)),
            backdropAccessory: AnyView(TrailerPreviewVideo(controller: trailerPreview)),
            supertitle: {
                EmptyView()
            },
            subtitle: {
                episodeHeroMetadata(season, episode: focusedEpisode, details: details)
            },
            actions: {
                if let focusedEpisode {
                    actionButtons(season, episode: focusedEpisode)
                }
            }
        )
        .backdropHidden(trailerPreview.coversBackdrop)
    }

    /// Hide Spoilers, from the season's own state, which knows about offline
    /// watching.
    private func hidesSpoilers(_ episode: PlexEpisode, in season: SeasonDetailViewModel) -> Bool {
        preferences.hidesSpoilers(isStarted: season.isWatched(episode) || season.isPartiallyWatched(episode))
    }

    // The focused episode's name, sitting under the show logo. Kept to a single
    // (truncated) line and non-animated so the banner doesn't grow/shrink or
    // cross-fade as the user zaps the episode row.
    @ViewBuilder
    private func episodeTitleView(_ episode: PlexEpisode?) -> some View {
        Text(episode?.title ?? "")
            .font(IthacaFont.TV.heroSubtitle)
            .foregroundStyle(Color.ithacaTextPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { transaction in
                transaction.disablesAnimations = true
            }
    }

    @ViewBuilder
    private func episodeHeroMetadata(
        _ season: SeasonDetailViewModel,
        episode: PlexEpisode?,
        details: PlexMediaDetails
    ) -> some View {
        Group {
            if let episode {
                // The episode name sits above in the title accessory, so this box
                // carries the supporting metadata: an "Episode N · 45 min · air
                // date" tagline (same styling as the rest of the app) and summary.
                VStack(alignment: .leading, spacing: 4) {
                    if let metaLine = episodeMetaLine(season, episode: episode) {
                        Text(metaLine)
                            .font(IthacaFont.TV.metadata)
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .lineLimit(1)
                    }

                    if hidesSpoilers(episode, in: season) {
                        Text(EpisodeSpoilers.hiddenSummary)
                            .font(IthacaFont.TV.caption)
                            .foregroundStyle(Color.ithacaTextSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: 720, alignment: .leading)
                    } else if let summary = episode.summary, !summary.isEmpty {
                        Text(summary)
                            .font(IthacaFont.TV.caption)
                            .foregroundStyle(Color.primary.opacity(0.76))
                            .lineSpacing(3)
                            .lineLimit(2)
                            .frame(maxWidth: 720, alignment: .leading)
                    }
                }
            } else {
                seasonTagline(season, details: details)
            }
        }
        .frame(height: episodeHeroMetadataHeight, alignment: .topLeading)
        .clipped()
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }

    private func episodeMetaLine(_ season: SeasonDetailViewModel, episode: PlexEpisode) -> String? {
        [season.episodeLabel(episode), season.episodeSubtitle(episode)]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    }

    @ViewBuilder
    private func seasonTagline(_ season: SeasonDetailViewModel, details: PlexMediaDetails) -> some View {
        let parts = [
            season.episodeCountText,
            season.watchedEpisodeCountText,
            details.contentRating,
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(IthacaFont.TV.metadata)
                .foregroundStyle(Color.primary.opacity(0.78))
        }
    }

    // The hero Play button plays whatever episode is focused in the row, keeping
    // it in sync with the banner the user is reading.
    @ViewBuilder
    private func actionButtons(_ season: SeasonDetailViewModel, episode: PlexEpisode) -> some View {
        HStack(spacing: detailHeroActionSpacing) {
            Button {
                play(episode, in: season)
            } label: {
                DetailHeroPrimaryActionButtonLabel(
                    title: preferences.playTitle(season.isPartiallyWatched(episode) ? "Resume" : "Play"),
                    systemImage: "play.fill"
                )
            }
            .detailHeroNativePrimaryButtonStyle()
            .contextMenu {
                PlayVersionContextMenu(versions: focusedEpisodeVersions(in: season)) { version in
                    Task {
                        await playback.playVersion(
                            id: episode.id,
                            mediaID: version.id,
                            resumeOffsetMilliseconds: episode.viewOffset,
                            placeholder: PlaybackPlaceholder(episode: episode)
                        )
                    }
                }
            }

            Button {
                Task { await viewModel.toggleSeasonWatched() }
            } label: {
                DetailHeroSecondaryIconLabel(systemImage: season.isSeasonWatched ? "eye.slash" : "eye")
            }
            .detailHeroNativeSecondaryButtonStyle()
            .accessibilityLabel(season.isSeasonWatched ? "Mark Season Unwatched" : "Mark Season Watched")

            // Rates the show, not the focused episode: taste is per title.
            if let show = viewModel.show {
                TasteRatingMenu(rating: show.tasteRating, subject: "Show") { rating in
                    Task { await show.rate(rating) }
                }
            }
        }
    }

    // MARK: - Season Pills

    @ViewBuilder
    private func seasonHeader() -> some View {
        Group {
            if viewModel.seasonItems.isEmpty {
                Text("Episodes")
                    .font(IthacaFont.TV.sectionHeader)
                    .foregroundStyle(Color.primary)
            } else {
                SeriesSeasonPills(
                    items: viewModel.seasonItems,
                    selectedSeasonKey: viewModel.selectedSeasonKey,
                    seerrBadge: { viewModel.show?.seasonRequestState($0).badgeTitle },
                    onSelect: { season in
                        Task { await viewModel.selectSeason(season) }
                    },
                    seasonMenu: { season in
                        seasonContextMenu(season)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: seasonHeaderHeight, maxHeight: seasonHeaderHeight, alignment: .leading)
    }

    @ViewBuilder
    private func seasonContextMenu(_ season: PlexSeason) -> some View {
        if !season.isFullyWatched {
            Button {
                Task { await viewModel.markSeason(season, watched: true) }
            } label: {
                Label("Mark Watched", systemImage: "eye")
            }
        }

        Button {
            Task { await viewModel.markSeason(season, watched: false) }
        } label: {
            Label("Mark Unwatched", systemImage: "eye.slash")
        }
    }

    // MARK: - Episodes

    @ViewBuilder
    private func episodesSection(_ season: SeasonDetailViewModel, width: CGFloat) -> some View {
        let contentWidth = max(width - (horizontalPadding * 2), 280)
        let artworkWidth = min(max(contentWidth * 0.44, 240), 360)
        let imageWidth = Int(artworkWidth.rounded(.up))
        let imageHeight = Int((artworkWidth / (16.0 / 9.0)).rounded(.up))

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    ForEach(season.displayEpisodes) { episode in
                        // The closures look the season up when called, so a card
                        // whose values haven't changed can keep the ones it has.
                        SeriesEpisodeCard(
                            episode: episode,
                            imageURL: season.episodeImageURL(episode, width: imageWidth, height: imageHeight),
                            progress: season.progress(for: episode),
                            isUnavailableOffline: season.isUnavailableOffline(episode),
                            isWatched: season.isWatched(episode),
                            hidesImage: hidesSpoilers(episode, in: season),
                            artworkWidth: artworkWidth,
                            onFocus: {
                                focusEpisode(episode)
                            },
                            onPlay: {
                                guard let season = viewModel.season else { return }
                                play(episode, in: season)
                            }
                        )
                        .equatable()
                        .id(episode.ratingKey)
                        .contextMenu {
                            episodeContextMenu(episode, in: season)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            // Start each season's row on the episode the page opened on. Keyed on
            // the season only: re-scrolling when next-up moves (after playback)
            // would pull the row out from under the card that has focus.
            .task(id: season.ratingKey) {
                guard let anchor = viewModel.anchorEpisode else { return }
                proxy.scrollTo(anchor.ratingKey, anchor: .leading)
            }
        }
        .opacity(viewModel.isSwitchingSeason ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.16), value: viewModel.isSwitchingSeason)
    }

    @ViewBuilder
    private func episodeContextMenu(_ episode: PlexEpisode, in season: SeasonDetailViewModel) -> some View {
        let downloadState = downloadManager.downloadState(for: DownloadScope(id: episode.id, type: .episode))

        if season.isPartiallyWatched(episode) {
            Button {
                Task { await playback.playFromStart(id: episode.id, placeholder: PlaybackPlaceholder(episode: episode)) }
            } label: {
                Label("Play from Start", systemImage: "arrow.counterclockwise")
            }

            Button {
                Task { await viewModel.setWatched(true, for: episode) }
            } label: {
                Label("Mark Watched", systemImage: "eye")
            }

            Button {
                Task { await viewModel.setWatched(false, for: episode) }
            } label: {
                Label("Mark Unwatched", systemImage: "eye.slash")
            }
        } else {
            Button {
                Task { await viewModel.toggleWatched(for: episode) }
            } label: {
                Label(
                    season.isWatched(episode) ? "Mark Unwatched" : "Mark Watched",
                    systemImage: season.isWatched(episode) ? "eye.slash" : "eye"
                )
            }
        }

        if DownloadsFeature.isVisible {
            if downloadState.hasRecords {
                DownloadContextMenuContent(
                    state: downloadState,
                    showsDelete: downloadState.canDelete,
                    showsCancel: downloadState.canCancel,
                    onPause: { downloadManager.pauseDownload(scope: downloadState.scope) },
                    onResume: { downloadManager.resumeDownload(scope: downloadState.scope) },
                    onCancel: { downloadManager.cancelDownload(scope: downloadState.scope) },
                    onDelete: { downloadManager.deleteDownload(scope: downloadState.scope) },
                    onRetry: { downloadManager.retryDownload(id: episode.id) }
                )
            } else {
                Button {
                    Task {
                        await downloadManager.queueDownload(episode: episode)
                    }
                } label: {
                    Label("Download Episode", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func episodeCastSection(_ season: SeasonDetailViewModel) -> some View {
        let details = focusedEpisodeDetails(in: season)
        let roles = details?.roles ?? []

        ZStack(alignment: .topLeading) {
            if !roles.isEmpty {
                DetailCastSection(
                    roles: roles,
                    serverID: season.serverID,
                    plexService: plexService,
                    title: "Episode Cast"
                )
                .transition(.opacity)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: episodeCastSectionHeight,
            maxHeight: episodeCastSectionHeight,
            alignment: .topLeading
        )
        .clipped()
        .animation(.easeInOut(duration: 0.16), value: details?.ratingKey)
    }

    // MARK: - Focus

    // Reads `episodeFocus.key`; call it only inside an `EpisodeFocusScope`.
    private func focusedEpisode(in season: SeasonDetailViewModel) -> PlexEpisode? {
        season.displayEpisodes.first { $0.ratingKey == episodeFocus.key }
            ?? viewModel.anchorEpisode
            ?? season.displayEpisodes.first
    }

    private func focusedEpisodeDetails(in season: SeasonDetailViewModel) -> PlexMediaDetails? {
        let ratingKey = focusedEpisode(in: season)?.ratingKey
        if season.focusedEpisodeDetails?.ratingKey == ratingKey {
            return season.focusedEpisodeDetails
        }
        if season.nextEpisodeDetails?.ratingKey == ratingKey {
            return season.nextEpisodeDetails
        }
        return nil
    }

    private func focusedEpisodeVersions(in season: SeasonDetailViewModel) -> [PlexMedia] {
        focusedEpisodeDetails(in: season)?.media.filter { !$0.parts.isEmpty } ?? []
    }

    @MainActor
    private func loadAnchorEpisodeDetailsIfNeeded() async {
        guard let season = viewModel.season else { return }
        // A card focused in this season keeps the banner. The page's own pick
        // follows the anchor when a refresh moves it (a season drawn from
        // recent metadata can start on an episode another client has since
        // finished, or playback moves next-up).
        if let focusedKey = episodeFocus.key, focusedKey != episodeFocus.anchoredKey,
           season.displayEpisodes.contains(where: { $0.ratingKey == focusedKey }) {
            return
        }
        guard let episode = viewModel.anchorEpisode ?? season.displayEpisodes.first,
              episode.ratingKey != episodeFocus.key else { return }
        setFocusedEpisodeKey(episode.ratingKey)
        episodeFocus.anchoredKey = episode.ratingKey
        await season.focusEpisode(episode)
    }

    @MainActor
    private func focusEpisode(_ episode: PlexEpisode) {
        guard let season = viewModel.season else { return }
        episodeFocus.anchoredKey = nil
        guard episodeFocus.key != episode.ratingKey else { return }

        // Debounce the committed focus. Updating the banner on every card while
        // the user zaps through the row quickly makes the outer ScrollView drift
        // downward even though focus stays on the row. The per-card focus
        // highlight is driven by the card's own state, so it still reacts
        // instantly — only the banner waits until the user settles on a card.
        episodeFocus.commitTask?.cancel()
        episodeFocus.commitTask = Task {
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            // The viewer moving along the row, not the page's own pick.
            if !hasBrowsedEpisodes, episodeFocus.key != nil, episodeFocus.anchoredKey == nil {
                hasBrowsedEpisodes = true
            }
            setFocusedEpisodeKey(episode.ratingKey)
            await season.focusEpisode(episode)
        }
    }

    @MainActor
    private func setFocusedEpisodeKey(_ ratingKey: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            episodeFocus.key = ratingKey
        }
    }

    private func play(_ episode: PlexEpisode, in season: SeasonDetailViewModel) {
        guard !season.constrainsPlaybackToOfflineAvailability || season.isPlayableOffline(episode) else { return }
        Task {
            await playback.play(
                id: episode.id,
                resumeOffsetMilliseconds: episode.viewOffset,
                resumeOffsetDurationMilliseconds: episode.duration,
                placeholder: PlaybackPlaceholder(episode: episode)
            )
        }
    }
}

// MARK: - Episode Focus

/// The episode the banner follows. It lives outside the page's own state so a
/// settled focus re-renders only the `EpisodeFocusScope`s that read it (the
/// banner and the cast row), not the season pills and the episode row.
@MainActor
@Observable
private final class SeriesEpisodeFocus {
    var key: String?
    /// `key` when the page picked it itself (the anchor), nil once a card
    /// took focus. Only the page's own pick follows a refresh.
    @ObservationIgnored var anchoredKey: String?
    @ObservationIgnored var commitTask: Task<Void, Never>?
}

/// Builds its content in its own body, so the episode focus and the season's
/// episode details it reads re-render this view instead of the whole page.
private struct EpisodeFocusScope<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

// MARK: - Season Pills

/// One pill per season above the episode row. Selecting a Plex season swaps the
/// row in place; a season only Seerr knows about opens its request page.
private struct SeriesSeasonPills<SeasonMenu: View>: View {
    let items: [ShowDetailViewModel.SeasonItem]
    let selectedSeasonKey: String?
    let seerrBadge: (SeerrSeasonSummary) -> String?
    let onSelect: (PlexSeason) -> Void
    @ViewBuilder let seasonMenu: (PlexSeason) -> SeasonMenu

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(items) { item in
                        pill(for: item)
                            .id(item.id)
                    }
                }
                .padding(.vertical, 14)
            }
            .scrollClipDisabled()
            .onAppear {
                guard let selectedSeasonKey else { return }
                proxy.scrollTo("plex:\(selectedSeasonKey)", anchor: .leading)
            }
        }
    }

    @ViewBuilder
    private func pill(for item: ShowDetailViewModel.SeasonItem) -> some View {
        switch item {
        case .plex(let season):
            let isSelected = season.ratingKey == selectedSeasonKey
            Button {
                onSelect(season)
            } label: {
                SeriesSeasonPillLabel(
                    title: season.title,
                    badge: nil,
                    isSelected: isSelected,
                    isWatched: season.isFullyWatched
                )
            }
            .seriesSeasonPillButtonStyle()
            .contextMenu {
                seasonMenu(season)
            }
        case .seerr(let tvID, let season):
            NavigationLink(value: AppNavigationRoute.seerrSeason(tvID: tvID, seasonNumber: season.seasonNumber)) {
                SeriesSeasonPillLabel(
                    title: season.name,
                    badge: seerrBadge(season),
                    isSelected: false,
                    isWatched: false
                )
            }
            .seriesSeasonPillButtonStyle()
        }
    }
}

/// The selected season reads brighter and bolder than the rest; a filled pill
/// would look exactly like the focused one. Label colours come from the system
/// glass (light unfocused, dark on the focused white platter), so emphasis is
/// carried by opacity and weight only, and focus always gets full contrast.
private struct SeriesSeasonPillLabel: View {
    let title: String
    let badge: String?
    let isSelected: Bool
    let isWatched: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(IthacaFont.TV.cardTitle)
                .fontWeight(isSelected ? .bold : .medium)
                .lineLimit(1)

            if isWatched {
                Image(systemName: "checkmark")
                    .font(IthacaFont.TV.glyphSmall)
                    .imageScale(.small)
                    .fontWeight(.semibold)
                    .opacity(0.7)
                    .accessibilityLabel("Watched")
            }

            if let badge {
                Text(badge)
                    .font(IthacaFont.TV.badge)
                    .opacity(0.7)
                    .lineLimit(1)
            }
        }
        .opacity(isSelected || isFocused ? 1 : 0.6)
    }
}

private extension View {
    func seriesSeasonPillButtonStyle() -> some View {
        self
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
    }
}

// MARK: - Episode Card

private struct SeriesEpisodeCard: View, Equatable {
    let episode: PlexEpisode
    let imageURL: URL?
    let progress: Double?
    let isUnavailableOffline: Bool
    let isWatched: Bool
    let hidesImage: Bool
    let artworkWidth: CGFloat
    let onFocus: () -> Void
    let onPlay: () -> Void

    @State private var isFocused = false

    /// Everything the card draws or plays from; the closures are left out.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.episode.ratingKey == rhs.episode.ratingKey
            && lhs.episode.serverID == rhs.episode.serverID
            && lhs.episode.title == rhs.episode.title
            && lhs.episode.index == rhs.episode.index
            && lhs.episode.parentIndex == rhs.episode.parentIndex
            && lhs.episode.viewOffset == rhs.episode.viewOffset
            && lhs.episode.duration == rhs.episode.duration
            && lhs.imageURL == rhs.imageURL
            && lhs.progress == rhs.progress
            && lhs.isUnavailableOffline == rhs.isUnavailableOffline
            && lhs.isWatched == rhs.isWatched
            && lhs.hidesImage == rhs.hidesImage
            && lhs.artworkWidth == rhs.artworkWidth
    }

    private var artworkHeight: CGFloat {
        artworkWidth / (16.0 / 9.0)
    }

    private var artworkShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var episodeNumberLabel: String? {
        MediaTextFormatter.seasonEpisodeLabel(season: episode.parentIndex, episode: episode.index)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IthacaPosterMetrics.cardSpacing) {
            Button(action: onPlay) {
                PosterArtwork(
                    imageURL: imageURL,
                    progress: progress,
                    width: artworkWidth,
                    imageAspectRatio: 16.0 / 9.0,
                    showsPlayOverlay: false,
                    hidesImage: hidesImage
                )
                .opacity(isUnavailableOffline ? 0.46 : 1)
                .contentShape(.contextMenuPreview, artworkShape)
                .background(FocusMirror(value: $isFocused) { focused in
                    if focused { onFocus() }
                })
            }
            .ithacaSuppressTVOSButtonChrome()
            .ithacaTVOSFocusEffectShape(artworkShape, scales: false)
            .accessibilityLabel("Play \(episode.title)")
            .frame(width: artworkWidth, height: artworkHeight, alignment: .leading)

            PosterCardText(
                title: episode.title,
                subtitle: episodeNumberLabel,
                width: artworkWidth,
                isWatched: isWatched
            )
        }
        .frame(width: artworkWidth, alignment: .topLeading)
        .ithacaTVOSFocusedScale(isFocused)
        .zIndex(isFocused ? 1 : 0)
    }
}
#endif
