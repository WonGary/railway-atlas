import Foundation

public enum DataEndpoint: String, CaseIterable, Identifiable, Sendable {
    case primary = "https://overpass-api.de/api/interpreter"
    case community = "https://overpass.private.coffee/api/interpreter"
    case vk = "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .primary: "Overpass · 德国"
        case .community: "Overpass · Private.coffee"
        case .vk: "Overpass · VK Maps"
        }
    }
}

public actor RailwayRepository {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func load() throws -> RailwayDataset? {
        let url = directory.appendingPathComponent("current.railmap")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try RailwayCodec.decode(Data(contentsOf: url))
    }

    public func save(_ dataset: RailwayDataset) throws {
        let data = try RailwayCodec.encode(dataset)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic replace keeps the last usable map if the app is interrupted.
        try data.write(to: directory.appendingPathComponent("current.railmap"), options: .atomic)
    }

    public func fetch(bounds: MapBounds, endpoint: DataEndpoint) async throws -> RailwayDataset {
        guard bounds.canDownload else {
            throw DataError.invalid("请放大地图后再下载，区域宽高各不超过 0.5°")
        }
        let query = """
        [out:json][timeout:25];
        (
          way["railway"~"^(rail|narrow_gauge|subway|light_rail|tram|monorail|construction|proposed|disused|abandoned|razed)$"](\(bounds.overpassValue));
          way[~"^(disused|abandoned|razed|construction|proposed):railway$"~"^(rail|narrow_gauge|subway|light_rail|tram|monorail)$"](\(bounds.overpassValue));
        )->.tracks;
        .tracks out body geom;
        (
          \(RailUrbanService.routeQuery(bounds: bounds))
          rel["type"="route_master"](\(bounds.overpassValue));
        );
        out body;
        nwr["railway"~"^(station|halt)$"](\(bounds.overpassValue));
        out center;
        """
        var components = URLComponents(string: endpoint.rawValue)!
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 45
        request.setValue("RailwayAtlas/0.1.0 (regional railway viewer)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Ephemeral session: explicit regional packages are the only persistent network data.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 55
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DataError.invalid("地图数据服务暂不可用（HTTP \(status)），可切换服务后重试")
        }
        guard response.expectedContentLength <= RailwayCodec.maxBytes else {
            throw DataError.invalid("响应过大，请缩小地图范围")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > RailwayCodec.maxBytes {
                throw DataError.invalid("响应过大，请缩小地图范围")
            }
        }
        try Task.checkCancellation()
        let result = try RailwayCodec.decodeOverpass(
            data, bounds: bounds,
            name: String(format: "区域 %.2f°N · %.2f°E", bounds.center.latitude, bounds.center.longitude),
            sourceURL: endpoint.rawValue
        )
        return result
    }
}
