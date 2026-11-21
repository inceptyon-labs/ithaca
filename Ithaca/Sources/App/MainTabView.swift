import SwiftUI

/// The main tab shell shown after authentication and server connection.
struct MainTabView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(UserPreferences.self) private var preferences
    @Environment(SeerrService.self) private var seerrService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTabItem = .home
    @State private var homePath = NavigationPath()
    @State private var moviesPath = NavigationPath()
    @State private var showsPath = NavigationPath()
    @State private var videosPath = NavigationPath()
    @State private var liveTVPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var discoverPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var morePath = NavigationPath()
    @State private var librariesViewModel: LibrariesViewModel?
    @State private var liveTVViewModel: LiveTVViewModel?
    #if os(tvOS)
    @Environment(TopShelfLinkRouter.self) private var topShelfLinks
    @State private var homeScroll = HomeScrollPosition()
    @State private var homeScrollToTopRevision = 0
    #endif

    private var resumeChoiceIsPresented: Binding<Bool> {
        Binding(
            get: { playback.resumeChoice != nil },
            set: { isPresented in
                if !isPresented, let choice = playback.resumeChoice {
                    playback.answerResumeChoice(choice, resume: nil)
                }
            }
        )
    }

    private var ratingPromptIsPresented: Binding<Bool> {
        Binding(
            get: { playback.ratingPrompt != nil },
            set: { isPresented in
                if !isPresented, let prompt = playback.ratingPrompt {
                    playback.answerRatingPrompt(prompt, with: nil)
                }
            }
        )
    }

    var body: some View {
        @Bindable var bindablePlayback = playback

        shellView
            // Which tabs exist depends on the merged library list, so the shell
            // reloads it whenever the set of connected servers changes: it
            // mounts before the first server is connected.
            .task(id: plexService.serverContentRevision) {
                if librariesViewModel == nil {
                    librariesViewModel = LibrariesViewModel(plexService: plexService)
                }
                if liveTVViewModel == nil {
                    liveTVViewModel = LiveTVViewModel(plexService: plexService)
                }
                await librariesViewModel?.loadLibraries()
                await liveTVViewModel?.discover()
            }
            // Looks for Athena beside the Plex servers once they connect, so
            // Describe It needs no address typed in.
            .task(id: plexService.serverContentRevision) {
                guard preferences.athenaURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let hosts = HomeServerFinder.hosts(plexService: plexService)
                guard !hosts.isEmpty, let found = await HomeServerFinder.findAthena(hosts: hosts),
                      found != preferences.foundAthenaURL else { return }
                preferences.foundAthenaURL = found
            }
            // Teaches Siri the recently watched and added titles, again on
            // each return to the foreground (at most every 30 minutes). Waits
            // a moment so it never competes with Home's first paint.
            .task(id: SiriCatalogRefreshTrigger(
                revision: plexService.serverContentRevision,
                isActive: scenePhase == .active
            )) {
                guard scenePhase == .active else { return }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await SiriTitleCatalog.shared.refreshIfNeeded(plexService: plexService)
            }
            .onChange(of: availableTabs) { _, newTabs in
                guard !newTabs.contains(selectedTab) else { return }
                // Active iPhone tabs are normally retained while the shell
                // folds into or out of More. This remains the fallback for a
                // destination that genuinely disappears with server state.
                switch selectedTab {
                case .search, .settings, .downloads:
                    selectedTab = newTabs.contains(.more) ? .more : .home
                case .more:
                    selectedTab = newTabs.contains(.settings) ? .settings : .home
                default:
                    selectedTab = .home
                }
            }
            .fullScreenCover(isPresented: $bindablePlayback.showPlayer, onDismiss: {
                playback.onPlayerDismissed()
            }) {
                PlayerView()
                    .environment(plexService)
                    .environment(playback)
                    .environment(playback.preferences)
            }
            // Play Starts is Ask Each Time and the title was started before.
            .confirmationDialog(
                playback.resumeChoice?.title ?? "",
                isPresented: resumeChoiceIsPresented,
                titleVisibility: .visible,
                presenting: playback.resumeChoice
            ) { choice in
                Button(choice.resumeTitle) {
                    playback.answerResumeChoice(choice, resume: true)
                }
                Button("Start Over") {
                    playback.answerResumeChoice(choice, resume: false)
                }
                Button("Cancel", role: .cancel) {
                    playback.answerResumeChoice(choice, resume: nil)
                }
            }
            // "How was it?" once a movie, or the last episode of a show, has
            // been watched to the end and the player has closed.
            .alert(
                playback.ratingPrompt.map { "How was \($0.title)?" } ?? "",
                isPresented: ratingPromptIsPresented,
                presenting: playback.ratingPrompt
            ) { prompt in
                ForEach(PlexTasteRating.allCases, id: \.self) { rating in
                    Button(rating.title) {
                        playback.answerRatingPrompt(prompt, with: rating)
                    }
                }
                Button("Not Now", role: .cancel) {
                    playback.answerRatingPrompt(prompt, with: nil)
                }
            } message: { _ in
                Text("Your ratings shape the recommendations on Home.")
            }
            #if DEBUG
            .task(id: plexService.serverContentRevision) {
                await applyScreenshotDestination()
            }
            #endif
            // Siri's "Pick a movie in Ithaca" lands on Pick Something in Home.
            .onChange(of: PickSomethingLauncher.shared.pending, initial: true) { _, request in
                guard request != nil else { return }
                openPendingPickSomething()
            }
            // A request made during playback waits for the player to close.
            .onChange(of: playback.showPlayer) { _, isShown in
                guard !isShown, PickSomethingLauncher.shared.pending != nil else { return }
                openPendingPickSomething()
            }
            #if os(iOS)
            // A tapped "it's here" notification opens the title in Home. A cold
            // launch delivers it before Seerr's server is connected, so this
            // runs again as servers connect. One tapped during playback opens
            // if the player closes within the minute the link lasts.
            .task(id: SeerrArrivalAttempt(
                link: SeerrArrivalLinks.shared.pending,
                revision: plexService.serverContentRevision,
                isPlayerShown: playback.showPlayer
            )) {
                await openPendingArrival()
            }
            #endif
            #if os(tvOS)
            // Re-checked whenever a server connects: a cold launch from the
            // Top Shelf delivers the link before the item's server is up.
            .task(id: TopShelfLinkAttempt(link: topShelfLinks.pending, revision: plexService.serverContentRevision)) {
                await openPendingTopShelfLink()
            }
            #endif
    }

    private func openPendingPickSomething() {
        // Replacing Home's stack behind the full-screen player would lose the
        // page playback started from.
        guard !playback.showPlayer,
              let kind = PickSomethingLauncher.shared.consume() else { return }
        if selectedTab != .home {
            activate(.home)
        }
        homePath = NavigationPath([AppNavigationRoute.pickSomething(kind)])
    }

    #if os(iOS)
    /// The title's Plex page is found by searching Seerr's server, so this
    /// waits a little for it to connect, then opens the page either way (it
    /// falls back to the Seerr page).
    private func openPendingArrival() async {
        guard !playback.showPlayer, SeerrArrivalLinks.shared.pending != nil else { return }
        let isServerUp = plexService.seerrBindingServerID
            .flatMap { plexService.pool.connection(for: $0) } != nil
        if !isServerUp {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
        }
        guard let link = SeerrArrivalLinks.shared.consume() else { return }
        if selectedTab != .home {
            activate(.home)
        }
        homePath = NavigationPath([link.route])
    }
    #endif

    private var tabSelection: Binding<MainTabItem> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                activate(newTab)
            }
        )
    }

    @ViewBuilder
    private var shellView: some View {
        #if os(tvOS)
        MainTabTVShell(
            tabs: availableTabs,
            selection: tabSelection,
            rootBackAction: rootBackAction,
            reselectAction: reselectAction,
            content: tabRootView(for:)
        )
        #else
        MainTabIOSShell(tabs: availableTabs, selection: tabSelection, content: tabRootView(for:))
        #endif
    }

    #if os(tvOS)
    /// What the Siri Remote's Back press does at the root of a tab, or `nil`
    /// to leave it to the system.
    ///
    /// By default Back at a tab root leaves the app, which feels wrong
    /// anywhere but Home. So every other tab goes back to Home, and Home
    /// scrolled down goes back to its hero. Only Home at its top leaves the
    /// app. Pushed screens keep the system's pop: the shell also checks the
    /// real navigation stack, because settings rows push without the path.
    ///
    /// The shell asks this on each press, so nothing it reads needs to
    /// re-render the shell when it changes.
    private func rootBackAction() -> (() -> Void)? {
        guard path(for: selectedTab).isEmpty else { return nil }
        if selectedTab != .home {
            return { activate(.home) }
        }
        guard homeScroll.isOffTop else { return nil }
        return { homeScrollToTopRevision += 1 }
    }

    /// What Select on the current tab in the tab bar does: pop that tab to its
    /// root, as tapping the current tab does on iPhone. tvOS's `TabView` never
    /// reports a reselect, so the shell catches the press. `nil` leaves it to
    /// the system.
    private func reselectAction() -> (() -> Void)? {
        let tab = selectedTab
        guard !path(for: tab).isEmpty else { return nil }
        return { popToRoot(for: tab) }
    }

    /// Acts on the Top Shelf link once the item's server is connected. Open
    /// lands on the item's detail page in Home; Play plays it like any Play
    /// button (Settings' Play Starts), from the server's current position, not
    /// the one the snapshot was written with.
    private func openPendingTopShelfLink() async {
        guard let link = topShelfLinks.pending else { return }
        // A tile from another profile's shelf never plays under this one.
        if link.isStale() || link.profileID != plexService.activeProfileID {
            topShelfLinks.pending = nil
            return
        }
        guard plexService.pool.connection(for: link.id.serverID) != nil else { return }
        topShelfLinks.pending = nil

        switch link.action {
        case .open:
            if selectedTab != .home {
                activate(.home)
            }
            homePath = NavigationPath([link.route])
        case .play:
            // Clearing `pending` above changes the `.task(id:)` key and cancels
            // this task, so playback runs in its own task.
            let plexService = plexService
            let playback = playback
            Task { @MainActor in
                let details = try? await plexService.getMediaDetails(
                    ratingKey: link.id.ratingKey,
                    serverID: link.id.serverID
                )
                await playback.play(
                    id: link.id,
                    resumeOffsetMilliseconds: details?.viewOffset,
                    resumeOffsetDurationMilliseconds: details?.duration,
                    placeholder: details.map(PlaybackPlaceholder.init(details:))
                )
            }
        }
    }
    #endif

    private var hasDownloads: Bool {
        DownloadsFeature.isVisible && !downloadManager.records.isEmpty
    }

    private var availableTabs: [MainTabItem] {
        let desiredTabs = desiredAvailableTabs

        #if os(tvOS)
        return desiredTabs
        #else
        // Downloads is a tab only while records exist. Deleting or cancelling
        // the last one from inside it must not tear down the page in use; the
        // tab goes on the next tab change. (With More, the slot swap below
        // keeps it.)
        if selectedTab == .downloads,
           !desiredTabs.contains(.downloads),
           !desiredTabs.contains(.more),
           let settingsIndex = desiredTabs.firstIndex(of: .settings) {
            var retainedTabs = desiredTabs
            retainedTabs.insert(.downloads, at: settingsIndex)
            return retainedTabs
        }

        guard UIDevice.current.userInterfaceIdiom != .pad else {
            return desiredTabs
        }

        // Never tear down the selected tab just because a visibility change
        // crosses the iPhone's five-tab limit. Replacing a selected More tab
        // with Settings (or the reverse) destroys its NavigationStack while a
        // pushed settings destination is still active. Keep that container
        // mounted until the user selects a different tab; the desired layout
        // takes effect immediately after the selection changes.
        if selectedTab == .more, !desiredTabs.contains(.more) {
            let trailingTabs: Set<MainTabItem> = [.downloads, .settings]
            return desiredTabs.filter { !trailingTabs.contains($0) } + [.more]
        }

        if !desiredTabs.contains(selectedTab),
           let moreIndex = desiredTabs.firstIndex(of: .more) {
            var retainedTabs = desiredTabs
            retainedTabs[moreIndex] = selectedTab
            return retainedTabs
        }

        return desiredTabs
        #endif
    }

    private var desiredAvailableTabs: [MainTabItem] {
        let availableLibraryTypes = librariesViewModel?.availableLibraryTypes ?? [.movie, .show]
        let availableTypes = availableLibraryTypes + (liveTVViewModel?.isAvailable == true ? [.liveTV] : [])
        let contentTabs = preferences.visibleLibraryTabs(from: availableTypes).map { type in
            type == .liveTV ? MainTabItem.liveTV : MainTabItem.library(type)
        }
        let baseTabs: [MainTabItem] = [.home] + contentTabs

        #if os(tvOS)
        let discoverTabs: [MainTabItem] = seerrService.isAvailableForCurrentContext ? [.discover] : []
        return baseTabs + discoverTabs + [.search, .settings]
        #else
        if UIDevice.current.userInterfaceIdiom == .pad {
            var trailingTabs: [MainTabItem] = []
            if hasDownloads {
                trailingTabs.append(.downloads)
            }
            trailingTabs.append(.settings)
            return baseTabs + trailingTabs
        }

        var trailingTabs: [MainTabItem] = []
        if hasDownloads {
            trailingTabs.append(.downloads)
        }
        trailingTabs.append(.settings)

        if baseTabs.count + trailingTabs.count > 5 {
            return [.home] + Array(contentTabs.prefix(3)) + [.more]
        }

        return baseTabs + trailingTabs
        #endif
    }

    /// Downloads folds into the More tab whenever it no longer fits as its own
    /// tab; the More list only shows a Downloads row in that case.
    private var moreTabIncludesDownloads: Bool {
        hasDownloads && !availableTabs.contains(.downloads)
    }

    private var moreTabContentTypes: [PlexLibraryType] {
        guard availableTabs.contains(.more) else { return [] }
        let availableLibraryTypes = librariesViewModel?.availableLibraryTypes ?? []
        let availableTypes = availableLibraryTypes + (liveTVViewModel?.isAvailable == true ? [.liveTV] : [])
        let visibleTypes = preferences.visibleLibraryTabs(from: availableTypes)
        let flatTypes = availableTabs.compactMap { tab -> PlexLibraryType? in
            switch tab {
            case .library(let type): type
            case .liveTV: .liveTV
            default: nil
            }
        }
        return visibleTypes.filter { !flatTypes.contains($0) }
    }

    @ViewBuilder
    private func tabRootView(for tab: MainTabItem) -> some View {
        switch tab {
        case .home:
            #if os(tvOS)
            HomeView(
                path: $homePath,
                isSelected: selectedTab == .home,
                liveTVViewModel: resolvedLiveTVViewModel,
                pageScroll: homeScroll,
                scrollToTopRevision: homeScrollToTopRevision
            )
            #else
            HomeView(
                path: $homePath,
                isSelected: selectedTab == .home,
                liveTVViewModel: resolvedLiveTVViewModel
            )
            #endif
        case .library(let libraryType):
            if let librariesViewModel {
                LibrariesView(
                    libraryType: libraryType,
                    viewModel: librariesViewModel,
                    path: binding(for: libraryType)
                )
            } else {
                NavigationStack(path: binding(for: libraryType)) {
                    ZStack {
                        Color.ithacaBackground.ignoresSafeArea()
                        FeatureLoadingView()
                    }
                }
            }
        case .liveTV:
            LiveTVView(viewModel: resolvedLiveTVViewModel, path: $liveTVPath)
        case .downloads:
            DownloadsView(path: $downloadsPath)
        case .discover:
            DiscoverView(path: $discoverPath)
        case .search:
            SearchView(path: $searchPath)
        case .settings:
            SettingsView(path: $settingsPath)
        case .more:
            if let librariesViewModel {
                MoreView(
                    path: $morePath,
                    showsDownloads: moreTabIncludesDownloads,
                    contentTypes: moreTabContentTypes,
                    librariesViewModel: librariesViewModel,
                    liveTVViewModel: resolvedLiveTVViewModel
                )
            }
        }
    }

    private var resolvedLiveTVViewModel: LiveTVViewModel {
        if let liveTVViewModel {
            return liveTVViewModel
        }
        let viewModel = LiveTVViewModel(plexService: plexService)
        return viewModel
    }

    private func activate(_ tab: MainTabItem) {
        if selectedTab == tab {
            popToRoot(for: tab)
            return
        }

        if !desiredAvailableTabs.contains(selectedTab) {
            setPath(NavigationPath(), for: selectedTab)
        }
        selectedTab = tab
    }

    private func popToRoot(for tab: MainTabItem) {
        guard !path(for: tab).isEmpty else { return }

        withAnimation {
            setPath(NavigationPath(), for: tab)
        }
    }

    private func path(for tab: MainTabItem) -> NavigationPath {
        switch tab {
        case .home:
            homePath
        case .library(.movie):
            moviesPath
        case .library(.show):
            showsPath
        case .library(.video):
            videosPath
        case .library(.liveTV), .liveTV:
            liveTVPath
        case .downloads:
            downloadsPath
        case .discover:
            discoverPath
        case .search:
            searchPath
        case .settings:
            settingsPath
        case .more:
            morePath
        }
    }

    private func setPath(_ path: NavigationPath, for tab: MainTabItem) {
        switch tab {
        case .home:
            homePath = path
        case .library(.movie):
            moviesPath = path
        case .library(.show):
            showsPath = path
        case .library(.video):
            videosPath = path
        case .library(.liveTV), .liveTV:
            liveTVPath = path
        case .downloads:
            downloadsPath = path
        case .discover:
            discoverPath = path
        case .search:
            searchPath = path
        case .settings:
            settingsPath = path
        case .more:
            morePath = path
        }
    }

    private func binding(for libraryType: PlexLibraryType) -> Binding<NavigationPath> {
        switch libraryType {
        case .movie:
            $moviesPath
        case .show:
            $showsPath
        case .video:
            $videosPath
        case .liveTV:
            $liveTVPath
        }
    }
}

#if DEBUG
private extension MainTabView {
    /// Screenshot mode (`ScreenshotMode`): opens the requested screen once the
    /// demo server and its libraries are in.
    func applyScreenshotDestination() async {
        guard ScreenshotMode.isActive else { return }
        for _ in 0..<60 {
            if let destination = await ScreenshotMode.consumeDestination(
                plexService: plexService,
                libraries: librariesViewModel?.libraries ?? [],
                downloadManager: downloadManager
            ) {
                if selectedTab != destination.tab {
                    selectedTab = destination.tab
                }
                setPath(NavigationPath(destination.routes), for: destination.tab)
                if let playID = destination.playID {
                    await playback.playForScreenshot(
                        id: playID,
                        startPosition: destination.playOffsetMilliseconds.map { TimeInterval($0) / 1000 }
                    )
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
    }
}
#endif

#if os(tvOS)
private struct TopShelfLinkAttempt: Equatable {
    let link: TopShelfLink?
    let revision: ServerContentRevision
}
#endif

#if os(iOS)
private struct SeerrArrivalAttempt: Equatable {
    let link: SeerrArrivalLinks.Link?
    let revision: ServerContentRevision
    let isPlayerShown: Bool
}
#endif

private struct SiriCatalogRefreshTrigger: Equatable {
    let revision: ServerContentRevision
    let isActive: Bool
}
