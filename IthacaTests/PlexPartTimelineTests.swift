import Foundation
import Testing
@testable import Ithaca

@Suite("Stacked part timeline")
struct PlexPartTimelineTests {
    private let timeline = PlexPartTimeline(partCount: 3, durationsMs: [1000, 2000, 500])

    @Test func itemOffsetMapsToPartAndOffsetInPart() {
        #expect(timeline.locate(itemOffsetMs: 0) == (0, 0))
        #expect(timeline.locate(itemOffsetMs: 999) == (0, 999))
        #expect(timeline.locate(itemOffsetMs: 1000) == (1, 0))
        #expect(timeline.locate(itemOffsetMs: 2500) == (1, 1500))
        #expect(timeline.locate(itemOffsetMs: 3200) == (2, 200))
        #expect(timeline.locate(itemOffsetMs: 9000) == (2, 500))
        #expect(timeline.totalDurationMs == 3500)
        #expect(timeline.startMs(ofPart: 2) == 3000)
    }

    @Test func unknownLengthsKeepTheOffsetOnTheFirstPart() {
        let unknown = PlexPartTimeline(partCount: 2, durationsMs: nil)
        #expect(unknown.locate(itemOffsetMs: 5000) == (0, 5000))
        #expect(unknown.totalDurationMs == nil)
        #expect(unknown.startMs(ofPart: 1) == 0)
    }

    @Test func withoutLengthsOnlyTheFirstPartReportsItemPosition() {
        let unknown = PlexPartTimeline(partCount: 2, durationsMs: nil)
        #expect(unknown.reportsItemPosition(forPart: 0))
        #expect(!unknown.reportsItemPosition(forPart: 1))
        #expect(timeline.reportsItemPosition(forPart: 2))
    }

    @Test func markersMapIntoThePartAndDropOutsideOnes() {
        let intro = PlexMarker(id: 1, type: "intro", startTimeOffset: 1200, endTimeOffset: 1800)
        let crossing = PlexMarker(id: 2, type: "intro", startTimeOffset: 800, endTimeOffset: 1400)
        let credits = PlexMarker(id: 3, type: "credits", startTimeOffset: 3100, endTimeOffset: 3500)
        let all = [intro, crossing, credits]

        let second = timeline.markers(all, forPart: 1).map { [$0.id, $0.startTimeOffset, $0.endTimeOffset] }
        #expect(second == [[1, 200, 800], [2, 0, 400]])
        let first = timeline.markers(all, forPart: 0).map { [$0.id, $0.startTimeOffset, $0.endTimeOffset] }
        #expect(first == [[2, 800, 1000]])
        let last = timeline.markers(all, forPart: 2).map { [$0.id, $0.startTimeOffset, $0.endTimeOffset] }
        #expect(last == [[3, 100, 500]])
    }
}

@Suite("Stacked part durations")
struct PlexPartDurationEstimateTests {
    @Test func knownDurationsSurviveAnEstimateForTheMissingPart() throws {
        let json = """
        {"id":1,"Part":[
          {"id":1,"key":"/p/1","size":100,"duration":1800000},
          {"id":2,"key":"/p/2","size":100}
        ],"duration":5400000}
        """
        let media = try JSONDecoder().decode(PlexMedia.self, from: Data(json.utf8))
        let timeline = try #require(PlexPartTimeline(media: media))
        #expect(timeline.durationsMs == [1_800_000, 3_600_000])
        #expect(timeline.locate(itemOffsetMs: 2_400_000) == (1, 600_000))
    }
}
