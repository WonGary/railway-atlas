import Foundation
import RailwayCore

enum ExperienceChecks {
    static func run() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw DataError.invalid("Experience: \(message)") }
            count += 1
        }
        func rejects(_ message: String, _ operation: () throws -> Void) throws {
            do { try operation() }
            catch { count += 1; return }
            throw DataError.invalid("Experience accepted invalid input: \(message)")
        }
        try check(RailCivilDate.valid("2024-02-29"), "leap day rejected")
        for date in ["2025-02-29", "2026-04-31", "2026-13-01", "2026-1-01", "26-11-08", "2026-11-00"] {
            try check(!RailCivilDate.valid(date), "invalid civil date \(date)")
        }
        try check(RailCivilDate.minute("23:59") == 1439, "24-hour clock")
        try check(RailCivilDate.minute("24:00") == nil && RailCivilDate.minute("09:61") == nil, "invalid clock accepted")
        try check(RailCivilDate.validHistorical("2018-09") && !RailCivilDate.validHistorical("2018-13"), "month precision")
        let trains = try RailExperienceCatalog.timetables()
        let train = trains.first!
        try check(train.train == "G6580" && train.stops.count == 9 && train.serviceDate == "2026-11-08", "bundled snapshot")
        try check(train.start == 964 && train.end == 1093, "published endpoints")
        try check(train.position(at: 978 * 60).phase == .dwelling, "arrival boundary must start dwell")
        try check(train.position(at: 980 * 60 - 0.01).phase == .dwelling, "dwell ended prematurely")
        try check(train.position(at: 980 * 60).phase == .running, "departure boundary must begin running")
        try check(train.position(at: 988 * 60).from == 2, "next stop boundary")
        try check(train.position(at: 1000 * 60 + 4 * 60).phase == .dwelling, "five-minute stop was shortened")
        try check(train.position(at: 1093 * 60).phase == .arrived, "arrival did not end simulation")
        try check(train.position(at: 0).phase == .waiting, "predeparture state")
        try check(train.position(at: .nan).phase == .unknown, "invalid animation input")
        let half = train.position(at: Double((980 + 988) * 30))
        try check(half.from == 1 && half.to == 2 && abs(half.fraction - 0.5) < 0.00001, "between-stop interpolation")
        var night = train
        night.id = "synthetic-clock-test"
        night.stops = [.init("A", arrival: nil, departure: 1430),
                       .init("B", arrival: 1450, departure: 1455),
                       .init("C", arrival: 1500, departure: nil)]
        try night.validate()
        try check(night.position(at: 1452 * 60).phase == .dwelling, "overnight dwell")
        try check(RailTimetable.clock(1452 * 60) == "D+1 00:12:00", "day rollover")
        try check(RailTimetable.clock(2 * 86400 + 65) == "D+2 00:01:05", "multiple-day rollover")
        var missing = night
        missing.stops[1].departure = nil
        try missing.validate()
        try check(!missing.hasCompleteDwellTimes && missing.position(at: 1452 * 60).phase == .unknown,
                  "missing departure invented dwell")
        var bad = night; bad.stops[1].arrival = 100
        try rejects("descending time") { try bad.validate() }
        bad = night; bad.timeZone = "invalid"
        try rejects("invalid time zone") { try bad.validate() }
        bad = night; bad.stops[1].arrival = 1430
        try rejects("zero travel interval") { try bad.validate() }
        let history = try RailExperienceCatalog.history()
        try check(history.count >= 8, "historical evidence catalog missing")
        try check(history.allSatisfy { RailCivilDate.validHistorical($0.date) }, "invalid event precision")
        try check(history.first?.date == "1952-07-01", "event sorting")
        try check(history.contains { $0.date == "2018-09" }, "month-only source promoted to exact date")
        let csv = "\u{FEFF}date,train,from,to,departure,note\r\n2026-11-08,G6580,香港西九龙,肇庆东,16:04,\"一段,有逗号\r\n和\"\"引号\"\"的文字\"\r\n"
        let rows = try JourneyImport.csv(csv)
        try check(rows.count == 1 && rows[0].note == "一段,有逗号\n和\"引号\"的文字", "quoted CSV")
        try check(rows[0].status == .needsReview && rows[0].validationMessage == nil, "CSV falsely confirmed boarding")
        let chinese = try JourneyImport.csv("日期,出发站,到达站,车次\n2024-02-29,北京,天津,C1\n")
        try check(chinese[0].date == "2024-02-29" && chinese[0].train == "C1", "localized CSV headers")
        for csv in ["date,from,to\n\"2020-01-01,A,B", "date,date,to\n1,2,3",
                    "date,from,to\n2020-01-01,A,B,extra", "date,from,to\n\"2020-01-01\"x,A,B"] {
            try rejects("CSV field misalignment") { _ = try JourneyImport.csv(csv) }
        }
        let parsed = JourneyImport.text("2026年11月8日 16:04 G6580次 香港西九龙→肇庆东")
        try check(parsed.count == 1 && parsed[0].date == "2026-11-08" && parsed[0].train == "G6580"
                  && parsed[0].from == "香港西九龙" && parsed[0].to == "肇庆东"
                  && parsed[0].departure == "16:04", "text extraction")
        try check(parsed[0].status == .needsReview, "text import asserted boarding")
        let incomplete = JourneyImport.text("11月8日 G6580次 香港西九龙→肇庆东")
        try check(incomplete[0].date.isEmpty && incomplete[0].validationMessage != nil, "missing year was invented")
        var journey = rows[0]
        journey.status = .travelled
        let archive = RailJourneyArchive(journeys: [journey])
        let restored = try RailJourneyArchive.decode(archive.encode())
        try check(restored.journeys == [journey], "passport backup roundtrip")
        try rejects("duplicate record UUIDs") { _ = try RailJourneyArchive.decode(RailJourneyArchive(journeys: [journey, journey]).encode()) }
        var invalid = journey; invalid.date = "2025-02-29"
        try rejects("invalid archived date") { _ = try RailJourneyArchive.decode(RailJourneyArchive(journeys: [invalid]).encode()) }
        invalid = journey; invalid.departure = "24:10"
        try check(invalid.validationMessage != nil, "invalid user time")
        let geometry = [[Coordinate(31, 120), Coordinate(31.1, 120.1), Coordinate(31.2, 120)]]
        let silhouette = RailSilhouette(coordinates: geometry, rotation: .pi / 2)
        let shapeData = try JSONEncoder().encode(silhouette)
        let shapeJSON = String(decoding: shapeData, as: UTF8.self)
        try check(!shapeJSON.contains("latitude") && !shapeJSON.contains("longitude")
                  && !shapeJSON.contains("name") && !shapeJSON.contains("color") && !shapeJSON.contains("id"),
                  "quiz renderer leaked metadata")
        try check(silhouette.paths.flatMap { $0 }.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) },
                  "shape not normalized")
        try check(RailSilhouette(coordinates: []).paths.isEmpty, "empty shape")
        print("PASS \(count) experience checks: published timetable, dwell/overnight boundaries, incomplete data, CSV/OCR candidates, passport roundtrip, source precision and anonymous geometry.")
    }
}
