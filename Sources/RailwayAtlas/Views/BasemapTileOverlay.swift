import Foundation
import MapKit
import RailwayCore

final class BasemapTileOverlay: MKTileOverlay {
    private let provider: BasemapSource
    private let dark: Bool

    init(template: String?, source: BasemapSource, dark: Bool) {
        self.provider = source
        self.dark = dark
        super.init(urlTemplate: template)
        tileSize = CGSize(width:256, height:256)
        maximumZ = 19
        canReplaceMapContent = true
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        let street = provider.isVector
        let address = street ? nil : url(forTilePath:path)
        let source = provider.rawValue
        let dark = dark
        Task {
            do {
                let data: Data
                if let address {
                    data = try await BasemapNetwork.fetch(address)
                } else {
                    let z = min(path.z,14), shift = path.z - z
                    guard (0...19).contains(path.z) else { throw URLError(.badURL) }
                    let parent = try await BasemapNetwork.shared.parent(source:source,z:z,x:path.x >> shift,y:path.y >> shift)
                    data = try parent.png(zoom:path.z,column:path.x,row:path.y,dark:dark,retina:path.contentScaleFactor > 1)
                }
                result(data,nil)
            } catch { result(nil,error) }
        }
    }
}

private actor BasemapNetwork {
    static let shared = BasemapNetwork()
    private var metadata: Task<String, Error>?
    private var metadataTime = Date.distantPast
    private var pending: [String:Task<StreetBasemapTile,Error>] = [:]
    private var tiles: [String:StreetBasemapTile] = [:]
    private var recent: [String] = []
    private var points = 0

    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url:url, timeoutInterval:15)
        request.setValue("RailwayAtlas/0.8 (github.com/WonGary/railway-atlas)", forHTTPHeaderField:"User-Agent")
        let (data,response) = try await URLSession.shared.data(for:request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= VectorTileDecoder.maxBytes else { throw URLError(.badServerResponse) }
        return data
    }

    private func template(_ source: String) async throws -> String {
        if source == "versaTiles" { return "https://tiles.versatiles.org/tiles/osm-vector/{z}/{x}/{y}" }
        if let metadata, Date().timeIntervalSince(metadataTime) < 3600 { return try await metadata.value }
        let task = Task {
            struct Catalog: Decodable { let tiles:[String] }
            let data = try await Self.fetch(URL(string:"https://tiles.openfreemap.org/planet")!)
            let catalog = try JSONDecoder().decode(Catalog.self,from:data)
            guard let path = catalog.tiles.first, path.hasPrefix("https://tiles.openfreemap.org/"),
                  AtlasConfiguration.validStreetTemplate(path) else { throw URLError(.cannotParseResponse) }
            return path
        }
        metadata = task
        metadataTime = Date()
        do { return try await task.value } catch { metadata = nil; throw error }
    }

    func parent(source: String, z: Int, x: Int, y: Int) async throws -> StreetBasemapTile {
        let key = "\(source)/\(z)/\(x)/\(y)"
        if let tile = tiles[key] { recent.removeAll { $0 == key }; recent.append(key); return tile }
        if let work = pending[key] { return try await work.value }
        let work = Task {
            let template = try await template(source)
            let path = template.replacingOccurrences(of:"{x}",with:String(x))
                .replacingOccurrences(of:"{y}",with:String(y)).replacingOccurrences(of:"{z}",with:String(z))
            guard let url = URL(string:path) else { throw URLError(.badURL) }
            let data = try await Self.fetch(url)
            return try await Task.detached(priority:.utility) { try StreetBasemapTile(data) }.value
        }
        pending[key] = work
        defer { pending[key] = nil }
        let tile = try await work.value
        tiles[key] = tile; recent.append(key); points += tile.pointCount
        while recent.count > 16 || points > 900_000 {
            let old = recent.removeFirst()
            points -= tiles.removeValue(forKey:old)?.pointCount ?? 0
        }
        return tile
    }
}
