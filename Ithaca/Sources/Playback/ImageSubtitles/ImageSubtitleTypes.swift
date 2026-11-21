import CoreGraphics
import Foundation

/// Reads bytes [range) of the media file. Throws on network/HTTP failure.
typealias ByteRangeReader = @Sendable (Range<UInt64>) async throws -> Data

enum ImageSubtitleError: Error, Equatable, Sendable {
    /// The file or track cannot be served this way (reason is for the log).
    case unsupported(String)
    /// The bytes violate the format.
    case malformed(String)
}

struct ImageSubtitleFrame: @unchecked Sendable {   // CGImage is immutable
    struct Image {
        let image: CGImage
        /// Canvas pixels, origin top-left.
        let frame: CGRect
    }

    /// PCS video width x height.
    let canvasSize: CGSize
    /// Empty means "clear the screen".
    let images: [Image]
}

struct ImageSubtitleEvent: Sendable {
    let start: TimeInterval
    /// Start of the next display set; nil for the last cue.
    let end: TimeInterval?
    let frame: ImageSubtitleFrame
}
