import Foundation

/// An OSM corridor may be shared by different services and dates. The key is the
/// full ordered topology and its mileage offsets, never the train number.
enum RailCorridor {
    struct Node: Decodable { let name: String; let km: Int; let line: String; let vertex: Int? }
    struct Snapshot: Decodable { let date: String; let nodes: [Node]; let points: [[Double]] }
    static let snapshots: [Snapshot] = {
        guard let url = Bundle.main.url(forResource: "railway-experience-corridors", withExtension: "json", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "railway-experience-corridors", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 12_000_000 else { return [] }
        return (try? JSONDecoder().decode([Snapshot].self, from: data)) ?? []
    }()
    static func sampleG337(_ timetable: RailTimetable) -> RailTrackJourney? {
        guard timetable.id == "12306.G337.2026-11-20",
              let snapshot = snapshots.first(where: { $0.date == timetable.serviceDate }),
              timetable.stops.map(\.station) == ["北京西", "石家庄", "郑州东", "武汉", "黄石北", "庐山", "南昌西"] else { return nil }
        let indices = timetable.stops.compactMap { stop in snapshot.nodes.first { $0.name == stop.station }?.vertex }
        guard indices.count == timetable.stops.count, indices.allSatisfy(snapshot.points.indices.contains) else { return nil }
        var legs: [[Coordinate]] = []
        for (a, b) in zip(indices, indices.dropFirst()) {
            guard a < b else { return nil }
            let coordinates = snapshot.points[a...b].compactMap { $0.count == 2 ? Coordinate($0[1], $0[0]) : nil }
            guard coordinates.count == b-a+1 else { return nil }
            legs.append(coordinates)
        }
        let route = RailTrackJourney(id: "sample.G337.20261120", train: timetable.train, serviceDate: timetable.serviceDate,
            stations: timetable.stops.map(\.station), legs: legs, source: .init(title: "© OpenStreetMap contributors",
                url: "https://www.openstreetmap.org/copyright", retrievedOn: snapshot.date, note: "按经停站切分的轨道几何。站场内位置为近似。"))
        guard (try? route.validate(for: timetable)) != nil else { return nil }
        return route
    }
    static func journey(_ timetable: RailTimetable) -> RailTrackJourney? {
        guard let plan = timetable.routing, (try? plan.validate(for: timetable)) != nil else { return nil }
        for snapshot in snapshots where plan.nodes.count <= snapshot.nodes.count {
            for start in snapshot.nodes.indices where snapshot.nodes[start].name == plan.nodes[0].station {
                for direction in [1, -1] {
                    let end = start + direction * (plan.nodes.count - 1)
                    guard snapshot.nodes.indices.contains(end) else { continue }
                    let baseKM = snapshot.nodes[start].km
                    guard plan.nodes.indices.allSatisfy({ i in
                        let j = start + direction * i, node = snapshot.nodes[j]
                        return node.name == plan.nodes[i].station && abs(node.km - baseKM) == plan.nodes[i].kilometre &&
                            (i == plan.edges.count || snapshot.nodes[min(j, j + direction)].line == plan.edges[i].lineName)
                    }) else { continue }
                    let vertices = plan.stopIndices.compactMap { snapshot.nodes[start + direction * $0].vertex }
                    guard vertices.count == timetable.stops.count, vertices.allSatisfy(snapshot.points.indices.contains) else { continue }
                    var legs: [[Coordinate]] = []
                    for (a, b) in zip(vertices, vertices.dropFirst()) {
                        guard direction * (b - a) > 0 else { break }
                        let segment = snapshot.points[min(a,b)...max(a,b)]
                        let coords = segment.compactMap { $0.count == 2 ? Coordinate($0[1], $0[0]) : nil }
                        guard coords.count == segment.count else { break }
                        legs.append(direction == 1 ? coords : coords.reversed())
                    }
                    let route = RailTrackJourney(id: "corridor/\(timetable.id)/\(plan.providerID)", train: timetable.train,
                        serviceDate: timetable.serviceDate, stations: timetable.stops.map(\.station), legs: legs,
                        source: RailEvidence(title: "路路通经由 · OpenStreetMap 轨道", url: "https://www.openstreetmap.org/copyright",
                            retrievedOn: snapshot.date, note: "© OpenStreetMap contributors，ODbL。按经由线路、站序和计价里程核对。地图呈现区间轨道，站场股道为近似。"))
                    if (try? route.validate(for: timetable)) != nil { return route }
                }
            }
        }
        return nil
    }
}
