import SwiftUI

#if !os(tvOS)
struct SettingsIOSView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(SeerrService.self) private var seerrService
    @Environment(UserPreferences.self) private var preferences
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager
    @Environment(IthacaStore.self) private var store
    @State private var presentedAccountURL: URL?
    @State private var confirmsDeletingDownloads = false
    let viewModel: SettingsViewModel

    var body: some View {
        SettingsContainer(viewModel: viewModel) {
            settingsContent
        }
        .sheet(isPresented: accountSheetPresented) {
            if let presentedAccountURL {
                IthacaSafariView(url: presentedAccountURL)
            }
        }
        .confirmationDialog(
            "Delete all downloads?",
            isPresented: $confirmsDeletingDownloads,
            titleVisibility: .visible
        ) {
            Button("Delete All Downloads", role: .destructive) {
                downloadManager.deleteAllDownloads()
                offlinePlaybackSyncManager.deleteAllLocalState()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded videos, saved metadata, artwork, pause data, and queue entries will be removed from this device.")
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        @Bindable var preferences = preferences
        let subtitleLanguageBinding = SettingsSupport.subtitleLanguageBinding(preferences)

        List {
            if plexService.homeUsers.count > 1, let activeUser = plexService.activeHomeUser {
                Section {
                    HStack(spacing: 16) {
                        PlexHomeUserAvatar(user: activeUser, size: 48)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current User")
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .tracking(0.4)
                                .foregroundStyle(Color.ithacaTextSecondary)

                            Text(activeUser.displayName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color.ithacaTextPrimary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 6)

                    Button {
                        viewModel.showHomeUserPicker = true
                    } label: {
                        HStack {
                            Text("Switch User")
                                .foregroundStyle(Color.ithacaTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.ithacaTextSecondary)
                        }
                    }
                    .ithacaSuppressTVOSButtonChrome()

                    Toggle("Automatically Sign In", isOn: automaticHomeSignInBinding)
                        .foregroundStyle(Color.ithacaTextPrimary)
                } header: {
                    Text("Plex Home")
                        .foregroundStyle(Color.ithacaTextSecondary)
                } footer: {
                    Text("When off, Ithaca asks who’s watching whenever it starts.")
                        .foregroundStyle(Color.ithacaTextSecondary)
                }
                .listRowBackground(Color.ithacaSurface)
            }

            Section {
                NavigationLink {
                    ProView()
                } label: {
                    HStack {
                        Text("Ithaca Pro")
                            .foregroundStyle(Color.ithacaTextPrimary)
                        Spacer()
                        Text(ProStatus.summary(store.entitlement))
                            .foregroundStyle(Color.ithacaTextSecondary)
                    }
                }
            } footer: {
                Text("Describe It in Pick Something. Restore a purchase here too.")
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                NavigationLink {
                    SeerrSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Seerr")
                            .foregroundStyle(Color.ithacaTextPrimary)
                        Text(seerrService.connectionSubtitle)
                            .font(.caption)
                            .foregroundStyle(Color.ithacaTextSecondary)
                    }
                }

                NavigationLink {
                    AthenaSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Athena")
                            .foregroundStyle(Color.ithacaTextPrimary)
                        Text(SettingsSupport.athenaSubtitle(preferences))
                            .font(.caption)
                            .foregroundStyle(Color.ithacaTextSecondary)
                    }
                }
            } header: {
                Text("Integrations")
                    .foregroundStyle(Color.ithacaTextSecondary)
            } footer: {
                Text("Seerr adds requestable movies and shows to search. Athena, a server of your own, lets Claude answer Describe It instead of this device.")
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                NavigationLink {
                    LibraryTabSettingsView()
                } label: {
                    HStack {
                        Text("Navigation Tabs")
                            .foregroundStyle(Color.ithacaTextPrimary)

                        Spacer()

                        Text(SettingsSupport.libraryTabsSummary(preferences))
                            .foregroundStyle(Color.ithacaTextSecondary)
                    }
                }

                NavigationLink {
                    LibraryOrderSettingsView()
                } label: {
                    HStack {
                        Text("Library Order")
                            .foregroundStyle(Color.ithacaTextPrimary)

                        Spacer()

                        Text(SettingsSupport.libraryOrderSummary(plexService))
                            .foregroundStyle(Color.ithacaTextSecondary)
                    }
                }

                NavigationLink {
                    ServerPrioritySettingsView()
                } label: {
                    HStack {
                        Text("Server Priority")
                            .foregroundStyle(Color.ithacaTextPrimary)

                        Spacer()

                        Text(SettingsSupport.serverPrioritySummary(plexService))
                            .foregroundStyle(Color.ithacaTextSecondary)
                    }
                }
            } header: {
                Text("Navigation")
                    .foregroundStyle(Color.ithacaTextSecondary)
            } footer: {
                Text(SettingsSupport.navigationFooterText)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                Toggle("Personalized shelves", isOn: $preferences.personalizedShelvesEnabled)
                    .foregroundStyle(Color.ithacaTextPrimary)
                Toggle("Ask for Ratings", isOn: $preferences.asksForRatings)
                    .foregroundStyle(Color.ithacaTextPrimary)
                Toggle("Show Live TV", isOn: $preferences.showsLiveTVOnHome)
                    .foregroundStyle(Color.ithacaTextPrimary)
                Toggle("Show Pick Something", isOn: $preferences.showsPickSomethingOnHome)
                    .foregroundStyle(Color.ithacaTextPrimary)
                Toggle("Show Your Requests", isOn: $preferences.showsRequestsOnHome)
                    .foregroundStyle(Color.ithacaTextPrimary)
            } header: {
                Text("Home")
                    .foregroundStyle(Color.ithacaTextSecondary)
            } footer: {
                Text(SettingsSupport.homeFooterText)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                Picker("Max Resolution", selection: $preferences.maxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)

                Picker("Subtitles", selection: subtitleLanguageBinding) {
                    ForEach(SettingsSupport.subtitleLanguageOptions, id: \.self) { languageCode in
                        Text(SettingsSupport.subtitleDisplayName(for: languageCode)).tag(languageCode)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)

                Toggle("Forced Only", isOn: $preferences.subtitleForcedOnly)
                    .foregroundStyle(Color.ithacaTextPrimary)

                Picker("Subtitle Size", selection: $preferences.subtitleFontSize) {
                    ForEach(SubtitleFontSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)

                Picker("Subtitle Background", selection: $preferences.subtitleBackground) {
                    ForEach(SubtitleBackground.allCases) { background in
                        Text(background.displayName).tag(background)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)

                Picker("Subtitle Color", selection: $preferences.subtitleColor) {
                    ForEach(SubtitleColor.allCases) { color in
                        Text(color.displayName).tag(color)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)

                Picker("Subtitle Position", selection: $preferences.subtitlePosition) {
                    ForEach(SubtitlePosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)

                Picker("Audio", selection: $preferences.defaultAudioLanguage) {
                    ForEach(CommonLanguage.allCases) { language in
                        Text(language.displayName).tag(language.code)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)
            } header: {
                Text("Playback Defaults")
                    .foregroundStyle(Color.ithacaTextSecondary)
            } footer: {
                Text(SettingsSupport.playbackDefaultsFooterText)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                Picker("Play Starts", selection: $preferences.playbackStartBehavior) {
                    ForEach(PlaybackStartBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)

                Picker("Auto-Skip Intros", selection: $preferences.autoSkipIntroMode) {
                    ForEach(AutoSkipIntroMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)

                Toggle("Auto-Skip Credits", isOn: $preferences.autoSkipCredits)
                    .foregroundStyle(Color.ithacaTextPrimary)

                Toggle("Continuous Play", isOn: $preferences.continuousPlayEnabled)
                    .foregroundStyle(Color.ithacaTextPrimary)

                if preferences.continuousPlayEnabled {
                    Picker("Next Episode Delay", selection: $preferences.continuousPlayCountdown) {
                        ForEach(ContinuousPlayCountdown.allCases) { countdown in
                            Text(countdown.displayName).tag(countdown)
                        }
                    }
                    .foregroundStyle(Color.ithacaTextPrimary)

                    Picker(
                        "Pause After",
                        selection: $preferences.continuousPlayPassoutProtectionEpisodeLimit
                    ) {
                        ForEach(SettingsSupport.passoutProtectionEpisodeOptions, id: \.self) { episodeLimit in
                            Text(SettingsSupport.passoutProtectionDisplayName(for: episodeLimit))
                                .tag(episodeLimit as Int?)
                        }
                    }
                    .foregroundStyle(Color.ithacaTextPrimary)
                }

                Toggle("Episode Buttons", isOn: $preferences.playerEpisodeButtonsEnabled)
                    .foregroundStyle(Color.ithacaTextPrimary)

                Toggle("Double-Tap to Seek", isOn: $preferences.playerDoubleTapSeekEnabled)
                    .foregroundStyle(Color.ithacaTextPrimary)

                if preferences.playerDoubleTapSeekEnabled {
                    Picker("Back Jump", selection: $preferences.playerDoubleTapBackwardInterval) {
                        ForEach(PlayerSeekInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .foregroundStyle(Color.ithacaTextPrimary)

                    Picker("Forward Jump", selection: $preferences.playerDoubleTapForwardInterval) {
                        ForEach(PlayerSeekInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .foregroundStyle(Color.ithacaTextPrimary)
                }
            } header: {
                Text("Playback Behavior")
                    .foregroundStyle(Color.ithacaTextSecondary)
            } footer: {
                Text(SettingsSupport.playbackBehaviorFooterText)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                Picker("Download Quality", selection: $preferences.downloadMaxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)

                Toggle("Wi-Fi Only", isOn: $preferences.downloadsWifiOnly)
                    .foregroundStyle(Color.ithacaTextPrimary)

                Picker("Simultaneous Downloads", selection: $preferences.maximumActiveDownloads) {
                    ForEach(DownloadConcurrency.allCases) { concurrency in
                        Text(concurrency.displayName).tag(concurrency)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)
                .onChange(of: preferences.maximumActiveDownloads) {
                    downloadManager.processQueueIfNeeded()
                }

                Picker("Keep Free", selection: $preferences.downloadFreeSpaceReserve) {
                    ForEach(DownloadFreeSpaceReserve.allCases) { reserve in
                        Text(reserve.displayName).tag(reserve)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)

                Toggle("Smart Downloads", isOn: $preferences.smartDownloadsEnabled)
                    .foregroundStyle(Color.ithacaTextPrimary)

                if preferences.smartDownloadsEnabled {
                    Picker("Keep Ready", selection: $preferences.smartDownloadEpisodeCount) {
                        ForEach(SmartDownloadEpisodeCount.allCases) { count in
                            Text(count.displayName).tag(count)
                        }
                    }
                    .foregroundStyle(Color.ithacaTextPrimary)
                }

                HStack {
                    Text("Storage Used")
                        .foregroundStyle(Color.ithacaTextPrimary)
                    Spacer()
                    Text(formattedBytes(downloadManager.storageUsageBytes))
                        .foregroundStyle(Color.ithacaTextSecondary)
                }

                if let availableStorageBytes = downloadManager.availableStorageBytes {
                    HStack {
                        Text("Available")
                            .foregroundStyle(Color.ithacaTextPrimary)
                        Spacer()
                        Text(formattedBytes(availableStorageBytes))
                            .foregroundStyle(Color.ithacaTextSecondary)
                    }
                }

                if offlinePlaybackSyncManager.pendingSyncCount > 0 {
                    HStack {
                        Text("Pending Watch Sync")
                            .foregroundStyle(Color.ithacaTextPrimary)
                        Spacer()
                        Text("\(offlinePlaybackSyncManager.pendingSyncCount)")
                            .foregroundStyle(Color.ithacaTextSecondary)
                    }

                    Button {
                        Task {
                            await offlinePlaybackSyncManager.syncPendingActions(force: true)
                        }
                    } label: {
                        if offlinePlaybackSyncManager.isSyncing {
                            Label("Syncing Watch Progress", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Sync Watch Progress Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(offlinePlaybackSyncManager.isSyncing)
                    .ithacaSuppressTVOSButtonChrome()
                }

                Button("Delete All Downloads", role: .destructive) {
                    confirmsDeletingDownloads = true
                }
                .disabled(downloadManager.records.isEmpty)
                .ithacaSuppressTVOSButtonChrome()
            } header: {
                Text("Downloads")
                    .foregroundStyle(Color.ithacaTextSecondary)
            } footer: {
                Text(SettingsSupport.downloadsFooterText)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                Picker("Appearance", selection: $preferences.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)

                Toggle("Hide Spoilers", isOn: $preferences.hidesEpisodeSpoilers)
                    .foregroundStyle(Color.ithacaTextPrimary)
            } header: {
                Text("Appearance")
                    .foregroundStyle(Color.ithacaTextSecondary)
            } footer: {
                Text(SettingsSupport.appearanceFooterText)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                Toggle("Dolby Atmos & Spatial Audio", isOn: $preferences.spatialAudioRemuxEnabled)
                    .foregroundStyle(Color.ithacaTextPrimary)

                Toggle("HDR & Dolby Vision", isOn: $preferences.hdrVideoRemuxEnabled)
                    .foregroundStyle(Color.ithacaTextPrimary)

                Toggle("Dolby Vision 7 → 8.1", isOn: $preferences.dolbyVision7ConversionEnabled)
                    .foregroundStyle(Color.ithacaTextPrimary)
                    .disabled(!preferences.hdrVideoRemuxEnabled)

                Toggle("Force AVPlayer", isOn: $preferences.forceAVPlayer)
                    .foregroundStyle(Color.ithacaTextPrimary)

                Toggle("Force VLCKit", isOn: $preferences.forceVLCKit)
                    .foregroundStyle(Color.ithacaTextPrimary)
            } header: {
                Text("Playback Advanced")
                    .foregroundStyle(Color.ithacaTextSecondary)
            } footer: {
                Text(SettingsSupport.playbackAdvancedFooterText)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                Button {
                    viewModel.clearImageCache()
                } label: {
                    HStack {
                        Text("Clear Image Cache")
                        Spacer()
                        Text(viewModel.formattedCacheSize)
                            .foregroundStyle(Color.ithacaTextSecondary)
                    }
                }
                .foregroundStyle(Color.ithacaTextPrimary)
                .ithacaSuppressTVOSButtonChrome()
            } header: {
                Text("Storage")
                    .foregroundStyle(Color.ithacaTextSecondary)
            } footer: {
                Text(viewModel.storageFooterText)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                HStack {
                    Text("Version")
                        .foregroundStyle(Color.ithacaTextPrimary)
                    Spacer()
                    Text(viewModel.appVersion)
                        .foregroundStyle(Color.ithacaTextSecondary)
                }

                Link(destination: SettingsSupport.githubURL) {
                    SettingsAboutRow(
                        title: "GitHub",
                        subtitle: "github.com/inceptyon-labs/ithaca",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        trailingSystemImage: "arrow.up.right"
                    )
                }
                .foregroundStyle(Color.ithacaTextPrimary)
            } header: {
                Text("About")
                    .foregroundStyle(Color.ithacaTextSecondary)
            } footer: {
                Text(SettingsSupport.aboutFooterText)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                Button {
                    presentedAccountURL = SettingsSupport.plexAccountURL
                } label: {
                    SettingsAboutRow(
                        title: "Manage Plex Account",
                        subtitle: "Open Plex account settings",
                        systemImage: "person.circle",
                        trailingSystemImage: "safari"
                    )
                }
                .foregroundStyle(Color.ithacaTextPrimary)
                .ithacaSuppressTVOSButtonChrome()

                Button {
                    presentedAccountURL = SettingsSupport.plexAccountURL
                } label: {
                    SettingsAboutRow(
                        title: "Delete Plex Account",
                        subtitle: "Open the Plex deletion controls",
                        systemImage: "trash",
                        trailingSystemImage: "safari",
                        titleColor: .red
                    )
                }
                .ithacaSuppressTVOSButtonChrome()

                Button("Sign Out", role: .destructive) {
                    plexService.signOut()
                }
                .ithacaSuppressTVOSButtonChrome()
            } footer: {
                Text(SettingsSupport.accountManagementFooterText + " " + SettingsSupport.accountFooterText)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            .listRowBackground(Color.ithacaSurface)
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .ithacaScrollContentBackgroundHidden()
    }

    private var accountSheetPresented: Binding<Bool> {
        Binding(
            get: { presentedAccountURL != nil },
            set: {
                guard !$0 else { return }
                presentedAccountURL = nil
            }
        )
    }

    private var automaticHomeSignInBinding: Binding<Bool> {
        Binding(
            get: { plexService.automaticHomeSignIn },
            set: { plexService.automaticHomeSignIn = $0 }
        )
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct SettingsAboutRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let trailingSystemImage: String
    var titleColor: Color = Color.ithacaTextPrimary

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.ithacaTextSecondary.opacity(0.14))
                    .frame(width: 34, height: 34)

                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ithacaTextPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(titleColor)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.ithacaTextSecondary)
            }

            Spacer()

            Image(systemName: trailingSystemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ithacaTextSecondary)
        }
        .contentShape(Rectangle())
    }
}
#endif
