import Compression
import Foundation

struct MatroskaTrack: Sendable, Equatable {
    /// TrackNumber.
    let number: UInt64
    /// Position of its TrackEntry within Tracks, 0-based (matches the
    /// ffprobe/Plex stream `index`).
    let streamIndex: Int
    /// 1 video, 2 audio, 0x11 subtitle.
    let type: UInt64
    /// e.g. "S_HDMV/PGS".
    let codecID: String
    let language: String?
    let compression: Compression

    enum Compression: Sendable, Equatable {
        case none
        case zlib
        case headerStripping(Data)
    }
}

struct MatroskaSubtitleCue: Sendable, Equatable {
    /// Seconds from file start (CueTime * TimestampScale).
    let time: TimeInterval
    /// Absolute file offset of the Cluster element.
    let clusterOffset: UInt64
    /// CueRelativePosition: the block element's offset inside the Cluster's
    /// data (0 = first byte after the Cluster's ID and size).
    let relativeOffset: UInt64
}

/// Track list and Cues of a Matroska file, read with a handful of range
/// requests instead of downloading the file.
struct MatroskaSubtitleIndex: Sendable {
    static let headSize = 64 * 1024
    static let maxTracksSize: UInt64 = 4 << 20
    static let maxCuesSize: UInt64 = 32 << 20
    static let maxBlockSize: UInt64 = 8 << 20

    let tracks: [MatroskaTrack]
    /// Stream indexes of tracks whose content encoding cannot be undone,
    /// with the reason.
    let unsupportedStreams: [Int: String]

    private let segmentDataStart: UInt64
    private let timestampScale: UInt64
    private let cuesData: [UInt8]

    /// Loads EBML header, Segment, SeekHead, Info, Tracks and the raw Cues bytes.
    static func load(reader: ByteRangeReader) async throws -> MatroskaSubtitleIndex {
        let head = [UInt8](try await reader(0..<UInt64(headSize)))
        guard let ebml = EBML.readHeader(in: head, at: 0), ebml.id == EBMLID.ebml,
              let ebmlSize = ebml.dataSize, ebmlSize <= UInt64(head.count) else {
            throw ImageSubtitleError.malformed("missing EBML header")
        }
        let segmentOffset = ebml.headerSize + Int(ebmlSize)
        // The Segment size may be unknown (live-written files); it is not needed.
        guard let segment = EBML.readHeader(in: head, at: segmentOffset), segment.id == EBMLID.segment else {
            throw ImageSubtitleError.malformed("missing Segment")
        }
        let segmentDataStart = UInt64(segmentOffset + segment.headerSize)

        var seekHeadOffset: Int?
        var cursor = Int(segmentDataStart)
        while seekHeadOffset == nil, let child = EBML.readHeader(in: head, at: cursor) {
            if child.id == EBMLID.seekHead { seekHeadOffset = cursor; break }
            guard let size = child.dataSize, size <= UInt64(head.count) else { break }
            cursor += child.headerSize + Int(size)
        }
        guard let seekHeadOffset else { throw ImageSubtitleError.unsupported("no SeekHead") }

        var positions = try await seekPositions(at: UInt64(seekHeadOffset), head: head, reader: reader)
        if positions[EBMLID.cues] == nil, let next = positions[EBMLID.seekHead] {
            // Some muxers chain a second SeekHead for the late elements.
            let more = try await seekPositions(at: try absolute(segmentDataStart, next), head: head, reader: reader)
            positions.merge(more) { current, _ in current }
        }
        guard let cuesPosition = positions[EBMLID.cues] else { throw ImageSubtitleError.unsupported("no Cues index") }
        guard let tracksPosition = positions[EBMLID.tracks] else { throw ImageSubtitleError.unsupported("no Tracks") }

        var scale: UInt64 = 1_000_000
        if let infoPosition = positions[EBMLID.info] {
            let info = try await element(
                at: try absolute(segmentDataStart, infoPosition), expecting: EBMLID.info,
                cap: maxTracksSize, head: head, reader: reader
            )
            try EBML.forEachChild(in: info, range: 0..<info.count) { header, range in
                if header.id == EBMLID.timestampScale { scale = try EBML.uint(info, range) }
            }
        }
        guard scale > 0 else { throw ImageSubtitleError.malformed("zero TimestampScale") }

        let tracksBody = try await element(
            at: try absolute(segmentDataStart, tracksPosition), expecting: EBMLID.tracks,
            cap: maxTracksSize, head: head, reader: reader
        )
        let parsed = try parseTracks(tracksBody)

        let cuesBody = try await element(
            at: try absolute(segmentDataStart, cuesPosition), expecting: EBMLID.cues,
            cap: maxCuesSize, head: head, reader: reader
        )
        return MatroskaSubtitleIndex(
            tracks: parsed.tracks,
            unsupportedStreams: parsed.unsupported,
            segmentDataStart: segmentDataStart,
            timestampScale: scale,
            cuesData: cuesBody
        )
    }

    /// Cue points of one track, sorted by time. Throws `.unsupported` when the
    /// track has no cue points or they lack CueRelativePosition.
    func cues(forTrackNumber number: UInt64) throws -> [MatroskaSubtitleCue] {
        let bytes = cuesData
        var cues: [MatroskaSubtitleCue] = []
        var missingRelative = false
        try EBML.forEachChild(in: bytes, range: 0..<bytes.count) { header, range in
            guard header.id == EBMLID.cuePoint else { return }
            var time: UInt64?
            var positions: [(track: UInt64, cluster: UInt64, relative: UInt64?)] = []
            try EBML.forEachChild(in: bytes, range: range) { child, childRange in
                switch child.id {
                case EBMLID.cueTime:
                    time = try EBML.uint(bytes, childRange)
                case EBMLID.cueTrackPositions:
                    var track: UInt64?
                    var cluster: UInt64?
                    var relative: UInt64?
                    try EBML.forEachChild(in: bytes, range: childRange) { field, fieldRange in
                        switch field.id {
                        case EBMLID.cueTrack: track = try EBML.uint(bytes, fieldRange)
                        case EBMLID.cueClusterPosition: cluster = try EBML.uint(bytes, fieldRange)
                        case EBMLID.cueRelativePosition: relative = try EBML.uint(bytes, fieldRange)
                        default: break
                        }
                    }
                    if let track, let cluster { positions.append((track, cluster, relative)) }
                default:
                    break
                }
            }
            guard let time else { return }
            for position in positions where position.track == number {
                guard let relative = position.relative else { missingRelative = true; continue }
                guard let offset = try? Self.absolute(segmentDataStart, position.cluster) else {
                    throw ImageSubtitleError.malformed("cluster position out of range")
                }
                // Double math: CueTime * scale can exceed UInt64 for corrupt files.
                let seconds = Double(time) * Double(timestampScale) / 1_000_000_000
                cues.append(MatroskaSubtitleCue(time: seconds, clusterOffset: offset, relativeOffset: relative))
            }
        }
        if missingRelative { throw ImageSubtitleError.unsupported("cues lack CueRelativePosition") }
        guard !cues.isEmpty else { throw ImageSubtitleError.unsupported("track \(number) has no cue points") }
        return cues.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }

    /// Absolute offset where a Cluster's data starts (after its ID and size).
    func clusterDataStart(forClusterAt offset: UInt64, reader: ByteRangeReader) async throws -> UInt64 {
        let bytes = [UInt8](try await reader(offset..<(offset + 12)))
        guard let header = EBML.readHeader(in: bytes, at: 0), header.id == EBMLID.cluster else {
            throw ImageSubtitleError.malformed("no Cluster at offset \(offset)")
        }
        return offset + UInt64(header.headerSize)
    }

    /// Payload bytes of the block a cue points at, with the track's content
    /// compression undone.
    func blockPayload(at cue: MatroskaSubtitleCue, track: MatroskaTrack, reader: ByteRangeReader) async throws -> Data {
        let dataStart = try await clusterDataStart(forClusterAt: cue.clusterOffset, reader: reader)
        return try await blockPayload(at: cue, track: track, clusterDataStart: dataStart, reader: reader)
    }

    /// Variant for callers that cache the Cluster header lookup.
    func blockPayload(
        at cue: MatroskaSubtitleCue,
        track: MatroskaTrack,
        clusterDataStart: UInt64,
        reader: ByteRangeReader
    ) async throws -> Data {
        let blockOffset = try Self.absolute(clusterDataStart, cue.relativeOffset)
        var bytes = [UInt8](try await reader(blockOffset..<(blockOffset + UInt64(Self.headSize))))
        guard let header = EBML.readHeader(in: bytes, at: 0), let size = header.dataSize else {
            throw ImageSubtitleError.malformed("no block element at offset \(blockOffset)")
        }
        guard size <= Self.maxBlockSize else { throw ImageSubtitleError.unsupported("subtitle block over \(Self.maxBlockSize) bytes") }
        let total = UInt64(header.headerSize) + size
        if total > UInt64(bytes.count) {
            let fetched = UInt64(bytes.count)
            guard fetched == UInt64(Self.headSize) else { throw ImageSubtitleError.malformed("truncated block element") }
            let rest = [UInt8](try await reader((blockOffset + fetched)..<(blockOffset + total)))
            guard UInt64(rest.count) == total - fetched else { throw ImageSubtitleError.malformed("truncated block element") }
            bytes += rest
        }
        let body = header.headerSize..<(header.headerSize + Int(size))

        var blockRange: Range<Int>?
        switch header.id {
        case EBMLID.block, EBMLID.simpleBlock:
            blockRange = body
        case EBMLID.blockGroup:
            try EBML.forEachChild(in: bytes, range: body) { child, range in
                if child.id == EBMLID.block, blockRange == nil { blockRange = range }
            }
        default:
            throw ImageSubtitleError.malformed("element \(String(header.id, radix: 16)) is not a block")
        }
        guard let blockRange else { throw ImageSubtitleError.malformed("BlockGroup without Block") }

        guard let number = EBML.readVint(in: bytes, at: blockRange.lowerBound, limit: blockRange.upperBound) else {
            throw ImageSubtitleError.malformed("truncated block header")
        }
        let flagsOffset = blockRange.lowerBound + number.length + 2
        guard flagsOffset < blockRange.upperBound else { throw ImageSubtitleError.malformed("truncated block header") }
        guard number.value == track.number else {
            throw ImageSubtitleError.malformed("block belongs to track \(number.value), expected \(track.number)")
        }
        guard bytes[flagsOffset] & 0x06 == 0 else { throw ImageSubtitleError.unsupported("laced subtitle block") }

        let payload = Data(bytes[(flagsOffset + 1)..<blockRange.upperBound])
        switch track.compression {
        case .none: return payload
        case .headerStripping(let stripped): return stripped + payload
        case .zlib: return try Self.inflate(payload)
        }
    }

    // MARK: Loading helpers

    private static func absolute(_ base: UInt64, _ offset: UInt64) throws -> UInt64 {
        let (sum, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, sum < UInt64(Int64.max) / 2 else { throw ImageSubtitleError.malformed("offset out of range") }
        return sum
    }

    /// SeekID to SeekPosition (relative to the Segment data start) of one SeekHead.
    private static func seekPositions(at offset: UInt64, head: [UInt8], reader: ByteRangeReader) async throws -> [UInt32: UInt64] {
        let body = try await element(at: offset, expecting: EBMLID.seekHead, cap: maxTracksSize, head: head, reader: reader)
        var positions: [UInt32: UInt64] = [:]
        try EBML.forEachChild(in: body, range: 0..<body.count) { entry, entryRange in
            guard entry.id == EBMLID.seek else { return }
            var id: UInt64?
            var position: UInt64?
            try EBML.forEachChild(in: body, range: entryRange) { field, range in
                if field.id == EBMLID.seekID, range.count <= 4 { id = try EBML.uint(body, range) }
                if field.id == EBMLID.seekPosition { position = try EBML.uint(body, range) }
            }
            if let id, let position, positions[UInt32(id)] == nil { positions[UInt32(id)] = position }
        }
        return positions
    }

    /// Body of the element at `offset`: from the first-64-KiB `head` when it
    /// lies inside, otherwise a header request and then a body request.
    private static func element(
        at offset: UInt64,
        expecting id: UInt32,
        cap: UInt64,
        head: [UInt8],
        reader: ByteRangeReader
    ) async throws -> [UInt8] {
        let parsed: EBMLElementHeader?
        if offset + 12 <= UInt64(head.count) {
            parsed = EBML.readHeader(in: head, at: Int(offset))
        } else {
            parsed = EBML.readHeader(in: [UInt8](try await reader(offset..<(offset + 12))), at: 0)
        }
        guard let header = parsed, header.id == id else {
            throw ImageSubtitleError.malformed("expected element \(String(id, radix: 16)) at offset \(offset)")
        }
        guard let size = header.dataSize else { throw ImageSubtitleError.malformed("unknown-size \(String(id, radix: 16))") }
        guard size <= cap else { throw ImageSubtitleError.unsupported("element \(String(id, radix: 16)) is \(size) bytes, over the \(cap) cap") }
        let bodyStart = try absolute(offset, UInt64(header.headerSize))
        let bodyEnd = bodyStart + size
        if bodyEnd <= UInt64(head.count) {
            return Array(head[Int(bodyStart)..<Int(bodyEnd)])
        }
        let body = [UInt8](try await reader(bodyStart..<bodyEnd))
        guard UInt64(body.count) == size else { throw ImageSubtitleError.malformed("short read of element \(String(id, radix: 16))") }
        return body
    }

    private static func parseTracks(_ bytes: [UInt8]) throws -> (tracks: [MatroskaTrack], unsupported: [Int: String]) {
        var tracks: [MatroskaTrack] = []
        var unsupported: [Int: String] = [:]
        var streamIndex = 0
        try EBML.forEachChild(in: bytes, range: 0..<bytes.count) { header, range in
            guard header.id == EBMLID.trackEntry else { return }
            defer { streamIndex += 1 }
            var number: UInt64?
            var type: UInt64?
            var codec = ""
            var language: String?
            var languageBCP47: String?
            var compression = MatroskaTrack.Compression.none
            var reason: String?
            try EBML.forEachChild(in: bytes, range: range) { field, fieldRange in
                switch field.id {
                case EBMLID.trackNumber: number = try EBML.uint(bytes, fieldRange)
                case EBMLID.trackType: type = try EBML.uint(bytes, fieldRange)
                case EBMLID.codecID: codec = EBML.string(bytes, fieldRange)
                case EBMLID.language: language = EBML.string(bytes, fieldRange)
                case EBMLID.languageBCP47: languageBCP47 = EBML.string(bytes, fieldRange)
                case EBMLID.contentEncodings:
                    do {
                        compression = try parseEncodings(bytes, fieldRange)
                    } catch ImageSubtitleError.unsupported(let why) {
                        reason = why
                    }
                default: break
                }
            }
            guard let number, let type else { throw ImageSubtitleError.malformed("TrackEntry without number or type") }
            if let reason {
                unsupported[streamIndex] = reason
                return
            }
            tracks.append(MatroskaTrack(
                number: number, streamIndex: streamIndex, type: type, codecID: codec,
                language: languageBCP47 ?? language, compression: compression
            ))
        }
        return (tracks, unsupported)
    }

    private static func parseEncodings(_ bytes: [UInt8], _ range: Range<Int>) throws -> MatroskaTrack.Compression {
        var count = 0
        var compression = MatroskaTrack.Compression.none
        try EBML.forEachChild(in: bytes, range: range) { header, encodingRange in
            guard header.id == EBMLID.contentEncoding else { return }
            count += 1
            var scope: UInt64 = 1
            var type: UInt64 = 0
            var algo: UInt64 = 0
            var settings = Data()
            var hasCompression = false
            var hasEncryption = false
            try EBML.forEachChild(in: bytes, range: encodingRange) { field, fieldRange in
                switch field.id {
                case EBMLID.contentEncodingScope: scope = try EBML.uint(bytes, fieldRange)
                case EBMLID.contentEncodingType: type = try EBML.uint(bytes, fieldRange)
                case EBMLID.contentEncryption: hasEncryption = true
                case EBMLID.contentCompression:
                    hasCompression = true
                    // An absent algorithm means zlib.
                    try EBML.forEachChild(in: bytes, range: fieldRange) { inner, innerRange in
                        if inner.id == EBMLID.contentCompAlgo { algo = try EBML.uint(bytes, innerRange) }
                        if inner.id == EBMLID.contentCompSettings { settings = Data(bytes[innerRange]) }
                    }
                default: break
                }
            }
            if hasEncryption || type == 1 { throw ImageSubtitleError.unsupported("encrypted track") }
            // Scope bit 0 is "block data"; other scopes only affect codec private data.
            guard scope & 1 != 0, hasCompression else { return }
            switch algo {
            case 0: compression = .zlib
            case 3: compression = .headerStripping(settings)
            default: throw ImageSubtitleError.unsupported("content compression algorithm \(algo)")
            }
        }
        if count > 1 { throw ImageSubtitleError.unsupported("multiple content encodings") }
        return compression
    }

    /// Matroska zlib is a full zlib stream; Apple's `.zlib` wants raw deflate,
    /// so the 2-byte header is dropped and the Adler-32 tail is left unread.
    private static func inflate(_ payload: Data) throws -> Data {
        let input = [UInt8](payload)
        guard input.count > 2, input[0] & 0x0F == 8, input[1] & 0x20 == 0 else {
            throw ImageSubtitleError.malformed("bad zlib header")
        }
        let cap = Int(maxBlockSize)
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { scratch.deallocate() }
        var stream = compression_stream(dst_ptr: scratch, dst_size: 0, src_ptr: UnsafePointer(scratch), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw ImageSubtitleError.malformed("zlib decoder unavailable")
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        try input.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            stream.src_ptr = base + 2
            stream.src_size = source.count - 2
            while true {
                let status: compression_status = chunk.withUnsafeMutableBufferPointer { destination in
                    stream.dst_ptr = destination.baseAddress ?? scratch
                    stream.dst_size = destination.count
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                if status == COMPRESSION_STATUS_ERROR { throw ImageSubtitleError.malformed("corrupt zlib data") }
                output.append(contentsOf: chunk[0..<(chunk.count - stream.dst_size)])
                if output.count > cap { throw ImageSubtitleError.unsupported("inflated subtitle block over \(cap) bytes") }
                if status == COMPRESSION_STATUS_END { break }
                if stream.src_size == 0, stream.dst_size != 0 { throw ImageSubtitleError.malformed("truncated zlib data") }
            }
        }
        return output
    }
}
