import Foundation

/// A stacked (multi-part) media version: one item whose file is split into
/// several parts played back to back. Item time is the parts end to end; the
/// player only ever has one part loaded, so everything that talks to Plex
/// (resume offset, timeline, scrobble, markers) is item-level and everything
/// the engine sees is relative to the current part.
struct PlexPartTimeline: Equatable, Sendable {
    let partCount: Int
    /// Length of each part in milliseconds; nil when any part's length is
    /// unknown, which leaves the parts without a shared item clock.
    let durationsMs: [Int]?

    init(partCount: Int, durationsMs: [Int]?) {
        self.partCount = partCount
        self.durationsMs = durationsMs
    }

    /// nil for single-part media. Known part durations are kept; parts without
    /// one share what is left of the media duration by file size; otherwise the
    /// lengths stay unknown.
    init?(media: PlexMedia) {
        let parts = media.parts
        guard parts.count > 1 else { return nil }
        let known = parts.map { $0.duration.flatMap { $0 > 0 ? $0 : nil } }
        let missing = known.indices.filter { known[$0] == nil }
        if missing.isEmpty {
            self.init(partCount: parts.count, durationsMs: known.compactMap { $0 })
            return
        }
        let sizes = missing.map { parts[$0].size.flatMap { $0 > 0 ? $0 : nil } }
        let remainder = (media.duration ?? 0) - known.compactMap { $0 }.reduce(0, +)
        guard remainder > 0, sizes.allSatisfy({ $0 != nil }) else {
            self.init(partCount: parts.count, durationsMs: nil)
            return
        }
        let sizeValues = sizes.compactMap { $0 }
        let totalSize = Double(sizeValues.reduce(0, +))
        var estimates = sizeValues.map { Int(Double(remainder) * Double($0) / totalSize) }
        estimates[estimates.count - 1] += remainder - estimates.reduce(0, +)
        var durations = known
        for (slot, index) in missing.enumerated() { durations[index] = estimates[slot] }
        self.init(partCount: parts.count, durationsMs: durations.compactMap { $0 })
    }

    /// Item duration, when every part's length is known.
    var totalDurationMs: Int? { durationsMs?.reduce(0, +) }

    /// Item-level start of a part; 0 when the lengths are unknown.
    func startMs(ofPart index: Int) -> Int {
        guard let durationsMs, index > 0 else { return 0 }
        return durationsMs.prefix(min(index, durationsMs.count)).reduce(0, +)
    }

    func isLastPart(_ index: Int) -> Bool { index >= partCount - 1 }

    /// Whether a part's position can be reported to Plex as the item's. Without
    /// known lengths only the first part's time is item time: a later part's
    /// position would be resumed inside the first part.
    func reportsItemPosition(forPart index: Int) -> Bool { durationsMs != nil || index == 0 }

    /// The part holding an item-level offset and the offset inside it. Without
    /// known lengths the offset cannot be placed, so it stays on the first
    /// part; an offset past the end lands on the last part's end.
    func locate(itemOffsetMs: Int) -> (index: Int, offsetMs: Int) {
        guard let durationsMs else { return (0, itemOffsetMs) }
        var start = 0
        for (index, duration) in durationsMs.enumerated() {
            if itemOffsetMs < start + duration || index == durationsMs.count - 1 {
                return (index, min(max(itemOffsetMs - start, 0), duration))
            }
            start += duration
        }
        return (0, itemOffsetMs)
    }

    /// Plex markers are item-level; the player works in the current part's
    /// time. Markers outside the part are dropped, ones crossing its edge are
    /// clamped, and credits only count on the last part.
    func markers(_ markers: [PlexMarker], forPart index: Int) -> [PlexMarker] {
        guard let durationsMs, index < durationsMs.count else {
            return index == 0 ? markers : []
        }
        let start = startMs(ofPart: index)
        let duration = durationsMs[index]
        return markers.compactMap { marker in
            if marker.isCredits && !isLastPart(index) { return nil }
            let shiftedStart = max(marker.startTimeOffset - start, 0)
            let shiftedEnd = min(marker.endTimeOffset - start, duration)
            guard shiftedEnd > shiftedStart else { return nil }
            return PlexMarker(
                id: marker.id,
                type: marker.type,
                startTimeOffset: shiftedStart,
                endTimeOffset: shiftedEnd,
                final: marker.final,
                isEstimated: marker.isEstimated
            )
        }
    }
}

extension PlaybackDebugInfo {
    /// The stacked-part position of this playback; nil for single-part media
    /// and local downloads (which hold one part).
    var stackedPart: (timeline: PlexPartTimeline, index: Int)? {
        if case .localDownload = decision { return nil }
        guard let timeline = PlexPartTimeline(media: media) else { return nil }
        return (timeline, media.parts.firstIndex { $0.id == part.id } ?? 0)
    }
}
