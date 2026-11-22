import AppIntents
import AVFoundation
import SwiftUI
import UIKit
#if os(iOS)
import UserNotifications
#endif

enum AppImageCache {
    static let memoryCapacity = 0
    static let diskCapacity = 200_000_000
    static let maxAge: TimeInterval = 3 * 24 * 60 * 60

    private static let cachedAtUserInfoKey = "IthacaCachedAt"

    static let shared = URLCache(
        memoryCapacity: memoryCapacity,
        diskCapacity: diskCapacity
    )

    static func configureSharedCache() {
        if URLCache.shared !== shared {
            URLCache.shared = shared
        }
    }

    static func clear() {
        shared.removeAllCachedResponses()
    }

    private static let serverLock = NSLock()
    /// Plex server IDs by connection origin (scheme, host, port). An origin
    /// keeps its server after the connection moves on, so URLs built for the
    /// previous connection still find their entries.
    nonisolated(unsafe) private static var serverIDsByOrigin: [String: String] = [:]

    /// Called by `ServerPool` whenever a server's connection is set.
    static func registerServer(_ serverID: String, at baseURL: URL) {
        guard let origin = origin(of: baseURL) else { return }
        serverLock.lock()
        serverIDsByOrigin[origin] = serverID
        serverLock.unlock()
    }

    /// The key an image is cached under, in memory and on disk. A Plex server
    /// URL keys on the server's ID plus the server-relative path and query, so
    /// the same artwork fetched over the LAN, a remote address or the relay is
    /// one entry. Any other URL is its own key.
    static func cacheKey(for url: URL) -> URL {
        guard let origin = origin(of: url) else { return url }
        serverLock.lock()
        let serverID = serverIDsByOrigin[origin]
        serverLock.unlock()

        guard let serverID,
              let encodedServerID = serverID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        // Never fetched; `.invalid` is a reserved name that cannot resolve.
        components.scheme = "https"
        components.host = "plex-image.invalid"
        components.port = nil
        components.percentEncodedPath = "/\(encodedServerID)\(components.percentEncodedPath)"
        return components.url ?? url
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    private static func keyRequest(for request: URLRequest) -> URLRequest {
        guard let url = request.url else { return request }
        return URLRequest(url: cacheKey(for: url))
    }

    static func cachedResponse(for request: URLRequest, now: Date = .now) -> CachedURLResponse? {
        let keyRequest = keyRequest(for: request)
        guard let response = shared.cachedResponse(for: keyRequest) else { return nil }

        guard isFresh(response, now: now) else {
            shared.removeCachedResponse(for: keyRequest)
            return nil
        }

        return response
    }

    static func storeCachedResponse(_ response: CachedURLResponse, for request: URLRequest, now: Date = .now) {
        var userInfo = response.userInfo ?? [:]
        userInfo[cachedAtUserInfoKey] = now

        let timestampedResponse = CachedURLResponse(
            response: response.response,
            data: response.data,
            userInfo: userInfo,
            storagePolicy: response.storagePolicy
        )
        shared.storeCachedResponse(timestampedResponse, for: keyRequest(for: request))
    }

    /// Stores a body fetched by a session without a URL cache, on a
    /// background task, for callers on the main actor.
    static func storeInBackground(_ data: Data, for request: URLRequest) {
        guard let url = request.url else { return }
        Task.detached(priority: .utility) {
            let response = URLResponse(url: url, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil)
            storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
        }
    }

    /// Re-stores the response URLSession cached for `request` under its cache
    /// key with the timestamp `isFresh` requires. Reads and writes the disk
    /// cache, so it must not run on the main thread.
    static func timestampStoredResponse(for request: URLRequest) {
        guard let cachedResponse = shared.cachedResponse(for: request) else { return }
        storeCachedResponse(cachedResponse, for: request)
    }

    /// `timestampStoredResponse(for:)` on a background task, for callers on
    /// the main actor.
    static func timestampStoredResponseInBackground(for request: URLRequest) {
        Task.detached(priority: .utility) {
            timestampStoredResponse(for: request)
        }
    }

    /// The fresh cached body for `request`, read off the main thread.
    static func cachedData(for request: URLRequest) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            cachedResponse(for: request)?.data
        }.value
    }

    static func cachedAt(for response: CachedURLResponse) -> Date? {
        response.userInfo?[cachedAtUserInfoKey] as? Date
    }

    private static func isFresh(_ response: CachedURLResponse, now: Date) -> Bool {
        // URLSession stores image responses itself, asynchronously, so an entry
        // can be on disk without Ithaca's stamp (or the stamped copy can be
        // overwritten by URLSession's own write). Fall back to the server's
        // Date header rather than discarding the entry and downloading again.
        guard let cachedAt = cachedAt(for: response) ?? responseDate(response.response) else {
            return false
        }

        return now.timeIntervalSince(cachedAt) <= maxAge
    }

    private static func responseDate(_ response: URLResponse) -> Date? {
        guard let value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date") else {
            return nil
        }
        return httpDateFormatter.date(from: value)
    }

    /// RFC 7231 IMF-fixdate. DateFormatter is thread-safe for parsing.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

#if os(iOS)
final class IthacaAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Set before launch finishes, so a tap that launched the app is delivered.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadBackgroundSessionRegistry.setCompletionHandler(completionHandler, for: identifier)
    }

    /// A request arriving while the app is open still shows its banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let link = SeerrRequestNotifications.link(
                from: response.notification.request.content.userInfo
              ) else { return }
        await MainActor.run {
            SeerrArrivalLinks.shared.open(link)
        }
    }
}
#endif

@main
struct IthacaApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(IthacaAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    @State private var plexService: PlexService
    @State private var seerrService: SeerrService
    @State private var requestTracker: SeerrRequestTracker
    @State private var tasteRecommender: TasteRecommender
    @State private var playbackCoordinator: PlaybackCoordinator
    @State private var downloadManager: DownloadManager
    @State private var offlinePlaybackSyncManager: OfflinePlaybackSyncManager
    @State private var userPreferences: UserPreferences
    @State private var store = IthacaStore()
    @State private var athenaLinks = AthenaLinkInbox()
    #if os(tvOS)
    @State private var topShelfLinks = TopShelfLinkRouter()
    #endif

    init() {
        AppImageCache.configureSharedCache()
        let service = PlexService()
        let seerr = SeerrService(plexService: service)
        let prefs = UserPreferences()
        let downloads = DownloadManager(plexService: service, preferences: prefs)
        let playbackSync = OfflinePlaybackSyncManager(plexService: service)
        _plexService = State(initialValue: service)
        _seerrService = State(initialValue: seerr)
        _requestTracker = State(initialValue: SeerrRequestTracker(
            seerrService: seerr,
            plexService: service,
            preferences: prefs
        ))
        let recommender = TasteRecommender(plexService: service, seerrService: seerr)
        _tasteRecommender = State(initialValue: recommender)
        _downloadManager = State(initialValue: downloads)
        _offlinePlaybackSyncManager = State(initialValue: playbackSync)
        let coordinator = PlaybackCoordinator(
            plexService: service,
            preferences: prefs,
            downloadManager: downloads,
            offlinePlaybackSyncManager: playbackSync
        )
        coordinator.tasteRecommender = recommender
        #if os(iOS)
        downloads.smartDownloads = SmartDownloads(
            plexService: service,
            preferences: prefs,
            downloadManager: downloads,
            playbackSync: playbackSync,
            // Entering Picture in Picture hides the player cover but playback continues.
            isPlayerShowing: { [weak coordinator] in
                coordinator?.showPlayer == true || coordinator?.isPictureInPictureActive == true
            }
        )
        #endif
        _playbackCoordinator = State(initialValue: coordinator)
        // Siri's intents run in this process and reach the app through it.
        let siri = SiriPlaybackService(plexService: service, playback: coordinator)
        AppDependencyManager.shared.add(dependency: siri)
        _userPreferences = State(initialValue: prefs)
        Self.configurePlaybackAudioSession()
        #if os(iOS)
        Self.configureTabBarAppearance()
        #elseif os(tvOS)
        Self.configureTabBarTint()
        #endif
    }

    var body: some Scene {
        #if os(iOS)
        let requestTracker = requestTracker
        #endif
        WindowGroup {
            ContentView()
                .environment(plexService)
                .environment(seerrService)
                .environment(requestTracker)
                .environment(tasteRecommender)
                .environment(playbackCoordinator)
                .environment(downloadManager)
                .environment(offlinePlaybackSyncManager)
                .environment(userPreferences)
                .environment(store)
                #if os(tvOS)
                .environment(topShelfLinks)
                #endif
                .onOpenURL { url in
                    if athenaLinks.open(url) { return }
                    #if os(tvOS)
                    topShelfLinks.open(url)
                    #endif
                }
                .alert(
                    "Use Athena for Describe It?",
                    isPresented: Binding(
                        get: { athenaLinks.pending != nil },
                        set: { if !$0 { athenaLinks.pending = nil } }
                    ),
                    presenting: athenaLinks.pending
                ) { link in
                    Button("Use Athena") { athenaLinks.accept(link, preferences: userPreferences) }
                    Button("Cancel", role: .cancel) { athenaLinks.pending = nil }
                } message: { link in
                    Text("Describe It will send what you type, the titles in your library that fit, and your sign-in for its Plex server, which works on that server only, to Athena at \(link.host), which passes the request to Anthropic's Claude. Only use an address from someone whose Plex server you use.")
                }
                .preferredColorScheme(userPreferences.appearanceMode.preferredColorScheme)
                .task {
                    PlaybackEngineFactory.prewarmIfNeeded()
                }
                .task(
                    id: seerrContextID
                ) {
                    requestTracker.contextDidChange(seerrContextID)
                    await seerrService.contextDidChange()
                }
                .task(
                    id: offlineContextID
                ) {
                    guard plexService.homeBootstrapCompleted else {
                        offlinePlaybackSyncManager.stopAutomaticSync()
                        return
                    }

                    downloadManager.activateProfile()
                    offlinePlaybackSyncManager.activateProfile()

                    guard plexService.isSessionReady else {
                        offlinePlaybackSyncManager.stopAutomaticSync()
                        return
                    }

                    offlinePlaybackSyncManager.startAutomaticSync()
                    await offlinePlaybackSyncManager.syncPendingActions(force: true)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                    }

                    #if os(tvOS)
                    if newPhase == .background, !TopShelfPublisher.isAllowed(for: plexService) {
                        TopShelfPublisher.shared.clear()
                    }
                    #endif

                    #if os(iOS)
                    if newPhase == .background {
                        requestTracker.scheduleBackgroundRefreshIfNeeded()
                    }
                    #endif

                    if newPhase == .active,
                       plexService.isSessionReady {
                        offlinePlaybackSyncManager.startAutomaticSync()
                        Task {
                            await offlinePlaybackSyncManager.syncPendingActions(force: true)
                        }
                    } else {
                        offlinePlaybackSyncManager.stopAutomaticSync()
                    }
                }
                .onChange(of: userPreferences.downloadsWifiOnly) {
                    downloadManager.evaluateNetworkConstraints()
                }
        }
        #if os(iOS)
        // Looks for arrived requests while the app is closed; scheduled only
        // while one is on its way.
        .backgroundTask(.appRefresh(SeerrRequestNotifications.refreshTaskIdentifier)) {
            await requestTracker.refreshInBackground()
        }
        #endif
    }
}

private extension IthacaApp {
    /// Seerr is bound to the account's first enabled server (see
    /// `SeerrService`), not to whichever server happens to be connected, so its
    /// context only changes when that binding or the profile does.
    var seerrContextID: String {
        [
            plexService.activeProfileID ?? "none",
            plexService.seerrBindingServerID ?? "none",
            String(plexService.isAuthenticated),
            String(plexService.isSessionReady),
        ].joined(separator: ":")
    }

    /// Offline sync spans the whole pool: a second server coming up has to
    /// re-arm it, so the connected count is part of the identity.
    var offlineContextID: String {
        [
            String(plexService.homeBootstrapCompleted),
            plexService.activeProfileID ?? "none",
            plexService.pool.primary?.serverID ?? "none",
            String(plexService.pool.connections.count),
        ].joined(separator: ":")
    }

    static func configurePlaybackAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            // `.longFormVideo` routing policy is iOS-only; tvOS keeps the plain
            // playback category (HDMI route, no AirPlay long-form handoff).
            #if os(tvOS)
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            #else
            try audioSession.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            #endif
            try audioSession.setSupportsMultichannelContent(true)
        } catch {
            assertionFailure("Failed to configure playback audio session: \(error.localizedDescription)")
        }
    }
}

#if os(iOS)
private extension IthacaApp {
    static func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = .ithacaSurface
        appearance.shadowColor = UIColor.label.withAlphaComponent(0.05)

        let tabBarAppearance = UITabBar.appearance()
        tabBarAppearance.standardAppearance = appearance
        tabBarAppearance.scrollEdgeAppearance = appearance
    }
}
#endif

#if os(tvOS)
private extension IthacaApp {
    /// Gives every tvOS tab bar an explicit tint at creation.
    ///
    /// Without it the bar inherits the window tint (the global accent color).
    /// The tab shell pins the same color on the live bar; this covers the bar
    /// before the shell's first update. See `MainTabTVShell`.
    static func configureTabBarTint() {
        UITabBar.appearance().tintColor = .ithacaTVTabBarTint
    }
}
#endif

extension Color {
    static let ithacaBackground = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(ithacaHex: 0x090A0F)
                : UIColor(ithacaHex: 0xF5F7FA)
        }
    )

    static let ithacaSurface = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(ithacaHex: 0x161824)
                : UIColor(ithacaHex: 0xFFFFFF)
        }
    )

    /// Brand accent. Reserved for brand moments; never a UI tint, state or
    /// progress color. See STYLE.md.
    static let ithacaAccent = Color(uiColor: .ithacaAccent)

    static let ithacaTextPrimary = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(ithacaHex: 0xF2F2F7)
                : UIColor(ithacaHex: 0x1C1C1E)
        }
    )

    static let ithacaTextSecondary = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(ithacaHex: 0x8E95A8)
                : UIColor(ithacaHex: 0x636366)
        }
    )

    /// Label/icon color for prominent primary action buttons whose fill is
    /// `Color.primary` (a dark glass capsule in Light mode, light in Dark mode).
    /// Resolves to the inverse of `primary` so the title stays legible on the
    /// contrasting fill: white in Light mode, black in Dark mode.
    static let ithacaPrimaryActionLabel = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(ithacaHex: 0x090A0F)
                : UIColor(ithacaHex: 0xFFFFFF)
        }
    )

    /// Content tint for the tvOS tab shell.
    ///
    /// tvOS draws the selected, unfocused tab item's icon and title in the bar's
    /// tint, so the tint has to be the label color: `TextPrimary` in Dark mode,
    /// black in Light mode. This is also tvOS's own default tint, and the focused
    /// item keeps its system contrast against the focus plate regardless of the
    /// tint. Backed by a dynamic `UIColor` so the same color can be pinned on the
    /// real `UITabBar` and resolves against the bar's own traits.
    static let ithacaTVTabBarTint = Color(uiColor: .ithacaTVTabBarTint)

    /// Tint for the prominent primary action glass. A *translucent* `primary` so
    /// the button keeps a dark/light lean for contrast while the glass material
    /// still reads through it — more "liquid glass" than a solid black/white fill.
    /// Lower the opacity for more glass, raise it for more contrast.
    static var ithacaPrimaryButtonTint: Color {
        Color.primary.opacity(0.7)
    }

}

extension UIColor {
    /// UIKit twin of `Color.ithacaTVTabBarTint`, pinned on the tvOS tab bar.
    static let ithacaTVTabBarTint = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(ithacaHex: 0xF2F2F7)
            : UIColor(ithacaHex: 0x000000)
    }
}

private extension UIColor {
    static let ithacaSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(ithacaHex: 0x161824)
            : UIColor(ithacaHex: 0xFFFFFF)
    }

    static let ithacaAccent = UIColor(ithacaHex: 0xE8B04A)

    static let ithacaTextSecondary = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(ithacaHex: 0x8E95A8)
            : UIColor(ithacaHex: 0x636366)
    }

    convenience init(ithacaHex: UInt32) {
        let red = CGFloat((ithacaHex >> 16) & 0xFF) / 255
        let green = CGFloat((ithacaHex >> 8) & 0xFF) / 255
        let blue = CGFloat(ithacaHex & 0xFF) / 255

        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
