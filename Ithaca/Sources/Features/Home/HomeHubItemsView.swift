import SwiftUI

struct HomeHubItemsView: View {
    @State private var viewModel: HomeHubItemsViewModel
    @Environment(\.scenePhase) private var scenePhase

    private let horizontalPadding: CGFloat = IthacaPosterMetrics.gridHorizontalPadding
    private let gridSpacing: CGFloat = IthacaPosterMetrics.gridSpacing
    private let gridRowSpacing: CGFloat = IthacaPosterMetrics.gridRowSpacing
    private let minimumColumnCount = 2

    private var isVideoHub: Bool {
        viewModel.items.isAllClips
    }

    private var preferredPosterWidth: CGFloat {
        isVideoHub ? IthacaPosterMetrics.videoGridPreferredWidth : IthacaPosterMetrics.gridPreferredWidth
    }

    private var imageAspectRatio: CGFloat {
        isVideoHub ? 16.0 / 9.0 : 2.0 / 3.0
    }

    init(hub: PlexHub, plexService: PlexService) {
        _viewModel = State(initialValue: HomeHubItemsViewModel(
            hub: hub,
            plexService: plexService
        ))
    }

    var body: some View {
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.items.isEmpty {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.items.isEmpty {
                FeatureErrorView(message: error) {
                    Task { await viewModel.reloadItems() }
                }
            } else if viewModel.items.isEmpty {
                emptyView
            } else {
                itemsGrid
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

    private var itemsGrid: some View {
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
                    PlexItemPosterGrid(
                        items: viewModel.items,
                        layout: layout,
                        rowSpacing: gridRowSpacing,
                        imageAspectRatio: imageAspectRatio,
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
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, 32)

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

    private var emptyView: some View {
        FeatureEmptyStateView(systemImage: "film", title: "No items found")
    }
}
