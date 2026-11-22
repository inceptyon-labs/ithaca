import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LibraryRecommendationsView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var viewModel: LibraryRecommendationsViewModel

    private let navigationTitle: String
    private let libraries: [PlexLibrary]
    /// Where "Browse" goes when this screen covers several libraries: the list
    /// of them, because there is no single library to open.
    private let libraryListDestination: LibraryTypeListDestination?

    private let continueWatchingCardWidth: CGFloat = IthacaPosterMetrics.continueWatchingWidth
    private let continueWatchingAspectRatio: CGFloat = 16.0 / 9.0

    init(
        library: PlexLibrary,
        plexService: PlexService,
        navigationTitle: String
    ) {
        self.init(
            libraries: [library],
            plexService: plexService,
            navigationTitle: navigationTitle,
            libraryListDestination: nil
        )
    }

    init(
        libraries: [PlexLibrary],
        plexService: PlexService,
        navigationTitle: String,
        libraryListDestination: LibraryTypeListDestination?
    ) {
        self.navigationTitle = navigationTitle
        self.libraries = libraries
        self.libraryListDestination = libraryListDestination
        _viewModel = State(initialValue: LibraryRecommendationsViewModel(
            libraries: libraries,
            plexService: plexService
        ))
    }

    var body: some View {
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()

            if !viewModel.hasLoadedOnce,
               viewModel.error == nil,
               !viewModel.hasAnyContent {
                FeatureLoadingView()
            } else {
                contentView
            }
        }
        .task {
            await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
        }
        .onChange(of: libraries.map(\.id)) {
            viewModel.update(libraries: libraries)
            Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
        }
        .onChange(of: playback.showPlayer) { _, isShowing in
            if !isShowing {
                Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
            }
        }
        .actionErrorAlert(viewModel.actionError) { viewModel.actionError = nil }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, viewModel.hasLoadedOnce else { return }
            Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                SearchToolbarLink()

                browseLibraryButton(labelText: "Browse Library")
            }
        }
        #endif
        .ithacaNavigationTitle(navigationTitle)
        .ithacaNavigationBarTitleDisplayModeLarge()
    }

    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                #if os(tvOS)
                HStack {
                    Spacer()
                    browseLibraryButton(labelText: "Browse")
                }
                .padding(.horizontal, IthacaPosterMetrics.carouselHorizontalPadding)
                .padding(.top, IthacaPosterMetrics.carouselHeaderSpacing)
                .padding(.bottom, IthacaPosterMetrics.carouselHeaderSpacing)
                #endif

                if let error = viewModel.error,
                   !viewModel.hasAnyContent {
                    FeatureErrorView(message: error) {
                        Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                    }
                    .padding(.top, 40)
                } else if !viewModel.hasAnyContent {
                    emptyView
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: IthacaPosterMetrics.pageSectionSpacing) {
                        ServerOutageNote()
                            .padding(.horizontal, IthacaPosterMetrics.libraryPageHorizontalPadding)

                        if !viewModel.continueWatching.isEmpty {
                            continueWatchingSection
                        }

                        ForEach(viewModel.prioritizedHubs) { hub in
                            let items = viewModel.inlineItems(in: hub)

                            if !items.isEmpty {
                                hubSection(hub, items: items)
                            }
                        }

                        if viewModel.isVideoLibrary {
                            ForEach(viewModel.secondaryHubs) { hub in
                                let items = viewModel.inlineItems(in: hub)

                                if !items.isEmpty {
                                    hubSection(hub, items: items)
                                }
                            }

                            ForEach(viewModel.channelShelves) { row in
                                if !row.shelf.items.isEmpty {
                                    channelShelfSection(row)
                                }
                            }

                            if !viewModel.rediscoverItems.isEmpty {
                                rediscoverSection
                            }
                        } else {
                            ForEach(viewModel.personalizedShelves) { shelf in
                                if !shelf.items.isEmpty {
                                    personalizedShelfSection(shelf)
                                }
                            }

                            ForEach(viewModel.secondaryHubs) { hub in
                                let items = viewModel.inlineItems(in: hub)

                                if !items.isEmpty {
                                    hubSection(hub, items: items)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 48)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 88)
        }
        .refreshable {
            await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        .ithacaTVOSPageBackground()
    }

    /// One library: browse it. Several: open the list of them, because there
    /// is no single library the button could mean.
    @ViewBuilder
    private func browseLibraryButton(labelText: String) -> some View {
        if let libraryListDestination, viewModel.isMultiLibrary {
            styledBrowseLink(
                NavigationLink(value: libraryListDestination) {
                    browseLabel("Libraries")
                }
            )
        } else {
            styledBrowseLink(
                NavigationLink(value: AppNavigationRoute.library(viewModel.library)) {
                    browseLabel(labelText)
                }
            )
        }
    }

    @ViewBuilder
    private func browseLabel(_ labelText: String) -> some View {
        #if os(tvOS)
        Text(labelText)
            .font(IthacaFont.buttonLabel(ios: .subheadline.weight(.semibold)))
        #else
        Label(labelText, systemImage: "square.grid.2x2")
            .font(.subheadline.weight(.semibold))
        #endif
    }

    @ViewBuilder
    private func styledBrowseLink(_ link: some View) -> some View {
        #if os(tvOS)
        link
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .buttonStyle(.glass)
            .tint(Color.primary)
        #else
        link
            .buttonStyle(.plain)
        #endif
    }

    private var continueWatchingSection: some View {
        PlexItemActionCarouselSection(
            title: viewModel.continueWatchingTitle,
            items: viewModel.continueWatching,
            action: { play($0) },
            posterWidth: continueWatchingCardWidth,
            imageAspectRatio: continueWatchingAspectRatio,
            horizontalPadding: IthacaPosterMetrics.libraryPageHorizontalPadding,
            subtitle: { viewModel.displaySubtitle(for: $0) },
            posterURL: { item, width, height in
                // Hide Spoilers: the show's art instead of an unstarted
                // episode's still.
                if preferences.hidesSpoilers(for: item) {
                    return plexService.imageURL(
                        for: item.grandparentArt ?? item.art,
                        serverID: item.serverID,
                        width: width,
                        height: height
                    )
                }
                return viewModel.landscapeImageURL(for: item, width: width, height: height)
            },
            progress: { viewModel.progress(for: $0) }
        ) { item in
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                },
                detailsRoute: AppNavigationRoute.destination(for: item),
                detailsLabel: detailsLabel(for: item)
            )
        }
    }

    @ViewBuilder
    private func personalizedShelfSection(_ shelf: LibraryPersonalizedShelf) -> some View {
        PlexItemPosterCarouselSection(
            title: shelf.title,
            items: shelf.items,
            horizontalPadding: IthacaPosterMetrics.libraryPageHorizontalPadding,
            showAllRoute: shelf.showAllLibrary.map {
                AppNavigationRoute.libraryGenre(library: $0, genre: shelf.genre)
            },
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            }
        ) { item in
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                }
            )
        }
    }

    @ViewBuilder
    private func hubSection(_ hub: PlexHub, items: [PlexItem]) -> some View {
        let showsShowAll = viewModel.shouldShowAll(for: hub)

        PlexItemPosterCarouselSection(
            title: viewModel.normalizedTitle(for: hub),
            items: items,
            posterWidth: shelfPosterWidth,
            imageAspectRatio: shelfImageAspectRatio,
            horizontalPadding: IthacaPosterMetrics.libraryPageHorizontalPadding,
            showAllRoute: showsShowAll ? AppNavigationRoute.hub(hub) : nil,
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            }
        ) { item in
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                }
            )
        }
    }

    @ViewBuilder
    private func channelShelfSection(_ row: LibraryChannelRow) -> some View {
        let shelf = row.shelf

        PlexItemPosterCarouselSection(
            title: shelf.collection.title,
            items: shelf.items,
            posterWidth: shelfPosterWidth,
            imageAspectRatio: shelfImageAspectRatio,
            horizontalPadding: IthacaPosterMetrics.libraryPageHorizontalPadding,
            showAllRoute: AppNavigationRoute.libraryCollection(
                library: row.library,
                collection: shelf.collection
            ),
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            }
        ) { item in
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                }
            )
        }
    }

    private var rediscoverSection: some View {
        PlexItemPosterCarouselSection(
            title: "Rediscover",
            items: viewModel.rediscoverItems,
            posterWidth: shelfPosterWidth,
            imageAspectRatio: shelfImageAspectRatio,
            horizontalPadding: IthacaPosterMetrics.libraryPageHorizontalPadding,
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            }
        ) { item in
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                }
            )
        }
    }

    /// Video-library shelves render 16:9 clip cards; movie/show shelves keep
    /// the standard 2:3 posters.
    private var shelfPosterWidth: CGFloat {
        viewModel.isVideoLibrary ? IthacaPosterMetrics.videoCarouselWidth : IthacaPosterMetrics.carouselPosterWidth
    }

    private var shelfImageAspectRatio: CGFloat {
        viewModel.isVideoLibrary ? 16.0 / 9.0 : 2.0 / 3.0
    }

    private var emptyView: some View {
        FeatureEmptyStateView(
            systemImage: viewModel.library.libraryType?.systemImage ?? "rectangle.stack",
            title: "No recommendations right now"
        )
    }

    private var recentlyAddedInlineItemLimit: Int {
        #if os(iOS)
        isRegularCanvas(horizontalSizeClass, verticalSizeClass) ? 22 : 15
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

    private func detailsLabel(for item: PlexItem) -> String {
        if item.isClip {
            return "Go to Video"
        }

        switch item.type {
        case .episode:
            return "Go to Episode"
        case .movie:
            return "Go to Movie"
        default:
            return "View Details"
        }
    }
}
