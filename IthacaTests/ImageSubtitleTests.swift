import CoreGraphics
import Foundation
import Testing
@testable import Ithaca

@Suite("Matroska EBML parsing")
struct EBMLParsingTests {
    @Test func idsKeepTheirLengthMarker() {
        #expect(EBML.readID(in: [0xA3], at: 0)?.id == 0xA3)
        #expect(EBML.readID(in: [0x42, 0x86], at: 0)?.id == 0x4286)
        #expect(EBML.readID(in: [0x1A, 0x45, 0xDF, 0xA3], at: 0)?.length == 4)
        #expect(EBML.readID(in: [0x1A, 0x45], at: 0) == nil)
        #expect(EBML.readID(in: [0x00, 0x01], at: 0) == nil)
    }

    @Test func sizesClearTheMarkerAndRecognizeUnknown() {
        #expect(EBML.readVint(in: [0x82], at: 0)?.value == 2)
        #expect(EBML.readVint(in: [0x40, 0x02], at: 0)?.value == 2)
        #expect(EBML.readVint(in: [0x40, 0x02], at: 0)?.length == 2)
        #expect(EBML.readVint(in: [0xFF], at: 0)?.isUnknown == true)
        #expect(EBML.readVint(in: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], at: 0)?.isUnknown == true)
        #expect(EBML.readVint(in: [0x01, 0, 0, 0, 0, 0, 0, 0x05], at: 0)?.value == 5)
        #expect(EBML.readVint(in: [0x40], at: 0) == nil)

        let header = EBML.readHeader(in: [0x18, 0x53, 0x80, 0x67, 0xFF], at: 0)
        #expect(header == EBMLElementHeader(id: EBMLID.segment, dataSize: nil, headerSize: 5))
    }

    @Test func childrenOverrunningTheirParentAreRejected() {
        #expect(throws: ImageSubtitleError.self) {
            try EBML.forEachChild(in: [0xD7, 0x85, 0x01], range: 0..<3) { _, _ in }
        }
    }
}

@Suite("Matroska subtitle index")
struct MatroskaSubtitleIndexTests {
    @Test func loadsTracksCuesAndBlockPayload() async throws {
        let file = SyntheticMKV(payloads: [displaySetPayload(), clearPayload()])
        let index = try await MatroskaSubtitleIndex.load(reader: file.reader)

        #expect(index.tracks.count == 2)
        let track = try #require(index.tracks.first { $0.streamIndex == 1 })
        #expect(track.number == 3)
        #expect(track.codecID == "S_HDMV/PGS")
        #expect(track.language == "eng")
        #expect(track.compression == .none)

        let cues = try index.cues(forTrackNumber: 3)
        #expect(cues.map(\.time) == [1.0, 3.0])
        #expect(cues[0].clusterOffset == file.clusterOffset)
        let payload = try await index.blockPayload(at: cues[1], track: track, reader: file.reader)
        #expect(payload == Data(clearPayload()))
    }

    @Test func fileWithoutCuesIsUnsupported() async {
        let file = SyntheticMKV(payloads: [displaySetPayload()], includeCues: false)
        await #expect(throws: ImageSubtitleError.unsupported("no Cues index")) {
            _ = try await MatroskaSubtitleIndex.load(reader: file.reader)
        }
    }

    @Test func zlibCompressedBlocksAreInflated() async throws {
        let file = SyntheticMKV(payloads: [displaySetPayload()], zlib: true)
        let index = try await MatroskaSubtitleIndex.load(reader: file.reader)
        let track = try #require(index.tracks.first { $0.streamIndex == 1 })
        #expect(track.compression == .zlib)

        let cue = try #require(try index.cues(forTrackNumber: 3).first)
        let payload = try await index.blockPayload(at: cue, track: track, reader: file.reader)
        #expect(payload == Data(displaySetPayload()))
    }
}

@Suite("PGS decoder")
struct PGSDecoderTests {
    @Test func epochStartDecodesPixelsAndPosition() throws {
        var decoder = PGSDecoder()
        guard case .frame(let frame) = decoder.decode(Data(displaySetPayload())) else {
            Issue.record("expected a frame")
            return
        }
        #expect(frame.canvasSize == CGSize(width: 1920, height: 1080))
        let image = try #require(frame.images.first)
        #expect(frame.images.count == 1)
        #expect(image.frame == CGRect(x: 100, y: 900, width: 4, height: 2))

        let pixels = [UInt8](try #require(image.image.dataProvider?.data) as Data)
        let transparent: [UInt8] = [0, 0, 0, 0]
        let expected: [UInt8] =
            [255, 255, 255, 255] + [0, 0, 0, 255] + [128, 128, 128, 128] + transparent
            + [0, 0, 0, 255] + [0, 0, 0, 255] + [0, 0, 0, 255] + [0, 0, 0, 255]
        #expect(pixels == expected)
    }

    @Test func compositionWithoutObjectsClearsTheScreen() {
        var decoder = PGSDecoder()
        guard case .frame(let frame) = decoder.decode(Data(clearPayload())) else {
            Issue.record("expected a frame")
            return
        }
        #expect(frame.images.isEmpty)
        #expect(frame.canvasSize == CGSize(width: 1920, height: 1080))
    }

    @Test func displaySetFromMidEpochNeedsEarlierData() {
        var decoder = PGSDecoder()
        let normal = segment(0x16, pcsBody(state: 0x00, objectIDs: [0])) + segment(0x80, [])
        guard case .needsEarlierData = decoder.decode(Data(normal)) else {
            Issue.record("expected needsEarlierData")
            return
        }
    }

    @Test func runsAreClampedToTheBitmap() {
        // 0x00 0x3F: 63 pixels of colour 0 into a 2x1 bitmap, then a 14-bit run of colour 5.
        let indices = PGSDecoder.decodeRLE([0, 0x3F, 0, 0xC0, 0x10, 5], width: 2, height: 1)
        #expect(indices == [0, 0])
    }
}

@Suite("Image subtitle provider")
struct ImageSubtitleProviderTests {
    @Test func eventEndsAtTheNextCue() async throws {
        let file = SyntheticMKV(payloads: [displaySetPayload(), clearPayload()])
        let provider = ImageSubtitleProvider(reader: file.reader, streamIndex: 1)
        let events = try await provider.events(in: 0...10)

        #expect(events.count == 2)
        #expect(events[0].start == 1.0)
        #expect(events[0].end == 3.0)
        #expect(events[0].frame.images.count == 1)
        #expect(events[1].start == 3.0)
        #expect(events[1].end == nil)
        #expect(events[1].frame.images.isEmpty)

        // The event already showing at the window start is included.
        let showing = try await provider.events(in: 2...2)
        #expect(showing.map(\.start) == [1.0])
    }

    @Test func nonPGSStreamIsUnsupported() async {
        let file = SyntheticMKV(payloads: [displaySetPayload()])
        let provider = ImageSubtitleProvider(reader: file.reader, streamIndex: 0)
        await #expect(throws: ImageSubtitleError.self) { try await provider.prepare() }
    }
}

// MARK: - Fixtures

@Suite("Overlay subtitle routing")
struct OverlaySubtitleRoutingTests {
    @Test func onlyEmbeddedPGSInMatroskaIsDrawnByIthaca() throws {
        let mkv = try media(container: "mkv")
        let streams = mkv.parts[0].streams
        #expect(StreamResolver.isOverlaySubtitle(streams[0], in: mkv))
        // ASS, a sidecar file, and a stream Plex gave no index for.
        #expect(!StreamResolver.isOverlaySubtitle(streams[1], in: mkv))
        #expect(!StreamResolver.isOverlaySubtitle(streams[2], in: mkv))
        #expect(!StreamResolver.isOverlaySubtitle(streams[3], in: mkv))

        let transportStream = try media(container: "mpegts")
        #expect(!StreamResolver.isOverlaySubtitle(transportStream.parts[0].streams[0], in: transportStream))
    }

    private func media(container: String) throws -> PlexMedia {
        let json = """
        {
            "id": 10,
            "container": "\(container)",
            "Part": [{
                "id": 20,
                "key": "/library/parts/20/file.\(container)",
                "Stream": [
                    { "id": 3, "index": 2, "streamType": 3, "codec": "pgs" },
                    { "id": 4, "index": 3, "streamType": 3, "codec": "ass" },
                    { "id": 5, "streamType": 3, "codec": "pgs", "key": "/library/streams/5" },
                    { "id": 6, "streamType": 3, "codec": "pgs" }
                ]
            }]
        }
        """
        return try JSONDecoder().decode(PlexMedia.self, from: Data(json.utf8))
    }
}

private func segment(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
    [type, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
}

private func pcsBody(state: UInt8, objectIDs: [UInt16]) -> [UInt8] {
    var body: [UInt8] = [0x07, 0x80, 0x04, 0x38, 0x10, 0x00, 0x01, state, 0x00, 0x00, UInt8(objectIDs.count)]
    for id in objectIDs {
        body += [UInt8(id >> 8), UInt8(id & 0xFF), 0x00, 0x00, 0x00, 100, 0x03, 0x84]
    }
    return body
}

/// Epoch start at (100, 900) with one 4x2 object: row 0 is white, black,
/// half-alpha white, then a 1-pixel colour-0 run; row 1 is a run of 4 black.
private func displaySetPayload() -> [UInt8] {
    let rle: [UInt8] = [1, 2, 3, 0, 1, 0, 0] + [0, 0x84, 2, 0, 0]
    let palette: [UInt8] = [0, 0] + [1, 235, 128, 128, 255] + [2, 16, 128, 128, 255] + [3, 235, 128, 128, 128]
    let length = rle.count + 4
    let object: [UInt8] = [0, 0, 0, 0xC0, 0, UInt8(length >> 8), UInt8(length & 0xFF), 0, 4, 0, 2] + rle
    return segment(0x16, pcsBody(state: 0x80, objectIDs: [0]))
        + segment(0x17, [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        + segment(0x14, palette)
        + segment(0x15, object)
        + segment(0x80, [])
}

private func clearPayload() -> [UInt8] {
    segment(0x16, pcsBody(state: 0x00, objectIDs: [])) + segment(0x80, [])
}

private func element(_ id: UInt32, _ body: [UInt8]) -> [UInt8] {
    var idBytes: [UInt8] = []
    var rest = id
    while rest > 0 {
        idBytes.insert(UInt8(rest & 0xFF), at: 0)
        rest >>= 8
    }
    let size = body.count
    let sizeBytes: [UInt8]
    if size < 0x7F {
        sizeBytes = [0x80 | UInt8(size)]
    } else {
        sizeBytes = [0x40 | UInt8(size >> 8), UInt8(size & 0xFF)]
    }
    return idBytes + sizeBytes + body
}

private func uintElement(_ id: UInt32, _ value: UInt64, width: Int = 1) -> [UInt8] {
    element(id, (0..<width).map { UInt8((value >> UInt64(8 * (width - 1 - $0))) & 0xFF) })
}

private func zlibStream(_ bytes: [UInt8]) -> [UInt8] {
    var adlerA: UInt32 = 1
    var adlerB: UInt32 = 0
    for byte in bytes {
        adlerA = (adlerA + UInt32(byte)) % 65521
        adlerB = (adlerB + adlerA) % 65521
    }
    let adler = adlerB << 16 | adlerA
    let deflated = (try? (Data(bytes) as NSData).compressed(using: .zlib)) ?? NSData()
    return [0x78, 0x9C] + [UInt8](deflated as Data) + (0..<4).map { UInt8((adler >> UInt32(24 - 8 * $0)) & 0xFF) }
}

/// A small MKV: EBML header, unknown-size Segment, SeekHead, Info, Tracks
/// (video track 1, PGS track 3), one Cluster with a BlockGroup per payload
/// at 1 s, 3 s, ..., and Cues at the end.
private struct SyntheticMKV {
    let data: Data
    let clusterOffset: UInt64

    init(payloads: [[UInt8]], includeCues: Bool = true, zlib: Bool = false) {
        func seekHead(infoAt: Int, tracksAt: Int, cuesAt: Int) -> [UInt8] {
            func entry(_ id: UInt32, _ position: Int) -> [UInt8] {
                var idBytes: [UInt8] = []
                var rest = id
                while rest > 0 { idBytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
                return element(0x4DBB, element(0x53AB, idBytes) + uintElement(0x53AC, UInt64(position), width: 4))
            }
            var body = entry(0x1549_A966, infoAt) + entry(0x1654_AE6B, tracksAt)
            if includeCues { body += entry(0x1C53_BB6B, cuesAt) }
            return element(0x114D_9B74, body)
        }

        let ebml = element(0x1A45_DFA3, element(0x4282, Array("matroska".utf8)))
        let info = element(0x1549_A966, uintElement(0x2A_D7B1, 1_000_000, width: 3))
        let compression = element(0x6D80, element(0x6240, element(0x5034, uintElement(0x4254, 0))))
        let tracks = element(0x1654_AE6B,
            element(0xAE, uintElement(0xD7, 1) + uintElement(0x83, 1) + element(0x86, Array("V_MPEGH/ISO/HEVC".utf8)))
            + element(0xAE, uintElement(0xD7, 3) + uintElement(0x83, 0x11) + element(0x86, Array("S_HDMV/PGS".utf8))
                + element(0x22_B59C, Array("eng".utf8)) + (zlib ? compression : []))
        )

        var blocks: [UInt8] = element(0xE7, [0])
        var relativeOffsets: [Int] = []
        for (position, payload) in payloads.enumerated() {
            relativeOffsets.append(blocks.count)
            let stored = zlib ? zlibStream(payload) : payload
            let block = element(0xA1, [0x83, 0x00, 0x00, 0x00] + stored)
            blocks += element(0xA0, block + uintElement(0x9B, UInt64(position)))
        }
        let cluster = [0x1F, 0x43, 0xB6, 0x75] + (0..<4).map { UInt8((0x1000_0000 | blocks.count) >> (24 - 8 * $0) & 0xFF) } + blocks

        // SeekHead entries have fixed-width positions, so its size is known up front.
        let seekSize = seekHead(infoAt: 0, tracksAt: 0, cuesAt: 0).count
        let infoAt = seekSize
        let tracksAt = infoAt + info.count
        let clusterAt = tracksAt + tracks.count
        let cuesAt = clusterAt + cluster.count

        var cuePoints: [UInt8] = []
        for (position, relative) in relativeOffsets.enumerated() {
            let positions = element(0xB7, uintElement(0xF7, 3) + uintElement(0xF1, UInt64(clusterAt), width: 2)
                + uintElement(0xF0, UInt64(relative), width: 2))
            cuePoints += element(0xBB, uintElement(0xB3, UInt64(1000 + 2000 * position), width: 2) + positions)
        }

        let segmentBody = seekHead(infoAt: infoAt, tracksAt: tracksAt, cuesAt: cuesAt)
            + info + tracks + cluster + (includeCues ? element(0x1C53_BB6B, cuePoints) : [])
        let segmentHeader: [UInt8] = [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let file = ebml + segmentHeader + segmentBody
        data = Data(file)
        clusterOffset = UInt64(ebml.count + segmentHeader.count + clusterAt)
    }

    var reader: ByteRangeReader {
        let data = data
        return { range in
            let lower = Int(min(range.lowerBound, UInt64(data.count)))
            let upper = Int(min(range.upperBound, UInt64(data.count)))
            return data.subdata(in: lower..<upper)
        }
    }
}
