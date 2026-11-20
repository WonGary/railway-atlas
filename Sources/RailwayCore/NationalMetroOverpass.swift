import Foundation

extension NationalMetroSnapshot {
    public static let overpassQuery = """
    [out:json][timeout:100][maxsize:268435456];
    area["ISO3166-1"~"^(CN|HK|MO|TW)$"]->.a;
    rel(area.a)["type"="route"]["route"~"^(subway|light_rail|tram|monorail)$"]->.routes;
    .routes out geom;
    rel(br.routes)["type"="route_master"];
    out body;
    """

    /// Converts complete route geometry, retaining original OSM lifecycle tags,
    /// explicit masters and colour provenance. A city label is display metadata,
    /// never evidence that two routes share an identity.
    public static func decodeOverpass(_ data: Data, cityReference: NationalMetroSnapshot?,
                                      fetchedAt: Date = .now) throws -> Self {
        guard data.count <= maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]],
              (root["remark"] as? String ?? "").isEmpty else {
            throw DataError.invalid("全国线路查询不完整，保留已有概览")
        }
        var parents: [Int64: [String: Any]] = [:]
        let ordered = elements.sorted {
            (($0["id"] as? NSNumber)?.int64Value ?? 0) < (($1["id"] as? NSNumber)?.int64Value ?? 0)
        }
        for element in ordered where (element["tags"] as? [String: String])?["type"] == "route_master" {
            for member in element["members"] as? [[String: Any]] ?? [] where member["type"] as? String == "relation" {
                if let id = (member["ref"] as? NSNumber)?.int64Value, parents[id] == nil { parents[id] = element }
            }
        }
        var knownCities: [String: String] = [:], networkCities: [String: Set<String>] = [:]
        var paletteCities: [String: Set<String>] = [:]
        for line in cityReference?.lines ?? [] {
            guard let city = line.tags["atlas:overviewCity"], !city.isEmpty else { continue }
            for route in line.routes ?? [] {
                knownCities[route.id] = city
                if let network = route.tags["network"], !network.isEmpty { networkCities[network, default: []].insert(city) }
                if let palette = route.tags["atlas:paletteCity"] { paletteCities[palette, default: []].insert(city) }
            }
        }
        func folded(_ text: String) -> String {
            (text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text)
                .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_Hans"))
        }
        let cityNames = (cityReference?.cityNames ?? []) + ["台北", "新北", "桃园", "台中", "高雄"]
        let cityTokens = Set(cityNames).filter { $0 != "未归档" }.map { ($0, folded($0)) }
        func city(for route: RailRoute) -> String {
            if let city = knownCities[route.id] { return city }
            if let network = route.tags["network"], let cities = networkCities[network], cities.count == 1 {
                return cities.first!
            }
            for field in ["network", "network:zh", "name:zh", "name"] {
                guard let value = route.tags[field], !value.isEmpty else { continue }
                let text = folded(value)
                let cities = cityTokens.filter { text.contains($0.1) }.map(\.0)
                if cities.count == 1 { return cities[0] }
            }
            if let palette = BundledMetroPalette.city(for: route),
               let cities = paletteCities[palette], cities.count == 1 { return cities.first! }
            return "未归档"
        }
        var features: [[String: Any]] = []
        for element in ordered {
            try Task.checkCancellation()
            guard element["type"] as? String == "relation",
                  let number = (element["id"] as? NSNumber)?.int64Value, number > 0,
                  var tags = element["tags"] as? [String: String],
                  let mode = tags["route"], RailCategory.urbanTypes.contains(mode) else { continue }
            let id = "relation/\(number)"
            var colourSource = id
            if let parent = parents[number], let masterID = (parent["id"] as? NSNumber)?.int64Value {
                let inherited = parent["tags"] as? [String: String] ?? [:]
                tags["atlas:routeMaster"] = "relation/\(masterID)"
                for field in ["ref", "network", "network:zh", "network:en", "operator", "wikidata", "wikipedia"]
                    where (tags[field] ?? "").isEmpty { tags[field] = inherited[field] }
                if (tags["colour"] ?? tags["color"]).flatMap(RailColor.init) == nil,
                   let colour = inherited["colour"] ?? inherited["color"], RailColor(colour) != nil {
                    tags["colour"] = colour
                    colourSource = "relation/\(masterID)"
                }
            }
            let name = tags["name:zh"] ?? tags["name"] ?? tags["ref"] ?? id
            let route = RailRoute(id: id, name: name, tags: tags, colourSourceID: colourSource)
            var parts: [[[Double]]] = []
            for member in element["members"] as? [[String: Any]] ?? []
                where member["type"] as? String == "way"
                    && ["", "forward", "backward", "route", "inactive"].contains(member["role"] as? String ?? "") {
                var part: [[Double]] = []
                for raw in member["geometry"] as? [Any] ?? [] {
                    if let point = raw as? [String: Any], let lat = point["lat"] as? Double, let lon = point["lon"] as? Double {
                        guard Coordinate(lat, lon).isValid else { throw DataError.invalid("全国轨道坐标无效") }
                        part.append([lon, lat])
                    } else {
                        if part.count >= 2 { parts.append(part) }
                        part = []
                    }
                }
                if part.count >= 2 { parts.append(part) }
            }
            guard !parts.isEmpty else { continue }
            tags["city"] = city(for: route)
            tags["osm_id"] = String(number)
            tags["line_name"] = name
            tags["route_type"] = mode
            tags["atlas:colourSourceID"] = colourSource
            tags["atlas:snapshotURL"] = "https://www.openstreetmap.org/\(id)"
            tags["atlas:sourceEndpoint"] = "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
            let stamp = (root["osm3s"] as? [String: Any])?["timestamp_osm_base"] as? String
            tags["atlas:snapshotDate"] = stamp
            features.append(["type": "Feature", "properties": tags,
                             "geometry": ["type": "MultiLineString", "coordinates": parts]])
        }
        guard !features.isEmpty else { throw DataError.invalid("全国线路查询没有轨道几何，保留已有概览") }
        let geoJSON = try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
        let stamp = (root["osm3s"] as? [String: Any])?["timestamp_osm_base"] as? String
        return try decodeGeoJSON(geoJSON, fetchedAt: fetchedAt, sourceDate: stamp.map { String($0.prefix(10)) })
    }
}
