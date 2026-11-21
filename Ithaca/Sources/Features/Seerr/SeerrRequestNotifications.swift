#if os(iOS)
import Foundation
import Observation
import BackgroundTasks
import UserNotifications

/// iPhone and iPad: the local "it's here" notification for an arrived request,
/// and the background app refresh that looks for arrivals while the app is
/// not open. Apple TV has no notification banners; its Requests row is the
/// announcement.
enum SeerrRequestNotifications {
    /// Also listed under `BGTaskSchedulerPermittedIdentifiers` in Info-iOS.plist.
    static let refreshTaskIdentifier = "com.inceptyon.ithaca.seerr-requests"

    /// iOS decides when the refresh actually runs; this is only the earliest.
    private static let refreshInterval: TimeInterval = 20 * 60

    private static let mediaTypeKey = "seerrMediaType"
    private static let tmdbIDKey = "seerrTMDBID"
    private static let titleKey = "seerrTitle"

    /// Asked right after the user's first request from the app, when the
    /// reason for the prompt is obvious.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func announce(
        requestID: Int,
        title: String,
        seasons: String?,
        type: SeerrMediaType,
        tmdbID: Int
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = seasons.map { "\($0) is ready to watch." } ?? "Ready to watch."
        content.sound = .default
        content.userInfo = [
            mediaTypeKey: type.rawValue,
            tmdbIDKey: tmdbID,
            titleKey: title,
        ]
        let request = UNNotificationRequest(
            identifier: "seerr-request-\(requestID)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        // Fails in the simulator and when background refresh is off; the row
        // still updates whenever Home is open.
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The title a tapped notification opens, if it is one of these.
    static func link(from userInfo: [AnyHashable: Any]) -> SeerrArrivalLinks.Link? {
        guard let typeValue = userInfo[mediaTypeKey] as? String,
              let type = SeerrMediaType(rawValue: typeValue),
              let tmdbID = userInfo[tmdbIDKey] as? Int,
              let title = userInfo[titleKey] as? String else {
            return nil
        }
        return SeerrArrivalLinks.Link(type: type, tmdbID: tmdbID, title: title, receivedAt: .now)
    }
}

/// Holds the title a tapped arrival notification opens until the tab shell can
/// show it: a cold launch from the notification arrives before Home exists.
/// `MainTabView` consumes it.
@MainActor @Observable
final class SeerrArrivalLinks {
    static let shared = SeerrArrivalLinks()

    struct Link: Equatable, Sendable {
        let type: SeerrMediaType
        let tmdbID: Int
        let title: String
        let receivedAt: Date

        var route: AppNavigationRoute {
            .seerrInPlex(type: type, id: tmdbID, title: title)
        }
    }

    /// A link the app could not show within this window (a profile had to be
    /// picked first) is dropped rather than opening the page out of nowhere.
    private static let maxPendingAge: TimeInterval = 60

    private(set) var pending: Link?

    func open(_ link: Link) {
        pending = link
    }

    func consume(now: Date = .now) -> Link? {
        defer { pending = nil }
        guard let pending, now.timeIntervalSince(pending.receivedAt) <= Self.maxPendingAge else { return nil }
        return pending
    }
}
#endif
