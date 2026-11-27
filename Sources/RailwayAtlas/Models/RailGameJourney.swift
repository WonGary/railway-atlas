import Foundation
import RailwayCore

/// A game sends the public trip identity and its selected interval, never map coordinates.
struct RailGameJourney: Decodable, Sendable {
    let train: String, trip: String, origin: String
    let from: Int, to: Int
    let first: String, last: String
    let departure: Int, arrival: Int

    func resolve(using paths: NationalJourneyPaths = .shared) async throws -> (RailTimetable, RailTrackJourney) {
        guard RailCivilDate.valid(origin), train.count <= 40, trip.count <= 40,
              first.count <= 80, last.count <= 80, 0 <= from, from < to, to < 250,
              let full = try await paths.timetable(train: train, date: origin, from: first, to: last),
              full.id == "national:\(trip):\(origin)", full.stops.indices.contains(to),
              full.stops[from].station == first, full.stops[to].station == last,
              full.stops[from].departure == departure, full.stops[to].arrival == arrival
        else { throw DataError.invalid("本机径路库与题目的车次、日期或区间不符。") }
        // Slice before checking the geometry. A gap outside the player's interval is irrelevant.
        let timetable = try full.passengerSection(from: first, to: last)
        guard let route = try await paths.journey(full, from: first, to: last) else {
            throw DataError.invalid("本机尚未收录这段径路。")
        }
        try route.validate(for: timetable)
        return (timetable, route)
    }
}
