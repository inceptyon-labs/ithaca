import Foundation

extension PlexService {
    /// Live TV comes from one server only (v1): the highest-priority connected
    /// one. A DVR lineup is server-specific, tuners are a scarce per-server
    /// resource, and merging two guides has no sane UI yet — so discovery asks
    /// this server, and everything after it goes to the provider's own server.
    var liveTVServerID: String? {
        pool.primary?.serverID
    }

    func getLiveTVProvider(serverID: String? = nil) async throws -> PlexLiveTVProvider? {
        let targetID = try resolveServerID(serverID ?? liveTVServerID)
        let data = try await rawServerRequest(path: "/media/providers", serverID: targetID)
        let response = try await decodeJSONInBackground(PlexMediaProvidersResponse.self, from: data, serverID: targetID)
        return response.MediaContainer.MediaProvider?
            .compactMap { $0.liveTVProvider(serverID: targetID) }
            .first
    }

    func getLiveTVChannels(provider: PlexLiveTVProvider) async throws -> [PlexLiveChannel] {
        let targetID = provider.serverID
        let data = try await rawServerRequest(path: provider.channelsKey, serverID: targetID)
        let response = try await decodeJSONInBackground(PlexLiveChannelsResponse.self, from: data, serverID: targetID)
        return (response.MediaContainer.Channel ?? []).sorted {
            Self.channelSortKey($0).lexicographicallyPrecedes(Self.channelSortKey($1))
        }
    }

    func getLiveTVNowPlaying(
        provider: PlexLiveTVProvider,
        channels: [PlexLiveChannel]
    ) async throws -> PlexLiveTVLineup {
        let programs: [PlexLiveProgram] = try await fetchMetadata(
            path: provider.watchNowKey,
            serverID: provider.serverID
        )
        return makeLiveTVLineup(provider: provider, channels: channels, programs: programs)
    }

    func getLiveTVGuide(
        provider: PlexLiveTVProvider,
        channels: [PlexLiveChannel],
        date: Date
    ) async throws -> PlexLiveTVLineup {
        // Ask for everything airing that day and sort it into channels here.
        // XMLTV lineups answer only the last of several `channelGridKey`
        // values, so per-channel batches came back nearly empty.
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        var programs: [PlexLiveProgram] = []
        var start = 0
        while true {
            let data = try await rawServerRequest(
                path: provider.gridKey,
                queryItems: [
                    URLQueryItem(name: "beginsAt<", value: String(Int(dayEnd.timeIntervalSince1970))),
                    URLQueryItem(name: "endsAt>", value: String(Int(dayStart.timeIntervalSince1970))),
                    URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(Self.liveTVGuidePageSize)),
                ],
                serverID: provider.serverID
            )
            let response = try await decodeJSONInBackground(
                MetadataResponse<PlexLiveProgram>.self,
                from: data,
                serverID: provider.serverID
            )
            let page = response.MediaContainer.Metadata ?? []
            programs.append(contentsOf: page)
            start += page.count
            guard !page.isEmpty, start < (response.MediaContainer.totalSize ?? start) else { break }
        }

        return makeLiveTVLineup(provider: provider, channels: channels, programs: programs)
    }

    private static let liveTVGuidePageSize = 500

    func tuneLiveTV(
        provider: PlexLiveTVProvider,
        channel: PlexLiveChannel
    ) async throws -> PlexLiveTuneResult {
        let targetID = provider.serverID
        let path = "/livetv/dvrs/\(provider.dvrID)/channels/\(channel.tuneIdentifier)/tune"
        let playbackSessionIdentifier = UUID().uuidString
        let data = try await rawServerRequest(
            method: "POST",
            path: path,
            queryItems: [
                URLQueryItem(
                    name: "X-Plex-Session-Identifier",
                    value: playbackSessionIdentifier
                ),
            ],
            serverID: targetID
        )
        let response = try decodeJSON(PlexLiveTuneResponse.self, from: data, serverID: targetID)
        guard let tuned = response.MediaContainer.tunedSession,
              let sessionID = tuned.sessionID else {
            let message = response.MediaContainer.message?.nilIfEmpty
                ?? "Plex did not return a Live TV session."
            throw PlexServiceError.decodingError(message)
        }

        let sessionPath = tuned.sessionPath
        let requestedTranscodeSessionID = UUID().uuidString
        // The tune above allocated a tuner. Anything that fails from here on
        // releases it, or the next tune finds no tuner free until Plex times
        // the orphan out.
        do {
            let media = tuned.media?.makeMedia(sessionPath: sessionPath)
                ?? makeFallbackLiveTVMedia(sessionPath: sessionPath)
            guard let part = media.firstAvailablePart else {
                throw PlexServiceError.decodingError("Plex did not return a playable Live TV stream.")
            }

            let liveStream = try await liveTVStreamURL(
                sessionPath: sessionPath,
                sessionIdentifier: playbackSessionIdentifier,
                transcodeSessionID: requestedTranscodeSessionID,
                serverID: targetID
            )

            let playbackURL: URL
            let transcodeSessionID: String?
            switch liveStream.outcome {
            case .transcodeAvailable:
                playbackURL = liveStream.url
                transcodeSessionID = requestedTranscodeSessionID
            case .directPlayOnly:
                let streamPath = tuned.playbackPath
                    ?? "\(sessionPath)/\(clientIdentifier)/index.m3u8"
                guard let connection = pool.connection(for: targetID),
                      let directURL = buildURL(
                        base: connection.baseURL.absoluteString,
                        path: streamPath,
                        queryItems: [URLQueryItem(name: "X-Plex-Token", value: connection.token)]
                      ) else {
                    throw PlexServiceError.invalidURL
                }
                playbackURL = directURL
                transcodeSessionID = nil
            case .failed(let message):
                throw PlexServiceError.decodingError(
                    message?.nilIfEmpty ?? "Plex could not create a Live TV stream."
                )
            }

            return PlexLiveTuneResult(
                serverID: targetID,
                sessionID: sessionID,
                playbackSessionIdentifier: playbackSessionIdentifier,
                transcodeSessionID: transcodeSessionID,
                playbackURL: playbackURL,
                media: media,
                part: part
            )
        } catch {
            Task {
                await stopTranscodeSession(transcodeSessionID: requestedTranscodeSessionID, serverID: targetID)
                await reportTimeline(
                    ratingKey: sessionID,
                    key: sessionPath,
                    state: .stopped,
                    timeMs: 0,
                    durationMs: 0,
                    sessionIdentifier: playbackSessionIdentifier,
                    serverID: targetID
                )
            }
            throw error
        }
    }

    private func makeFallbackLiveTVMedia(sessionPath: String) -> PlexMedia {
        let part = PlexMediaPart(
            id: 0,
            key: sessionPath,
            file: nil,
            size: nil,
            container: "mpegts",
            duration: nil,
            videoProfile: nil,
            audioProfile: nil,
            accessible: true,
            exists: true,
            streams: []
        )
        return PlexMedia(
            id: 0,
            container: "hls",
            videoCodec: nil,
            audioCodec: nil,
            videoResolution: nil,
            videoProfile: nil,
            audioProfile: nil,
            audioChannels: nil,
            width: nil,
            height: nil,
            bitrate: nil,
            duration: nil,
            optimizedForStreaming: nil,
            parts: [part]
        )
    }

    private func makeLiveTVLineup(
        provider: PlexLiveTVProvider,
        channels: [PlexLiveChannel],
        programs: [PlexLiveProgram]
    ) -> PlexLiveTVLineup {
        PlexLiveTVLineup(provider: provider, guides: Self.liveTVGuides(channels: channels, programs: programs))
    }

    /// One guide per channel. Plex groups a title's airings under one entry,
    /// across channels and across the day, so each airing is split out and
    /// filed under its own channel.
    nonisolated static func liveTVGuides(channels: [PlexLiveChannel], programs: [PlexLiveProgram]) -> [PlexLiveChannelGuide] {
        var seen = Set<String>()
        let airings = programs
            .flatMap { program in program.airings.map { program.narrowed(to: $0) } }
            .filter { seen.insert($0.id).inserted }
        let programsByChannel = Dictionary(grouping: airings) { program in
            program.channelGridKey ?? program.channelIdentifier ?? ""
        }
        return channels.map { channel in
            let channelPrograms = (
                programsByChannel[channel.gridKey]
                    ?? programsByChannel[channel.id]
                    ?? []
            ).sorted {
                ($0.beginsAt ?? .distantPast) < ($1.beginsAt ?? .distantPast)
            }
            return PlexLiveChannelGuide(channel: channel, programs: channelPrograms)
        }
    }

    private static func channelSortKey(_ channel: PlexLiveChannel) -> [Int] {
        let components = (channel.vcn ?? channel.id)
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        return components.isEmpty ? [Int.max] : components
    }

}
