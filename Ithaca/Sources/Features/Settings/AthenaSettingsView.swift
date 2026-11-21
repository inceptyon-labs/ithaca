import SwiftUI

/// Athena's address, and whether it answers. Athena is the server that picks
/// from what the viewer describes in Pick Something (`AthenaClient`).
struct AthenaSettingsView: View {
    @Environment(UserPreferences.self) private var preferences
    @State private var status: AthenaStatus = .checking
    #if !os(tvOS)
    @State private var draft = ""
    #endif

    /// The setup instructions live in Athena's public repo.
    private static let repo = "github.com/inceptyon-labs/athena"
    private static let about = "Athena is an optional server you run beside Plex with your own Anthropic API key. It answers Describe It in Pick Something with Claude, for anyone with access to your Plex server."
    private static let finding = "Running on the Plex machine on port 8800, it's found without an address. Otherwise enter its address, like 192.168.1.10:8800."
    #if os(tvOS)
    private static let footer = "\(about) Set it up from \(repo). \(finding)"
    #else
    private static let footer = "\(about) Set it up from [\(repo)](https://\(repo)). \(finding)"
    #endif

    private static let consentFooter = "On, what you type in Describe It and the titles in your library that fit go to Athena, and from there to Anthropic's Claude. Off, Describe It runs on this device."

    private var usesAthena: Binding<Bool> {
        Binding(
            get: { preferences.athenaConsent == .allowed },
            set: { preferences.athenaConsent = $0 ? .allowed : .declined }
        )
    }

    /// The found address, shown in the empty field.
    private var prompt: String {
        preferences.foundAthenaURL.nilIfEmpty ?? "Address"
    }

    #if os(tvOS)
    private var emptyValue: String {
        preferences.foundAthenaURL.nilIfEmpty.map { "Found at \($0)" } ?? "Not set"
    }
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
        .ithacaNavigationTitle("Athena")
        .task(id: preferences.athenaAddress) {
            await check()
        }
    }

    private func check() async {
        guard let client = AthenaClient(address: preferences.athenaAddress) else {
            status = AthenaClient.refusesAsInsecure(preferences.athenaAddress)
                ? .failed("Plain HTTP only works on your network. Start this address with https://")
                : .notSet
            return
        }
        status = .checking
        do {
            let health = try await client.health()
            status = health.ready ? .ready(model: health.model) : .noKey
        } catch is CancellationError {
            return
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    #if !os(tvOS)
    private var iosContent: some View {
        List {
            Section {
                TextField(prompt, text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit { preferences.athenaURL = draft.trimmingCharacters(in: .whitespacesAndNewlines) }

                statusRow
            } header: {
                Text("Server")
            } footer: {
                // Markdown, so the repo is a link.
                Text(LocalizedStringKey(Self.footer))
            }
            .listRowBackground(Color.ithacaSurface)

            Section {
                Toggle("Use Athena for Describe It", isOn: usesAthena)
                    .foregroundStyle(Color.ithacaTextPrimary)
            } footer: {
                Text(Self.consentFooter)
            }
            .listRowBackground(Color.ithacaSurface)
        }
        .scrollContentBackground(.hidden)
        .onAppear { draft = preferences.athenaURL }
        // A shared link (`AthenaShareLink`) can set the address while this is open.
        .onChange(of: preferences.athenaURL) { _, address in draft = address }
        .onDisappear { preferences.athenaURL = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    #endif

    #if os(tvOS)
    private var tvContent: some View {
        @Bindable var preferences = preferences
        return ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(title: "Server", footer: Self.footer) {
                    TVSettingsURLFieldRow(
                        prompt: "Address",
                        text: $preferences.athenaURL,
                        isDisabled: false,
                        editorTitle: "Athena Address",
                        editorMessage: "Your server's IP with port 8800, like 192.168.1.10:8800. Leave it empty to use the Athena found beside Plex.",
                        emptyValue: emptyValue
                    )

                    Rectangle()
                        .fill(Color.ithacaTextSecondary.opacity(0.16))
                        .frame(height: 1)

                    statusRow
                }

                TVSettingsSection(title: "Describe It", footer: Self.consentFooter) {
                    TVSettingsToggleRow(title: "Use Athena for Describe It", isOn: usesAthena)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }
    #endif

    private var statusRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Status")
                    .ithacaFont(tvOnly: IthacaFont.TV.rowTitle)
                    .foregroundStyle(Color.ithacaTextPrimary)
                Text(status.subtitle)
                    .font(IthacaFont.caption(ios: .caption))
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
            Spacer()
            if status == .checking {
                ProgressView()
            } else {
                ConnectionStatusDot(tone: status.tone)
            }
        }
        .frame(minHeight: 52)
    }
}

private enum AthenaStatus: Equatable {
    case notSet
    case checking
    case ready(model: String)
    case noKey
    case failed(String)

    var subtitle: String {
        switch self {
        case .notSet: "Not set"
        case .checking: "Checking…"
        case .ready(let model): "Ready, using \(model)"
        case .noKey: "Athena answers but has no Anthropic API key yet."
        case .failed(let message): message
        }
    }

    var tone: ConnectionStatusTone {
        switch self {
        case .ready: .good
        case .noKey, .failed: .bad
        case .notSet, .checking: .neutral
        }
    }
}
