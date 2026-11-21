import Foundation
import Observation

/// Holds a Siri request to open Pick Something until the tab shell can show
/// it: a cold launch runs the intent before Home exists. `MainTabView`
/// consumes it.
@MainActor @Observable
final class PickSomethingLauncher {
    static let shared = PickSomethingLauncher()

    struct Request: Equatable {
        let kind: PickSomethingKind
        let receivedAt: Date
    }

    /// A request the app could not show within this window (a profile had to
    /// be picked first) is dropped rather than opening the screen later out
    /// of nowhere.
    private static let maxPendingAge: TimeInterval = 60

    private(set) var pending: Request?

    func open(_ kind: PickSomethingKind) {
        pending = Request(kind: kind, receivedAt: .now)
    }

    func consume(now: Date = .now) -> PickSomethingKind? {
        defer { pending = nil }
        guard let pending, now.timeIntervalSince(pending.receivedAt) <= Self.maxPendingAge else { return nil }
        return pending.kind
    }
}
