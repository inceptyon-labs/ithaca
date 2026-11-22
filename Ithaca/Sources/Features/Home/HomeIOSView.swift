#if os(iOS)
import SwiftUI
import UIKit

struct HomeIOSView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(UserPreferences.self) private var preferences
    @Environment(SeerrService.self) private var seerrService
    @Binding var path: NavigationPath
    @State private var isHeroOnScreen = true

    let viewModel: HomeViewModel
    /// Enabled servers that are currently unreachable. Only used for the quiet
    /// inline note; Home never names the server a row came from, because with
    /// every server merged into one screen that would be noise.
    let offlineServerNames: [String]
    let recentlyAddedInlineItemLimit: Int
    let heroSelectionResetRevision: Int
    let liveTVViewModel: LiveTVViewModel
    let showsLiveTV: Bool
    let playLiveTV: (PlexLiveChannel, PlexLiveProgram, PlexLiveTVLineup) -> Void
    let play: (PlexItem) -> Void

    var body: some View {
        applyNavigationChrome(to: content, showsHero: showsCinematicHero)
            .toolbar {
                if seerrService.isAvailableForCurrentContext {
                    ToolbarItem(placement: .topBarTrailing) {
                        DiscoverToolbarLink()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SearchToolbarLink()
                }
            }
    }

    private var content: some View {
        GeometryReader { geometry in
            let heroItems = viewModel.heroItems()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !heroItems.isEmpty {
                        HomeCinematicHero(
                            items: heroItems,
                            viewModel: viewModel,
                            containerSize: geometry.size,
                            topInset: geometry.safeAreaInsets.top,
                            layout: heroLayout,
                            autoRotates: true,
                            supportsDragNavigation: true,
                            selectionResetRevision: heroSelectionResetRevision,
                            isOnScreen: isHeroOnScreen,
                            primaryAction: { item, callbacks in
                                AnyView(
                                    Button {
                                        callbacks.restartRotation()
                                        play(item)
                                    } label: {
                                        HomeHeroActionButtonLabel(
                                            title: preferences.playTitle(viewModel.heroPrimaryActionTitle(for: item)),
                                            systemImage: "play.fill",
                                            fillsWidth: true
                                        )
                                    }
                                    .homeHeroNativeButtonStyle()
                                    .frame(
                                        maxWidth: isRegularCanvas(horizontalSizeClass, verticalSizeClass) ? 300 : 240,
                                        alignment: .leading
                                    )
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { _ in callbacks.pauseRotation() }
                                    )
                                    .contextMenu {
                                        HomeItemContextMenu(
                                            item: item,
                                            detailsLabel: heroDetailsLabel(for: item),
                                            onMarkWatched: {
                                                Task { await viewModel.setWatched(true, for: item) }
                                            },
                                            onMarkUnwatched: {
                                                Task { await viewModel.setWatched(false, for: item) }
                                            },
                                            onSelectRoute: { route in
                                                path.append(route)
                                            },
                                            onRemoveFromContinueWatching: {
                                                Task { await viewModel.removeFromContinueWatching(item) }
                                            }
                                        )
                                    }
                                    .accessibilityAddTraits(.isButton)
                                )
                            },
                            detailsAction: { item in
                                path.append(AppNavigationRoute.destination(for: item))
                            }
                        )
                        // The hero stays mounted while the shelves scroll over
                        // it; this stops its rotation once it is out of view.
                        .onScrollVisibilityChange(threshold: 0.1) { isHeroOnScreen = $0 }
                    }

                    LazyVStack(alignment: .leading, spacing: 18) {
                        ServerOutageNote(offlineServerNames: offlineServerNames)
                            .padding(.horizontal, 20)

                        if showsLiveTV {
                            LiveTVHomeShelf(viewModel: liveTVViewModel, play: playLiveTV)
                        }

                        PickSomethingHomeRow()

                        SeerrRequestsHomeRow()

                        ForEach(viewModel.hubs) { hub in
                            hubSection(hub)
                        }

                        ForEach(viewModel.personalizedShelves) { shelf in
                            personalizedSection(shelf)
                        }
                    }
                    .padding(.top, heroItems.isEmpty ? 0 : 24)
                }
                .padding(.top, heroItems.isEmpty ? 16 : -geometry.safeAreaInsets.top)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 88)
        }
        .task(id: showsLiveTV) {
            guard showsLiveTV else { return }
            await liveTVViewModel.loadNowPlaying(force: true)
        }
    }

    @ViewBuilder
    private func hubSection(_ hub: PlexHub) -> some View {
        let items = viewModel.inlineItems(
            in: hub,
            maxRecentlyAddedItems: recentlyAddedInlineItemLimit
        )

        if !items.isEmpty {
            let isVideoHub = viewModel.isVideoHub(hub)

            PlexItemPosterCarouselSection(
                title: hub.title,
                items: items,
                posterWidth: isVideoHub ? IthacaPosterMetrics.videoCarouselWidth : 130,
                imageAspectRatio: isVideoHub ? 16.0 / 9.0 : 2.0 / 3.0,
                showAllRoute: viewModel.shouldShowAll(
                    for: hub,
                    maxRecentlyAddedItems: recentlyAddedInlineItemLimit
                ) ? AppNavigationRoute.hub(hub) : nil,
                subtitle: { isVideoHub ? $0.standardPosterSubtitle : $0.year.map(String.init) },
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
    }

    @ViewBuilder
    private func personalizedSection(_ shelf: HomePersonalizedShelf) -> some View {
        if !shelf.items.isEmpty {
            PlexItemPosterCarouselSection(
                title: shelf.title,
                items: shelf.items,
                posterWidth: 130,
                showAllRoute: viewModel.showAllRoute(for: shelf),
                subtitle: { item in
                    viewModel.subtitle(for: item)
                },
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
    }

    @ViewBuilder
    private func applyNavigationChrome<Content: View>(to content: Content, showsHero: Bool) -> some View {
        if showsHero {
            content
                .ithacaNavigationTitle("")
                .ithacaNavigationBarTitleDisplayModeInline()
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
                .ithacaNavigationTitle("Home")
                .ithacaNavigationBarTitleDisplayModeLarge()
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    /// iPad and the iPhone Duo's inner screen get the near-full-screen hero;
    /// iPhone (landscape included) and compact iPad multitasking keep the
    /// shorter banner.
    private var heroLayout: HomeCinematicHeroLayout {
        isRegularCanvas(horizontalSizeClass, verticalSizeClass) ? .iPad : .ios
    }

    private var showsCinematicHero: Bool {
        !viewModel.heroItems().isEmpty
    }

    private func heroDetailsLabel(for item: PlexItem) -> String {
        switch item.type {
        case .episode:
            return "Go to Episode"
        case .season:
            return "Go to Season"
        case .show:
            return "Go to Show"
        case .movie:
            return "Go to Movie"
        default:
            return "View Details"
        }
    }
}
#endif
