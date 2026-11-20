import Foundation
import RailwayCore

enum JourneyRouteChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw DataError.invalid("Journey routing: " + message) }
    }
    static func run() throws {
        let full = try RailTrackJourney.bundled()[0]
        let slice = try full.slice(from: "深圳北", to: "佛山西")
        try require(slice.stations == ["深圳北", "光明城", "虎门", "广州南", "佛山西"], "passenger slice retained non-ridden stops")
        try require(slice.legs == Array(full.legs[2..<6]), "passenger slice changed actual track geometry")
        try require(slice.distance < full.distance, "passenger slice returned whole service")
        for (from, to) in [("佛山西", "深圳北"), ("深圳北", "深圳北"), ("不存在", "佛山西")] {
            do { _ = try full.slice(from: from, to: to); throw DataError.invalid("invalid slice accepted") }
            catch { try require(error.localizedDescription != "invalid slice accepted", "reversed or unknown endpoints accepted") }
        }
        try require(RailCivilDate.addingDays(-1, to: "2026-01-01") == "2025-12-31", "boarding-date year rollover")
        try require(RailCivilDate.addingDays(1, to: "2024-02-28") == "2024-02-29", "boarding-date leap day")
        try require(LuluRouteDatabase.trainNames("G1234/1") == Set(["G1234", "G1231"]), "abbreviated train aliases")
        try require(RailJourneyMatcher.normalized("香港西九龍 Hong Kong West Kowloon") == "香港西九龙", "traditional station alias")
        print("PASS passenger slicing: exact source geometry, middle boarding/alighting, wrong direction/same station/missing station rejection, date rollover and train/station aliases.")
    }

    static func real(snapshot: String, routing: String, geometry: String, output: String) throws {
        var library = try LuluTimetableSnapshot.read(Data(contentsOf: URL(fileURLWithPath: snapshot)))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: routing))
        let database = try LuluRouteDatabase.decode(bytes)
        library.routing = database
        try require(database.lines.count == 796 && database.routes.count == 14997, "provider resource counts changed")
        for data in [Data(bytes.dropLast()), Data(bytes.prefix(100))] {
            do { _ = try LuluRouteDatabase.decode(data); throw DataError.invalid("truncated routing accepted") }
            catch { try require(error.localizedDescription != "truncated routing accepted", "truncation not rejected") }
        }
        var invalid = database; invalid.routes[0].parts[0].lineID = 999999
        do { try invalid.validate(); throw DataError.invalid("invalid reference accepted") }
        catch { try require(error.localizedDescription != "invalid reference accepted", "bad line reference") }
        for name in ["G1", "G101", "T109", "G6580"] {
            guard let service = library.services.first(where: { $0.train == name }) else { throw DataError.invalid("missing sample") }
            let train = try library.timetable(service, on: "2026-11-09")
            let plan = train.routing!
            for (i, index) in plan.stopIndices.enumerated() {
                try require(plan.nodes[index].kilometre == service.kilometreMarks[i], "\(name) mileage at stop \(i)")
            }
            print("PASS \(name): \(plan.providerID), \(plan.nodes.count) routing nodes, all stop mileages match.")
        }
        struct Features: Decodable { var lines: [RailLine]; var stations: [RailStation] }
        let decoded = try JSONDecoder().decode(Features.self, from: Data(contentsOf: URL(fileURLWithPath: geometry)))
        var features = RailTileFeatures(); features.lines = decoded.lines; features.stations = decoded.stations
        let service = library.services.first { $0.train == "G6580" }!
        let overnightService = library.services.first { $0.train == "T109" }!
        let overnight = try library.timetable(overnightService, on: "2026-11-09").passengerSection(from: "徐州", to: "南京")
        try require(overnight.serviceDate == "2026-11-10" && overnight.start == 251, "overnight passenger section date/time")
        try require(overnight.routing?.nodes.first?.kilometre == 0, "passenger section mileage not rebased")
        let train = try library.timetable(service, on: "2026-11-09")
        let route = try RailJourneyMatcher.match(train, features: features)
        try route.validate(for: train)
        try require(route.legs.count == 8 && (210_000...225_000).contains(route.distance), "real graph matching distance")
        let slice = try route.slice(from: "深圳北", to: "佛山西")
        try require(slice.legs == Array(route.legs[2..<6]), "live matched slice does not preserve legs")
        let section = try train.passengerSection(from: "深圳北", to: "佛山西")
        try require(section.routing?.nodes.first?.station == "深圳北" && section.routing?.nodes.last?.station == "佛山西",
                    "passenger plan retained outside nodes")
        let partial = try RailJourneyMatcher.match(section, features: features)
        try require(partial.legs == slice.legs, "matching just the passenger segment changes the route")
        for name in ["G6201", "G6205"] {
            let other = library.services.first { $0.train == name }!
            let reverse = try library.timetable(other, on: "2026-11-09")
            let geometry = try RailJourneyMatcher.match(reverse, features: features)
            try geometry.validate(for: reverse)
            try require(geometry.stations.first == "广州南" && geometry.stations.last == "深圳北"
                        && (98_000...108_000).contains(geometry.distance), "reverse train or different stopping pattern failed")
            print("PASS \(name): independent imported train, opposite direction, \(geometry.legs.count) scheduled legs, \(Int(geometry.distance)) m.")
        }
        var withoutTracks = features; withoutTracks.lines = []
        do { _ = try RailJourneyMatcher.match(section, features: withoutTracks); throw DataError.invalid("missing track accepted") }
        catch { try require(error.localizedDescription != "missing track accepted", "missing track replaced by straight line") }
        var wrong = service; wrong.kilometreMarks[4] += 30
        do { _ = try database.plan(for: wrong, edition: library.edition); throw DataError.invalid("wrong mileage accepted") }
        catch { try require(error.localizedDescription != "wrong mileage accepted", "wrong mileage should reject route revision") }
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(library)
        _ = try LuluTimetableSnapshot.read(data)
        try data.write(to: folder.appendingPathComponent("lulutong-with-routes.json"), options: .atomic)
        try JSONEncoder().encode(route).write(to: folder.appendingPathComponent("matched-g6580.json"), options: .atomic)
        try JSONEncoder().encode(slice).write(to: folder.appendingPathComponent("passenger-segment.json"), options: .atomic)
        print("PASS real offline data: \(library.services.count) services + \(database.routes.count) routings; G6580 \(Int(route.distance))m; passenger slice \(Int(slice.distance))m. Snapshot round-trip, malformed resource/reference and mismatched mileage rejected.")
    }
}
