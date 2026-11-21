import SwiftUI

struct LibraryItemsView: View {
    @State private var viewModel: LibraryItemsViewModel
    @Environment(\.scenePhase) private var scenePhase

    private let horizontalPadding: CGFloat = IthacaPosterMetrics.gridHorizontalPadding
    private let gridSpacing: CGFloat = IthacaPosterMetrics.gridSpacing
    private let gridRowSpacing: CGFloat = IthacaPosterMetrics.gridRowSpacing
    private let minimumColumnCount = 2

    init(
        library: PlexLibrary,
        plexService: PlexService,
        collection: PlexLibraryCollection? = nil,
        initialGenre: LibraryGenreOption? = nil,
        preferLocalGenreFiltering: Bool = false
    ) {
        _viewModel = State(initialValue: LibraryItemsViewModel(
            library: library,
            plexService: plexService,
            collection: collection,
            initialGenre: initialGenre,
            preferLocalGenreFiltering: preferLocalGenreFiltering
        ))
    }

    /// Video libraries browse in 16:9 clip cards; movie/show grids keep the
    /// standard 2:3 posters.
    private var preferredPosterWidth: CGFloat {
        viewModel.isVideoLibrary ? IthacaPosterMetrics.videoGridPreferredWidth : IthacaPosterMetrics.gridPreferredWidth
    }

    private var gridImageAspectRatio: CGFloat {
        viewModel.isVideoLibrary ? 16.0 / 9.0 : 2.0 / 3.0
    }

    var body: some View {
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.items.isEmpty {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.items.isEmpty, !viewModel.showsBrowseControls {
                FeatureErrorView(message: error) {
                    Task { await viewModel.loadItems() }
                }
            } else {
                libraryContent
            }
        }
        .ithacaNavigationTitle(viewModel.navigationTitle)
        .ithacaNavigationBarTitleDisplayModeLarge()
        // Runs again each time the grid reappears, which refreshes it.
        .task {
            await viewModel.loadItems()
        }
        .actionErrorAlert(viewModel.actionError) { viewModel.actionError = nil }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, !viewModel.items.isEmpty else { return }
            Task { await viewModel.loadItems() }
        }
    }

    private var libraryContent: some View {
        GeometryReader { geometry in
            let layout = AdaptivePosterGridLayout.make(
                containerWidth: geometry.size.width,
                horizontalPadding: horizontalPadding,
                gridSpacing: gridSpacing,
                preferredPosterWidth: preferredPosterWidth,
                minimumColumnCount: minimumColumnCount
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.showsBrowseControls {
                        browseControls
                    }

                    if let error = viewModel.error, viewModel.items.isEmpty {
                        FeatureErrorView(message: error) {
                            Task { await viewModel.reloadItems() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, 40)
                    } else if viewModel.items.isEmpty {
                        emptyView
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.top, 40)
                    } else {
                        posterGrid(layout)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 32)
                        .padding(.bottom, 32)
                    }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }

                    if viewModel.loadMoreFailed {
                        loadMoreRetry
                    }
                }
            }
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    private var loadMoreRetry: some View {
        FeatureErrorView(message: "Couldn't load more titles.") {
            Task { await viewModel.retryLoadMore() }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var browseControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if viewModel.availableGenres.count > 1 {
                    genreMenu
                }

                unwatchedToggle

                sortMenu

                if viewModel.isLoading && !viewModel.items.isEmpty {
                    ProgressView()
                        .padding(.leading, 6)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    private var genreMenu: some View {
        Menu {
            Section("Genre") {
                ForEach(viewModel.availableGenres) { genre in
                    Button {
                        Task { await viewModel.selectGenre(genre) }
                    } label: {
                        if genre == viewModel.selectedGenre {
                            Label(genre.title, systemImage: "checkmark")
                        } else {
                            Text(genre.title)
                        }
                    }
                }
            }
        } label: {
            FilterMenuChipLabel(
                value: viewModel.selectedGenre.title,
                systemImage: "line.3.horizontal.decrease.circle",
                isActive: viewModel.selectedGenre != .all,
                accessibilityLabel: "Genre"
            )
        }
        .ithacaSuppressTVOSButtonChrome()
    }

    private var sortMenu: some View {
        Menu {
            Section("Sort") {
                ForEach(viewModel.availableSortOptions) { sort in
                    Button {
                        Task { await viewModel.selectSort(sort) }
                    } label: {
                        if sort == viewModel.selectedSort {
                            Label(sort.title, systemImage: "checkmark")
                        } else {
                            Text(sort.title)
                        }
                    }
                }
            }
        } label: {
            FilterMenuChipLabel(
                value: viewModel.selectedSort.title,
                systemImage: "arrow.up.arrow.down.circle",
                isActive: viewModel.selectedSort != viewModel.defaultSortOption,
                accessibilityLabel: "Sort"
            )
        }
        .ithacaSuppressTVOSButtonChrome()
    }

    private var unwatchedToggle: some View {
        let isOn = viewModel.showsUnwatchedOnly
        return FilterToggleChip(title: "Unwatched", isOn: isOn, accessibilityLabel: "Unwatched only") {
            Task { await viewModel.setShowsUnwatchedOnly(!isOn) }
        }
    }

    private func posterGrid(_ layout: AdaptivePosterGridLayout) -> some View {
        PlexItemPosterGrid(
            items: viewModel.items,
            layout: layout,
            rowSpacing: gridRowSpacing,
            imageAspectRatio: gridImageAspectRatio,
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            },
            subtitle: { viewModel.subtitle(for: $0) },
            progress: { viewModel.progress(for: $0) },
            onItemAppear: { item in
                Task { await viewModel.loadMoreIfNeeded(currentItem: item) }
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

    private var emptyView: some View {
        FeatureEmptyStateView(
            systemImage: viewModel.emptyStateSystemImage,
            title: viewModel.emptyStateTitle,
            message: viewModel.emptyStateMessage
        )
    }
}
