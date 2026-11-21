import AVFoundation
import Foundation
import OSLog

private let spatialAudioLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Ithaca",
    category: "SpatialAudio"
)

/// Dolby Atmos / spatial-audio delivery for files only VLCKit could direct
/// play. VLCKit decodes Dolby audio to plain PCM, which drops Atmos objects
/// and never reaches AirPods spatial audio; AVPlayer renders both. Plex copies
/// the original video and audio into fMP4 HLS (no re-encode), the session
/// plays on AVPlayer, and `RemuxHLSLoader` restores the Atmos
/// signaling Plex's muxer drops. See docs/playback.md → "Dolby Atmos and
/// spatial audio".
extension PlaybackCoordinator {
    struct SpatialAudioRemux {
        let url: URL
        let transcodeSessionID: String
        let reason: String
        /// Plex converts the audio (instead of copying it) in this remux.
        let convertsAudio: Bool
        let restoresDolbyAtmos: Bool
        /// Set when the requested subtitle is drawn by Ithaca over the remux.
        var imageSubtitles: RemuxImageSubtitles?
    }

    var isSpatialAudioSession: Bool {
        debugInfo?.decision.isSpatialAudio == true
    }

    /// Sessions whose audio/subtitle tracks are chosen by Plex (and changed by
    /// rebuilding the HLS session) rather than by the local engine.
    var usesServerTrackSelection: Bool {
        isAirPlaySession || isSpatialAudioSession || isServerStreamSession
    }

    /// Manual transcode or server-stream fallback: the subtitle is burned in.
    var isServerStreamSession: Bool {
        debugInfo?.decision.isServerStream == true
    }

    /// Requests a copy-remux, or video copied with the audio converted.
    /// Validates Plex's container/codecs before loading an engine. A declined
    /// decision releases the server session and keeps plain direct play.
    ///
    /// Dolby Vision profile 5 files take the same remux for their video
    /// (AVPlayer renders DV5 from MP4; libvlc cannot) regardless of the
    /// spatial-audio setting, and have Plex convert any audio the fMP4 cannot
    /// carry instead of refusing. Other HDR files (HDR10, HDR10+, HLG, Dolby
    /// Vision 7/8) take it when `hdrVideoRemuxEnabled` is on: with the audio
    /// copied when fMP4 carries it, otherwise converted up front (to FLAC, so
    /// a lossless track stays lossless) rather than giving up the HDR picture.
    func requestSpatialAudioRemux(
        ratingKey: String,
        mediaIndex: Int,
        media: PlexMedia,
        part: PlexMediaPart,
        audioStreamID: Int?,
        subtitleStreamID: Int?,
        convertsAudio: Bool = false,
        persistsAudioSelection: Bool = true,
        sessionIdentifier: String,
        serverID: String?
    ) async -> SpatialAudioRemux? {
        let isDolbyVisionRemux = StreamResolver.isDolbyVisionProfile5(media)
        let resolverDecision = StreamResolver.evaluate(media: media)
        let audioStream = part.streams.first { $0.streamType == .audio && $0.id == audioStreamID }
        let subtitleStream = subtitleStreamID.flatMap { id in
            part.streams.first { $0.streamType == .subtitle && $0.id == id }
        }
        // A PGS subtitle is drawn over the video by Ithaca, so the remux is
        // judged and requested without it.
        let overlaySubtitle = subtitleStream.flatMap {
            StreamResolver.isOverlaySubtitle($0, in: media) ? $0 : nil
        }
        let remuxSubtitleStream = overlaySubtitle == nil ? subtitleStream : nil
        let remuxSubtitleStreamID = overlaySubtitle == nil ? subtitleStreamID : nil
        // HDR picture wins over local decoding of a track fMP4 cannot carry
        // (DTS-HD, TrueHD, PCM, …). Decide before the first Plex request,
        // including on stock builds and track changes, so no undecodable
        // local/copy-only attempt precedes the remux.
        let convertsForHDRVideo = !isAudioConversionRemuxSuppressed && audioStream.map {
            StreamResolver.convertedAudioRemuxBlocker(
                media: media,
                decision: resolverDecision,
                audioStream: $0,
                subtitleStream: remuxSubtitleStream,
                displaySupportsHDR: AVPlayer.eligibleForHDRPlayback,
                hdrVideoRemuxEnabled: preferences.hdrVideoRemuxEnabled
            ) == nil
        } ?? false
        // tvOS on a stock VLCKit folds surround to stereo. Keep a surround
        // track surround on AVPlayer: copied when fMP4 carries it, otherwise
        // (DTS, FLAC, PCM, …) converted by Plex.
        let restoresSurround = preferences.spatialAudioRemuxEnabled
            && audioStream.map { StreamResolver.losesSurroundOnVLCKit($0) } == true
        let convertsSurround = restoresSurround
            && audioStream.map { !StreamResolver.canCopyIntoRemux(audio: $0) } == true
        let convertsAudio = convertsAudio || convertsForHDRVideo || convertsSurround
            || (isDolbyVisionRemux && audioStream.map { !StreamResolver.canCopyIntoRemux(audio: $0) } == true)
        // Audio conversion serves picture preservation/decoder recovery, so
        // it does not depend on the spatial-audio preference.
        let considersSpatialAudio = preferences.spatialAudioRemuxEnabled || convertsAudio
        let considersHDRVideo = preferences.hdrVideoRemuxEnabled
        guard considersSpatialAudio || considersHDRVideo || isDolbyVisionRemux,
              !preferences.forceAVPlayer,
              !preferences.forceVLCKit else {
            return nil
        }

        let blocker: String?
        // Which of the two non-DV5 reasons qualified, for the session reason.
        var qualifiesForSpatialAudio = false
        var qualifiesForHDRVideo = false
        if isDolbyVisionRemux {
            blocker = StreamResolver.dolbyVisionRemuxBlocker(
                media: media,
                subtitleStream: remuxSubtitleStream,
                displaySupportsHDR: AVPlayer.eligibleForHDRPlayback
            )
        } else {
            let spatialAudioBlocker = considersSpatialAudio
                ? StreamResolver.spatialAudioRemuxBlocker(
                    media: media,
                    decision: resolverDecision,
                    audioStream: audioStream,
                    subtitleStream: remuxSubtitleStream,
                    displaySupportsHDR: AVPlayer.eligibleForHDRPlayback,
                    convertsAudio: convertsAudio
                )
                : "Dolby Atmos remux is off"
            let hdrVideoBlocker = considersHDRVideo
                ? StreamResolver.hdrVideoRemuxBlocker(
                    media: media,
                    decision: resolverDecision,
                    audioStream: audioStream,
                    subtitleStream: remuxSubtitleStream,
                    displaySupportsHDR: AVPlayer.eligibleForHDRPlayback
                )
                : "HDR remux is off"
            qualifiesForSpatialAudio = spatialAudioBlocker == nil
            qualifiesForHDRVideo = hdrVideoBlocker == nil
            blocker = qualifiesForSpatialAudio || qualifiesForHDRVideo
                ? nil
                : [spatialAudioBlocker, hdrVideoBlocker].compactMap { $0 }.joined(separator: "; ")
        }
        if let blocker {
            spatialAudioLogger.notice(
                "No spatial-audio remux for ratingKey \(ratingKey, privacy: .public): \(blocker, privacy: .public)"
            )
            return nil
        }

        var imageSubtitles: RemuxImageSubtitles?
        if let overlaySubtitle {
            imageSubtitles = await preparedImageSubtitles(
                for: overlaySubtitle, part: part, ratingKey: ratingKey, serverID: serverID
            )
            // Unreadable from this file: the caller keeps direct play, where
            // VLCKit draws the subtitle.
            guard imageSubtitles != nil else { return nil }
        }

        // Plex builds a session's subtitle from the part's server-side
        // selection, so mirror the choice there first (as Plex's own clients
        // do on a track change). Only touched when it actually differs.
        let selectedAudioID = part.streams.first { $0.streamType == .audio && ($0.isSelected ?? false) }?.id
        let selectedSubtitleID = part.streams.first { $0.streamType == .subtitle && ($0.isSelected ?? false) }?.id
        // An automatic startup pick is not written back: it may be the
        // remux-constrained one, and the owner's other clients share this part.
        if (persistsAudioSelection && selectedAudioID != audioStreamID) || selectedSubtitleID != subtitleStreamID {
            do {
                try await plexService.selectStreams(
                    partID: part.id,
                    audioStreamID: persistsAudioSelection ? audioStreamID : nil,
                    subtitleStreamID: subtitleStreamID ?? 0,
                    serverID: serverID
                )
            } catch {
                spatialAudioLogger.error(
                    "Could not record stream selection for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public); keeping direct play"
                )
                return nil
            }
        }

        let transcodeSessionID = UUID().uuidString
        do {
            let result = try await plexService.spatialAudioRemuxURL(
                ratingKey: ratingKey,
                mediaIndex: mediaIndex,
                sessionIdentifier: sessionIdentifier,
                transcodeSessionID: transcodeSessionID,
                audioStreamID: audioStreamID,
                subtitleStreamID: remuxSubtitleStreamID,
                convertsAudio: convertsAudio,
                serverID: serverID
            )
            let acceptsStreams = convertsAudio
                ? result.streams.isConvertedAudioRemux(sourceChannels: audioStream?.channels)
                : result.streams.isLosslessRemux
            guard case .transcodeAvailable = result.outcome,
                  acceptsStreams,
                  remuxSubtitleStreamID == nil || result.streams.subtitleLocation == "segments-subs" else {
                stopTranscodeSessionInBackground(transcodeSessionID, serverID: serverID)
                spatialAudioLogger.notice(
                    "Plex declined a compatible spatial-audio remux for ratingKey \(ratingKey, privacy: .public) (outcome \(String(describing: result.outcome), privacy: .public), \(result.streams.logDescription, privacy: .public)); keeping direct play"
                )
                return nil
            }

            spatialAudioLogger.notice(
                "Spatial-audio remux accepted for ratingKey \(ratingKey, privacy: .public): \(result.streams.logDescription, privacy: .public)"
            )
            let reason: String
            if isDolbyVisionRemux {
                let audioNote = convertsAudio
                    ? ", \(audioStream?.codec?.uppercased() ?? "audio") converted to \(result.streams.audioCodec?.uppercased() ?? "a supported codec")"
                    : ""
                reason = "Dolby Vision profile 5 via lossless Plex remux\(audioNote)"
            } else if convertsAudio {
                let source = audioStream?.codec?.uppercased() ?? "audio"
                let target = result.streams.audioCodec?.uppercased() ?? "a supported codec"
                let videoNote = remuxDolbyVision7Conversion(for: media, decision: .spatialAudio) != nil
                    ? ", Dolby Vision 7 → 8.1 on device"
                    : ""
                reason = "\(source) converted to \(target) by Plex, video copied\(videoNote) (\(resolverDecision.reason))"
            } else {
                var labels: [String] = []
                if qualifiesForSpatialAudio {
                    labels.append(audioStream.map { stream in
                        if StreamResolver.isDolbyAtmos(stream) { return "Dolby Atmos" }
                        let codec = stream.codec?.lowercased()
                        return codec == "eac3" || codec == "ac3"
                            ? "multichannel Dolby"
                            : "multichannel \(codec?.uppercased() ?? "audio")"
                    } ?? "Dolby")
                }
                if remuxDolbyVision7Conversion(for: media, decision: .spatialAudio) != nil {
                    labels.append("Dolby Vision 7 → 8.1")
                } else if qualifiesForHDRVideo {
                    labels.append(StreamResolver.hdrVideoLabel(for: media))
                }
                reason = "\(labels.joined(separator: " + ")) via lossless Plex remux (\(resolverDecision.reason))"
            }
            return SpatialAudioRemux(
                url: result.url,
                transcodeSessionID: transcodeSessionID,
                reason: imageSubtitles == nil ? reason : "\(reason); PGS subtitle drawn by Ithaca",
                convertsAudio: convertsAudio,
                restoresDolbyAtmos: result.streams.hasDolbyAtmosAudio,
                imageSubtitles: imageSubtitles
            )
        } catch {
            stopTranscodeSessionInBackground(transcodeSessionID, serverID: serverID)
            spatialAudioLogger.error(
                "Spatial-audio remux request failed for ratingKey \(ratingKey, privacy: .public): \(error.localizedDescription, privacy: .public); keeping direct play"
            )
            return nil
        }
    }

    /// The viewer picked different tracks in a remux session: rebuild the
    /// remux around them, or — when the new combination cannot take a remux
    /// (a DTS track on SDR video, a VobSub subtitle, …) — move to plain direct
    /// play with exactly those tracks. Serialized like AirPlay transitions.
    func scheduleSpatialAudioTrackChange() {
        let previousTask = spatialAudioTransitionTask
        previousTask?.cancel()
        spatialAudioTransitionTask = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }
            await self?.rebuildSpatialAudioSession(
                transitionLabel: "rebuilding the spatial-audio remux for selected tracks",
                declineReason: "Selected tracks cannot ride the spatial-audio remux; direct play"
            )
        }
    }

    /// A failed Dolby Vision 7 → 8.1 session: rebuilds the same remux without
    /// the conversion (the caller has already suppressed it for this item).
    /// Queued behind any track-change rebuild in flight, so the two never
    /// race; one that already replaced the failed engine counts as the retry.
    /// Returns false only when no rebuild could start, so the caller can take
    /// the next rung of the ladder instead of leaving the error overlay up.
    func retryRemuxWithoutDolbyVision7Conversion(failureDescription: String) async -> Bool {
        let failedEngine = engine
        let previousTask = spatialAudioTransitionTask
        let retry = Task { @MainActor [weak self] () -> Bool in
            if let previousTask {
                await previousTask.value
            }
            guard let self else { return true }
            guard self.engine === failedEngine else { return true }
            return await self.rebuildSpatialAudioSession(
                transitionLabel: "retrying the remux without Dolby Vision 7 conversion (\(failureDescription))",
                declineReason: "Remux unavailable after Dolby Vision 7 conversion failed; direct play"
            )
        }
        // A track change picked meanwhile waits for this retry to land.
        spatialAudioTransitionTask = Task { _ = await retry.value }
        return await retry.value
    }

    /// Asks Plex for a fresh remux of the live item around the active tracks
    /// and swaps to it at the live position (the old transcode session is
    /// stopped). When Plex declines, moves to direct play with `declineReason`.
    /// Returns false when the session is not in a state to rebuild (nothing
    /// was requested); true once it ran, including when it was superseded.
    @discardableResult
    func rebuildSpatialAudioSession(transitionLabel: String, declineReason: String) async -> Bool {
        guard isSpatialAudioSession,
              !isSwitchingQuality,
              !didFinalizeCurrentSession,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }),
              let part = details.media[mediaIndex].parts.first else {
            return false
        }

        let media = details.media[mediaIndex]
        let playbackSessionID = activePlaybackSessionIdentifier ?? UUID().uuidString
        activePlaybackSessionIdentifier = playbackSessionID
        let expectedPresentationID = playerPresentationID
        let requestServerID = activePlaybackServerID
        let audioStreamID = activeAudioStreamID
        let subtitleStreamID = activeSubtitleStreamID
        let audioCodec = part.streams.first { $0.streamType == .audio && $0.id == audioStreamID }?.codec
        // Keep converting when the remux being rebuilt already converts this
        // very stream (a subtitle change, the Dolby Vision 7 retry): TrueHD is
        // locally decodable on Ithaca's VLCKit, so the codec alone would drop
        // the conversion and with it the remux (and HDR). A newly picked
        // decodable stream (TrueHD, DTS) still leaves for direct play.
        let keepsAudioConversion = remuxAudioConversion.map { $0.audioStreamID == audioStreamID } ?? false

        let remux = await requestSpatialAudioRemux(
            ratingKey: ratingKey,
            mediaIndex: mediaIndex,
            media: media,
            part: part,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            convertsAudio: keepsAudioConversion || PlayerViewModel.isLocallyUndecodableAudioCodec(audioCodec),
            sessionIdentifier: playbackSessionID,
            serverID: requestServerID
        )

        guard !Task.isCancelled,
              !didFinalizeCurrentSession,
              playerPresentationID == expectedPresentationID,
              self.ratingKey == ratingKey else {
            if let remux {
                stopTranscodeSessionInBackground(remux.transcodeSessionID, serverID: requestServerID)
            }
            return true
        }

        guard let remux else {
            await leaveSpatialAudioRemux(reason: declineReason, keepsExplicitTracks: true)
            return true
        }

        let wasPlaying = engine?.state != .paused
        let resumePosition = currentResumePosition
        if let oldTranscodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(oldTranscodeSessionID, serverID: requestServerID)
        }
        activeTranscodeSessionID = remux.transcodeSessionID
        remuxAudioConversion = remux.convertsAudio
            ? RemuxAudioConversion(audioStreamID: audioStreamID, restoresDolbyAtmos: remux.restoresDolbyAtmos)
            : nil
        activeImageSubtitles = remux.imageSubtitles
        activateReplacementAttempt(
            transitionLabel: transitionLabel,
            attemptID: UUID(),
            details: details,
            ratingKey: ratingKey,
            media: media,
            part: part,
            playbackURL: remux.url,
            sanitizedURL: plexService.sanitizedPlaybackURLString(for: remux.url),
            playbackDecision: .spatialAudio,
            engineType: .avPlayer,
            resolverReason: remux.reason,
            startPosition: resumePosition,
            shouldAutoPlay: wasPlaying
        )
        return true
    }

    /// Undecodable-audio fallback (TrueHD on VLCKit): restarts the session as
    /// a video-copy remux whose audio Plex converts (FLAC, else E-AC-3), on
    /// AVPlayer at the live position. Returns false when that is not possible
    /// so the caller can fall back to a full transcode. A bitmap subtitle
    /// Ithaca cannot draw itself is dropped rather than forcing a video
    /// re-encode; picking one later moves the session to direct play.
    func playConvertedAudioRemux(audioStreamID: Int?) async -> Bool {
        guard !didFinalizeCurrentSession,
              !isSwitchingQuality,
              !isAirPlayPlaybackActive,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }),
              let part = details.media[mediaIndex].parts.first else {
            return false
        }

        let media = details.media[mediaIndex]
        let subtitleStreamID = activeSubtitleStreamID.flatMap { id -> Int? in
            guard let stream = part.streams.first(where: { $0.streamType == .subtitle && $0.id == id }) else {
                return nil
            }
            return StreamResolver.canRideRemux(subtitle: stream)
                || StreamResolver.isOverlaySubtitle(stream, in: media) ? id : nil
        }
        let playbackSessionID = activePlaybackSessionIdentifier ?? UUID().uuidString
        activePlaybackSessionIdentifier = playbackSessionID
        let expectedPresentationID = playerPresentationID
        let requestServerID = activePlaybackServerID

        guard let remux = await requestSpatialAudioRemux(
            ratingKey: ratingKey,
            mediaIndex: mediaIndex,
            media: media,
            part: part,
            audioStreamID: audioStreamID,
            subtitleStreamID: subtitleStreamID,
            convertsAudio: true,
            sessionIdentifier: playbackSessionID,
            serverID: requestServerID
        ) else {
            return false
        }

        guard !didFinalizeCurrentSession,
              playerPresentationID == expectedPresentationID,
              self.ratingKey == ratingKey else {
            stopTranscodeSessionInBackground(remux.transcodeSessionID, serverID: requestServerID)
            return true
        }

        let wasPlaying = engine?.state != .paused
        let resumePosition = currentResumePosition
        if let oldTranscodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(oldTranscodeSessionID, serverID: requestServerID)
        }
        activeTranscodeSessionID = remux.transcodeSessionID
        activeAudioStreamID = audioStreamID
        activeSubtitleStreamID = subtitleStreamID
        remuxAudioConversion = RemuxAudioConversion(
            audioStreamID: audioStreamID, restoresDolbyAtmos: remux.restoresDolbyAtmos
        )
        activeImageSubtitles = remux.imageSubtitles
        activateReplacementAttempt(
            transitionLabel: "converting undecodable audio on the server (video copied)",
            attemptID: UUID(),
            details: details,
            ratingKey: ratingKey,
            media: media,
            part: part,
            playbackURL: remux.url,
            sanitizedURL: plexService.sanitizedPlaybackURLString(for: remux.url),
            playbackDecision: .spatialAudio,
            engineType: .avPlayer,
            resolverReason: remux.reason,
            startPosition: resumePosition,
            shouldAutoPlay: wasPlaying
        )
        return true
    }

    /// Moves a remux session to plain direct play (the resolver's engine) at
    /// the live position. With `keepsExplicitTracks`, the viewer's current
    /// Plex stream choices are carried over instead of re-running automatic
    /// selection; otherwise (a failed remux) the normal policy applies.
    func leaveSpatialAudioRemux(reason: String, keepsExplicitTracks: Bool) async {
        guard isSpatialAudioSession,
              !didFinalizeCurrentSession,
              let details = activeItemDetails,
              let ratingKey,
              let debugInfo,
              let mediaIndex = details.media.firstIndex(where: { $0.id == debugInfo.media.id }),
              let part = details.media[mediaIndex].parts.first,
              let directPlayURL = plexService.directPlayURL(for: part, serverID: activePlaybackServerID) else {
            return
        }

        let media = details.media[mediaIndex]
        let resolverDecision = StreamResolver.evaluate(
            media: media,
            forceAVPlayer: preferences.forceAVPlayer,
            forceVLCKit: preferences.forceVLCKit
        )
        // A failed remux reports .error; recovery from it keeps playing.
        let wasPlaying = engine?.state != .paused

        var audioTrackPosition: Int?
        if keepsExplicitTracks {
            let audioStreams = part.streams.filter { $0.streamType == .audio }
            // Never open libvlc on a track it cannot decode (TrueHD): that is
            // a silent start. Automatic selection picks a decodable one.
            audioTrackPosition = audioStreams.firstIndex {
                $0.id == activeAudioStreamID && !PlayerViewModel.isLocallyUndecodableAudioCodec($0.codec)
            }
            pendingExplicitTrackSelection = ExplicitTrackSelection(
                audioStreamID: activeAudioStreamID,
                subtitleStreamID: activeSubtitleStreamID
            )
        } else {
            pendingExplicitTrackSelection = nil
        }

        if let oldTranscodeSessionID = activeTranscodeSessionID {
            stopTranscodeSessionInBackground(oldTranscodeSessionID, serverID: activePlaybackServerID)
        }
        activeTranscodeSessionID = nil
        remuxAudioConversion = nil
        activeImageSubtitles = nil
        spatialAudioLogger.notice(
            "Leaving spatial-audio remux for ratingKey \(ratingKey, privacy: .public): \(reason, privacy: .public)"
        )
        activateReplacementAttempt(
            transitionLabel: "leaving the spatial-audio remux for direct play",
            attemptID: UUID(),
            details: details,
            ratingKey: ratingKey,
            media: media,
            part: part,
            playbackURL: directPlayURL,
            sanitizedURL: plexService.sanitizedPlaybackURLString(for: directPlayURL),
            playbackDecision: .directPlay,
            engineType: resolverDecision.engine,
            resolverReason: "\(reason) (\(resolverDecision.reason))",
            startPosition: currentResumePosition,
            shouldAutoPlay: wasPlaying,
            audioTrackPositionOverride: audioTrackPosition
        )
    }

    /// The Dolby Vision signaling `RemuxHLSLoader` restores on a remux of a
    /// Dolby Vision profile 5 file, or of a profile 8.1/8.4 file while the
    /// HDR setting is on (any remux of it: HDR, Atmos or converted audio);
    /// nil for every other session.
    func remuxDolbyVisionConfiguration(
        for media: PlexMedia,
        decision: PlaybackDecision
    ) -> DolbyVisionConfiguration? {
        guard decision.isSpatialAudio else { return nil }
        return StreamResolver.dolbyVisionSignalingStream(
            in: media,
            includesProfile8: preferences.hdrVideoRemuxEnabled
        )
        .flatMap(DolbyVisionConfiguration.init(stream:))
    }

    /// The 8.1 configuration a remux of a Dolby Vision profile 7 file is
    /// converted to on device (`DolbyVision7HLSProxy`): any remux of it (HDR,
    /// Atmos or converted audio) while the HDR and conversion settings are
    /// on and the conversion has not failed for this item; nil otherwise.
    /// The single place that decides; extend it rather than checking elsewhere.
    func remuxDolbyVision7Conversion(
        for media: PlexMedia,
        decision: PlaybackDecision
    ) -> DolbyVisionConfiguration? {
        guard decision.isSpatialAudio,
              preferences.hdrVideoRemuxEnabled,
              preferences.dolbyVision7ConversionEnabled,
              !isDolbyVision7ConversionSuppressed else {
            return nil
        }
        return StreamResolver.dolbyVision7ConversionTarget(in: media)
    }

    /// Whether the remux's audio is E-AC-3 + JOC. Only then does the session
    /// go through `RemuxHLSLoader`: claiming Atmos for a plain 5.1 E-AC-3
    /// track would mislabel it to the decoder (and to an HDMI receiver).
    func activeAudioStreamIsDolbyAtmos(in part: PlexMediaPart) -> Bool {
        if let conversion = remuxAudioConversion, conversion.audioStreamID == activeAudioStreamID {
            return conversion.restoresDolbyAtmos
        }
        guard let stream = part.streams.first(where: {
            $0.streamType == .audio && $0.id == activeAudioStreamID
        }) else {
            return false
        }
        return StreamResolver.isDolbyAtmos(stream)
    }

    /// The provider for a PGS subtitle, once its file index has proved usable;
    /// nil (with the reason logged) when it has not within a few seconds. A
    /// rebuild around the same subtitle reuses the session's provider and its
    /// index instead of fetching the index again.
    private func preparedImageSubtitles(
        for stream: PlexStream,
        part: PlexMediaPart,
        ratingKey: String,
        serverID: String?
    ) async -> RemuxImageSubtitles? {
        if let active = activeImageSubtitles,
           active.streamID == stream.id, active.partID == part.id, active.serverID == serverID {
            return active
        }
        guard let streamIndex = stream.index,
              let reader = plexService.partByteRangeReader(for: part, serverID: serverID) else {
            return nil
        }
        let provider = ImageSubtitleProvider(reader: reader, streamIndex: streamIndex)
        // The index sits at the end of the file; never let a slow link hold
        // up the start for longer than this.
        let failure = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask {
                do {
                    try await provider.prepare()
                    return nil
                } catch {
                    return String(describing: error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return "timed out reading the file's index"
            }
            let first = await group.next() ?? "no result"
            group.cancelAll()
            return first
        }
        if let failure {
            spatialAudioLogger.notice(
                "PGS subtitle \(stream.id, privacy: .public) of ratingKey \(ratingKey, privacy: .public) cannot be drawn over a remux: \(failure, privacy: .public)"
            )
            return nil
        }
        return RemuxImageSubtitles(
            serverID: serverID, partID: part.id, streamID: stream.id, provider: provider
        )
    }

    /// A session reopened after a network change may reach its server at
    /// another address. The provider's reader was bound to the old one (and
    /// would keep sending the token there), so it is replaced; the new one
    /// loads the index again on first use.
    func rebindActiveImageSubtitles(part: PlexMediaPart) {
        guard let active = activeImageSubtitles else { return }
        guard let streamIndex = part.streams.first(where: { $0.id == active.streamID })?.index,
              let reader = plexService.partByteRangeReader(for: part, serverID: active.serverID) else {
            activeImageSubtitles = nil
            return
        }
        activeImageSubtitles = RemuxImageSubtitles(
            serverID: active.serverID,
            partID: active.partID,
            streamID: active.streamID,
            provider: ImageSubtitleProvider(reader: reader, streamIndex: streamIndex)
        )
    }

    /// Hands the carried-over track choice to the player exactly once.
    func consumePendingExplicitTrackSelection() -> ExplicitTrackSelection? {
        defer { pendingExplicitTrackSelection = nil }
        return pendingExplicitTrackSelection
    }

    private var currentResumePosition: TimeInterval {
        currentPlaybackPosition
    }
}

extension PlaybackDecision {
    /// Manual transcode or server-stream fallback.
    var isServerStream: Bool {
        switch self {
        case .transcode, .serverStream: true
        default: false
        }
    }

    var isServerStreamFallback: Bool {
        if case .serverStream = self { return true }
        return false
    }
}

/// The audio stream a remux session has Plex convert (see
/// `PlaybackCoordinator.remuxAudioConversion`).
struct RemuxAudioConversion: Sendable, Equatable {
    let audioStreamID: Int?
    var restoresDolbyAtmos = false
}

/// The PGS subtitle a remux session draws over the video itself.
struct RemuxImageSubtitles: Sendable {
    let serverID: String?
    let partID: Int
    let streamID: Int
    let provider: ImageSubtitleProvider
}

/// The previous stream IDs after a failed server-stream track rebuild.
struct ServerStreamTrackRevert: Equatable {
    let id = UUID()
    let audioStreamID: Int?
    let subtitleStreamID: Int?
}

/// Plex stream ids the viewer explicitly chose, carried across an engine swap
/// so the new engine opens on them instead of re-running automatic selection.
/// `subtitleStreamID == nil` means subtitles off.
struct ExplicitTrackSelection: Sendable, Equatable {
    let audioStreamID: Int?
    let subtitleStreamID: Int?
}
