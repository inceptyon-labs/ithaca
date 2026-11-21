import Foundation
import OSLog
import QuartzCore

private let imageSubtitleLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Ithaca",
    category: "ImageSubtitles"
)

/// Draws an `ImageSubtitleProvider`'s events into a layer that sits above the
/// AVPlayer layer. The engine drives it from a periodic time observer; this
/// keeps a window of decoded events around the playhead and shows the one
/// whose time span contains it.
///
/// The layer is ordinary SDR content over the HDR video layer, so subtitle
/// white lands at the display's reference white, not at peak brightness.
@MainActor
final class ImageSubtitleOverlay {
    /// Enough to survive a slow link without holding many bitmaps.
    private static let lookAhead: TimeInterval = 30
    /// A short skip back should not blank the subtitle that was showing.
    private static let lookBehind: TimeInterval = 5
    private static let refillMargin: TimeInterval = 10
    /// The file's last display set has no successor to end it.
    private static let lastEventDuration: TimeInterval = 10
    private static let maxConsecutiveFailures = 5

    private let provider: ImageSubtitleProvider
    private let layer: CALayer
    private var events: [ImageSubtitleEvent] = []
    private var loadedWindow: ClosedRange<TimeInterval>?
    private var loadingWindow: ClosedRange<TimeInterval>?
    private var loadTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var retryNotBefore: Date?
    private var shownEventStart: TimeInterval?
    private var shownVideoRect: CGRect = .null

    /// - Parameter layer: An empty layer above the video, sized like the
    ///   player layer. The overlay owns its sublayers until `invalidate()`.
    init(provider: ImageSubtitleProvider, layer: CALayer) {
        self.provider = provider
        self.layer = layer
    }

    /// - Parameters:
    ///   - time: The player's position in the file, in seconds.
    ///   - videoRect: Where the video is drawn, in the layer's coordinates.
    func update(time: TimeInterval, videoRect: CGRect) {
        guard time.isFinite, time >= 0 else { return }
        loadIfNeeded(around: time)

        var active: ImageSubtitleEvent?
        if loadedWindow?.contains(time) == true,
           let event = events.last(where: { $0.start <= time }),
           time < (event.end ?? event.start + Self.lastEventDuration) {
            active = event
        }
        let eventStart = active.flatMap { $0.frame.images.isEmpty ? nil : $0.start }
        guard eventStart != shownEventStart || videoRect != shownVideoRect else { return }
        shownEventStart = eventStart
        shownVideoRect = videoRect
        draw(eventStart == nil ? nil : active?.frame, videoRect: videoRect)
    }

    func invalidate() {
        loadTask?.cancel()
        loadTask = nil
        loadingWindow = nil
        events = []
        loadedWindow = nil
        shownEventStart = nil
        shownVideoRect = .null
        draw(nil, videoRect: .zero)
    }

    private func loadIfNeeded(around time: TimeInterval) {
        if let loadedWindow, loadedWindow.contains(time),
           loadedWindow.upperBound - time > Self.refillMargin {
            return
        }
        // A seek leaves the window being loaded behind.
        if let loadingWindow {
            if loadingWindow.contains(time) { return }
            loadTask?.cancel()
        }
        guard consecutiveFailures < Self.maxConsecutiveFailures else { return }
        if let retryNotBefore, retryNotBefore > .now { return }

        let window = max(0, time - Self.lookBehind)...(time + Self.lookAhead)
        loadingWindow = window
        loadTask = Task { [weak self, provider] in
            let result: Result<[ImageSubtitleEvent], Error>
            do {
                result = .success(try await provider.events(in: window))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, self.loadingWindow == window else { return }
            self.loadingWindow = nil
            self.loadTask = nil
            switch result {
            case let .success(events):
                self.events = events
                self.loadedWindow = window
                self.consecutiveFailures = 0
                self.retryNotBefore = nil
            case let .failure(error):
                self.consecutiveFailures += 1
                self.retryNotBefore = .now + 2
                let givesUp = self.consecutiveFailures >= Self.maxConsecutiveFailures
                imageSubtitleLogger.error(
                    "Image subtitles could not be read at \(window.lowerBound, privacy: .public)s\(givesUp ? ", giving up" : "", privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func draw(_ frame: ImageSubtitleFrame?, videoRect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let frame,
              frame.canvasSize.width > 0, frame.canvasSize.height > 0,
              videoRect.width > 0, layer.bounds.height > 0 else {
            return
        }
        // The canvas is the disc's full frame, and a film stored cropped to
        // its picture (letterbox or pillarbox bars removed) still fills that
        // frame in one dimension. So the canvas is scaled to contain the
        // video and centred on it; subtitles then land in the bars as on
        // disc. A screen too small for that (a phone, or zoom-to-fill) gets
        // the canvas shrunk to fit so no line falls off the edge.
        let scale = min(
            max(
                videoRect.width / frame.canvasSize.width,
                videoRect.height / frame.canvasSize.height
            ),
            layer.bounds.width / frame.canvasSize.width,
            layer.bounds.height / frame.canvasSize.height
        )
        let origin = CGPoint(
            x: videoRect.midX - frame.canvasSize.width * scale / 2,
            y: videoRect.midY - frame.canvasSize.height * scale / 2
        )
        for image in frame.images {
            let sublayer = CALayer()
            sublayer.contents = image.image
            sublayer.contentsGravity = .resize
            sublayer.frame = CGRect(
                x: origin.x + image.frame.minX * scale,
                y: origin.y + image.frame.minY * scale,
                width: image.frame.width * scale,
                height: image.frame.height * scale
            )
            layer.addSublayer(sublayer)
        }
    }
}
