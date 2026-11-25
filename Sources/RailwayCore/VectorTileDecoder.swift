import Foundation

/// Small, bounded reader for the public Mapbox Vector Tile 2.x wire format.
/// Unknown protobuf fields are skipped; malformed or oversized data is rejected.
public enum VectorTileDecoder {
    public static let maxBytes = 12 * 1024 * 1024

    public static func decode(_ data: Data, key: RailTileKey) throws -> RailTileFeatures {
        guard key.tile.isValid, data.count <= maxBytes else { throw invalid() }
        var reader = ProtoReader(data)
        var output = RailTileFeatures()
        while let field = try reader.field() {
            if field == 26 {
                try layer(reader.bytes(), key: key, into: &output)
            } else { try reader.skip(field & 7) }
        }
        return output
    }

    private static func layer(_ data: Data, key: RailTileKey, into output: inout RailTileFeatures) throws {
        var reader = ProtoReader(data)
        var name = "", extent = 4096
        var keys: [String] = [], values: [String] = [], features: [Data] = []
        while let field = try reader.field() {
            switch field {
            case 10: name = try reader.string()
            case 18: features.append(try reader.bytes())
            case 26: keys.append(try reader.string())
            case 34: values.append(try value(reader.bytes()))
            case 40: extent = Int(try reader.varint())
            default: try reader.skip(field & 7)
            }
            guard features.count <= 100_000, keys.count <= 10_000, values.count <= 500_000 else { throw invalid() }
        }
        guard extent > 0, extent <= 65_536 else { throw invalid() }
        let openMapTiles = name == "transportation" || name == "transportation_name" || name == "poi"
        let shortbread = name == "streets" || name == "public_transport"
        let isTrack = name == "railway_line_high" || name == "speed_railway_line_low"
            || name == "transportation" || name == "transportation_name" || name == "streets"
        let isStation = ["standard_railway_text_stations", "standard_railway_text_stations_low",
                         "standard_railway_text_stations_med", "poi", "public_transport"].contains(name)
        guard isTrack || isStation else { return }
        var vertexBudget = 1_000_000
        for (index, feature) in features.enumerated() {
            var r = ProtoReader(feature)
            var tags: [String: String] = [:], geometry = Data(), type: UInt64 = 0
            while let field = try r.field() {
                switch field {
                case 18:
                    var packed = ProtoReader(try r.bytes())
                    while !packed.isAtEnd {
                        let k = try packed.varint(), v = try packed.varint()
                        guard k < keys.count, v < values.count else { throw invalid() }
                        tags[keys[Int(k)]] = values[Int(v)]
                    }
                case 24: type = try r.varint()
                case 34: geometry = try r.bytes()
                default: try r.skip(field & 7)
                }
            }
            guard (isTrack && type == 2) || (isStation && type == 1) else { continue }
            if openMapTiles {
                let kind = tags["class"] ?? "", subtype = tags["subclass"] ?? ""
                if isTrack {
                    guard ["rail", "transit"].contains(kind),
                          ["rail", "subway", "light_rail", "tram", "monorail", "narrow_gauge", "funicular"].contains(subtype) else { continue }
                    tags["feature"] = subtype
                    if name == "transportation_name" {
                        // A line identity is useful even without a colour.
                        // Keeping it permits immediate offline palette lookup.
                        guard RailCategory.urbanTypes.contains(subtype),
                              (1...16).contains(where: {
                                  tags["route_\($0)_colour"] != nil || tags["route_\($0)_name"] != nil || tags["route_\($0)_ref"] != nil
                              }) else { continue }
                        tags["atlas:routeOverlay"] = "yes"
                    }
                } else {
                    guard ["railway", "railway_station"].contains(kind) ||
                            ["station", "halt", "tram_stop", "subway"].contains(subtype) else { continue }
                    tags["feature"] = subtype == "tram_stop" ? "tram_stop" : "station"
                    if subtype == "subway" { tags["station"] = "subway" }
                }
                tags["name:zh"] = tags["name:zh-Hans"] ?? tags["name:zh"]
            } else if shortbread {
                let kind = tags["kind"] ?? ""
                if isTrack {
                    guard tags["rail"] == "yes",
                          ["rail", "subway", "light_rail", "tram", "monorail", "narrow_gauge", "funicular", "disused", "abandoned"].contains(kind) else { continue }
                    tags["feature"] = kind
                } else {
                    guard ["station", "halt", "tram_stop", "subway_station"].contains(kind) else { continue }
                    tags["feature"] = kind == "subway_station" ? "station" : kind
                    if kind == "subway_station" { tags["station"] = "subway" }
                }
                tags["name:zh"] = tags["name_zh-Hans"] ?? tags["name_zh"]
            }
            let paths = try paths(geometry, tile: key.tile, extent: extent, budget: &vertexBudget)
            tags = normalized(tags, layer: name)
            if openMapTiles { tags["atlas:source"] = "OpenFreeMap / OpenMapTiles" }
            if shortbread { tags["atlas:source"] = "VersaTiles" }
            let identity = "\(key.path)/\(name)/\(index)"
            let title = tags["name:zh"] ?? tags["localized_name"] ?? tags["name"] ?? tags["ref"]
            if isTrack {
                for (part, coordinates) in paths.enumerated() where coordinates.count >= 2 {
                    output.lines.append(RailLine(id: "\(identity)/\(part)",
                                                 name: title ?? RailCategory.classify(tags).title,
                                                 coordinates: coordinates, tags: tags,
                                                 routes: routes(tags, identity: identity)))
                }
            } else if let coordinate = paths.first?.first {
                let feature = tags["railway"] ?? ""
                guard ["station", "halt", "tram_stop"].contains(feature) else { continue }
                output.stations.append(RailStation(id: tags["atlas:osm"] ?? identity,
                                                   name: title ?? "未命名车站", coordinate: coordinate, tags: tags))
            }
        }
    }

    private static func normalized(_ original: [String: String], layer: String) -> [String: String] {
        var tags = original
        let type = tags["feature"] ?? "rail"
        tags["railway"] = type
        if let state = tags["state"], ["construction", "proposed", "disused", "abandoned", "razed"].contains(state) {
            tags["\(state):railway"] = type
        }
        if let traffic = tags["traffic_mode"] { tags["railway:traffic_mode"] = traffic }
        if let gauge = tags["gauge0"] { tags["gauge"] = gauge }
        if let electrified = tags["electrification_state"] { tags["electrified"] = electrified }
        if let primary = tags["primary_operator"] { tags["operator"] = primary }
        // Generalized low-zoom identifiers do not identify individual OSM ways.
        if layer == "railway_line_high" || layer.contains("stations") {
            if layer.contains("stations"), let id = tags["id"] {
                let parts = id.split(separator: "-")
                if parts.count >= 2, ["node", "way", "relation"].contains(parts[0]), UInt64(parts[1]) != nil {
                    tags["atlas:osm"] = "\(parts[0])/\(parts[1])"
                }
            }
            if let id = tags["id"], let first = id.first,
               ["W", "N", "R", "w", "n", "r"].contains(String(first)),
               UInt64(id.dropFirst()) != nil {
                let kind = first.lowercased() == "w" ? "way" : first.lowercased() == "n" ? "node" : "relation"
                tags["atlas:osm"] = "\(kind)/\(id.dropFirst())"
            } else if let id = tags["osm_id"], UInt64(id) != nil {
                tags["atlas:osm"] = "\(tags["osm_type"] == "N" ? "node" : "way")/\(id)"
            }
            // ORM import/openrailwaymap.lua: id = "%d-%d", OSM way and
            // segment index. This is not a general rule for other schemas.
            if layer == "railway_line_high", let id = tags["id"] {
                let pieces = id.split(separator: "-")
                if pieces.count == 2, UInt64(pieces[0]) != nil, UInt64(pieces[1]) != nil {
                    tags["atlas:osm"] = "way/\(pieces[0])"
                }
            }
        }
        tags["atlas:source"] = "OpenRailwayMap"
        return tags
    }

    private static func routes(_ tags: [String: String], identity: String) -> [RailRoute]? {
        if RailCategory.urbanTypes.contains(tags["railway"] ?? ""), tags["class"] != nil {
            let result: [RailRoute] = (1...16).compactMap { index in
                let prefix = "route_\(index)_"
                var routeTags = Dictionary(uniqueKeysWithValues: tags.filter { $0.key.hasPrefix(prefix) }
                    .map { (String($0.key.dropFirst(prefix.count)), $0.value) })
                guard ["colour", "name", "ref"].contains(where: { routeTags[$0]?.isEmpty == false }) else { return nil }
                routeTags["route"] = tags["railway"] ?? "subway"
                for field in ["network", "network:en", "operator"] where routeTags[field] == nil {
                    routeTags[field] = tags[field]
                }
                return RailRoute(id: "tile-route/\(identity)/\(index)",
                                 name: tags["route_\(index)_name"] ?? tags["route_\(index)_ref"] ?? "城市轨道",
                                 tags: routeTags, colourSourceID: nil)
            }
            return result.isEmpty ? nil : result
        }
        guard let raw = tags["line_routes"], let data = raw.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let result = list.prefix(32).compactMap { entry -> RailRoute? in
            guard let id = entry["route_id"].map({ String(describing: $0) }), UInt64(id) != nil else { return nil }
            var routeTags = entry.compactMapValues { $0 as? String }
            routeTags["colour"] = (entry["colour"] ?? entry["color"]) as? String
            routeTags["route"] = entry["route"] as? String
                ?? (RailCategory.urbanTypes.contains(tags["railway"] ?? "") ? tags["railway"] : "train")
            guard RailUrbanService.supportsRoute(routeTags) else { return nil }
            for field in ["network", "network:en", "operator"] where routeTags[field] == nil {
                routeTags[field] = tags[field]
            }
            return RailRoute(id: "relation/\(id)", name: entry["label"] as? String ?? entry["name"] as? String ?? "城市轨道",
                             tags: routeTags)
        }
        return result.isEmpty ? nil : result
    }

    private static func paths(_ data: Data, tile: RailTile, extent: Int, budget: inout Int) throws -> [[Coordinate]] {
        var r = ProtoReader(data), x: Int64 = 0, y: Int64 = 0
        var result: [[Coordinate]] = [], current: [Coordinate] = []
        while !r.isAtEnd {
            let command = try r.varint(), kind = command & 7, count = command >> 3
            guard count > 0, count <= budget, [1, 2, 7].contains(kind) else { throw invalid() }
            if kind == 7 { continue }
            for _ in 0..<count {
                if kind == 1, !current.isEmpty { result.append(current); current = [] }
                let dx = try r.signed(), dy = try r.signed()
                guard (-10_000_000...10_000_000).contains(dx), (-10_000_000...10_000_000).contains(dy),
                      (-10_000_000...10_000_000).contains(x), (-10_000_000...10_000_000).contains(y) else { throw invalid() }
                x += dx; y += dy
                let point = tile.coordinate(Double(x), Double(y), extent: Double(extent))
                guard point.latitude.isFinite, point.longitude.isFinite else { throw invalid() }
                current.append(point)
                budget -= 1
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func value(_ data: Data) throws -> String {
        var reader = ProtoReader(data)
        var result = ""
        while let field = try reader.field() {
            switch field {
            case 10: result = try reader.string()
            case 21: result = String(Float(bitPattern: UInt32(try reader.fixed(4))))
            case 25: result = String(Double(bitPattern: try reader.fixed(8)))
            case 32: result = String(Int64(bitPattern: try reader.varint()))
            case 40: result = String(try reader.varint())
            case 48: result = String(try reader.signed())
            case 56: result = try reader.varint() == 0 ? "no" : "yes"
            default: try reader.skip(field & 7)
            }
        }
        return result
    }

    private static func invalid() -> DataError { .invalid("铁路矢量瓦片无效或超出大小限制") }
}

struct ProtoReader {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = Data(data) }
    var isAtEnd: Bool { offset == data.count }
    func invalid() -> DataError { .invalid("铁路矢量瓦片损坏") }
    mutating func field() throws -> UInt64? {
        guard !isAtEnd else { return nil }
        let value = try varint()
        guard value >> 3 > 0 else { throw invalid() }
        return value
    }
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 70, by: 7) {
            guard offset < data.count else { throw invalid() }
            let byte = data[offset]; offset += 1
            if shift == 63 && byte > 1 { throw invalid() }
            result |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return result }
        }
        throw invalid()
    }
    mutating func signed() throws -> Int64 {
        let n = try varint()
        return Int64(bitPattern: n >> 1) ^ -Int64(n & 1)
    }
    mutating func bytes() throws -> Data {
        let length = try varint()
        guard length <= data.count - offset else { throw invalid() }
        let end = offset + Int(length)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
    mutating func string() throws -> String {
        guard let value = String(data: try bytes(), encoding: .utf8) else { throw invalid() }
        return value
    }
    mutating func fixed(_ count: Int) throws -> UInt64 {
        guard data.count - offset >= count else { throw invalid() }
        var result: UInt64 = 0
        for n in 0..<count { result |= UInt64(data[offset + n]) << (n * 8) }
        offset += count
        return result
    }
    mutating func skip(_ wire: UInt64) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: _ = try fixed(8)
        case 2: _ = try bytes()
        case 5: _ = try fixed(4)
        default: throw invalid()
        }
    }
}
