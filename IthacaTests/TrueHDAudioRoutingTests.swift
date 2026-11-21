import Foundation
import Testing
@testable import Ithaca

@Suite("TrueHD routing with Ithaca's VLCKit build")
@MainActor
struct TrueHDAudioRoutingTests {
    // MARK: - Decodability

    @Test func trueHDIsDecodableOnlyWithIthacasBuild() {
        for codec in ["truehd", "TrueHD", "mlp"] {
            #expect(!PlayerViewModel.isLocallyUndecodableAudioCodec(codec, decodesTrueHD: true))
            #expect(PlayerViewModel.isLocallyUndecodableAudioCodec(codec, decodesTrueHD: false))
        }
        for codec in ["eac3", "ac3", "dca", "flac", nil] {
            #expect(!PlayerViewModel.isLocallyUndecodableAudioCodec(codec, decodesTrueHD: false))
        }
    }

    // MARK: - Direct-play preselection

    @Test func preselectionOpensOnTrueHDOnTVOS() throws {
        let part = try makePart(audio: bluRayAudio)
        let position = PlayerViewModel.preferredAudioStreamPosition(
            inPart: part,
            preferredLanguage: nil,
            decodesTrueHD: true
        )
        #if os(tvOS)
        // Lossless ranks top on tvOS: discrete 7.1 PCM over HDMI.
        #expect(position == 0)
        #else
        // iPhone/iPad downmix to stereo either way, so the lossy sibling wins.
        #expect(position == 1)
        #endif
    }

    @Test func stockBuildNeverPreselectsTrueHD() throws {
        let part = try makePart(audio: bluRayAudio)
        let position = PlayerViewModel.preferredAudioStreamPosition(
            inPart: part,
            preferredLanguage: nil,
            decodesTrueHD: false
        )
        #expect(position == 1)
    }

    @Test func stockBuildOpensOnTrueHDWhenOnlyCommentaryRemains() throws {
        let part = try makePart(audio: """
            { "id": 2, "streamType": 2, "codec": "ac3", "channels": 6, "languageCode": "deu", "default": true, "displayTitle": "German (AC3 5.1)" },
            { "id": 3, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "displayTitle": "English (TrueHD 7.1 Atmos)" },
            { "id": 4, "streamType": 2, "codec": "ac3", "channels": 2, "languageCode": "eng", "displayTitle": "English (AC3 2.0) Commentary" }
            """)
        // The English main track is preselected explicitly, not left to the
        // German container default.
        #expect(PlayerViewModel.preferredAudioStreamPosition(
            inPart: part, preferredLanguage: "eng", keepsUndecodableMain: true, decodesTrueHD: false) == 1)
        // Offline downloads cannot convert on the server: keep the commentary.
        #expect(PlayerViewModel.preferredAudioStreamPosition(
            inPart: part, preferredLanguage: "eng", decodesTrueHD: false) == 2)
    }

    @Test func keptTrueHDMainFollowsTheDefaultRanking() throws {
        let part = try makePart(audio: """
            { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "displayTitle": "English (TrueHD 7.1)" },
            { "id": 3, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1 Atmos)" },
            { "id": 4, "streamType": 2, "codec": "ac3", "channels": 2, "languageCode": "eng", "displayTitle": "English (AC3 2.0) Commentary" }
            """)
        #expect(PlayerViewModel.preferredAudioStreamPosition(
            inPart: part, preferredLanguage: nil, keepsUndecodableMain: true, decodesTrueHD: false) == 1)
    }

    // MARK: - Startup remux pick

    @Test func remuxDecisionKeepsTheCopyableSibling() throws {
        let part = try makePart(audio: bluRayAudio)
        let stream = PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil)
        #expect(stream?.id == 3)
    }

    @Test func remuxDecisionPrefersEAC3AtmosOverTrueHDAtmos() throws {
        let part = try makePart(audio: """
            { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1 Atmos)" },
            { "id": 3, "streamType": 2, "codec": "eac3", "channels": 8, "languageCode": "eng", "profile": "dolby digital plus + dolby atmos", "displayTitle": "English (EAC3 7.1 Atmos)" }
            """)
        let stream = try #require(PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil))
        #expect(stream.id == 3)
        #expect(StreamResolver.isSpatialAudioCandidate(stream))
    }

    @Test func remuxDecisionFallsBackToTrueHDWhenItIsTheOnlyTrack() throws {
        let part = try makePart(audio: trueHDOnlyAudio)
        let stream = PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil)
        #expect(stream?.id == 2)
        #expect(PlayerViewModel.isTrueHDAudioCodec(stream?.codec))
    }

    @Test func remuxDecisionNeverPicksCommentaryAsTheOnlyCandidate() throws {
        let part = try makePart(audio: """
            { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1 Atmos)" },
            { "id": 3, "streamType": 2, "codec": "ac3", "channels": 2, "languageCode": "eng", "displayTitle": "English (AC3 2.0) Commentary" }
            """)
        let stream = try #require(PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil))
        #expect(stream.id == 2)
    }

    @Test func remuxDecisionPicksMainTrackOverCommentary() throws {
        let part = try makePart(audio: """
            { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1 Atmos)" },
            { "id": 3, "streamType": 2, "codec": "ac3", "channels": 2, "languageCode": "eng", "displayTitle": "English (AC3 2.0) Commentary" },
            { "id": 4, "streamType": 2, "codec": "ac3", "channels": 6, "languageCode": "eng", "displayTitle": "English (AC3 5.1)" }
            """)
        let stream = try #require(PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil))
        #expect(stream.id == 4)
    }

    @Test func remuxDecisionStaysInThePreferredLanguage() throws {
        let part = try makePart(audio: """
            { "id": 2, "streamType": 2, "codec": "ac3", "channels": 6, "languageCode": "deu", "default": true, "displayTitle": "German (AC3 5.1)" },
            { "id": 3, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "displayTitle": "English (TrueHD 7.1 Atmos)" },
            { "id": 4, "streamType": 2, "codec": "ac3", "channels": 2, "languageCode": "eng", "displayTitle": "English (AC3 2.0) Commentary" }
            """)
        let stream = try #require(PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: "eng"))
        #expect(stream.id == 3)
    }

    @Test func hdrRemuxStillQualifiesForTrueHDPlusAC3() throws {
        let media = try makeMedia(video: #""colorTrc": "smpte2084""#, audio: bluRayAudio)
        let part = media.parts[0]
        let remuxAudio = PlayerViewModel.preferredRemuxAudioStream(inPart: part, preferredLanguage: nil)
        let blocker = StreamResolver.hdrVideoRemuxBlocker(
            media: media,
            decision: StreamResolver.evaluate(media: media),
            audioStream: remuxAudio,
            subtitleStream: nil,
            displaySupportsHDR: true
        )
        #expect(blocker == nil)
    }

    // MARK: - Surround on a stock VLCKit

    @Test func onlyAStockTVOSBuildLosesSurround() throws {
        let part = try makePart(audio: """
            { "id": 2, "streamType": 2, "codec": "dca", "channels": 6, "default": true },
            { "id": 3, "streamType": 2, "codec": "aac", "channels": 2 }
            """)
        let surround = part.streams[1]
        let stereo = part.streams[2]
        #if os(tvOS)
        #expect(StreamResolver.losesSurroundOnVLCKit(surround, vlcKitOutputsMultichannel: false))
        #else
        #expect(!StreamResolver.losesSurroundOnVLCKit(surround, vlcKitOutputsMultichannel: false))
        #endif
        #expect(!StreamResolver.losesSurroundOnVLCKit(surround, vlcKitOutputsMultichannel: true))
        #expect(!StreamResolver.losesSurroundOnVLCKit(stereo, vlcKitOutputsMultichannel: false))
    }

    @Test func multichannelDolbyTakesTheRemuxWhenVLCKitWouldFoldIt() throws {
        let media = try makeMedia(
            video: #""colorTrc": "bt709""#,
            audio: #"{ "id": 2, "streamType": 2, "codec": "eac3", "channels": 6, "default": true }"#,
            subtitleCodec: "srt"
        )
        let streams = media.parts[0].streams
        let decision = StreamResolver.evaluate(media: media)
        func blocker(vlcKitOutputsMultichannel: Bool) -> String? {
            StreamResolver.spatialAudioRemuxBlocker(
                media: media, decision: decision,
                audioStream: streams.first { $0.streamType == .audio },
                subtitleStream: streams.first { $0.streamType == .subtitle },
                // The fixture's 10-bit video counts as HDR.
                displaySupportsHDR: true,
                vlcKitOutputsMultichannel: vlcKitOutputsMultichannel
            )
        }
        #expect(decision.engine == .vlcKit)
        #expect(blocker(vlcKitOutputsMultichannel: false) == nil)
        #if os(tvOS)
        // Ithaca's build outputs discrete 5.1 itself: only Atmos is worth it.
        #expect(blocker(vlcKitOutputsMultichannel: true) != nil)
        #else
        #expect(blocker(vlcKitOutputsMultichannel: true) == nil)
        #endif
    }

    // MARK: - Converted-audio remux gate

    @Test(arguments: [6, 8], ["truehd", "mlp"])
    func dv7TrueHDStartsWithConvertedAudio(channels: Int, codec: String) throws {
        // The HDR10 Atmos demo has 8 channels; the HDR10+ sibling has 6
        // and a forced SRT. HDR10+ is not distinguished in Plex metadata.
        let media = try makeMedia(
            video: dv7Video,
            audio: #"{ "id": 2, "streamType": 2, "codec": "\#(codec)", "channels": \#(channels), "default": true }"#,
            subtitleCodec: channels == 6 ? "srt" : nil
        )
        let streams = media.parts[0].streams
        let decision = StreamResolver.evaluate(media: media)
        let audio = PlayerViewModel.preferredRemuxAudioStream(inPart: media.parts[0], preferredLanguage: nil)
        let subtitle = streams.first { $0.streamType == .subtitle }
        #expect(decision.engine == .vlcKit)
        #expect(!decision.requiresServerTranscode)
        #expect(StreamResolver.hdrVideoRemuxBlocker(
            media: media, decision: decision, audioStream: audio,
            subtitleStream: subtitle, displaySupportsHDR: true
        ) != nil)
        #expect(StreamResolver.spatialAudioRemuxBlocker(
            media: media, decision: decision, audioStream: audio,
            subtitleStream: subtitle, displaySupportsHDR: true
        ) != nil)
        #expect(convertedBlocker(for: media, subtitleID: subtitle?.id) == nil)
        #expect(StreamResolver.spatialAudioRemuxBlocker(
            media: media, decision: decision, audioStream: audio,
            subtitleStream: subtitle, displaySupportsHDR: true, convertsAudio: true
        ) == nil)
        let target = try #require(StreamResolver.dolbyVision7ConversionTarget(in: media))
        #expect(target.profile == 8)
        #expect(target.blSignalCompatibilityID == 1)
        #expect(target.convertedFromProfile == 7)
    }

    @Test func dv7WithCopyableAudioKeepsConversion() throws {
        for audio in [bluRayAudio, #"{ "id": 2, "streamType": 2, "codec": "eac3", "channels": 6 }"#] {
            let media = try makeMedia(video: dv7Video, audio: audio)
            let stream = PlayerViewModel.preferredRemuxAudioStream(inPart: media.parts[0], preferredLanguage: nil)
            #expect(StreamResolver.hdrVideoRemuxBlocker(
                media: media, decision: StreamResolver.evaluate(media: media),
                audioStream: stream, subtitleStream: nil, displaySupportsHDR: true
            ) == nil)
            #expect(StreamResolver.dolbyVision7ConversionTarget(in: media) != nil)
        }
    }

    @Test func dv8TrueHDConvertsToKeepThePicture() throws {
        let media = try makeMedia(
            video: #""DOVIPresent": true, "DOVIProfile": 8, "DOVIBLCompatID": 1, "colorTrc": "smpte2084""#,
            audio: trueHDOnlyAudio
        )
        #expect(convertedBlocker(for: media) == nil)
    }

    @Test(arguments: ["truehd", "dca", "pcm", "flac"])
    func hdrFileWithUncopyableAudioConvertsToKeepThePicture(codec: String) throws {
        let media = try makeMedia(
            video: #""colorTrc": "smpte2084""#,
            audio: #"{ "id": 2, "streamType": 2, "codec": "\#(codec)", "channels": 6, "default": true }"#
        )
        #expect(convertedBlocker(for: media) == nil)
    }

    @Test func hdrFileWithCopyableAudioIsNotConverted() throws {
        let media = try makeMedia(
            video: #""colorTrc": "smpte2084""#,
            audio: #"{ "id": 2, "streamType": 2, "codec": "eac3", "channels": 6, "default": true }"#
        )
        #expect(convertedBlocker(for: media) != nil)
    }

    @Test func hdrGateHonoursDisplayAndSetting() throws {
        let media = try makeMedia(video: dv7Video, audio: trueHDOnlyAudio)
        #expect(convertedBlocker(for: media, displaySupportsHDR: false) != nil)
        #expect(convertedBlocker(for: media, hdrVideoRemuxEnabled: false) != nil)
    }

    @Test func sdrTrueHDOnlyFileDecodesLocally() throws {
        let media = try makeMedia(video: #""colorTrc": "bt709""#, audio: trueHDOnlyAudio)
        #expect(convertedBlocker(for: media) != nil)
    }

    @Test func bitmapSubtitleKeepsTrueHDLocal() throws {
        let media = try makeMedia(
            video: dv7Video,
            audio: trueHDOnlyAudio,
            subtitleCodec: "pgs"
        )
        #expect(convertedBlocker(for: media, subtitleID: 9) != nil)
    }

    @Test func convertedRequestCopiesVideoAndPrefersLosslessAudio() {
        let service = PlexService()
        let items = service.transcodeQueryItems(
            ratingKey: "1", mediaIndex: 0, sourcePath: nil,
            mode: .spatialAudioRemux(convertsAudio: true),
            sessionIdentifier: "session", transcodeSessionID: "transcode",
            audioStreamID: 2, subtitleStreamID: 9, token: nil
        )
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["directPlay"] == "0")
        #expect(query["directStream"] == "1")
        #expect(query["directStreamAudio"] == "0")
        #expect(query["audioStreamID"] == "2")
        #expect(query["subtitles"] == "auto")
        #expect(query["maxVideoBitrate"] == nil)
        let profile = query["X-Plex-Client-Profile-Extra"] ?? ""
        #expect(profile.contains("container=mp4&videoCodec=hevc,h264&audioCodec=flac,eac3)"))
        #expect(profile.contains("scopeName=eac3&type=upperBound&name=audio.channels&value=8"))
        #expect(profile.contains("scopeName=flac&type=upperBound&name=audio.channels&value=8"))
        #expect(!profile.contains("audioCodec=ac3"))
        #expect(!profile.contains("audioCodec=aac"))
        #expect(!profile.contains("container=mpegts"))
    }

    @Test(arguments: [6, 8])
    func convertedDecisionRequiresCompatibleSurround(channels: Int) {
        var decision = PlexService.TranscodeStreamDecisions(
            container: "mp4", videoDecision: "copy", videoCodec: "hevc",
            audioDecision: "transcode", audioCodec: "eac3", audioChannels: channels
        )
        #expect(decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.audioCodec = "flac"
        #expect(decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.audioCodec = "truehd"
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.audioCodec = "aac"
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.audioCodec = "eac3"
        decision.audioDecision = "copy"
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.audioDecision = "transcode"
        decision.container = "mpegts"
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
        decision.container = "mp4"
        decision.audioChannels = 2
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
        // A 4.0 source must not come out stereo either.
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 4))
        #expect(decision.isConvertedAudioRemux(sourceChannels: 2))
        decision.audioChannels = channels
        #expect(decision.isConvertedAudioRemux(sourceChannels: 4))
        decision.videoDecision = "transcode"
        #expect(!decision.isConvertedAudioRemux(sourceChannels: 8))
    }

    @Test func convertedAudioRestoresOnlyConfirmedJOC() throws {
        var decision = PlexService.TranscodeStreamDecisions(
            container: "mp4", videoDecision: "copy", videoCodec: "hevc",
            audioDecision: "transcode", audioCodec: "eac3", audioChannels: 6
        )
        let media = try makeMedia(video: dv7Video, audio: trueHDOnlyAudio)
        let playback = PlaybackCoordinator(plexService: PlexService())
        playback.activeAudioStreamID = 2
        for (profile, expectsAtmos) in [
            (nil, false), ("dolby digital plus", false),
            ("dolby truehd + dolby atmos", false),
            ("dolby digital plus + dolby atmos", true), ("joc", true),
        ] as [(String?, Bool)] {
            decision.audioProfile = profile
            #expect(decision.hasDolbyAtmosAudio == expectsAtmos)
            playback.remuxAudioConversion = RemuxAudioConversion(
                audioStreamID: 2, restoresDolbyAtmos: decision.hasDolbyAtmosAudio
            )
            #expect(playback.activeAudioStreamIsDolbyAtmos(in: media.parts[0]) == expectsAtmos)
        }
    }

    // MARK: - Helpers

    private let dv7Video = #""DOVIPresent": true, "DOVIProfile": 7, "DOVILevel": 6, "DOVIBLCompatID": 6, "colorTrc": "smpte2084""#

    private let bluRayAudio = """
        { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1)" },
        { "id": 3, "streamType": 2, "codec": "ac3", "channels": 6, "languageCode": "eng", "displayTitle": "English (AC3 5.1)" }
        """

    private let trueHDOnlyAudio = """
        { "id": 2, "streamType": 2, "codec": "truehd", "channels": 8, "languageCode": "eng", "default": true, "displayTitle": "English (TrueHD 7.1 Atmos)" }
        """

    private func convertedBlocker(
        for media: PlexMedia,
        subtitleID: Int? = nil,
        displaySupportsHDR: Bool = true,
        hdrVideoRemuxEnabled: Bool = true
    ) -> String? {
        let streams = media.parts[0].streams
        guard let audio = streams.first(where: { $0.streamType == .audio }) else {
            return "no audio"
        }
        return StreamResolver.convertedAudioRemuxBlocker(
            media: media,
            decision: StreamResolver.evaluate(media: media),
            audioStream: audio,
            subtitleStream: subtitleID.flatMap { id in streams.first { $0.id == id } },
            displaySupportsHDR: displaySupportsHDR,
            hdrVideoRemuxEnabled: hdrVideoRemuxEnabled
        )
    }

    private func makePart(audio: String) throws -> PlexMediaPart {
        try makeMedia(video: #""colorTrc": "bt709""#, audio: audio).parts[0]
    }

    private func makeMedia(
        video: String,
        audio: String,
        subtitleCodec: String? = nil
    ) throws -> PlexMedia {
        let subtitle = subtitleCodec.map { #", { "id": 9, "streamType": 3, "codec": "\#($0)" }"# } ?? ""
        let json = """
        {
            "id": 10,
            "container": "mkv",
            "Part": [{
                "id": 20,
                "key": "/library/parts/20/file.mkv",
                "container": "mkv",
                "Stream": [
                    { "id": 1, "streamType": 1, "codec": "hevc", "bitDepth": 10, "frameRate": 23.976, \(video) },
                    \(audio)\(subtitle)
                ]
            }]
        }
        """
        return try JSONDecoder().decode(PlexMedia.self, from: Data(json.utf8))
    }
}
