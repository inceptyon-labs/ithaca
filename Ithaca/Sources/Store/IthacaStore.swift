import Foundation
import StoreKit

/// Ithaca Pro, which unlocks Describe It. Ithaca is free to download, with a
/// 7-day trial (a free in-app item, which App Review guideline 3.1.1 allows
/// without a subscription) and a one-time purchase. One purchase covers iPhone,
/// iPad and Apple TV (universal purchase), and Family Sharing covers the
/// household. The trial is not shared.
@MainActor
@Observable
final class IthacaStore {
    static let trialID = "com.inceptyon.ithaca.trial"
    static let proID = "com.inceptyon.ithaca.pro"

    private(set) var entitlement = ProEntitlement.load()
    private(set) var trial: Product?
    private(set) var pro: Product?
    private(set) var isBusy = false
    var problem: String?
    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        // Purchases made elsewhere (another device, Family Sharing, Ask to Buy
        // approved later) arrive here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await load() }
    }

    var hasPro: Bool { entitlement.hasPro() }

    /// The one-time price as the App Store shows it in this country; nil until
    /// the products load.
    var price: String? { pro?.displayPrice }

    func load() async {
        if let products = try? await Product.products(for: [Self.trialID, Self.proID]) {
            trial = products.first { $0.id == Self.trialID }
            pro = products.first { $0.id == Self.proID }
        }
        await refresh()
    }

    /// What this Apple Account owns, from StoreKit's own record on the device.
    func refresh() async {
        var entitlement = ProEntitlement()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case Self.proID: entitlement.owned = true
            case Self.trialID: entitlement.trialStart = transaction.purchaseDate
            default: break
            }
        }
        if entitlement != self.entitlement {
            self.entitlement = entitlement
            entitlement.save()
        }
    }

    func startTrial() async { await purchase(trial) }
    func buy() async { await purchase(pro) }

    func restore() async {
        isBusy = true
        defer { isBusy = false }
        problem = nil
        do { try await AppStore.sync() } catch { problem = Self.unreachable }
        await refresh()
    }

    private func purchase(_ product: Product?) async {
        guard let product else {
            problem = Self.unreachable
            return
        }
        isBusy = true
        defer { isBusy = false }
        problem = nil
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let transaction) = result { await transaction.finish() }
                await refresh()
            case .pending:
                problem = "The purchase is waiting for approval, such as Ask to Buy."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    private static let unreachable = "Couldn't reach the App Store. Try again in a moment."
}

/// What the Apple Account owns, kept in the Keychain so the state shows before
/// StoreKit answers.
struct ProEntitlement: Codable, Equatable {
    var owned = false
    var trialStart: Date?

    static let trialDays = 7

    var trialEnds: Date? {
        trialStart.flatMap { Calendar.current.date(byAdding: .day, value: Self.trialDays, to: $0) }
    }

    func isInTrial(at now: Date = .now) -> Bool {
        !owned && trialEnds.map { now < $0 } == true
    }

    func hasPro(at now: Date = .now) -> Bool {
        #if DEBUG
        // Development builds have no App Store products: Pro is on unless the
        // -IthacaPaywall YES launch argument turns the check on.
        if !UserDefaults.standard.bool(forKey: "IthacaPaywall") { return true }
        #endif
        return owned || isInTrial(at: now)
    }

    private static let keychainKey = "proEntitlement"

    static func load() -> ProEntitlement {
        KeychainHelper.load(key: keychainKey).flatMap { try? JSONDecoder().decode(ProEntitlement.self, from: $0) }
            ?? ProEntitlement()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        KeychainHelper.save(key: Self.keychainKey, data: data)
    }
}
