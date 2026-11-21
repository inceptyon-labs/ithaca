import Foundation

/// Serves decoded PGS subtitle events for a time window, reading only the
/// blocks it needs from the original MKV with range requests.
actor ImageSubtitleProvider {
    private struct Prepared: Sendable {
        let index: MatroskaSubtitleIndex
        let track: MatroskaTrack
        let cues: [MatroskaSubtitleCue]
    }

    private struct CacheEntry {
        let event: ImageSubtitleEvent?
        let bytes: Int
        let sequence: Int
    }

    private static let maxCachedEvents = 60
    private static let maxCachedBytes = 64 << 20
    private static let maxWalkBack = 12

    private let reader: ByteRangeReader
    private let streamIndex: Int
    private var preparation: Task<Prepared, Error>?

    private var decoder = PGSDecoder()
    /// Cue index the decoder state continues at; nil after a reset.
    private var decoderNext: Int?
    /// Keyed by cue index. A nil event records a cue that produced no frame.
    private var cache: [Int: CacheEntry] = [:]
    private var cacheBytes = 0
    private var cacheSequence = 0
    private var clusterDataStarts: [UInt64: UInt64] = [:]

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(reader: @escaping ByteRangeReader, streamIndex: Int) {
        self.reader = reader
        self.streamIndex = streamIndex
    }

    /// Loads the index and checks the stream is a PGS track with usable cues.
    func prepare() async throws {
        _ = try await prepared()
    }

    /// Decoded events whose [start, end) intersects `window`, in time order,
    /// including the event already showing at `window.lowerBound`.
    func events(in window: ClosedRange<TimeInterval>) async throws -> [ImageSubtitleEvent] {
        let prepared = try await prepared()
        await acquire()
        defer { release() }
        try Task.checkCancellation()

        let cues = prepared.cues
        guard let last = Self.lastCue(in: cues, atOrBefore: window.upperBound) else { return [] }
        let first = Self.lastCue(in: cues, atOrBefore: window.lowerBound) ?? 0

        var result: [ImageSubtitleEvent] = []
        for cueIndex in first...last {
            try Task.checkCancellation()
            if let entry = cache[cueIndex] {
                if let event = entry.event { result.append(event) }
            } else if let event = try await decodeCue(cueIndex, prepared) {
                result.append(event)
            }
        }
        return result
    }

    // MARK: Preparation

    private func prepared() async throws -> Prepared {
        if let preparation { return try await preparation.value }
        let reader = reader
        let streamIndex = streamIndex
        let task = Task<Prepared, Error> {
            let index = try await MatroskaSubtitleIndex.load(reader: reader)
            if let reason = index.unsupportedStreams[streamIndex] { throw ImageSubtitleError.unsupported(reason) }
            guard let track = index.tracks.first(where: { $0.streamIndex == streamIndex }) else {
                throw ImageSubtitleError.unsupported("stream \(streamIndex) is not in the Matroska Tracks")
            }
            guard track.type == 0x11, track.codecID == "S_HDMV/PGS" else {
                throw ImageSubtitleError.unsupported("stream \(streamIndex) is \(track.codecID), not PGS")
            }
            return Prepared(index: index, track: track, cues: try index.cues(forTrackNumber: track.number))
        }
        preparation = task
        do {
            return try await task.value
        } catch {
            // A format verdict is final; a network failure may succeed next time.
            if !(error is ImageSubtitleError) { preparation = nil }
            throw error
        }
    }

    // MARK: Decoding

    private func decodeCue(_ cueIndex: Int, _ prepared: Prepared) async throws -> ImageSubtitleEvent? {
        let output: PGSDecoder.Output
        if decoderNext == cueIndex {
            if let payload = try await payload(of: cueIndex, prepared) {
                output = decoder.decode(payload)
            } else {
                output = .none
            }
        } else {
            decoder.reset()
            decoderNext = nil
            output = try await decodeAfterSeek(cueIndex, prepared)
        }
        decoderNext = cueIndex + 1

        var event: ImageSubtitleEvent?
        var bytes = 0
        if case .frame(let frame) = output {
            let cues = prepared.cues
            event = ImageSubtitleEvent(
                start: cues[cueIndex].time,
                end: cueIndex + 1 < cues.count ? cues[cueIndex + 1].time : nil,
                frame: frame
            )
            bytes = frame.images.reduce(0) { $0 + $1.image.width * $1.image.height * 4 }
        }
        remember(cueIndex, event, bytes: bytes)
        return event
    }

    /// Decodes a cue with a fresh decoder. A display set that needs state from
    /// before it is retried from up to `maxWalkBack` earlier cues, replaying
    /// them in order, until one is an epoch start.
    private func decodeAfterSeek(_ cueIndex: Int, _ prepared: Prepared) async throws -> PGSDecoder.Output {
        guard let own = try await payload(of: cueIndex, prepared) else { return .none }
        var output = decoder.decode(own)
        guard case .needsEarlierData = output else { return output }

        var earlier: [Data] = []   // earlier[k] is the payload of cue cueIndex - 1 - k
        for back in 1...Self.maxWalkBack where cueIndex - back >= 0 {
            try Task.checkCancellation()
            earlier.append(try await payload(of: cueIndex - back, prepared) ?? Data())
            decoder.reset()
            for payload in earlier.reversed() { _ = decoder.decode(payload) }
            output = decoder.decode(own)
            if case .frame = output { return output }
        }
        decoder.reset()
        return .needsEarlierData
    }

    private func payload(of cueIndex: Int, _ prepared: Prepared) async throws -> Data? {
        let cue = prepared.cues[cueIndex]
        do {
            let dataStart: UInt64
            if let cached = clusterDataStarts[cue.clusterOffset] {
                dataStart = cached
            } else {
                dataStart = try await prepared.index.clusterDataStart(forClusterAt: cue.clusterOffset, reader: reader)
                clusterDataStarts[cue.clusterOffset] = dataStart
            }
            return try await prepared.index.blockPayload(
                at: cue, track: prepared.track, clusterDataStart: dataStart, reader: reader
            )
        } catch ImageSubtitleError.malformed {
            // One unreadable block should not blank the rest of the track.
            return nil
        }
    }

    private func remember(_ cueIndex: Int, _ event: ImageSubtitleEvent?, bytes: Int) {
        cacheSequence += 1
        if let old = cache[cueIndex] { cacheBytes -= old.bytes }
        cache[cueIndex] = CacheEntry(event: event, bytes: bytes, sequence: cacheSequence)
        cacheBytes += bytes
        while cache.count > Self.maxCachedEvents || cacheBytes > Self.maxCachedBytes,
              let oldest = cache.min(by: { $0.value.sequence < $1.value.sequence }) {
            cacheBytes -= oldest.value.bytes
            cache[oldest.key] = nil
        }
    }

    /// Index of the last cue with `time <= limit`.
    private static func lastCue(in cues: [MatroskaSubtitleCue], atOrBefore limit: TimeInterval) -> Int? {
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].time <= limit { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? low - 1 : nil
    }

    // MARK: Serialization

    /// Decoder state is shared across awaits, so one `events` call runs at a time.
    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
