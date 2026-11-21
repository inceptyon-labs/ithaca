import SwiftUI

struct SeerrSettingsView: View {
    @Environment(SeerrService.self) private var seerrService
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences
    @State private var viewModel = SeerrSettingsViewModel()

    #if os(tvOS)
    private static let requestsFooter = "Ready titles leave Your Requests on Home after this long."
    #else
    private static let requestsFooter = "Notify When Ready sends a notification when something you requested can be watched. Ready titles leave Your Requests on Home after Keep Ready Titles."
    #endif

    var body: some View {
        Group {
            #if os(tvOS)
            tvContent
            #else
            iosContent
            #endif
        }
        .background(Color.ithacaBackground.ignoresSafeArea())
        .ithacaNavigationTitle("Seerr")
        .task {
            await viewModel.load(from: seerrService, plexService: plexService)
        }
        .confirmationDialog(
            "Connect to Seerr?",
            isPresented: $viewModel.showsConnectionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Connect") {
                Task { await viewModel.connect(using: seerrService) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.confirmationMessage)
        }
    }

    #if !os(tvOS)
    private var iosContent: some View {
        @Bindable var preferences = preferences
        return List {
            Section {
                TextField("Server URL", text: $viewModel.serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(seerrService.isConnected || viewModel.isWorking)

                connectionRow
            } header: {
                Text("Server")
            } footer: {
                Text(viewModel.footer)
            }
            .listRowBackground(Color.ithacaSurface)

            if let errorMessage = viewModel.errorMessage ?? seerrService.lastConnectionError {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.ithacaTextSecondary)
                }
                .listRowBackground(Color.ithacaSurface)
            }

            Section {
                if seerrService.isConnected {
                    Button("Disconnect", role: .destructive) {
                        Task { await viewModel.disconnect(using: seerrService) }
                    }
                    .disabled(viewModel.isWorking)
                } else {
                    Button {
                        Task { await viewModel.prepareConnection(using: seerrService) }
                    } label: {
                        HStack {
                            Text("Connect with Plex")
                            Spacer()
                            if viewModel.isWorking {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isWorking || viewModel.serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                Toggle("Notify When Ready", isOn: $preferences.requestArrivalNotificationsEnabled)
                    .onChange(of: preferences.requestArrivalNotificationsEnabled) { _, isOn in
                        guard isOn else { return }
                        Task { await SeerrRequestNotifications.requestAuthorizationIfNeeded() }
                    }
                Picker("Keep Ready Titles", selection: $preferences.readyRequestShelfLife) {
                    ForEach(ReadyRequestShelfLife.allCases) { shelfLife in
                        Text(shelfLife.displayName).tag(shelfLife)
                    }
                }
            } header: {
                Text("Your Requests")
            } footer: {
                Text(Self.requestsFooter)
            }
            .listRowBackground(Color.ithacaSurface)
        }
        .scrollContentBackground(.hidden)
    }
    #endif

    #if os(tvOS)
    private var tvContent: some View {
        @Bindable var preferences = preferences
        return ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(
                    title: "Server",
                    footer: viewModel.footer
                ) {
                    TVSettingsURLFieldRow(
                        prompt: "Server URL",
                        text: $viewModel.serverURL,
                        isDisabled: seerrService.isConnected || viewModel.isWorking
                    )

                    tvRowDivider
                    connectionRow
                }

                if let errorMessage = viewModel.errorMessage ?? seerrService.lastConnectionError {
                    TVSettingsSection(title: "Connection") {
                        Text(errorMessage)
                            .font(IthacaFont.TV.rowValue)
                            .foregroundStyle(Color.ithacaTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: TVSettingsMetrics.rowMinHeight,
                                alignment: .leading
                            )
                    }
                }

                TVSettingsSection(
                    title: "Account",
                    footer: "This connection is kept separate for each Plex Home user and Plex server."
                ) {
                    if seerrService.isConnected {
                        TVSettingsActionRow(
                            title: "Disconnect",
                            tint: .red,
                            role: .destructive,
                            isLoading: viewModel.isWorking
                        ) {
                            Task { await viewModel.disconnect(using: seerrService) }
                        }
                    } else {
                        TVSettingsActionRow(
                            title: "Connect with Plex",
                            isLoading: viewModel.isWorking
                        ) {
                            Task { await viewModel.prepareConnection(using: seerrService) }
                        }
                    }
                }

                TVSettingsSection(title: "Your Requests", footer: Self.requestsFooter) {
                    TVSettingsMenuRow(
                        title: "Keep Ready Titles",
                        options: ReadyRequestShelfLife.allCases,
                        selection: $preferences.readyRequestShelfLife,
                        selectedTitle: preferences.readyRequestShelfLife.displayName
                    ) { $0.displayName }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }
    #endif

    private var connectionRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Status")
                    .ithacaFont(tvOnly: IthacaFont.TV.rowTitle)
                    .foregroundStyle(Color.ithacaTextPrimary)
                Text(seerrService.connectionSubtitle)
                    .font(IthacaFont.caption(ios: .caption))
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            Spacer()
            ConnectionStatusDot(tone: seerrStatusTone)
        }
        .frame(minHeight: 52)
    }

    private var seerrStatusTone: ConnectionStatusTone {
        if seerrService.lastConnectionError != nil { return .bad }
        return seerrService.isConnected ? .good : .neutral
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.ithacaTextSecondary.opacity(0.16))
            .frame(height: 1)
    }
}
