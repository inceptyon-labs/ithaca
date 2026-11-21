import SwiftUI
#if os(iOS)
import UIKit
#endif

struct HomeView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(UserPreferences.self) private var preferences
    @Environment(SeerrRequestTracker.self) private var requestTracker
    @Environment(TasteRecommender.self) private var tasteRecommender
    @Environment(\.scenePhase) private var scenePhase
    @Binding var path: NavigationPath
    let isSelected: Bool
    let liveTVViewModel: LiveTVViewModel
    /// tvOS: whether the page is scrolled away from its top, so the tab
    /// shell can send the Siri Remote's Back press back to the hero instead
    /// of letting it leave the app.
    var pageScroll: HomeScrollPosition? = nil
    /// tvOS: bumped by the tab shell to bring the page back to the hero.
    var scrollToTopRevision = 0
    @State private var viewModel: HomeViewModel?
    @State private var heroSelectionResetRevision = 0

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.ithacaBackground.ignoresSafeArea()

                if let viewModel {
                    let hasHomeContent = viewModel.hasLoadedContent

                    if !hasHomeContent, !availability.isReady {
                        // Nothing to show and the cause is the servers, not
                        // Home: say which one, with the action that fixes it.
                        ServerAvailabilityStateView(availability: availability)
                    } else if viewModel.isLoading, !hasHomeContent {
                        FeatureLoadingView()
                    } else if let error = viewModel.error, !hasHomeContent {
                        FeatureErrorView(message: error) {
                            Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                        }
                    } else {
                        platformContent(viewModel)
                    }
                } else {
                    FeatureLoadingView()
                }
            }
            // The scrolled-down report comes from the page itself, so it goes
            // stale once a loading, error, or outage state replaces the page.
            .onChange(of: showsPlatformContent) { _, isShowing in
                if !isShowing { pageScroll?.isOffTop = false }
            }
            // Keyed on the merged-content revision: Home has to reload when a
            // server connects or drops, when priority changes, and when the
            // profile changes — the tab shell mounts before any of that.
            .task(id: plexService.serverContentRevision) {
                let newViewModel = viewModel ?? HomeViewModel(
                    plexService: plexService,
                    tasteRecommender: tasteRecommender,
                    personalizedShelvesEnabled: preferences.personalizedShelvesEnabled
                )
                viewModel = newViewModel
                newViewModel.setPersonalizedShelvesEnabled(preferences.personalizedShelvesEnabled)
                await newViewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
            }
            // Your Requests polls only while Home is on screen; the task stops
            // when a page is pushed or another tab is chosen.
            .task(id: requestTracker.contextID) {
                await requestTracker.poll()
            }
            .onChange(of: preferences.personalizedShelvesEnabled) { _, enabled in
                viewModel?.setPersonalizedShelvesEnabled(enabled)
            }
            // A rating (detail page, or the prompt after a movie) changes what
            // the "Because You Liked" shelves are built from.
            .onChange(of: plexService.tasteRevision) {
                viewModel?.refreshTasteShelves()
            }
            // No `.onAppear` reload: `.task(id:)` above already runs again every
            // time Home reappears (tab return, back from a detail page), and a
            // second load would supersede the first and repeat all its work.
            .onChange(of: playback.showPlayer) { _, isShowing in
                if !isShowing {
                    resetHeroSelection()
                    Task {
                        await viewModel?.load(
                            maxRecentlyAddedItems: recentlyAddedInlineItemLimit,
                            refreshesRecommendations: true
                        )
                    }
                }
            }
            .actionErrorAlert(viewModel?.actionError) { viewModel?.actionError = nil }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, viewModel != nil else { return }
                resetHeroSelection()
                Task { await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                Task { await requestTracker.refresh() }
            }
            .onChange(of: isSelected) { _, isSelected in
                guard isSelected else { return }
                resetHeroSelection()
                guard preferences.showsLiveTVOnHome else { return }
                Task { await liveTVViewModel.loadNowPlaying(force: true) }
            }
            .refreshable {
                async let requests = requestTracker.refresh(force: true)
                await viewModel?.load(
                    maxRecentlyAddedItems: recentlyAddedInlineItemLimit,
                    refreshesRecommendations: true
                )
                _ = await requests
            }
            .ithacaAppNavigationDestinations()
        }
    }

    @ViewBuilder
    private func platformContent(_ viewModel: HomeViewModel) -> some View {
        #if os(tvOS)
        HomeTVView(
            path: $path,
            viewModel: viewModel,
            offlineServerNames: availability.offlineServerNames,
            recentlyAddedInlineItemLimit: recentlyAddedInlineItemLimit,
            heroSelectionResetRevision: heroSelectionResetRevision,
            liveTVViewModel: liveTVViewModel,
            showsLiveTV: preferences.showsLiveTVOnHome,
            pageScroll: pageScroll,
            scrollToTopRevision: scrollToTopRevision,
            playLiveTV: playLiveTV,
            play: play
        )
        #else
        HomeIOSView(
            path: $path,
            viewModel: viewModel,
            offlineServerNames: availability.offlineServerNames,
            recentlyAddedInlineItemLimit: recentlyAddedInlineItemLimit,
            heroSelectionResetRevision: heroSelectionResetRevision,
            liveTVViewModel: liveTVViewModel,
            showsLiveTV: preferences.showsLiveTVOnHome,
            playLiveTV: playLiveTV,
            play: play
        )
        #endif
    }

    /// Mirrors the branches in `body`: whether the page itself is on screen.
    private var showsPlatformContent: Bool {
        guard let viewModel else { return false }
        if viewModel.hasLoadedContent { return true }
        return availability.isReady && !viewModel.isLoading && viewModel.error == nil
    }

    private var availability: ServerAvailability {
        plexService.pool.availability
    }

    private var recentlyAddedInlineItemLimit: Int {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? 22 : 15
        #else
        15
        #endif
    }

    private func play(_ item: PlexItem) {
        Task {
            await playback.play(
                id: item.id,
                resumeOffsetMilliseconds: item.viewOffset,
                resumeOffsetDurationMilliseconds: item.duration,
                placeholder: PlaybackPlaceholder(item: item)
            )
        }
    }

    private func playLiveTV(
        _ channel: PlexLiveChannel,
        _ program: PlexLiveProgram,
        _ lineup: PlexLiveTVLineup
    ) {
        Task {
            await playback.playLiveTV(channel: channel, program: program, lineup: lineup)
        }
    }

    private func resetHeroSelection() {
        heroSelectionResetRevision += 1
    }
}

/// Whether tvOS Home is scrolled away from its hero. A plain reference, not
/// state or a binding: it flips on every move between the hero and the
/// shelves. As tab-shell state it re-rendered every tab as that scroll
/// started. A get/set binding to it would not help: SwiftUI counts such a
/// binding as changed on every update and re-runs `HomeTVView`. Only the Back
/// press reads it (`MainTabView.rootBackAction`).
final class HomeScrollPosition {
    var isOffTop = false
}
