import Foundation

public struct Coordinate: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-85...85).contains(latitude) && (-180...180).contains(longitude)
    }
}

public struct MapBounds: Codable, Equatable, Sendable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    public static let shanghai = MapBounds(south: 31.14, west: 121.25, north: 31.34, east: 121.55)

    public var isValid: Bool {
        Coordinate(south, west).isValid && Coordinate(north, east).isValid
            && south < north && west < east
    }

    public var canDownload: Bool {
        isValid && north - south <= 0.5 && east - west <= 0.5
    }

    public var center: Coordinate { Coordinate((south + north) / 2, (west + east) / 2) }

    public var overpassValue: String { "\(south),\(west),\(north),\(east)" }
}

public struct RailLine: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var coordinates: [Coordinate]
    public var tags: [String: String]
    public var routes: [RailRoute]?
    public var category: RailCategory {
        .classify(tags, hasUrbanRoute: (routes ?? []).contains { RailCategory.urbanTypes.contains($0.tags["route"] ?? "") })
    }
    public var isUrbanTransit: Bool { RailUrbanService.line(tags, routes: routes ?? []) }
}

public struct RailStation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var coordinate: Coordinate
    public var tags: [String: String]
    public var routes: [RailRoute]? = nil
    public init(id: String, name: String, coordinate: Coordinate, tags: [String: String], routes: [RailRoute]? = nil) {
        self.id = id; self.name = name; self.coordinate = coordinate; self.tags = tags; self.routes = routes
    }
}

public struct RailwayDataset: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var attribution: String? = "© OpenStreetMap contributors"
    public var licenseURL: String? = "https://opendatacommons.org/licenses/odbl/1-0/"
    public var name: String
    public var downloadedAt: Date
    public var osmTimestamp: String?
    public var sourceURL: String
    public var bounds: MapBounds
    public var lines: [RailLine]
    public var stations: [RailStation]

    public func validate() throws {
        guard schemaVersion == 1 else { throw DataError.invalid("不支持此数据包版本") }
        guard bounds.isValid else { throw DataError.invalid("数据包的区域范围无效") }
        guard lines.count <= 20_000, stations.count <= 8_000,
              lines.reduce(0, { $0 + $1.coordinates.count }) <= 600_000 else {
            throw DataError.invalid("区域过大，请导入较小的铁路数据包")
        }
        guard !lines.isEmpty || !stations.isEmpty else { throw DataError.invalid("此区域没有铁路数据") }
        let ids = lines.map(\.id) + stations.map(\.id)
        guard Set(ids).count == ids.count else { throw DataError.invalid("数据中存在重复的 OSM 标识") }
        guard ids.allSatisfy({ id in
            let pieces = id.split(separator: "/")
            return pieces.count == 2 && ["node", "way", "relation"].contains(String(pieces[0]))
                && UInt64(pieces[1]) != nil
        }) else { throw DataError.invalid("OSM 标识应为 node、way 或 relation 加数字编号") }
        guard lines.allSatisfy({ $0.coordinates.count >= 2 && $0.coordinates.allSatisfy(\.isValid) }),
              stations.allSatisfy({ $0.coordinate.isValid }) else {
            throw DataError.invalid("数据中存在无效坐标")
        }
        for line in lines {
            let routes = line.routes ?? []
            guard routes.count <= 32, Set(routes.map(\.id)).count == routes.count,
                  routes.allSatisfy({ route in
                      [route.id, route.colourSourceID ?? route.id].allSatisfy {
                          let parts = $0.split(separator: "/")
                          return parts.count == 2 && parts[0] == "relation" && UInt64(parts[1]) != nil
                      } && RailUrbanService.supportsRoute(route.tags)
                  }) else { throw DataError.invalid("线路关系的编号、类型或数量无效") }
        }
    }
}

public enum DataError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

public enum RailwayCodec {
    public static let maxBytes = 32 * 1024 * 1024

    public static func encode(_ dataset: RailwayDataset) throws -> Data {
        try dataset.validate()
        var dataset = dataset
        dataset.attribution = "© OpenStreetMap contributors"
        dataset.licenseURL = "https://opendatacommons.org/licenses/odbl/1-0/"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(dataset)
        guard data.count <= maxBytes else { throw DataError.invalid("数据包不能超过 32 MB") }
        return data
    }

    public static func decode(_ data: Data) throws -> RailwayDataset {
        guard data.count <= maxBytes else { throw DataError.invalid("数据包不能超过 32 MB") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dataset = try decoder.decode(RailwayDataset.self, from: data)
        try dataset.validate()
        return dataset
    }

    public static func decodeOverpass(
        _ data: Data, bounds: MapBounds, name: String, sourceURL: String
    ) throws -> RailwayDataset {
        guard data.count <= maxBytes else { throw DataError.invalid("响应过大，请缩小下载范围") }
        let document = try JSONDecoder().decode(OSMDocument.self, from: data)
        if let remark = document.remark, !remark.isEmpty {
            // Overpass may return HTTP 200 with a timeout and partial results.
            throw DataError.invalid("数据服务未完成查询，请稍后重试或缩小区域")
        }
        var lines: [RailLine] = []
        var stations: [RailStation] = []
        let memberships = routeMemberships(in: document)
        for element in document.elements {
            let tags = element.tags ?? [:]
            let railway = tags["railway"] ?? ""
            if element.type == "way", RailCategory.isTrack(tags) {
                let coordinates = (element.geometry ?? []).compactMap { point -> Coordinate? in
                    guard let lat = point.lat, let lon = point.lon else { return nil }
                    return Coordinate(lat, lon)
                }
                // Do not silently connect across missing geometry.
                guard coordinates.count >= 2, coordinates.count == element.geometry?.count else { continue }
                let routes = memberships["way/\(element.id)"] ?? []
                lines.append(RailLine(
                    id: "way/\(element.id)",
                    name: tags["name:zh"] ?? tags["name"] ?? tags["ref"]
                        ?? routes.first?.name ?? RailCategory.classify(tags).title,
                    coordinates: coordinates,
                    tags: tags, routes: routes.isEmpty ? nil : routes
                ))
            } else if ["station", "halt"].contains(railway) {
                guard let lat = element.lat ?? element.center?.lat,
                      let lon = element.lon ?? element.center?.lon else { continue }
                stations.append(RailStation(
                    id: "\(element.type)/\(element.id)",
                    name: tags["name:zh"] ?? tags["name"] ?? "未命名车站",
                    coordinate: Coordinate(lat, lon), tags: tags,
                    routes: memberships["\(element.type)/\(element.id)"]
                ))
            }
        }
        let dataset = RailwayDataset(
            name: name, downloadedAt: .now, osmTimestamp: document.osm3s?.timestamp_osm_base,
            sourceURL: sourceURL, bounds: bounds, lines: lines, stations: stations
        )
        try dataset.validate()
        return dataset
    }

    /// Adds relation metadata to an existing package without replacing its track geometry.
    public static func enrichRoutes(_ data: Data, in dataset: RailwayDataset) throws -> RailwayDataset {
        guard data.count <= maxBytes else { throw DataError.invalid("线路关系响应过大") }
        let document = try JSONDecoder().decode(OSMDocument.self, from: data)
        guard document.remark?.isEmpty != false else { throw DataError.invalid("线路关系查询未完成") }
        let memberships = routeMemberships(in: document)
        var result = dataset
        for index in result.lines.indices {
            guard result.lines[index].id.hasPrefix("way/"),
                  let routes = memberships[result.lines[index].id] else { continue }
            result.lines[index].routes = routes
            if result.lines[index].tags["name"] == nil, result.lines[index].tags["name:zh"] == nil,
               result.lines[index].tags["ref"] == nil, let route = routes.first {
                result.lines[index].name = route.name
            }
        }
        for index in result.stations.indices {
            if let routes = memberships[result.stations[index].id] { result.stations[index].routes = routes }
        }
        try result.validate()
        return result
    }

    private static func routeMemberships(in document: OSMDocument) -> [String: [RailRoute]] {
        var masters: [Int64: OSMElement] = [:]
        for master in document.elements where master.type == "relation" && master.tags?["type"] == "route_master" {
            for member in master.members ?? [] where member.type == "relation" {
                // Prefer the lowest relation ID deterministically if the source contains multiple masters.
                if masters[member.ref] == nil || master.id < masters[member.ref]!.id { masters[member.ref] = master }
            }
        }
        var membership: [String: [RailRoute]] = [:]
        for element in document.elements.sorted(by: { $0.id < $1.id })
            where element.type == "relation" && element.tags?["type"] == "route" {
            var tags = element.tags ?? [:]
            var colorSource = "relation/\(element.id)"
            if let master = masters[element.id] {
                for key in ["ref", "network", "network:en", "operator"] + RailUrbanService.evidenceKeys
                    where tags[key] == nil { tags[key] = master.tags?[key] }
                if (tags["colour"] ?? tags["color"]).flatMap(RailColor.init) == nil,
                   let color = master.tags?["colour"] ?? master.tags?["color"], RailColor(color) != nil {
                    tags["colour"] = color
                    colorSource = "relation/\(master.id)"
                }
            }
            guard RailUrbanService.supportsRoute(tags) else { continue }
            let route = RailRoute(
                id: "relation/\(element.id)",
                name: tags["name:zh"] ?? tags["name"] ?? tags["ref"] ?? "未命名城市轨道",
                tags: tags, colourSourceID: colorSource
            )
            for member in element.members ?? [] where
                (member.type == "way" && ["", "forward", "backward", "route", "inactive"].contains(member.role ?? ""))
                || (member.role ?? "").hasPrefix("stop") {
                let key = "\(member.type)/\(member.ref)"
                if membership[key]?.contains(where: { $0.id == route.id }) != true {
                    membership[key, default: []].append(route)
                }
            }
        }
        return membership
    }
}

private struct OSMDocument: Decodable {
    var elements: [OSMElement]
    var remark: String?
    var osm3s: OSMMeta?
}

private struct OSMMeta: Decodable { var timestamp_osm_base: String? }
private struct OSMPoint: Decodable { var lat: Double?; var lon: Double? }
private struct OSMElement: Decodable {
    var type: String
    var id: Int64
    var lat: Double?
    var lon: Double?
    var tags: [String: String]?
    var geometry: [OSMPoint]?
    var center: OSMPoint?
    var members: [OSMMember]?
}
private struct OSMMember: Decodable { var type: String; var ref: Int64; var role: String? }

public enum RailwaySearch {
    public static func normalized(_ text: String) -> String {
        (text.applyingTransform(.toLatin, reverse: false) ?? text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { !$0.isWhitespace }
    }
}
