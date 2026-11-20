import Foundation
import RailwayCore

enum ExperienceExpansionChecks {
    static func run() throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw DataError.invalid("Expansion: \(message)") }
        }
        let train = try RailExperienceCatalog.timetables()[0]
        let routes = try RailTrackJourney.bundled()
        try require(routes.count == 2 && routes.contains { $0.train == "G337" && $0.legs.count == 6
            && $0.stations.first == "北京西" && $0.stations.last == "南昌西" }, "bundled track journey missing")
        let route = routes[0]
        try route.validate(for: train)
        try require((210_000...225_000).contains(route.distance), "G6580 corridor length")
        let stationPoints = [
            Coordinate(22.3036146, 114.1654275), Coordinate(22.5415741, 114.0513039),
            Coordinate(22.6120301, 114.0239239), Coordinate(22.7349804, 113.9495555),
            Coordinate(22.8632846, 113.6682415), Coordinate(22.9911876, 113.2637215),
            Coordinate(23.0819426, 113.0283737), Coordinate(23.1158044, 112.8659184),
            Coordinate(23.2170440, 112.6578780)
        ]
        for i in train.stops.indices {
            let time = Double((train.stops[i].arrival ?? train.stops[i].departure!) * 60)
            let point = route.coordinate(at: train.position(at: time))
            try require(point.map { RailTrackJourney.metres($0, stationPoints[i]) < 80 } ?? false,
                        "station coordinate mismatch: \(train.stops[i].station)")
        }
        for i in 1..<train.stops.count - 1 {
            let arrival = Double(train.stops[i].arrival! * 60)
            let point = route.coordinate(at: train.position(at: arrival))
            try require(point == route.coordinate(at: train.position(at: arrival + 30)), "train moves while dwelling")
        }
        let curved = [Coordinate(0, 0), Coordinate(0, 0.01), Coordinate(0.01, 0.01)]
        try require(RailTrackJourney.interpolate(curved, fraction: 0.5) == curved[1], "interpolation cut the corner")
        var broken = route; broken.legs[0] = [Coordinate(0, 0), Coordinate(1, 1)]
        do { try broken.validate(for: train); throw DataError.invalid("gap accepted") }
        catch let error as DataError {
            try require(error.localizedDescription != "gap accepted", "disconnected route accepted")
        }
        let regions = try RailHistoricalGeometry.bundled()
        try require(regions.count >= 4, "dated geometry coverage missing")
        let hk = regions.first { $0.id == "hongkong" }!
        try require(hk.segments.filter { $0.opened != nil }.count > 800, "way dates missing")
        try require(hk.segments.allSatisfy { $0.id.hasPrefix("way/") }, "relation date applied to track")
        try require(hk.segments.filter { $0.visible(on: "1980-12-31") }.count
                    < hk.segments.filter { $0.visible(on: "2026-11-08") }.count, "timeline fails to accumulate")
        try require(hk.segments.filter { $0.opened == nil }.allSatisfy { !$0.visible(on: "2026-11-08") }, "unknown dates shown as history")
        try require(RailDatedSegment.upperBound("2024-02") == "2024-02-29", "month precision leap day")
        try require(RailDatedSegment.upperBound("1980") == "1980-12-31", "year precision")

        // Independent synthetic provider fixture exercises the nonstandard
        // base-255 IDs above 255, base-128 civil dates and midnight stop times.
        func dictionary(_ items: [String]) -> Data {
            var b: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 255)]
            for text in items {
                let bytes = Array(text.utf8)
                b += [UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
            }
            return Data(b)
        }
        let names = (0..<300).map { "G\($0)" }
        let stations = (0..<300).map { "站" + String(UnicodeScalar(0x4e00 + $0)!) }
        func base255(_ value: Int) -> [UInt8] { [UInt8(value / 255), UInt8(value % 255)] }
        func date(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (7 * $0)) & 127) } }
        var block: [UInt8] = []
        for i in 0..<300 {
            block += base255(i) + [6, 0, 0] + date(20261101) + date(20261130) + [0, 0, 0, 3]
            block += base255(1) + [23, 50, 0] + base255(0)
            block += base255(257) + [0, 10, 5] + base255(256)
            block += base255(299) + [1, 0, 0] + base255(500)
        }
        let resources = ["res/trains": dictionary(names), "res/stations": dictionary(stations),
                         "res/version.txt": Data("20261114".utf8), "res/schedule.dat": Data(block)]
        let decoded = try LuluTimetableSnapshot.decodeResources(resources, retrievedOn: "2026-11-08")
        try require(decoded.services.count == 300 && decoded.stationCount == 300, "complete offline library")
        let last = try decoded.services[299].timetable(on: "2026-11-08", edition: decoded.edition)
        try require(last.train == "G299" && last.stops[1].station == stations[257], "base-255 IDs")
        try require(last.stops[1].arrival == 1450 && last.stops[1].departure == 1455 && last.end == 1500, "midnight decoding")
        try require(decoded.edition == "2026-11-14" && decoded.retrievedOn == "2026-11-08", "future edition relabelled as fetch date")
        var truncated = resources; truncated["res/schedule.dat"] = Data(block.dropLast())
        do {
            _ = try LuluTimetableSnapshot.decodeResources(truncated, retrievedOn: "2026-11-08")
            throw DataError.invalid("partial accepted")
        } catch let error as DataError {
            try require(error.localizedDescription != "partial accepted", "truncated library accepted")
        }
        print("PASS expansion: 8 continuous G6580 legs, distance-based playback, all dwell points, way-level construction timeline, precision/unknown dates, complete LLT resource decoding, midnight/base255/base128 and truncation rejection.")
    }
}
