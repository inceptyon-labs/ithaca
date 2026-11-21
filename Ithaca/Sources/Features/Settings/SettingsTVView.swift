import SwiftUI

struct SettingsTVView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(SeerrService.self) private var seerrService
    @Environment(UserPreferences.self) private var preferences
    @Environment(IthacaStore.self) private var store
    let viewModel: SettingsViewModel

    var body: some View {
        SettingsContainer(viewModel: viewModel) {
            settingsContent
        }
    }

    private var settingsContent: some View {
        @Bindable var preferences = preferences
        let subtitleLanguageBinding = SettingsSupport.subtitleLanguageBinding(preferences)

        return ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                Text("Settings")
                    .font(IthacaFont.pageTitle(ios: .title.weight(.bold)))
                    .foregroundStyle(Color.ithacaTextPrimary)
                    .padding(.leading, TVSettingsMetrics.contentInset)

                if plexService.homeUsers.count > 1, let activeUser = plexService.activeHomeUser {
                    TVSettingsSection(
                        title: "Plex Home",
                        footer: "When off, Ithaca asks who’s watching whenever it starts."
                    ) {
                        HStack(spacing: 22) {
                            PlexHomeUserAvatar(user: activeUser, size: 68)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Current User")
                                    .font(IthacaFont.badge(ios: .caption.weight(.semibold)))
                                    .textCase(.uppercase)
                                    .tracking(0.5)
                                    .foregroundStyle(Color.ithacaTextSecondary)

                                Text(activeUser.displayName)
                                    .font(IthacaFont.rowTitle(ios: .headline.weight(.semibold)))
                                    .foregroundStyle(Color.ithacaTextPrimary)
                                    .lineLimit(1)
                            }

                            Spacer()
                        }
                        .frame(minHeight: 100)
                        .padding(.vertical, 14)

                        tvRowDivider

                        TVSettingsActionRow(
                            title: "Switch User",
                            showsChevron: true
                        ) {
                            viewModel.showHomeUserPicker = true
                        }

                        tvRowDivider

                        TVSettingsToggleRow(
                            title: "Automatically Sign In",
                            isOn: automaticHomeSignInBinding
                        )
                    }
                }

                TVSettingsSection(
                    title: "Ithaca Pro",
                    footer: "Describe It in Pick Something. Restore a purchase here too."
                ) {
                    TVSettingsNavigationRow(
                        title: "Ithaca Pro",
                        detail: ProStatus.summary(store.entitlement)
                    ) {
                        ProView()
                    }
                }

                TVSettingsSection(
                    title: "Integrations",
                    footer: "Seerr adds requestable movies and shows to search. Athena, a server of your own, lets Claude answer Describe It instead of this device."
                ) {
                    TVSettingsNavigationRow(
                        title: "Seerr",
                        detail: seerrService.connectionSubtitle
                    ) {
                        SeerrSettingsView()
                    }

                    tvRowDivider

                    TVSettingsNavigationRow(
                        title: "Athena",
                        detail: SettingsSupport.athenaSubtitle(preferences)
                    ) {
                        AthenaSettingsView()
                    }
                }

                TVSettingsSection(
                    title: "Navigation",
                    footer: SettingsSupport.navigationFooterText
                ) {
                    TVSettingsNavigationRow(
                        title: "Navigation Tabs",
                        detail: SettingsSupport.libraryTabsSummary(preferences)
                    ) {
                        LibraryTabSettingsView()
                    }

                    tvRowDivider

                    TVSettingsNavigationRow(
                        title: "Library Order",
                        detail: SettingsSupport.libraryOrderSummary(plexService)
                    ) {
                        LibraryOrderSettingsView()
                    }

                    tvRowDivider

                    TVSettingsNavigationRow(
                        title: "Server Priority",
                        detail: SettingsSupport.serverPrioritySummary(plexService)
                    ) {
                        ServerPrioritySettingsView()
                    }
                }

                TVSettingsSection(title: "Home", footer: SettingsSupport.homeFooterText) {
                    TVSettingsToggleRow(title: "Personalized shelves", isOn: $preferences.personalizedShelvesEnabled)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Ask for Ratings", isOn: $preferences.asksForRatings)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Show Live TV", isOn: $preferences.showsLiveTVOnHome)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Show Pick Something", isOn: $preferences.showsPickSomethingOnHome)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Show Your Requests", isOn: $preferences.showsRequestsOnHome)
                }

                TVSettingsSection(title: "Playback Defaults", footer: SettingsSupport.playbackDefaultsFooterText) {
                    TVSettingsMenuRow(
                        title: "Max Resolution",
                        options: MaxResolution.allCases,
                        selection: $preferences.maxResolution,
                        selectedTitle: preferences.maxResolution.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Subtitles",
                        options: SettingsSupport.subtitleLanguageOptions,
                        selection: subtitleLanguageBinding,
                        selectedTitle: SettingsSupport.subtitleDisplayName(for: subtitleLanguageBinding.wrappedValue)
                    ) { SettingsSupport.subtitleDisplayName(for: $0) }

                    tvRowDivider

                    TVSettingsToggleRow(title: "Forced Only", isOn: $preferences.subtitleForcedOnly)

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Subtitle Size",
                        options: SubtitleFontSize.allCases,
                        selection: $preferences.subtitleFontSize,
                        selectedTitle: preferences.subtitleFontSize.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Subtitle Background",
                        options: SubtitleBackground.allCases,
                        selection: $preferences.subtitleBackground,
                        selectedTitle: preferences.subtitleBackground.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Subtitle Color",
                        options: SubtitleColor.allCases,
                        selection: $preferences.subtitleColor,
                        selectedTitle: preferences.subtitleColor.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Subtitle Position",
                        options: SubtitlePosition.allCases,
                        selection: $preferences.subtitlePosition,
                        selectedTitle: preferences.subtitlePosition.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Audio",
                        options: SettingsSupport.audioLanguageOptions,
                        selection: $preferences.defaultAudioLanguage,
                        selectedTitle: SettingsSupport.languageDisplayName(for: preferences.defaultAudioLanguage)
                    ) { SettingsSupport.languageDisplayName(for: $0) }
                }

                TVSettingsSection(title: "Playback Behavior", footer: SettingsSupport.playbackBehaviorFooterText) {
                    TVSettingsMenuRow(
                        title: "Play Starts",
                        options: PlaybackStartBehavior.allCases,
                        selection: $preferences.playbackStartBehavior,
                        selectedTitle: preferences.playbackStartBehavior.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsMenuRow(
                        title: "Auto-Skip Intros",
                        options: AutoSkipIntroMode.allCases,
                        selection: $preferences.autoSkipIntroMode,
                        selectedTitle: preferences.autoSkipIntroMode.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsToggleRow(title: "Auto-Skip Credits", isOn: $preferences.autoSkipCredits)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Continuous Play", isOn: $preferences.continuousPlayEnabled)

                    if preferences.continuousPlayEnabled {
                        tvRowDivider

                        TVSettingsMenuRow(
                            title: "Next Episode Delay",
                            options: ContinuousPlayCountdown.allCases,
                            selection: $preferences.continuousPlayCountdown,
                            selectedTitle: preferences.continuousPlayCountdown.displayName
                        ) { $0.displayName }

                        tvRowDivider

                        TVSettingsMenuRow(
                            title: "Pause After",
                            options: SettingsSupport.passoutProtectionEpisodeOptions,
                            selection: $preferences.continuousPlayPassoutProtectionEpisodeLimit,
                            selectedTitle: SettingsSupport.passoutProtectionDisplayName(
                                for: preferences.continuousPlayPassoutProtectionEpisodeLimit
                            )
                        ) {
                            SettingsSupport.passoutProtectionDisplayName(for: $0)
                        }
                    }

                    tvRowDivider

                    TVSettingsToggleRow(title: "Trailer Previews", isOn: $preferences.trailerPreviewsEnabled)
                }

                TVSettingsSection(title: "Appearance", footer: SettingsSupport.appearanceFooterText) {
                    TVSettingsMenuRow(
                        title: "Appearance",
                        options: AppearanceMode.allCases,
                        selection: $preferences.appearanceMode,
                        selectedTitle: preferences.appearanceMode.displayName
                    ) { $0.displayName }

                    tvRowDivider

                    TVSettingsToggleRow(title: "Hide Spoilers", isOn: $preferences.hidesEpisodeSpoilers)
                }

                TVSettingsSection(title: "Playback Advanced", footer: SettingsSupport.playbackAdvancedFooterText) {
                    TVSettingsToggleRow(title: "Dolby Atmos", isOn: $preferences.spatialAudioRemuxEnabled)

                    tvRowDivider

                    TVSettingsToggleRow(title: "HDR & Dolby Vision", isOn: $preferences.hdrVideoRemuxEnabled)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Dolby Vision 7 → 8.1", isOn: $preferences.dolbyVision7ConversionEnabled)
                        .disabled(!preferences.hdrVideoRemuxEnabled)
                        .opacity(preferences.hdrVideoRemuxEnabled ? 1 : 0.5)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Force AVPlayer", isOn: $preferences.forceAVPlayer)

                    tvRowDivider

                    TVSettingsToggleRow(title: "Force VLCKit", isOn: $preferences.forceVLCKit)
                }

                TVSettingsSection(title: "Storage", footer: viewModel.storageFooterText) {
                    TVSettingsActionRow(
                        title: "Clear Image Cache",
                        detail: viewModel.formattedCacheSize
                    ) {
                        viewModel.clearImageCache()
                    }
                }

                TVSettingsSection(title: "About", footer: SettingsSupport.aboutFooterText) {
                    HStack(spacing: 20) {
                        Text("Version")
                            .font(IthacaFont.rowTitle(ios: .headline))
                            .foregroundStyle(Color.ithacaTextPrimary)

                        Spacer()

                        Text(viewModel.appVersion)
                            .ithacaFont(tvOnly: IthacaFont.TV.rowValue)
                            .foregroundStyle(Color.ithacaTextSecondary)
                    }
                    .frame(minHeight: TVSettingsMetrics.rowMinHeight)

                    tvRowDivider

                    TVSettingsExternalLinkRow(
                        title: "GitHub",
                        subtitle: "github.com/inceptyon-labs/ithaca"
                    )
                }

                TVSettingsSection(title: "Account", footer: SettingsSupport.accountFooterText) {
                    TVSettingsActionRow(
                        title: "Sign Out",
                        tint: .red,
                        role: .destructive
                    ) {
                        plexService.signOut()
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.ithacaTextSecondary.opacity(0.16))
            .frame(height: 1)
    }

    private var automaticHomeSignInBinding: Binding<Bool> {
        Binding(
            get: { plexService.automaticHomeSignIn },
            set: { plexService.automaticHomeSignIn = $0 }
        )
    }
}
