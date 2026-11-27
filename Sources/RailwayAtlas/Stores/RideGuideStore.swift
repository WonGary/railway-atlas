import MapKit
import RailwayCore
import SwiftUI

@MainActor
final class RideGuideStore: ObservableObject {
    enum CameraMode { case train, sightseeing }
    @Published private(set) var camera: CameraMode = .train
    @Published private(set) var zoomLocked = false
    @Published private(set) var chain: [String] = []
    private(set) var lockedSpan: MKCoordinateSpan?
    private(set) var session = UUID()
    private(set) var activeTrip: String?
    private(set) var origin = ""
    private var pending = UUID()
    let catalog = JourneyGuideCatalog()
    static let kinds = [("station","铁路车站"),("hub","铁路交汇站"),("city","城市"),
                        ("metro","城轨站"),("landmark","桥隧"),("history","建设记录")]

    func reset(_ table: RailTimetable? = nil) {
        session = UUID(); pending = UUID()
        camera = .train; setLock(nil); chain = []
        let id = table?.id.components(separatedBy: "/section/").first ?? ""
        let pieces = id.components(separatedBy: ":")
        let isNational = pieces.count >= 3 && ["board","national"].contains(pieces[0])
        activeTrip = isNational ? pieces[1] : nil
        origin = isNational ? pieces[2] : table?.serviceDate ?? ""
    }

    func setLock(_ span: MKCoordinateSpan?) { lockedSpan = span; zoomLocked = span != nil }
    func selectCamera(_ value: CameraMode) { camera = value }

    func connections(_ player: RailMapPlayback, stop index: Int, hours: Int) async throws -> [RideConnection] {
        guard let table = player.timetable, player.mode == .train else { return [] }
        return try await catalog.connections(timetable: table, activeTrip: activeTrip, origin: origin,
            index: index, seconds: player.seconds, hours: hours, local: player.playbackMap?.journeyWorkspace.library.lulu)
    }

    func invalidateBoarding() { pending = UUID() }
    func advanced() { session = UUID(); invalidateBoarding() }

    func board(_ c: RideConnection, at index: Int, through end: Int, player: RailMapPlayback) async throws {
        guard let old = player.timetable, player.mode == .train, old.stops.indices.contains(index),
              let arrival = old.stops[index].arrival, let destination = c.destinations.first(where: { $0.index == end }),
              let day = RailCivilDate.addingDays(arrival / 1440, to: old.serviceDate) else {
            throw DataError.invalid("所选接力站或到达时刻已变化")
        }
        let request = UUID(), generation = session, station = old.stops[index].station
        pending = request
        func checkTime() throws {
            try Task.checkCancellation()
            guard session == generation, pending == request, player.mode == .train,
                  index == old.stops.count-1 || player.seconds <= Double(old.stops[index].departure ?? -1) * 60,
                  Int(ceil(player.seconds/60)) <= arrival + c.wait else {
                throw DataError.invalid("换乘时间或车次已变化，请重新查询")
            }
        }
        try checkTime()
        guard end > c.boardIndex else { throw DataError.invalid("下车站须在上车站之后") }
        let bounds = c.boardIndex...end
        let section: RailTimetable, track: RailTrackJourney
        if c.source == "local" {
            guard let workspace = player.playbackMap?.journeyWorkspace, let db = workspace.library.lulu,
                  let row = db.services.first(where: { "local/\(db.edition)/\($0.id)" == c.trip }) else {
                throw DataError.invalid("离线库已更换，请重新查找车次")
            }
            let full = try db.timetable(row, on: c.origin)
            section = try full.passengerSection(indices: bounds)
            if let known = try? await NationalJourneyPaths.shared.journey(full, from: station, to: destination.name) {
                try known.validate(for: section); track = known
            } else {
                track = try await workspace.prepareRoute(section, retryMissing: true)
            }
        } else {
            (section,track) = try await NationalJourneyPaths.shared.relaySection(train: c.train, origin: c.origin, trip: c.trip, indices: bounds)
        }
        try checkTime()
        guard section.stops.first?.station == station, section.start == c.departure % 1440,
              section.serviceDate == c.boardDate, section.stops.last?.station == destination.name,
              section.end == destination.arrival - (c.departure / 1440) * 1440 else {
            throw DataError.invalid("该排图的乘车区间或时刻与所选班次不符")
        }
        let completed = chain + ["\(old.train)　\(old.stops[0].station) → \(station)　\(day) \(RailTimetable.clock(Double(arrival % 1440 * 60), includeSeconds: false))"]
        let mode = camera, span = lockedSpan, following = player.follow
        try player.start(section, route: track, continuing: true)
        chain = completed; activeTrip = c.trip; origin = c.origin
        selectCamera(mode); setLock(span); player.follow = following
    }
}
