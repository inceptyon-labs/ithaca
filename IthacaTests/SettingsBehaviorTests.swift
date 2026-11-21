import CoreMedia
import Foundation
import Testing
@testable import Ithaca

/// Settings that change what other screens do: Hide Spoilers, Play Starts and
/// subtitle style.
@Suite("Settings behavior")
struct SettingsBehaviorTests {
    @Test("Hide Spoilers covers only episodes this profile hasn't started, and only while on")
    @MainActor func spoilers() throws {
        try withStoredDefault("hidesEpisodeSpoilers") {
            let preferences = UserPreferences()
            let unstarted = try item(type: "episode")
            #expect(!preferences.hidesSpoilers(for: unstarted))

            preferences.hidesEpisodeSpoilers = true
            #expect(preferences.hidesSpoilers(for: unstarted))
            #expect(!preferences.hidesSpoilers(for: try item(type: "episode", viewOffset: 60_000)))
            #expect(!preferences.hidesSpoilers(for: try item(type: "episode", viewCount: 1)))
            #expect(!preferences.hidesSpoilers(for: try item(type: "movie")))
        }
    }

    @Test("From the Beginning takes Resume off Play buttons; the other choices keep it")
    @MainActor func playTitle() {
        withStoredDefault("playbackStartBehavior") {
            let preferences = UserPreferences()
            #expect(preferences.playbackStartBehavior == .resume)
            #expect(preferences.playTitle("Resume from 12:04") == "Resume from 12:04")
            preferences.playbackStartBehavior = .ask
            #expect(preferences.playTitle("Resume") == "Resume")
            preferences.playbackStartBehavior = .startOver
            #expect(preferences.playTitle("Resume from 12:04") == "Play")
        }
    }

    @Test("A subtitle style becomes AVPlayer text attributes and libvlc library options")
    @MainActor func subtitleStyle() {
        let positionKey = kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String
        #expect(PlaybackSubtitleStyle.avPlayerTextMarkupAttributes(for: SubtitleStyle())[positionKey] == nil)

        let raised = SubtitleStyle(background: .solid, color: .yellow, position: .raised)
        let attributes = PlaybackSubtitleStyle.avPlayerTextMarkupAttributes(for: raised)
        #expect((attributes[positionKey] as? Double).map { abs($0 - 80) < 0.001 } == true)
        #expect(attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] as? [Double] == [1, 0, 0, 0])

        #expect(PlaybackSubtitleStyle.vlcLibraryOptions(for: SubtitleStyle(), canvasSize: CGSize(width: 3840, height: 2160)) == [
            "--freetype-color=16777215",
            "--freetype-background-color=0",
            "--freetype-background-opacity=110",
        ])
        #expect(PlaybackSubtitleStyle.vlcLibraryOptions(for: raised, canvasSize: CGSize(width: 3840, height: 2160)) == [
            "--freetype-color=16770304",
            "--freetype-background-color=0",
            "--freetype-background-opacity=255",
            "--sub-margin=216",
        ])
    }

    // MARK: - Fixtures

    /// Runs `body` with `key` cleared in the standard defaults, then puts back
    /// what was there.
    @MainActor private func withStoredDefault(_ key: String, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        try body()
    }

    private func item(type: String, viewCount: Int? = nil, viewOffset: Int? = nil) throws -> PlexItem {
        var object: [String: Any] = ["ratingKey": "1", "key": "/library/metadata/1", "type": type, "title": "Pilot"]
        object["viewCount"] = viewCount
        object["viewOffset"] = viewOffset
        return try JSONDecoder().decode(PlexItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
