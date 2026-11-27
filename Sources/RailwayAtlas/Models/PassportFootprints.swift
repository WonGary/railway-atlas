import Foundation
import RailwayCore

enum PassportActivityKind: String, Codable, CaseIterable {
    case browsed, simulated
    var title: String { self == .browsed ? "浏览" : "模拟" }
}

struct PassportActivity: Identifiable, Codable {
    enum Subject: Codable {
        case segment(RailJourney)
        case feature(key: String, name: String, station: Bool)
    }
    var id = UUID()
    let kind: PassportActivityKind
    let subject: Subject
    var opened = Date()

    var key: String {
        switch subject {
        case .segment(let journey): "\(kind.rawValue)/segment/\(journey.duplicateKey)"
        case .feature(let key, _, let station): "\(kind.rawValue)/\(station ? "station" : "line")/\(key)"
        }
    }

    var candidate: RailJourney? {
        guard case .segment(let journey) = subject else { return nil }
        return Self.pending(journey, source: "\(kind.title)区间")
    }

    static func pending(_ input: RailJourney, source: String) -> RailJourney {
        var result = RailJourney(date: input.date, train: input.train, from: input.from, to: input.to,
                                 departure: input.departure, status: .needsReview, source: source)
        result.timetable = input.timetable
        return result
    }

    static func segment(_ timetable: RailTimetable, from: String, to: String) throws -> RailJourney {
        let section = try timetable.passengerSection(from: from, to: to)
        var result = RailJourney(date: section.serviceDate, train: section.train, from: from, to: to,
                                 departure: RailTimetable.clock(Double(section.start * 60), includeSeconds: false),
                                 source: "车次区间")
        result.timetable = timetable
        return result
    }
}

struct PassportFootprint {
    struct Section: Identifiable {
        let journey: RailJourney
        let legs: [[Coordinate]]
        let metres: Double
        var id: UUID { journey.id }
    }
    struct Missing: Identifiable {
        let journey: RailJourney
        let reason: String
        var id: UUID { journey.id }
    }
    let confirmed: [RailJourney]
    var sections: [Section] = []
    var missing: [Missing] = []
    var metres: Double { sections.reduce(0) { $0 + $1.metres } }
    var stations: [String] { Set(confirmed.flatMap { [$0.from, $0.to] }).sorted() }

    @MainActor
    static func load(_ records: [RailJourney], reusing previous: Self? = nil,
                     route: (RailJourney) async throws -> RailTrackJourney) async throws -> Self {
        var result = Self(confirmed: records.filter { $0.status == .travelled })
        let cached = Dictionary(uniqueKeysWithValues: (previous?.sections ?? []).map { ($0.id, $0) })
        for journey in result.confirmed {
            try Task.checkCancellation()
            if let section = cached[journey.id], section.journey == journey {
                result.sections.append(section)
                continue
            }
            do {
                let track = try await route(journey)
                guard track.stations.first == journey.from, track.stations.last == journey.to,
                      track.legs.count == track.stations.count - 1, !track.legs.isEmpty else {
                    throw DataError.invalid("径路的上下车站与记录不符")
                }
                // Measure the original geometry. Only the drawing uses the smaller copy.
                let section = await Task.detached(priority: .utility) {
                    Section(journey: journey, legs: track.legs.map(Self.displayLeg), metres: track.distance)
                }.value
                result.sections.append(section)
            } catch {
                try Task.checkCancellation()
                result.missing.append(.init(journey: journey, reason: error.localizedDescription))
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func displayLeg(_ points: [Coordinate]) -> [Coordinate] {
        guard points.count > 2, let last = points.last else { return points }
        var kept = [points[0]]
        for point in points.dropFirst().dropLast() where RailTrackJourney.metres(kept[kept.count - 1], point) >= 100 {
            kept.append(point)
        }
        kept.append(last)
        return kept
    }

    struct Stamp: Identifiable {
        let id: String, name: String, detail: String, icon: String
    }
    var stamps: [Stamp] {
        guard !confirmed.isEmpty else { return [] }
        var result = [Stamp(id: "first", name: "初次出发", detail: "第一段已确认的乘车记录", icon: "ticket")]
        for km in [100, 1_000, 10_000] where metres >= Double(km) * 1000 {
            result.append(Stamp(id: "km/\(km)", name: "\(km) 公里", detail: "累计实乘轨道里程", icon: "ruler"))
        }
        for station in stations {
            result.append(Stamp(id: "station/\(station)", name: station, detail: "实乘上下车站", icon: "tram"))
        }
        return result
    }
}
