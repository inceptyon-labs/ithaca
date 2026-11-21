import SwiftUI

/// Ithaca Pro: what it unlocks, the trial, the purchase and restore. Pushed
/// from Settings, and shown as a sheet (`ProSheet`) from a locked Describe It.
/// Says how long the trial is, what stops after it, and the price, as App
/// Review asks.
struct ProView: View {
    @Environment(IthacaStore.self) private var store

    var body: some View {
        Group {
            #if os(tvOS)
            tvContent
            #else
            iosContent
            #endif
        }
        .background(Color.ithacaBackground.ignoresSafeArea())
        .ithacaNavigationTitle("Ithaca Pro")
        .task { await store.load() }
    }

    private var entitlement: ProEntitlement { store.entitlement }
    private var trialEnded: Bool { entitlement.trialStart != nil && !entitlement.isInTrial() }
    private var priceText: String { store.price.map { "\($0), once" } ?? "a one-time price" }

    private var headline: String {
        if entitlement.owned { return "Ithaca Pro is yours" }
        if entitlement.isInTrial() { return ProStatus.trialLeft(entitlement) }
        if trialEnded { return "Your free week is over" }
        return "Try it free for \(ProEntitlement.trialDays) days"
    }

    private static let pitch = "Describe It: tell Ithaca what you're in the mood for, like “a heist movie under two hours” or “something funny from the 90s,” and it picks from your library. With Seerr connected, it suggests new titles to request too."

    private var terms: String {
        if entitlement.owned {
            return "It covers your iPhone, iPad and Apple TV, and Family Sharing covers everyone at home."
        }
        let after = trialEnded
            ? "Keep Describe It for \(priceText)."
            : "After \(ProEntitlement.trialDays) days, Describe It locks unless you buy Ithaca Pro for \(priceText)."
        return "\(after) No subscription. One purchase covers iPhone, iPad and Apple TV, and Family Sharing covers everyone at home. Everything else in Ithaca stays free."
    }

    private var canStartTrial: Bool { entitlement.trialStart == nil && !entitlement.owned }
    private var buyTitle: String { store.price.map { "Buy Ithaca Pro for \($0)" } ?? "Buy Ithaca Pro" }

    #if !os(tvOS)
    private var iosContent: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(headline)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.ithacaTextPrimary)
                    Text(Self.pitch)
                        .foregroundStyle(Color.ithacaTextSecondary)
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.ithacaSurface)

            if !entitlement.owned {
                Section {
                    if canStartTrial {
                        Button { Task { await store.startTrial() } } label: {
                            actionLabel("Start the Free Trial")
                        }
                    }
                    Button { Task { await store.buy() } } label: {
                        actionLabel(buyTitle)
                    }
                    Button("Restore Purchase") { Task { await store.restore() } }
                        .foregroundStyle(Color.ithacaTextPrimary)
                } footer: {
                    Text(terms)
                }
                .disabled(store.isBusy)
                .listRowBackground(Color.ithacaSurface)
            } else {
                Section {
                } footer: {
                    Text(terms)
                }
            }

            if let problem = store.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                .listRowBackground(Color.ithacaSurface)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func actionLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(Color.ithacaTextPrimary)
            if store.isBusy {
                Spacer()
                ProgressView()
            }
        }
    }
    #endif

    #if os(tvOS)
    private var tvContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(headline)
                        .font(IthacaFont.pageTitle(ios: .title))
                        .foregroundStyle(Color.ithacaTextPrimary)
                    Text(Self.pitch)
                        .font(IthacaFont.body(ios: .body))
                        .foregroundStyle(Color.ithacaTextSecondary)
                }

                if !entitlement.owned {
                    TVSettingsSection(title: "Ithaca Pro", footer: terms) {
                        if canStartTrial {
                            TVSettingsActionRow(title: "Start the Free Trial", isLoading: store.isBusy) {
                                Task { await store.startTrial() }
                            }
                            divider
                        }
                        TVSettingsActionRow(title: buyTitle, isLoading: store.isBusy) {
                            Task { await store.buy() }
                        }
                        divider
                        TVSettingsActionRow(title: "Restore Purchase") {
                            Task { await store.restore() }
                        }
                    }
                    .disabled(store.isBusy)
                } else {
                    Text(terms)
                        .font(IthacaFont.caption(ios: .footnote))
                        .foregroundStyle(Color.ithacaTextSecondary)
                }

                if let problem = store.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(IthacaFont.caption(ios: .footnote))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.ithacaTextSecondary.opacity(0.16))
            .frame(height: 1)
    }
    #endif
}

/// `ProView` in its own navigation stack, with Done, for a sheet. Closes by
/// itself once Pro is unlocked.
struct ProSheet: View {
    @Environment(IthacaStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProView()
                #if !os(tvOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                #endif
        }
        .onChange(of: store.hasPro) { _, hasPro in
            if hasPro { dismiss() }
        }
    }
}

enum ProStatus {
    /// Settings' one-line state.
    static func summary(_ entitlement: ProEntitlement) -> String {
        if entitlement.owned { return "Unlocked" }
        if entitlement.isInTrial() { return trialLeft(entitlement) }
        if entitlement.trialStart != nil { return "Trial ended" }
        return "Free trial"
    }

    static func trialLeft(_ entitlement: ProEntitlement) -> String {
        guard let ends = entitlement.trialEnds else { return "Trial" }
        let days = max(1, Int(ceil(ends.timeIntervalSinceNow / 86_400)))
        return days == 1 ? "1 day left in your trial" : "\(days) days left in your trial"
    }
}
