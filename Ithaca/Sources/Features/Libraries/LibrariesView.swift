import SwiftUI

/// The list of a type's libraries, as a navigation value.
///
/// Local to this screen rather than an `AppNavigationRoute` case because it is
/// only ever reachable from the type tab itself: the tab lands on merged
/// recommendations and this is the way out to the individual libraries.
struct LibraryTypeListDestination: Hashable {
    let libraryType: PlexLibraryType
}

struct LibrariesView: View {
    let libraryType: PlexLibraryType
    let viewModel: LibrariesViewModel
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            LibrariesRootContent(libraryType: libraryType, viewModel: viewModel)
                .ithacaAppNavigationDestinations()
        }
    }
}

struct LibrariesRootContent: View {
    @Environment(PlexService.self) private var plexService
    let libraryType: PlexLibraryType
    let viewModel: LibrariesViewModel

    var body: some View {
        rootContent
            // Reloads when a server connects, drops out, is reordered or
            // switched off: the tab shell mounts before anything is connected.
            .task(id: viewModel.serverContentRevision) {
                await viewModel.loadLibraries()
            }
            .navigationDestination(for: LibraryTypeListDestination.self) { destination in
                LibraryTypeListView(libraryType: destination.libraryType, viewModel: viewModel)
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        let libraries = viewModel.libraries(for: libraryType)

        if viewModel.libraries.isEmpty, !viewModel.availability.isReady {
            // Nothing to list and the cause is the servers, not this screen.
            ZStack {
                Color.ithacaBackground.ignoresSafeArea()
                ServerAvailabilityStateView(availability: viewModel.availability)
            }
            .ithacaNavigationTitle(libraryType.tabTitle)
            .ithacaNavigationBarTitleDisplayModeLarge()
        } else if viewModel.isLoading && viewModel.libraries.isEmpty {
            loadingView
        } else if let error = viewModel.error, viewModel.libraries.isEmpty {
            errorView(message: error)
        } else if libraries.isEmpty {
            emptyView
        } else {
            // The tab always lands on recommendations, merged across every
            // library of this type on every server. With one library this is
            // exactly the screen it always was; with several, "Libraries" in
            // the toolbar opens the list.
            LibraryRecommendationsView(
                libraries: libraries,
                plexService: plexService,
                navigationTitle: libraryType.tabTitle,
                libraryListDestination: libraries.count > 1
                    ? LibraryTypeListDestination(libraryType: libraryType)
                    : nil
            )
        }
    }

    private var loadingView: some View {
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()
            FeatureLoadingView()
        }
        .ithacaNavigationTitle(libraryType.tabTitle)
        .ithacaNavigationBarTitleDisplayModeLarge()
    }

    private func errorView(message: String) -> some View {
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()
            FeatureErrorView(message: message) {
                Task { await viewModel.loadLibraries(force: true) }
            }
        }
        .ithacaNavigationTitle(libraryType.tabTitle)
        .ithacaNavigationBarTitleDisplayModeLarge()
    }

    private var emptyView: some View {
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()
            FeatureEmptyStateView(
                systemImage: libraryType.systemImage,
                title: "No \(libraryType.tabTitle) libraries found"
            )
        }
        .ithacaNavigationTitle(libraryType.tabTitle)
        .ithacaNavigationBarTitleDisplayModeLarge()
    }
}

/// Every library of one type, in the account's cross-server order.
struct LibraryTypeListView: View {
    let libraryType: PlexLibraryType
    let viewModel: LibrariesViewModel

    var body: some View {
        let libraries = viewModel.libraries(for: libraryType)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ServerOutageNote(offlineServerNames: viewModel.availability.offlineServerNames)
                    .padding(.horizontal, 4)

                ForEach(libraries) { library in
                    NavigationLink(value: AppNavigationRoute.libraryRecommendations(library)) {
                        LibraryRowContent(library: library, vm: viewModel)
                    }
                    .ithacaSuppressTVOSButtonChrome()
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .background(Color.ithacaBackground.ignoresSafeArea())
        .ithacaNavigationTitle(libraryType.tabTitle)
        .ithacaNavigationBarTitleDisplayModeLarge()
    }
}

private struct LibraryRowContent: View {
    let library: PlexLibrary
    let vm: LibrariesViewModel

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                if let url = vm.artURL(for: library, width: 64, height: 64) {
                    IthacaAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            libraryIconPlaceholder(vm.iconName(for: library))
                        }
                    }
                } else {
                    libraryIconPlaceholder(vm.iconName(for: library))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 4) {
                // Carries the server name only when another library of the same
                // type has the same title. See `ServerLabeling`.
                Text(vm.displayTitle(for: library))
                    .font(IthacaFont.rowTitle(ios: .headline))
                    .foregroundStyle(Color.ithacaTextPrimary)

                Text(libraryTypeLabel)
                    .font(IthacaFont.caption(ios: .subheadline))
                    .foregroundStyle(Color.ithacaTextSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(IthacaFont.glyphSmall(ios: .caption))
                .foregroundStyle(Color.ithacaTextSecondary)
        }
        .padding(12)
        .background(Color.ithacaSurface)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .ithacaTVOSFocusEffectShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var libraryTypeLabel: String {
        library.libraryType?.tabTitle ?? library.type.capitalized
    }

    private func libraryIconPlaceholder(_ iconName: String) -> some View {
        Color.ithacaSurface
            .overlay {
                Image(systemName: iconName)
                    .font(libraryPlaceholderIconFont)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
    }

    private var libraryPlaceholderIconFont: Font {
        IthacaFont.glyphMedium(ios: .title2)
    }
}

// MARK: - PlexLibrary Hashable conformance for NavigationLink

/// Keyed on `id` (`"<serverID>|<key>"`), never on `key` alone: section keys are
/// per-server counters, so two servers' "3" sections would compare equal and a
/// navigation link could open the wrong library.
extension PlexLibrary: Hashable {
    static func == (lhs: PlexLibrary, rhs: PlexLibrary) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
