import Foundation
import JavaScriptCore

public struct RidePlace: Decodable, Identifiable, Sendable {
    public let id, kind, name, note, source, url: String
    public let lat, lon: Double
    public let metres, track: Int
}

public struct RideConnection: Decodable, Identifiable, Sendable {
    public struct Destination: Decodable, Identifiable, Sendable {
        public let name: String
        public let index, arrival: Int
        public var id: Int { index }
    }
    public let id, train, trip, origin, boardDate, source: String
    public let boardIndex, departure, wait, absolute: Int
    public let destinations: [Destination]
}

/// The bundled board and corridor filter are shared with the web player.
/// The context, national board and spatial index belong to this actor. No web view or network.
public actor JourneyGuideCatalog {
    private let directory: URL
    private var context: JSContext?
    private var session: JSValue?
    private var hasPlaces = false
    private var geometryKey: UUID?

    public init(directory: URL? = nil) {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Web/station-directory")
        let bundle = Bundle.main.resourceURL?.appendingPathComponent("station-directory")
        self.directory = directory ?? (bundle.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? checkout)
    }

    private func open() throws {
        if session != nil { return }
        guard let js = JSContext() else { throw DataError.invalid("无法打开本机沿线资料") }
        for file in ["catalog.js", "national.js", "journey-guide-core.js"] {
            let url = directory.appendingPathComponent(file)
            js.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
            if let error = js.exception { throw DataError.invalid(error.toString()) }
        }
        let instance = js.evaluateScript("""
            (() => {
              const directory=globalThis.atlasRailDirectory, catalog=StationCatalog.national(directory);
              let places, legs;
              return {
                setPlaces(text) {places=new JourneyGuideCore.Places(JSON.parse(text),directory,catalog);},
                setLegs(text) {legs=JSON.parse(text);},
                nearby(i,y,x,kinds) {return JSON.stringify(places.nearby(legs,i,[y,x],kinds));},
                connections(text,i,seconds,active,hours,local) {
                  const table=JSON.parse(text), arrival=JourneyGuideCore.arrival(table,i,seconds);
                  active.stops=table.stops; active.tableDate=table.serviceDate;
                  const extras=JSON.parse(local);
                  const board=(name,date)=>catalog.board(name,date).concat(extras.filter(r=>r.date===date)
                    .map(r=>({...r,source:"local",detail:()=>({id:r.trip,number:r.train,stops:r.stops})})));
                  return JSON.stringify(JourneyGuideCore.transfers(arrival,active,board,hours));
                }
              };
            })()
            """)
        guard let instance, js.exception == nil else { throw DataError.invalid("读取沿线工具失败") }
        context = js
        session = instance
    }

    @discardableResult private func call(_ method: String, _ args: [Any]) throws -> JSValue {
        try open()
        context?.exception = nil
        let result = session?.invokeMethod(method, withArguments: args)
        if let error = context?.exception { throw DataError.invalid(error.toString()) }
        guard let result else { throw DataError.invalid("沿线资料没有返回结果") }
        return result
    }

    private func decoded<T: Decodable>(_ method: String, _ args: [Any]) throws -> T {
        let text = try call(method,args).toString() ?? ""
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    public func nearby(route: RailTrackJourney, session key: UUID, leg: Int, coordinate: Coordinate, kinds: [String]) throws -> [RidePlace] {
        try Task.checkCancellation()
        if !hasPlaces {
            try call("setPlaces", [String(contentsOf: directory.appendingPathComponent("journey-places.json"), encoding: .utf8)])
            hasPlaces = true
        }
        if geometryKey != key {
            let coords = route.legs.map { $0.map { [$0.latitude,$0.longitude] } }
            try call("setLegs",[String(decoding: try JSONEncoder().encode(coords), as: UTF8.self)])
            geometryKey = key
        }
        try Task.checkCancellation()
        return try decoded("nearby",[leg,coordinate.latitude,coordinate.longitude,kinds])
    }

    public func connections(timetable: RailTimetable, activeTrip: String?, origin: String,
                            index: Int, seconds: Double, hours: Int, local: LuluTimetableSnapshot? = nil) throws -> [RideConnection] {
        guard timetable.stops.indices.contains(index), let eta = timetable.stops[index].arrival,
              seconds.isFinite, (0...Double(14 * 86400)).contains(seconds), [6,24].contains(hours) else { return [] }
        try Task.checkCancellation()
        let station = timetable.stops[index].station, earliest = max(eta, Int(ceil(seconds / 60)))
        let args: [String:Any] = ["train": timetable.train, "numbers": Array(LuluRouteDatabase.trainNames(timetable.train)),
                                  "source":activeTrip?.hasPrefix("local/") == true ? "local" : "national",
                                  "origin": origin, "trip": activeTrip as Any? ?? NSNull()]
        var extras: [[String:Any]] = []
        if let local {
            let days = (earliest / 1440)...((earliest + 60 * hours) / 1440)
            let dates = days.compactMap { RailCivilDate.addingDays($0, to: timetable.serviceDate) }
            var originCache: [String:String] = [:]
            for row in local.services {
                for call in row.stops.dropLast() where call.station == station {
                    guard let dep = call.departure else { continue }
                    for day in dates {
                        let key = "\(day)|\(dep / 1440)"
                        let start = originCache[key] ?? RailCivilDate.addingDays(-(dep / 1440), to: day) ?? ""
                        originCache[key] = start
                        guard row.validFrom <= start, start <= row.validThrough else { continue }
                        let stops: [[Any]] = row.stops.map { [$0.station,$0.arrival as Any? ?? NSNull(),$0.departure as Any? ?? NSNull()] }
                        extras.append(["train":row.train,"trip":"local/\(local.edition)/\(row.id)","origin":start,
                                       "date":day,"dep":dep,"stops":stops])
                    }
                }
            }
        }
        let text = String(decoding: try JSONEncoder().encode(timetable), as: UTF8.self)
        let localText = String(decoding: try JSONSerialization.data(withJSONObject: extras), as: UTF8.self)
        return try decoded("connections",[text,index,seconds,args,hours,localText])
    }
}
