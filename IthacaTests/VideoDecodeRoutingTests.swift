import Foundation
import Testing
@testable import Ithaca

@Suite("Video decode routing")
struct VideoDecodeRoutingTests {
    @Test(arguments: ["4:2:2", "4:4:4"])
    func chromaAppleHardwareCannotDecodeGoesToVLCKit(chroma: String) throws {
        let media = try makeMedia(container: "mp4", video: #""codec": "hevc", "chromaSubsampling": "\#(chroma)""#)
        #expect(StreamResolver.evaluate(media: media).engine == .vlcKit)

        let byProfile = try makeMedia(container: "mov", video: #""codec": "h264", "profile": "high \#(chroma)""#)
        #expect(StreamResolver.evaluate(media: byProfile).engine == .vlcKit)

        let standard = try makeMedia(container: "mp4", video: #""codec": "hevc", "chromaSubsampling": "4:2:0""#)
        #expect(StreamResolver.evaluate(media: standard).engine == .avPlayer)
    }

    @Test(arguments: ["av1", "vp9"])
    func softwareDecodeAbove1440pStartsOnTheServer(codec: String) throws {
        let ultraHD = try makeMedia(container: "mkv", video: #""codec": "\#(codec)", "width": 3840, "height": 1600"#)
        #expect(StreamResolver.softwareDecodeLimit(
            for: ultraHD, hasAV1HardwareDecode: false, processorCount: 6
        ) != nil)
        // Eight cores (M-class iPads) decode it locally.
        #expect(StreamResolver.softwareDecodeLimit(
            for: ultraHD, hasAV1HardwareDecode: false, processorCount: 8
        ) == nil)

        let fullHD = try makeMedia(container: "mkv", video: #""codec": "\#(codec)", "width": 1920, "height": 1080"#)
        #expect(StreamResolver.softwareDecodeLimit(
            for: fullHD, hasAV1HardwareDecode: false, processorCount: 6
        ) == nil)
    }

    @Test func av1WithAHardwareDecoderIsNotLimited() throws {
        let media = try makeMedia(container: "mkv", video: #""codec": "av1", "width": 3840, "height": 2160"#)
        #expect(StreamResolver.softwareDecodeLimit(
            for: media, hasAV1HardwareDecode: true, processorCount: 6
        ) == nil)
    }

    private func makeMedia(container: String, video: String) throws -> PlexMedia {
        let json = """
        {
            "id": 10,
            "container": "\(container)",
            "Part": [{
                "id": 20,
                "key": "/library/parts/20/file.\(container)",
                "Stream": [
                    { "id": 1, "streamType": 1, \(video) },
                    { "id": 2, "streamType": 2, "codec": "aac", "channels": 2 }
                ]
            }]
        }
        """
        return try JSONDecoder().decode(PlexMedia.self, from: Data(json.utf8))
    }
}
