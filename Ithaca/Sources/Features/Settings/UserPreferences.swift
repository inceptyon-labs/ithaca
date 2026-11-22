import Foundation
import SwiftUI

/// Centralized user preferences backed by UserDefaults.
///
/// Injected into the environment so any view or coordinator can read settings.
/// StreamResolver and PlaybackCoordinator consume these to pick the right engine
/// and select default tracks.
@MainActor
@Observable
final class UserPreferences {
    // MARK: - Keys

    private enum Keys {
        static let maxResolution = "maxResolution"
        static let defaultSubtitleLanguage = "defaultSubtitleLanguage"
        static let subtitleForcedOnly = "subtitleForcedOnly"
        static let subtitleFontSize = "subtitleFontSize"
        static let subtitleBackground = "subtitleBackground"
        static let subtitleColor = "subtitleColor"
        static let subtitlePosition = "subtitlePosition"
        static let playbackStartBehavior = "playbackStartBehavior"
        static let hidesEpisodeSpoilers = "hidesEpisodeSpoilers"
        static let showsPickSomethingOnHome = "showsPickSomethingOnHome"
        static let showsRequestsOnHome = "showsRequestsOnHome"
        static let requestArrivalNotificationsEnabled = "requestArrivalNotificationsEnabled"
        static let readyRequestShelfLife = "readyRequestShelfLife"
        static let smartDownloadsEnabled = "smartDownloadsEnabled"
        static let smartDownloadEpisodeCount = "smartDownloadEpisodeCount"
        static let defaultAudioLanguage = "defaultAudioLanguage"
        static let continuousPlayEnabled = "continuousPlayEnabled"
        static let continuousPlayCountdown = "continuousPlayCountdown"
        static let continuousPlayPassoutProtectionEpisodeLimit = "continuousPlayPassoutProtectionEpisodeLimit"
        static let playerDoubleTapSeekEnabled = "playerDoubleTapSeekEnabled"
        static let playerEpisodeButtonsEnabled = "playerEpisodeButtonsEnabled"
        static let playerDoubleTapForwardInterval = "playerDoubleTapForwardInterval"
        static let playerDoubleTapBackwardInterval = "playerDoubleTapBackwardInterval"
        static let playerAspectFillPortrait = "playerAspectFillPortrait"
        static let playerAspectFillLandscape = "playerAspectFillLandscape"
        static let autoSkipIntroMode = "autoSkipIntroMode"
        static let autoSkipIntro = "autoSkipIntro"
        static let autoSkipCredits = "autoSkipCredits"
        static let forceAVPlayer = "forceAVPlayer"
        static let forceVLCKit = "forceVLCKit"
        static let spatialAudioRemuxEnabled = "spatialAudioRemuxEnabled"
        static let hdrVideoRemuxEnabled = "hdrVideoRemuxEnabled"
        static let dolbyVision7ConversionEnabled = "dolbyVision7ConversionEnabled"
        static let appearanceMode = "appearanceMode"
        static let libraryTabOrder = "libraryTabOrder"
        static let hiddenLibraryTabs = "hiddenLibraryTabs"
        static let showsLiveTVOnHome = "showsLiveTVOnHome"
        static let personalizedShelvesEnabled = "personalizedShelvesEnabled"
        static let asksForRatings = "asksForRatings"
        static let athenaURL = "athenaURL"
        static let foundAthenaURL = "foundAthenaURL"
        static let athenaConsent = "athenaConsent"
        static let athenaConsentAddress = "athenaConsentAddress"
        /// Before Athena was renamed from Mentor: read when the new key is unset.
        static let legacyMentorURL = "mentorURL"
        static let legacyFoundMentorURL = "foundMentorURL"
        static let legacyMentorConsent = "mentorConsent"
        static let trailerPreviewsEnabled = "trailerPreviewsEnabled"
        static let downloadMaxResolution = "downloadMaxResolution"
        static let downloadsWifiOnly = "downloadsWifiOnly"
        static let maximumActiveDownloads = "maximumActiveDownloads"
        static let downloadFreeSpaceReserve = "downloadFreeSpaceReserve"
    }

    // MARK: - Properties

    var maxResolution: MaxResolution {
        didSet { UserDefaults.standard.set(maxResolution.rawValue, forKey: Keys.maxResolution) }
    }

    /// ISO 639-1 language code, or nil for "None" (no default subtitle).
    var defaultSubtitleLanguage: String? {
        didSet { UserDefaults.standard.set(defaultSubtitleLanguage ?? "", forKey: Keys.defaultSubtitleLanguage) }
    }

    /// When enabled, automatic subtitle selection only picks forced tracks.
    var subtitleForcedOnly: Bool {
        didSet { UserDefaults.standard.set(subtitleForcedOnly, forKey: Keys.subtitleForcedOnly) }
    }

    /// On-screen size of locally rendered subtitles. Applies to both engines
    /// and can also be changed from inside the player.
    var subtitleFontSize: SubtitleFontSize {
        didSet { UserDefaults.standard.set(subtitleFontSize.rawValue, forKey: Keys.subtitleFontSize) }
    }

    var subtitleBackground: SubtitleBackground {
        didSet { UserDefaults.standard.set(subtitleBackground.rawValue, forKey: Keys.subtitleBackground) }
    }

    var subtitleColor: SubtitleColor {
        didSet { UserDefaults.standard.set(subtitleColor.rawValue, forKey: Keys.subtitleColor) }
    }

    var subtitlePosition: SubtitlePosition {
        didSet { UserDefaults.standard.set(subtitlePosition.rawValue, forKey: Keys.subtitlePosition) }
    }

    /// Everything about how locally rendered subtitles look, for the engines.
    var subtitleStyle: SubtitleStyle {
        SubtitleStyle(size: subtitleFontSize, background: subtitleBackground, color: subtitleColor, position: subtitlePosition)
    }

    /// What Play does for a title with a saved position.
    var playbackStartBehavior: PlaybackStartBehavior {
        didSet { UserDefaults.standard.set(playbackStartBehavior.rawValue, forKey: Keys.playbackStartBehavior) }
    }

    /// A Play button's title: one that says Resume only while Play does.
    func playTitle(_ resumingTitle: String) -> String {
        playbackStartBehavior == .startOver ? "Play" : resumingTitle
    }

    /// Blurs the pictures and hides the summaries of episodes this profile
    /// hasn't started (`EpisodeSpoilers`). Off by default.
    var hidesEpisodeSpoilers: Bool {
        didSet { UserDefaults.standard.set(hidesEpisodeSpoilers, forKey: Keys.hidesEpisodeSpoilers) }
    }

    /// ISO 639-1 language code for preferred audio track.
    var defaultAudioLanguage: String {
        didSet { UserDefaults.standard.set(defaultAudioLanguage, forKey: Keys.defaultAudioLanguage) }
    }

    /// Automatically continue to the next episode when TV playback finishes.
    var continuousPlayEnabled: Bool {
        didSet { UserDefaults.standard.set(continuousPlayEnabled, forKey: Keys.continuousPlayEnabled) }
    }

    /// Delay before automatically starting the next episode from the Up Next screen.
    var continuousPlayCountdown: ContinuousPlayCountdown {
        didSet { UserDefaults.standard.set(continuousPlayCountdown.rawValue, forKey: Keys.continuousPlayCountdown) }
    }

    /// Stops automatic episode chaining after a streak until the user confirms.
    /// `nil` disables passout protection entirely.
    var continuousPlayPassoutProtectionEpisodeLimit: Int? {
        didSet {
            let storedValue = max(continuousPlayPassoutProtectionEpisodeLimit ?? 0, 0)
            UserDefaults.standard.set(storedValue, forKey: Keys.continuousPlayPassoutProtectionEpisodeLimit)
        }
    }

    /// Controls automatic skipping of intro markers after a brief countdown.
    var autoSkipIntroMode: AutoSkipIntroMode {
        didSet { UserDefaults.standard.set(autoSkipIntroMode.rawValue, forKey: Keys.autoSkipIntroMode) }
    }

    /// Automatically skip credits markers after a brief countdown.
    var autoSkipCredits: Bool {
        didSet { UserDefaults.standard.set(autoSkipCredits, forKey: Keys.autoSkipCredits) }
    }

    /// Enable left/right double-tap seeking on touch-based platforms.
    var playerDoubleTapSeekEnabled: Bool {
        didSet { UserDefaults.standard.set(playerDoubleTapSeekEnabled, forKey: Keys.playerDoubleTapSeekEnabled) }
    }

    /// Previous / Next Episode buttons beside Play in the iOS player. Opt-in so
    /// the default HUD stays clean; tvOS always offers Next Episode in its
    /// action row and has no toggle.
    var playerEpisodeButtonsEnabled: Bool {
        didSet { UserDefaults.standard.set(playerEpisodeButtonsEnabled, forKey: Keys.playerEpisodeButtonsEnabled) }
    }

    /// Jump interval for double-tapping the right side of the player.
    var playerDoubleTapForwardInterval: PlayerSeekInterval {
        didSet { UserDefaults.standard.set(playerDoubleTapForwardInterval.rawValue, forKey: Keys.playerDoubleTapForwardInterval) }
    }

    /// Jump interval for double-tapping the left side of the player.
    var playerDoubleTapBackwardInterval: PlayerSeekInterval {
        didSet { UserDefaults.standard.set(playerDoubleTapBackwardInterval.rawValue, forKey: Keys.playerDoubleTapBackwardInterval) }
    }

    /// Whether the player's zoom-to-fill control is on while the video area is
    /// taller than wide (portrait). Stored separately from landscape so each
    /// orientation remembers its own framing independently.
    var playerAspectFillPortrait: Bool {
        didSet { UserDefaults.standard.set(playerAspectFillPortrait, forKey: Keys.playerAspectFillPortrait) }
    }

    /// Whether the player's zoom-to-fill control is on while the video area is
    /// wider than tall (landscape).
    var playerAspectFillLandscape: Bool {
        didSet { UserDefaults.standard.set(playerAspectFillLandscape, forKey: Keys.playerAspectFillLandscape) }
    }

    /// Saved zoom-to-fill choice for the given player orientation.
    func playerAspectFill(isLandscape: Bool) -> Bool {
        isLandscape ? playerAspectFillLandscape : playerAspectFillPortrait
    }

    /// Persists the zoom-to-fill choice for the given player orientation.
    func setPlayerAspectFill(_ enabled: Bool, isLandscape: Bool) {
        if isLandscape {
            playerAspectFillLandscape = enabled
        } else {
            playerAspectFillPortrait = enabled
        }
    }

    /// Bypass StreamResolver and always use AVPlayer.
    var forceAVPlayer: Bool {
        didSet {
            if forceAVPlayer && forceVLCKit {
                forceVLCKit = false
            }
            UserDefaults.standard.set(forceAVPlayer, forKey: Keys.forceAVPlayer)
        }
    }

    /// Bypass StreamResolver and always use VLCKit.
    var forceVLCKit: Bool {
        didSet {
            if forceVLCKit && forceAVPlayer {
                forceAVPlayer = false
            }
            UserDefaults.standard.set(forceVLCKit, forKey: Keys.forceVLCKit)
        }
    }

    /// Play Dolby Atmos (and, on iPhone/iPad, multichannel Dolby) from files
    /// only VLCKit could direct play through a lossless Plex remux into
    /// AVPlayer, so Atmos reaches HDMI and AirPods get spatial audio.
    var spatialAudioRemuxEnabled: Bool {
        didSet { UserDefaults.standard.set(spatialAudioRemuxEnabled, forKey: Keys.spatialAudioRemuxEnabled) }
    }

    /// Play HDR files only VLCKit could direct play (HDR10, HDR10+, HLG,
    /// Dolby Vision 7/8) through a lossless Plex remux into AVPlayer, which
    /// shows real HDR and applies Dolby Vision 8.1/8.4 metadata. VLCKit
    /// renders into an 8-bit SDR surface on iOS/tvOS.
    var hdrVideoRemuxEnabled: Bool {
        didSet { UserDefaults.standard.set(hdrVideoRemuxEnabled, forKey: Keys.hdrVideoRemuxEnabled) }
    }

    /// Convert Dolby Vision profile 7 to 8.1 on device during the HDR remux,
    /// so a Dolby Vision display shows Dolby Vision instead of the HDR10
    /// base layer. Only applies while `hdrVideoRemuxEnabled` is on.
    var dolbyVision7ConversionEnabled: Bool {
        didSet { UserDefaults.standard.set(dolbyVision7ConversionEnabled, forKey: Keys.dolbyVision7ConversionEnabled) }
    }

    /// App-wide appearance override.
    var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }

    /// The preferred order of library destinations in the main tab bar.
    /// All supported types remain in this array, including hidden ones, so a
    /// library returns to its previous position when it is shown again.
    private(set) var libraryTabOrder: [PlexLibraryType] {
        didSet {
            UserDefaults.standard.set(
                libraryTabOrder.map(\.rawValue),
                forKey: Keys.libraryTabOrder
            )
        }
    }

    /// Library destinations excluded from the main tab bar.
    private var hiddenLibraryTabs: Set<PlexLibraryType> {
        didSet {
            UserDefaults.standard.set(
                hiddenLibraryTabs.map(\.rawValue).sorted(),
                forKey: Keys.hiddenLibraryTabs
            )
        }
    }

    func visibleLibraryTabs(from availableTypes: [PlexLibraryType]) -> [PlexLibraryType] {
        let availableTypes = Set(availableTypes)
        return libraryTabOrder.filter {
            availableTypes.contains($0) && !hiddenLibraryTabs.contains($0)
        }
    }

    func isLibraryTabVisible(_ libraryType: PlexLibraryType) -> Bool {
        !hiddenLibraryTabs.contains(libraryType)
    }

    func setLibraryTabVisible(_ isVisible: Bool, for libraryType: PlexLibraryType) {
        if isVisible {
            hiddenLibraryTabs.remove(libraryType)
        } else {
            hiddenLibraryTabs.insert(libraryType)
        }
    }

    func moveLibraryTabs(fromOffsets: IndexSet, toOffset: Int) {
        libraryTabOrder.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func moveLibraryTab(_ libraryType: PlexLibraryType, to destinationIndex: Int) {
        guard let sourceIndex = libraryTabOrder.firstIndex(of: libraryType) else { return }

        var reorderedTabs = libraryTabOrder
        let movedTab = reorderedTabs.remove(at: sourceIndex)
        let clampedIndex = min(max(destinationIndex, 0), reorderedTabs.count)
        reorderedTabs.insert(movedTab, at: clampedIndex)
        libraryTabOrder = reorderedTabs
    }

    /// Whether Home shows the currently airing Live TV shelf. Off by default;
    /// it does not affect the Live TV navigation tab.
    var showsLiveTVOnHome: Bool {
        didSet { UserDefaults.standard.set(showsLiveTVOnHome, forKey: Keys.showsLiveTVOnHome) }
    }

    /// Extra Home shelves generated by Ithaca, enabled for existing installs.
    var personalizedShelvesEnabled: Bool {
        didSet { UserDefaults.standard.set(personalizedShelvesEnabled, forKey: Keys.personalizedShelvesEnabled) }
    }

    /// Asks "How was it?" after a movie, or the last episode there is of a
    /// show, is watched to the end. On by default.
    var asksForRatings: Bool {
        didSet { UserDefaults.standard.set(asksForRatings, forKey: Keys.asksForRatings) }
    }

    /// Athena, the server that answers Pick Something's Describe It
    /// (`AthenaClient`), as typed in Settings. Empty when there is none.
    var athenaURL: String {
        didSet { UserDefaults.standard.set(athenaURL, forKey: Keys.athenaURL) }
    }

    /// Where `HomeServerFinder` last found Athena beside a Plex server. Kept
    /// while away from home, where it can't be looked for.
    var foundAthenaURL: String {
        didSet { UserDefaults.standard.set(foundAthenaURL, forKey: Keys.foundAthenaURL) }
    }

    /// The Athena in use: the typed address, else the found one.
    var athenaAddress: String {
        athenaURL.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? foundAthenaURL
    }

    /// Whether Describe It may send requests, with the viewer's token for
    /// Athena's Plex server, to the Athena in use, which passes them to Anthropic's Claude. Asked
    /// before the first one (App Review guideline 5.1.2(i)); declined,
    /// Describe It runs on the device. The answer belongs to the address it
    /// was given for: another Athena, typed, found or shared, is asked about
    /// again.
    var athenaConsent: AthenaConsent {
        get {
            athenaConsentAddress == Self.athenaConsentKey(athenaAddress) ? storedAthenaConsent : .undecided
        }
        set {
            storedAthenaConsent = newValue
            athenaConsentAddress = Self.athenaConsentKey(athenaAddress)
        }
    }

    private var storedAthenaConsent: AthenaConsent {
        didSet { UserDefaults.standard.set(storedAthenaConsent.rawValue, forKey: Keys.athenaConsent) }
    }

    /// The Athena `storedAthenaConsent` was given for, as `AthenaClient`
    /// normalizes it. Empty for an answer from before consent had an address.
    private var athenaConsentAddress: String {
        didSet { UserDefaults.standard.set(athenaConsentAddress, forKey: Keys.athenaConsentAddress) }
    }

    private static func athenaConsentKey(_ address: String) -> String {
        AthenaClient(address: address)?.baseURL.absoluteString ?? ""
    }

    /// tvOS: a movie or show page plays its trailer, muted, behind the hero
    /// after a few seconds. On by default.
    var trailerPreviewsEnabled: Bool {
        didSet { UserDefaults.standard.set(trailerPreviewsEnabled, forKey: Keys.trailerPreviewsEnabled) }
    }

    /// Home's Pick Something row. On by default.
    var showsPickSomethingOnHome: Bool {
        didSet { UserDefaults.standard.set(showsPickSomethingOnHome, forKey: Keys.showsPickSomethingOnHome) }
    }

    /// Home's Your Requests row. On by default.
    var showsRequestsOnHome: Bool {
        didSet { UserDefaults.standard.set(showsRequestsOnHome, forKey: Keys.showsRequestsOnHome) }
    }

    /// iOS: a notification when a request is ready to watch. On by default.
    var requestArrivalNotificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(requestArrivalNotificationsEnabled, forKey: Keys.requestArrivalNotificationsEnabled)
        }
    }

    /// How long a ready request stays in Your Requests.
    var readyRequestShelfLife: ReadyRequestShelfLife {
        didSet { UserDefaults.standard.set(readyRequestShelfLife.rawValue, forKey: Keys.readyRequestShelfLife) }
    }

    /// iOS: keeps the next episodes of a show with downloads downloaded, and
    /// removes a downloaded episode from the device once it's watched. Never
    /// touches the server. Off by default.
    var smartDownloadsEnabled: Bool {
        didSet { UserDefaults.standard.set(smartDownloadsEnabled, forKey: Keys.smartDownloadsEnabled) }
    }

    /// How many unwatched episodes smart downloads keep ready per show.
    var smartDownloadEpisodeCount: SmartDownloadEpisodeCount {
        didSet { UserDefaults.standard.set(smartDownloadEpisodeCount.rawValue, forKey: Keys.smartDownloadEpisodeCount) }
    }

    /// Maximum version quality selected for downloads.
    var downloadMaxResolution: MaxResolution {
        didSet { UserDefaults.standard.set(downloadMaxResolution.rawValue, forKey: Keys.downloadMaxResolution) }
    }

    /// Prevent new download tasks from using expensive networks such as cellular.
    var downloadsWifiOnly: Bool {
        didSet { UserDefaults.standard.set(downloadsWifiOnly, forKey: Keys.downloadsWifiOnly) }
    }

    /// Number of download tasks the queue may run at the same time.
    var maximumActiveDownloads: DownloadConcurrency {
        didSet { UserDefaults.standard.set(maximumActiveDownloads.rawValue, forKey: Keys.maximumActiveDownloads) }
    }

    /// Amount of free storage Ithaca should leave available.
    var downloadFreeSpaceReserve: DownloadFreeSpaceReserve {
        didSet { UserDefaults.standard.set(downloadFreeSpaceReserve.rawValue, forKey: Keys.downloadFreeSpaceReserve) }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        let maxResolution: MaxResolution
        if let raw = defaults.string(forKey: Keys.maxResolution),
           let value = MaxResolution(rawValue: raw) {
            maxResolution = value
        } else {
            maxResolution = .auto
        }

        let defaultSubtitleLanguage = Self.storedSubtitleLanguage(defaults: defaults)
        let subtitleForcedOnly = defaults.object(forKey: Keys.subtitleForcedOnly) as? Bool ?? true
        let subtitleFontSize: SubtitleFontSize
        if let raw = defaults.string(forKey: Keys.subtitleFontSize),
           let value = SubtitleFontSize(rawValue: raw) {
            subtitleFontSize = value
        } else {
            subtitleFontSize = .default
        }
        let defaultAudioLanguage = defaults.string(forKey: Keys.defaultAudioLanguage) ?? "en"
        let continuousPlayEnabled = defaults.object(forKey: Keys.continuousPlayEnabled) as? Bool ?? true
        let continuousPlayCountdown = Self.storedContinuousPlayCountdown(
            forKey: Keys.continuousPlayCountdown,
            defaults: defaults,
            fallback: .fiveSeconds
        )
        let continuousPlayPassoutProtectionEpisodeLimit = Self.storedOptionalPositiveInt(
            forKey: Keys.continuousPlayPassoutProtectionEpisodeLimit,
            defaults: defaults,
            fallback: 3
        )
        let autoSkipIntroMode = Self.storedAutoSkipIntroMode(defaults: defaults)
        let autoSkipCredits = defaults.object(forKey: Keys.autoSkipCredits) as? Bool ?? false
        let playerDoubleTapSeekEnabled = defaults.object(forKey: Keys.playerDoubleTapSeekEnabled) as? Bool ?? true
        let playerEpisodeButtonsEnabled = defaults.bool(forKey: Keys.playerEpisodeButtonsEnabled)
        let playerDoubleTapForwardInterval = Self.storedSeekInterval(
            forKey: Keys.playerDoubleTapForwardInterval,
            defaults: defaults,
            fallback: .fifteenSeconds
        )
        let playerDoubleTapBackwardInterval = Self.storedSeekInterval(
            forKey: Keys.playerDoubleTapBackwardInterval,
            defaults: defaults,
            fallback: .fifteenSeconds
        )
        // Absent defaults to `false` (letterboxed fit), matching the old
        // session-scoped behavior where zoom always started off.
        let playerAspectFillPortrait = defaults.bool(forKey: Keys.playerAspectFillPortrait)
        let playerAspectFillLandscape = defaults.bool(forKey: Keys.playerAspectFillLandscape)
        let storedForceAVPlayer = defaults.bool(forKey: Keys.forceAVPlayer)
        let storedForceVLCKit = defaults.bool(forKey: Keys.forceVLCKit)
        let forceAVPlayer = storedForceAVPlayer
        let forceVLCKit = storedForceAVPlayer ? false : storedForceVLCKit
        let downloadMaxResolution: MaxResolution
        if let raw = defaults.string(forKey: Keys.downloadMaxResolution),
           let value = MaxResolution(rawValue: raw) {
            downloadMaxResolution = value
        } else {
            downloadMaxResolution = maxResolution
        }
        let downloadsWifiOnly = defaults.object(forKey: Keys.downloadsWifiOnly) as? Bool ?? true
        let maximumActiveDownloads = Self.storedDownloadConcurrency(
            forKey: Keys.maximumActiveDownloads,
            defaults: defaults,
            fallback: .one
        )
        let downloadFreeSpaceReserve = Self.storedDownloadFreeSpaceReserve(
            forKey: Keys.downloadFreeSpaceReserve,
            defaults: defaults,
            fallback: .fiveGB
        )

        let appearanceMode: AppearanceMode
        if let raw = defaults.string(forKey: Keys.appearanceMode),
           let mode = AppearanceMode(rawValue: raw) {
            appearanceMode = mode
        } else {
            // tvOS's Light appearance is unpleasant for this app, so default to Dark
            // there. Other platforms still follow the system setting by default.
            #if os(tvOS)
            appearanceMode = .dark
            #else
            appearanceMode = .system
            #endif
        }
        let libraryTabOrder = Self.storedLibraryTabOrder(defaults: defaults)
        let hiddenLibraryTabs = Self.storedHiddenLibraryTabs(defaults: defaults)

        self.maxResolution = maxResolution
        self.defaultSubtitleLanguage = defaultSubtitleLanguage
        self.subtitleForcedOnly = subtitleForcedOnly
        self.subtitleFontSize = subtitleFontSize
        self.subtitleBackground = defaults.string(forKey: Keys.subtitleBackground)
            .flatMap(SubtitleBackground.init(rawValue:)) ?? .default
        self.subtitleColor = defaults.string(forKey: Keys.subtitleColor).flatMap(SubtitleColor.init(rawValue:)) ?? .default
        self.subtitlePosition = defaults.string(forKey: Keys.subtitlePosition)
            .flatMap(SubtitlePosition.init(rawValue:)) ?? .default
        self.playbackStartBehavior = defaults.string(forKey: Keys.playbackStartBehavior)
            .flatMap(PlaybackStartBehavior.init(rawValue:)) ?? .resume
        self.hidesEpisodeSpoilers = defaults.bool(forKey: Keys.hidesEpisodeSpoilers)
        self.defaultAudioLanguage = defaultAudioLanguage
        self.continuousPlayEnabled = continuousPlayEnabled
        self.continuousPlayCountdown = continuousPlayCountdown
        self.continuousPlayPassoutProtectionEpisodeLimit = continuousPlayPassoutProtectionEpisodeLimit
        self.autoSkipIntroMode = autoSkipIntroMode
        self.autoSkipCredits = autoSkipCredits
        self.playerDoubleTapSeekEnabled = playerDoubleTapSeekEnabled
        self.playerEpisodeButtonsEnabled = playerEpisodeButtonsEnabled
        self.playerDoubleTapForwardInterval = playerDoubleTapForwardInterval
        self.playerDoubleTapBackwardInterval = playerDoubleTapBackwardInterval
        self.playerAspectFillPortrait = playerAspectFillPortrait
        self.playerAspectFillLandscape = playerAspectFillLandscape
        self.forceAVPlayer = forceAVPlayer
        self.forceVLCKit = forceVLCKit
        self.spatialAudioRemuxEnabled = defaults.object(forKey: Keys.spatialAudioRemuxEnabled) as? Bool ?? true
        self.hdrVideoRemuxEnabled = defaults.object(forKey: Keys.hdrVideoRemuxEnabled) as? Bool ?? true
        self.dolbyVision7ConversionEnabled = defaults.object(forKey: Keys.dolbyVision7ConversionEnabled) as? Bool ?? true
        self.appearanceMode = appearanceMode
        self.libraryTabOrder = libraryTabOrder
        self.hiddenLibraryTabs = hiddenLibraryTabs
        self.showsLiveTVOnHome = defaults.bool(forKey: Keys.showsLiveTVOnHome)
        self.personalizedShelvesEnabled = defaults.object(forKey: Keys.personalizedShelvesEnabled) as? Bool ?? true
        self.asksForRatings = defaults.object(forKey: Keys.asksForRatings) as? Bool ?? true
        self.athenaURL = defaults.string(forKey: Keys.athenaURL) ?? defaults.string(forKey: Keys.legacyMentorURL) ?? ""
        self.foundAthenaURL = defaults.string(forKey: Keys.foundAthenaURL) ?? defaults.string(forKey: Keys.legacyFoundMentorURL) ?? ""
        self.storedAthenaConsent = AthenaConsent(
            rawValue: defaults.integer(forKey: defaults.object(forKey: Keys.athenaConsent) == nil
                ? Keys.legacyMentorConsent : Keys.athenaConsent)
        ) ?? .undecided
        self.athenaConsentAddress = defaults.string(forKey: Keys.athenaConsentAddress) ?? ""
        self.trailerPreviewsEnabled = defaults.object(forKey: Keys.trailerPreviewsEnabled) as? Bool ?? true
        self.downloadMaxResolution = downloadMaxResolution
        self.downloadsWifiOnly = downloadsWifiOnly
        self.maximumActiveDownloads = maximumActiveDownloads
        self.downloadFreeSpaceReserve = downloadFreeSpaceReserve
        self.showsPickSomethingOnHome = defaults.object(forKey: Keys.showsPickSomethingOnHome) as? Bool ?? true
        self.showsRequestsOnHome = defaults.object(forKey: Keys.showsRequestsOnHome) as? Bool ?? true
        self.requestArrivalNotificationsEnabled = defaults.object(
            forKey: Keys.requestArrivalNotificationsEnabled
        ) as? Bool ?? true
        self.readyRequestShelfLife = ReadyRequestShelfLife(rawValue: defaults.integer(forKey: Keys.readyRequestShelfLife))
            ?? .week
        self.smartDownloadsEnabled = defaults.bool(forKey: Keys.smartDownloadsEnabled)
        self.smartDownloadEpisodeCount = SmartDownloadEpisodeCount(
            rawValue: defaults.integer(forKey: Keys.smartDownloadEpisodeCount)
        ) ?? .three
    }

    private static func storedSeekInterval(
        forKey key: String,
        defaults: UserDefaults,
        fallback: PlayerSeekInterval
    ) -> PlayerSeekInterval {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return PlayerSeekInterval(rawValue: defaults.integer(forKey: key)) ?? fallback
    }

    private static func storedLibraryTabOrder(defaults: UserDefaults) -> [PlexLibraryType] {
        let storedTypes = (defaults.stringArray(forKey: Keys.libraryTabOrder) ?? [])
            .compactMap(PlexLibraryType.init(rawValue:))

        var normalizedTypes: [PlexLibraryType] = []
        for libraryType in storedTypes + PlexLibraryType.allCases
        where !normalizedTypes.contains(libraryType) {
            normalizedTypes.append(libraryType)
        }
        return normalizedTypes
    }

    private static func storedHiddenLibraryTabs(defaults: UserDefaults) -> Set<PlexLibraryType> {
        Set(
            (defaults.stringArray(forKey: Keys.hiddenLibraryTabs) ?? [])
                .compactMap(PlexLibraryType.init(rawValue:))
        )
    }

    private static func storedContinuousPlayCountdown(
        forKey key: String,
        defaults: UserDefaults,
        fallback: ContinuousPlayCountdown
    ) -> ContinuousPlayCountdown {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return ContinuousPlayCountdown(rawValue: defaults.integer(forKey: key)) ?? fallback
    }

    private static func storedAutoSkipIntroMode(defaults: UserDefaults) -> AutoSkipIntroMode {
        if let raw = defaults.string(forKey: Keys.autoSkipIntroMode),
           let mode = AutoSkipIntroMode(rawValue: raw) {
            return mode
        }

        if let legacyValue = defaults.object(forKey: Keys.autoSkipIntro) as? Bool {
            return legacyValue ? .always : .off
        }

        return .alwaysExceptFirstEpisode
    }

    private static func storedDownloadConcurrency(
        forKey key: String,
        defaults: UserDefaults,
        fallback: DownloadConcurrency
    ) -> DownloadConcurrency {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return DownloadConcurrency(rawValue: defaults.integer(forKey: key)) ?? fallback
    }

    private static func storedDownloadFreeSpaceReserve(
        forKey key: String,
        defaults: UserDefaults,
        fallback: DownloadFreeSpaceReserve
    ) -> DownloadFreeSpaceReserve {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return DownloadFreeSpaceReserve(rawValue: defaults.integer(forKey: key)) ?? fallback
    }

    private static func storedOptionalPositiveInt(
        forKey key: String,
        defaults: UserDefaults,
        fallback: Int?
    ) -> Int? {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let value = defaults.integer(forKey: key)
        return value > 0 ? value : nil
    }

    private static func storedSubtitleLanguage(defaults: UserDefaults) -> String? {
        guard defaults.object(forKey: Keys.defaultSubtitleLanguage) != nil else {
            return systemPreferredSubtitleLanguageCode
        }

        guard let storedValue = defaults.string(forKey: Keys.defaultSubtitleLanguage) else {
            return nil
        }

        return storedValue.isEmpty ? nil : normalizedLanguageCode(from: storedValue)
    }

    nonisolated static var systemPreferredSubtitleLanguageCode: String? {
        Locale.preferredLanguages.lazy
            .compactMap(normalizedLanguageCode(from:))
            .first
    }

    nonisolated private static func normalizedLanguageCode(from identifier: String) -> String? {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else { return nil }

        let normalizedIdentifier = trimmedIdentifier.replacingOccurrences(of: "-", with: "_")

        if let languageCode = Locale.Language(identifier: normalizedIdentifier).languageCode?.identifier, !languageCode.isEmpty {
            return languageCode.lowercased()
        }

        if normalizedIdentifier.range(of: "_") == nil {
            return normalizedIdentifier.lowercased()
        }

        return nil
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AutoSkipIntroMode: String, CaseIterable, Identifiable {
    case off
    case always
    case alwaysExceptFirstEpisode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .always: "Always"
        case .alwaysExceptFirstEpisode: "Always Except First Episode"
        }
    }

    func shouldAutoSkipIntro(isFirstEpisodeInSeason: Bool) -> Bool {
        switch self {
        case .off:
            false
        case .always:
            true
        case .alwaysExceptFirstEpisode:
            !isFirstEpisodeInSeason
        }
    }
}

enum PlayerSeekInterval: Int, CaseIterable, Identifiable {
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case fortyFiveSeconds = 45
    case sixtySeconds = 60

    var id: Int { rawValue }

    var displayName: String {
        "\(rawValue)s"
    }

    var timeInterval: TimeInterval {
        TimeInterval(rawValue)
    }
}

enum ContinuousPlayCountdown: Int, CaseIterable, Identifiable {
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15

    var id: Int { rawValue }

    var displayName: String {
        "\(rawValue)s"
    }

    var timeInterval: TimeInterval {
        TimeInterval(rawValue)
    }
}

/// What Play does for a title with a saved position.
enum PlaybackStartBehavior: String, CaseIterable, Identifiable {
    case resume
    case ask
    case startOver

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .resume: "Where You Left Off"
        case .ask: "Ask Each Time"
        case .startOver: "From the Beginning"
        }
    }
}

/// How long a ready request stays in Your Requests, in days.
enum ReadyRequestShelfLife: Int, CaseIterable, Identifiable {
    case day = 1
    case threeDays = 3
    case week = 7
    case twoWeeks = 14
    case month = 30

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .day: "1 Day"
        case .threeDays: "3 Days"
        case .week: "1 Week"
        case .twoWeeks: "2 Weeks"
        case .month: "1 Month"
        }
    }

    var timeInterval: TimeInterval {
        TimeInterval(rawValue) * 24 * 60 * 60
    }
}

/// Unwatched episodes smart downloads keep ready per show.
enum SmartDownloadEpisodeCount: Int, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case three = 3
    case five = 5

    var id: Int { rawValue }

    var displayName: String {
        rawValue == 1 ? "1 Episode" : "\(rawValue) Episodes"
    }
}

enum DownloadConcurrency: Int, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case three = 3

    var id: Int { rawValue }

    var displayName: String {
        rawValue == 1 ? "1 Download" : "\(rawValue) Downloads"
    }
}

enum DownloadFreeSpaceReserve: Int, CaseIterable, Identifiable {
    case oneGB = 1_000_000_000
    case fiveGB = 5_000_000_000
    case tenGB = 10_000_000_000
    case twentyGB = 20_000_000_000

    var id: Int { rawValue }

    var bytes: Int64 {
        Int64(rawValue)
    }

    var displayName: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - MaxResolution

enum MaxResolution: String, CaseIterable, Identifiable {
    case auto = "auto"
    case fourK = "4k"
    case tenEightyP = "1080p"
    case sevenTwentyP = "720p"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .fourK: "4K"
        case .tenEightyP: "1080p"
        case .sevenTwentyP: "720p"
        }
    }

    /// Maximum vertical resolution in pixels, or nil for "auto" (no limit).
    var maxHeight: Int? {
        switch self {
        case .auto: nil
        case .fourK: 2160
        case .tenEightyP: 1080
        case .sevenTwentyP: 720
        }
    }

    /// Playback target used when selecting among multiple Plex media versions.
    /// Auto prefers 4K on Apple TV and 1080p everywhere else.
    var selectionTargetMaxHeight: Int {
        switch self {
        case .auto:
            #if os(tvOS)
            2160
            #else
            1080
            #endif
        case .fourK:
            2160
        case .tenEightyP:
            1080
        case .sevenTwentyP:
            720
        }
    }
}

enum AthenaConsent: Int, Sendable {
    case undecided
    case allowed
    case declined
}
