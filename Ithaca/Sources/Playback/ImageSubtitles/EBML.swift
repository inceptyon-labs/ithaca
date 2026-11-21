import Foundation

/// Element IDs used by the subtitle reader. IDs keep their length marker.
enum EBMLID {
    static let ebml: UInt32 = 0x1A45_DFA3
    static let segment: UInt32 = 0x1853_8067
    static let seekHead: UInt32 = 0x114D_9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549_A966
    static let timestampScale: UInt32 = 0x2A_D7B1
    static let tracks: UInt32 = 0x1654_AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let codecID: UInt32 = 0x86
    static let language: UInt32 = 0x22_B59C
    static let languageBCP47: UInt32 = 0x22_B59D
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingScope: UInt32 = 0x5032
    static let contentEncodingType: UInt32 = 0x5033
    static let contentCompression: UInt32 = 0x5034
    static let contentEncryption: UInt32 = 0x5035
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255
    static let cues: UInt32 = 0x1C53_BB6B
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7
    static let cueClusterPosition: UInt32 = 0xF1
    static let cueRelativePosition: UInt32 = 0xF0
    static let cluster: UInt32 = 0x1F43_B675
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let simpleBlock: UInt32 = 0xA3
}

struct EBMLElementHeader: Equatable {
    let id: UInt32
    /// nil when the size field holds the reserved "unknown" value.
    let dataSize: UInt64?
    let headerSize: Int
}

enum EBML {
    /// An element ID of 1-4 bytes, length marker included.
    static func readID(in bytes: [UInt8], at offset: Int, limit: Int? = nil) -> (id: UInt32, length: Int)? {
        let end = min(limit ?? bytes.count, bytes.count)
        guard offset >= 0, offset < end else { return nil }
        let first = bytes[offset]
        let length = first.leadingZeroBitCount + 1
        guard length <= 4, offset + length <= end else { return nil }
        var value: UInt32 = 0
        for index in offset..<(offset + length) {
            value = value << 8 | UInt32(bytes[index])
        }
        return (value, length)
    }

    /// A size vint of 1-8 bytes with the marker bit cleared. An all-ones
    /// value is "unknown".
    static func readVint(in bytes: [UInt8], at offset: Int, limit: Int? = nil) -> (value: UInt64, length: Int, isUnknown: Bool)? {
        let end = min(limit ?? bytes.count, bytes.count)
        guard offset >= 0, offset < end else { return nil }
        let first = bytes[offset]
        let length = first.leadingZeroBitCount + 1
        guard length <= 8, offset + length <= end else { return nil }
        let valueMask = UInt8(0xFF) >> UInt8(length)
        var value = UInt64(first & valueMask)
        var allOnes = (first & valueMask) == valueMask
        for index in (offset + 1)..<(offset + length) {
            value = value << 8 | UInt64(bytes[index])
            if bytes[index] != 0xFF { allOnes = false }
        }
        return (value, length, allOnes)
    }

    static func readHeader(in bytes: [UInt8], at offset: Int, limit: Int? = nil) -> EBMLElementHeader? {
        guard let id = readID(in: bytes, at: offset, limit: limit),
              let size = readVint(in: bytes, at: offset + id.length, limit: limit) else { return nil }
        return EBMLElementHeader(
            id: id.id,
            dataSize: size.isUnknown ? nil : size.value,
            headerSize: id.length + size.length
        )
    }

    /// Big-endian unsigned integer of 0-8 bytes.
    static func uint(_ bytes: [UInt8], _ range: Range<Int>) throws -> UInt64 {
        guard range.count <= 8, range.lowerBound >= 0, range.upperBound <= bytes.count else {
            throw ImageSubtitleError.malformed("integer element of \(range.count) bytes")
        }
        return bytes[range].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    static func string(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        let text = bytes[range].prefix { $0 != 0 }
        return String(decoding: text, as: UTF8.self)
    }

    /// Calls `body` for each child element in `range` with the range of its
    /// data. Throws when a child is truncated, overruns `range` or has an
    /// unknown size (only legal for Segment and Cluster).
    static func forEachChild(
        in bytes: [UInt8],
        range: Range<Int>,
        _ body: (EBMLElementHeader, Range<Int>) throws -> Void
    ) throws {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
            throw ImageSubtitleError.malformed("element range outside its buffer")
        }
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard let header = readHeader(in: bytes, at: offset, limit: range.upperBound) else {
                throw ImageSubtitleError.malformed("truncated element header")
            }
            guard let size = header.dataSize else {
                throw ImageSubtitleError.malformed("unknown-size element \(String(header.id, radix: 16))")
            }
            let start = offset + header.headerSize
            guard size <= UInt64(range.upperBound - start) else {
                throw ImageSubtitleError.malformed("element \(String(header.id, radix: 16)) overruns its parent")
            }
            let end = start + Int(size)
            try body(header, start..<end)
            offset = end
        }
    }
}
