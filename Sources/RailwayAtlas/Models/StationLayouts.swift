import Foundation
import JavaScriptCore
import MapKit
import RailwayCore
import SwiftUI

enum StationLayoutKind: String, Codable, CaseIterable {
    case outline, platform, passage
    var minimumZoom: Double {
        switch self { case .outline: 16; case .platform: 17; case .passage: 18 }
    }
    func ink(dark: Bool) -> Color {
        let hex: String
        switch self {
        case .outline: hex = dark ? "#B9C8DA" : "#536981"
        case .platform: hex = dark ? "#7FD3C4" : "#216B62"
        case .passage: hex = dark ? "#E4ACF3" : "#864097"
        }
        return RailColor(hex)!.tint
    }
    var opacity: Double { self == .outline ? 0.17 : 0.34 }
    var width: Double { self == .outline ? 1.4 : 2.2 }
    var dash: [CGFloat] { self == .passage ? [4, 3] : [] }
}

struct StationLayout: Decodable, Equatable, Identifiable {
    let id: String
    let kind: StationLayoutKind
    let network: RailNetwork
    let area: Bool
    let paths: [[Coordinate]]
    let bounds: MapBounds

    enum CodingKeys: CodingKey { case id, kind, network, area, paths }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(StationLayoutKind.self, forKey: .kind)
        network = RailNetwork(rawValue: try c.decode(String.self, forKey: .network)) ?? .other
        area = try c.decode(Bool.self, forKey: .area)
        let vertices = try c.decode([[[Double]]].self, forKey: .paths)
        paths = try vertices.map { ring in
            try ring.map { pair in
                guard pair.count == 2, Coordinate(pair[1], pair[0]).isValid else { throw URLError(.cannotParseResponse) }
                return Coordinate(pair[1], pair[0])
            }
        }
        guard let outer = paths.first, outer.count >= 2,
              area ? paths.allSatisfy({ $0.count >= 4 && $0.first == $0.last }) : paths.count == 1
        else { throw URLError(.cannotParseResponse) }
        bounds = MapBounds(points: outer)
    }
    func overlay(alignment: MapAlignment) -> any MKOverlay {
        func polygon(_ ring: [Coordinate], holes: [MKPolygon]? = nil) -> MKPolygon {
            let points = ring.map { alignment.display($0).location }
            return MKPolygon(coordinates: points, count: points.count, interiorPolygons: holes)
        }
        if area { return polygon(paths[0], holes: paths.dropFirst().map { polygon($0) }) }
        let segments = alignment.displaySegments(paths[0]).map { line in
            let points = line.map(\.location)
            return MKPolyline(coordinates: points, count: points.count)
        }
        return MKMultiPolyline(segments)
    }
    func draw(_ context: inout GraphicsContext, projection: RailProjection, dark: Bool) {
        var path = Path()
        for ring in paths {
            guard let first = ring.first else { continue }
            path.move(to: projection.screen(first))
            for p in ring.dropFirst() { path.addLine(to: projection.screen(p)) }
            if area { path.closeSubpath() }
        }
        let color = kind.ink(dark: dark)
        if area { context.fill(path, with: .color(color.opacity(kind.opacity)), style: FillStyle(eoFill: true)) }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: kind.width, lineCap: .round,
                                                                     lineJoin: .round, dash: kind.dash))
    }
}

private struct LayoutSnapshot: Decodable {
    let features: [StationLayout]
}

extension RailwayMapStore {
    static func bundledLayouts() -> [StationLayout] {
        guard let url = resourceURL("station-layouts", extension: "json"), let data = try? Data(contentsOf: url),
              let pack = try? JSONDecoder().decode(LayoutSnapshot.self, from: data) else { return [] }
        return pack.features
    }
    func stationLayouts(in bounds: MapBounds, zoom: Double) -> [StationLayout] {
        guard zoom >= 16, showsStationLayouts, showsStations, !historyMapActive else { return [] }
        return layoutFeatures.filter { feature in
            zoom + 0.000001 >= feature.kind.minimumZoom && feature.bounds.intersects(bounds) &&
            networkVisible(feature.network) &&
            (feature.network == .railway || categoryVisible(.urban))
        }
    }

    func loadStationLayouts() async {
        guard !loadingLayouts, mapMode == .apple, showsStationLayouts, displayZoom >= 16 else { return }
        let bounds = viewportBounds
        guard let script = Self.resourceURL("station-layouts", extension: "js") else { return }
        loadingLayouts = true
        layoutStatus = "正在读取当前站区…"
        defer { loadingLayouts = false }
        do {
            let data = try await StationLayoutFetch.load(bounds: bounds, endpoint: endpoint.rawValue, script: script)
            let additions = try JSONDecoder().decode([StationLayout].self, from: data)
            if !additions.isEmpty {
                if let cache = layoutCacheDirectory {
                    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    let key = "\(Int((bounds.center.latitude * 1000).rounded()))_\(Int((bounds.center.longitude * 1000).rounded()))"
                    try data.write(to: cache.appendingPathComponent(key).appendingPathExtension("json"), options: .atomic)
                }
                mergeStationLayouts(additions)
            }
            layoutStatus = additions.isEmpty ? "这个站区暂缺已绘制的细节。" : "已读取当前站区的 \(additions.count) 个要素。"
        } catch { layoutStatus = "未能读取这个站区。可稍后重试，或在数据设置中切换 Overpass 来源。" }
    }
    var layoutCacheDirectory: URL? {
        guard !CommandLine.arguments.contains("--ui-smoke") else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RailwayAtlas/StationLayouts-v1", isDirectory: true)
    }
    func mergeStationLayouts(_ extra: [StationLayout]) {
        var byID = Dictionary(layoutFeatures.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for f in extra { byID[f.id] = f }
        layoutFeatures = byID.values.sorted { ($0.kind.minimumZoom, $0.id) < ($1.kind.minimumZoom, $1.id) }
    }
    func restoreStationLayouts() {
        guard let dir = layoutCacheDirectory, let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let extra = files.filter { $0.pathExtension == "json" }.sorted {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast <
            (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }.suffix(32).flatMap { url -> [StationLayout] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([StationLayout].self, from: data)) ?? []
        }
        if !extra.isEmpty { mergeStationLayouts(extra) }
    }
}

private enum StationLayoutFetch {
    // JS contexts stay on one synchronous invocation, off the UI thread.
    static func run(_ script: URL, method: String, arguments: [Any]) throws -> JSValue {
        guard let context = JSContext() else { throw URLError(.cannotDecodeContentData) }
        context.evaluateScript(try String(contentsOf: script, encoding: .utf8))
        guard let result = context.objectForKeyedSubscript("StationLayoutOSM")?.invokeMethod(method, withArguments: arguments),
              context.exception == nil, !result.isUndefined else { throw URLError(.cannotParseResponse) }
        return result
    }
    static func load(bounds: MapBounds, endpoint: String, script: URL) async throws -> Data {
        let q = try run(script, method: "query", arguments: [bounds.south,bounds.west,bounds.north,bounds.east]).toString()!
        for source in [endpoint] + (endpoint == DataEndpoint.primary.rawValue ? [] : [DataEndpoint.primary.rawValue]) {
            try Task.checkCancellation()
            var components = URLComponents(string: source)!
            components.queryItems = [URLQueryItem(name: "data", value: q)]
            var request = URLRequest(url: components.url!, timeoutInterval: 20)
            request.setValue("RailwayAtlas/0.8.1 (+https://github.com/WonGary/railway-atlas)", forHTTPHeaderField: "User-Agent")
            request.setValue("https://wongary.github.io/railway-atlas/", forHTTPHeaderField: "Referer")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8_000_000 else { continue }
                let document = try JSONSerialization.jsonObject(with: data)
                guard let rows = try run(script, method: "extract", arguments: [document]).toArray() else { continue }
                return try JSONSerialization.data(withJSONObject: rows)
            } catch { try Task.checkCancellation() }
        }
        throw URLError(.badServerResponse)
    }
}
