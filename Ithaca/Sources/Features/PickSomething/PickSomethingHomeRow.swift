import SwiftUI

/// Home's way into Pick Something: one button, above the Plex hubs. Hidden
/// when there is no movie or TV library to pick from, or when Settings turns
/// it off.
struct PickSomethingHomeRow: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences

    /// Whether the row renders. tvOS Home mirrors it to pick the shelf the
    /// hero's down-press lands on.
    static func isShown(in plexService: PlexService, preferences: UserPreferences) -> Bool {
        preferences.showsPickSomethingOnHome && plexService.libraryOrder.orderedSections.contains {
            $0.libraryType == .movie || $0.libraryType == .show
        }
    }

    var body: some View {
        if Self.isShown(in: plexService, preferences: preferences) {
            HStack(spacing: 24) {
                NavigationLink(value: AppNavigationRoute.pickSomething(.movie)) {
                    HStack(spacing: 8) {
                        Image(systemName: "dice")
                        Text("Pick Something")
                            .lineLimit(1)
                    }
                    .font(IthacaFont.buttonLabel(ios: .headline.weight(.semibold)))
                    .foregroundStyle(Color.primary)
                    #if os(tvOS)
                    .frame(minHeight: 28)
                    #else
                    .padding(.horizontal, 4)
                    .frame(minHeight: 32)
                    #endif
                    .contentShape(Capsule())
                }
                .pickSomethingGlassButtonStyle()
                // On tvOS Home this can be the first thing under the hero.
                .carouselLeadingFocusTarget()

                Text("Three picks from your libraries.")
                    .font(IthacaFont.caption(ios: .subheadline))
                    .foregroundStyle(Color.ithacaTextSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, IthacaPosterMetrics.carouselHorizontalPadding)
        }
    }
}

private extension View {
    /// Plain Liquid Glass, not the hero's prominent style: this sits among
    /// the shelves and should not outshout the artwork.
    @ViewBuilder
    func pickSomethingGlassButtonStyle() -> some View {
        #if os(tvOS)
        self
            .buttonStyle(.glass)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
        #else
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
        } else {
            self
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        }
        #endif
    }
}
