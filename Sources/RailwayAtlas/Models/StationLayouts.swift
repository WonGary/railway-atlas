import Foundation
import JavaScriptCore
import MapKit
import RailwayCore
import SwiftUI

enum StationLayoutKind: String, Codable, CaseIterable {
    case outline, concourse, platform, passage
    var minimumZoom: Double {
        switch self { case .outline: 16; case .concourse, .platform: 17; case .passage: 18 }
    }
    func ink(dark: Bool) -> Color {
        let hex: String
        switch self {
        case .outline: hex = dark ? "#B9C8DA" : "#536981"
        case .concourse: hex = dark ? "#FFCD8F" : "#925216"
        case .platform: hex = dark ? "#7FD3C4" : "#216B62"
        case .passage: hex = dark ? "#E4ACF3" : "#864097"
        }
        return RailColor(hex)!.tint
    }
    var opacity: Double { self == .outline ? 0.17 : self == .concourse ? 0.22 : 0.34 }
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
    let platformLabel: String?
    let labelAnchors: [Coordinate]
    let labelOwner: String?
    var hasGeometry: Bool { !paths[0].isEmpty }
    var hasShape: Bool { paths[0].count > 1 }

    enum CodingKeys: CodingKey { case id, kind, network, area, paths, platformLabel, labelAnchors, labelOwner }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(StationLayoutKind.self, forKey: .kind)
        network = RailNetwork(rawValue: try c.decode(String.self, forKey: .network)) ?? .other
        area = try c.decode(Bool.self, forKey: .area)
        let vertices = try c.decode([[[Double]]].self, forKey: .paths)
        func coordinate(_ pair: [Double]) throws -> Coordinate {
            guard pair.count == 2, Coordinate(pair[1], pair[0]).isValid else { throw URLError(.cannotParseResponse) }
            return Coordinate(pair[1], pair[0])
        }
        paths = try vertices.map { try $0.map(coordinate) }
        platformLabel = try c.decodeIfPresent(String.self, forKey: .platformLabel)
        labelOwner = try c.decodeIfPresent(String.self, forKey: .labelOwner)
        labelAnchors = try (c.decodeIfPresent([[Double]].self, forKey: .labelAnchors) ?? []).map(coordinate)
        guard let outer = paths.first, !outer.isEmpty,
              outer.count >= 2 || kind == .platform,
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
        if paths[0].count == 1, kind == .platform {
            return MKCircle(center: alignment.display(paths[0][0]).location, radius: 8)
        }
        let segments = alignment.displaySegments(paths[0]).map { line in
            let points = line.map(\.location)
            return MKPolyline(coordinates: points, count: points.count)
        }
        return MKMultiPolyline(segments)
    }
    func draw(_ context: inout GraphicsContext, projection: RailProjection, dark: Bool) {
        guard let first = paths.first?.first else { return }
        let color = kind.ink(dark: dark)
        if paths[0].count == 1, kind == .platform {
            let radius = CGFloat(5)
            let frame = CGRect(x: projection.screen(first).x - radius, y: projection.screen(first).y - radius,
                               width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: frame), with: .color(color.opacity(kind.opacity)))
            context.stroke(Path(ellipseIn: frame), with: .color(color),
                            style: StrokeStyle(lineWidth: kind.width))
            return
        }
        var path = Path()
        for ring in paths {
            guard let first = ring.first else { continue }
            path.move(to: projection.screen(first))
            for p in ring.dropFirst() { path.addLine(to: projection.screen(p)) }
            if area { path.closeSubpath() }
        }
        if area { context.fill(path, with: .color(color.opacity(kind.opacity)), style: FillStyle(eoFill: true)) }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: kind.width, lineCap: .round,
                                                                     lineJoin: .round, dash: kind.dash))
    }
}

struct PlatformNumberPlacement {
    let id: String
    let text: String
    let coordinate: Coordinate
    let point: CGPoint
    let frame: CGRect

    static func text(_ number: String, scale: CGFloat, light: Bool) -> some View {
        Text(verbatim: number)
            .font(.system(size: 11 * scale, weight: .semibold).monospacedDigit())
            .foregroundStyle(light ? Color.white : Color(red: 0.05, green: 0.20, blue: 0.19))
            .shadow(color: light ? .black : .white, radius: 1)
            .fixedSize().padding(2)
    }
}

private struct LayoutSnapshot: Decodable {
    let features: [StationLayout]
}

// Overlapping station-sized windows keep the surroundings in the query even at Z20.
struct StationLayoutCell: Hashable {
    let y: Int, x: Int
    init(_ point: Coordinate) {
        y = Int((point.latitude * 250).rounded())
        x = Int((point.longitude * 250).rounded())
    }
    init?(filename: String) {
        let parts = filename.split(separator: "_")
        guard parts.count == 2, let y = Int(parts[0]), let x = Int(parts[1]),
              (-21250...21250).contains(y), (-45000...45000).contains(x) else { return nil }
        self.y = y; self.x = x
    }
    var filename: String { "\(y)_\(x)" }
    var bounds: MapBounds {
        let lat = Double(y) / 250, lon = Double(x) / 250
        return MapBounds(south: max(-85, lat - 0.006), west: max(-180, lon - 0.008),
                         north: min(85, lat + 0.006), east: min(180, lon + 0.008))
    }
}

struct StationLayoutVisit {
    let date: Date
    let features: [StationLayout]
    var isFresh: Bool { Date().timeIntervalSince(date) < (features.isEmpty ? 86_400 : 7 * 86_400) }
}

extension RailwayMapStore {
    func focusStationLayouts(at point: Coordinate) {
        guard point.isValid, !historyMapActive else { return }
        let zoom = max(18.3, displayZoom)
        let degreesPerPoint = 360 / (256 * exp2(zoom))
        region = MKCoordinateRegion(center: point.location, span: MKCoordinateSpan(
            latitudeDelta: degreesPerPoint * max(100, viewportHeight) * cos(point.latitude * .pi / 180),
            longitudeDelta: degreesPerPoint * max(320, viewportWidth)))
        if !showsStationLayouts { showsStationLayouts = true }
        cameraRevision += 1
        rebuildVisible()
        if mapMode != .offline { refreshViewport() }
    }

    static func bundledLayouts() -> [StationLayout] {
        guard let url = resourceURL("station-layouts", extension: "json"), let data = try? Data(contentsOf: url),
              let pack = try? JSONDecoder().decode(LayoutSnapshot.self, from: data) else { return [] }
        return pack.features
    }
    func stationLayouts(in bounds: MapBounds, zoom: Double) -> [StationLayout] {
        guard zoom + 0.000001 >= 16, showsStationLayouts, !historyMapActive else { return [] }
        return layoutFeatures.filter { feature in
            let enabled = switch feature.kind {
            case .outline: showsStationOutlines
            case .concourse: showsConcourses
            case .platform: showsPlatforms
            case .passage: showsPassengerPassages
            }
            return enabled && feature.hasGeometry && zoom + 0.000001 >= feature.kind.minimumZoom && feature.bounds.intersects(bounds)
        }
    }

    func platformNumbers(in bounds: MapBounds, zoom: Double, screen: CGRect,
                         project: (Coordinate) -> CGPoint) -> [PlatformNumberPlacement] {
        guard showsStationLayouts, showsPlatformNumbers, !historyMapActive, zoom + 0.000001 >= 18 else { return [] }
        let candidates = layoutFeatures.filter { $0.platformLabel != nil && !$0.labelAnchors.isEmpty && $0.bounds.intersects(bounds) }
        let ids = Set(candidates.map(\.id))
        var placed: [PlatformNumberPlacement] = []
        for feature in candidates.sorted(by: { ($0.area ? 0 : 1, $0.id) < ($1.area ? 0 : 1, $1.id) }) {
            guard let text = feature.platformLabel, !text.isEmpty,
                  !(feature.labelOwner.map(ids.contains) ?? false) else { continue }
            let width = max(13, CGFloat(text.count) * 7.5 + 5) * uiScale
            let height = 17 * uiScale
            for anchor in feature.labelAnchors {
                let point = project(anchor)
                let frame = CGRect(x: point.x - width/2, y: point.y - height/2, width: width, height: height)
                if screen.contains(frame) && !placed.contains(where: { $0.frame.insetBy(dx: -2, dy: -1).intersects(frame) }) {
                    placed.append(.init(id: feature.id, text: text, coordinate: anchor, point: point, frame: frame))
                    break
                }
            }
        }
        return placed
    }

    var stationLayoutHint: String {
        guard !historyMapActive else { return "返回当前地图可查看站区细节。" }
        guard displayZoom >= 16 else { return "放大到 Z16 可查看站区。地铁、轻轨和铁路共用这些开关。" }
        let nearby = layoutFeatures.filter { $0.bounds.intersects(viewportBounds) }
        guard !nearby.isEmpty else {
            return mapMode == .apple ? "放大后会自动查询地图中心附近的站区。" : "本地没有当前视野的站区图形。"
        }
        let counts = Dictionary(grouping: nearby.filter(\.hasGeometry), by: \.kind).mapValues(\.count)
        return "当前视野已收录车站轮廓 \(counts[.outline, default: 0])，站厅 \(counts[.concourse, default: 0])，站台 \(counts[.platform, default: 0])，通道 \(counts[.passage, default: 0])。"
    }
    var currentLayoutStatus: String {
        guard layoutStatusCell == stationLayoutTarget else { return "" }
        return layoutStatus
    }

    var stationLayoutTarget: StationLayoutCell? {
        let point = viewportBounds.center
        guard mapMode == .apple, !historyMapActive, showsStationLayouts, displayZoom + 0.000001 >= 16,
              showsStationOutlines || showsConcourses || showsPlatforms || showsPassengerPassages || showsPlatformNumbers,
              point.isValid, abs(point.latitude) <= 85 else { return nil }
        return StationLayoutCell(point)
    }

    func scheduleStationLayouts(force: Bool = false) {
        let target = stationLayoutTarget
        if !force, target == scheduledLayoutCell {
            guard let target, layoutWork == nil, layoutVisits[target]?.isFresh != true,
                  layoutRetry[target, default: .distantPast] <= Date() else { return }
        }
        layoutWork?.cancel()
        let generation = UUID()
        layoutGeneration = generation
        scheduledLayoutCell = target
        // This may be called by MapKit during a view update. Publish state on the next actor turn.
        layoutWork = Task { [weak self] in
            guard let self, self.layoutGeneration == generation else { return }
            defer { if self.layoutGeneration == generation { self.layoutWork = nil } }
            self.loadingLayouts = false
            guard let target else { return }
            self.layoutStatusCell = target
            if !force, let visit = self.layoutVisits[target], visit.isFresh {
                self.layoutStatus = self.layoutResult(visit.features)
                return
            }
            self.layoutStatus = ""
            if !force {
                if let failed = self.layoutRetry[target], failed > Date() {
                    self.layoutStatus = "上次读取失败，可点「重新查询」重试。"
                    return
                }
                let delay = max(0.8, self.layoutNextRequest.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, self.stationLayoutTarget == target else { return }
            await self.fetchStationLayouts(target, generation: generation)
        }
    }
    private func layoutResult(_ rows: [StationLayout]) -> String {
        rows.isEmpty ? "已查询，OSM 暂无这片站区可绘制的站台、站厅、站体或通道。" : "已读取地图中心附近的 \(rows.count) 个站区要素。"
    }
    private func fetchStationLayouts(_ cell: StationLayoutCell, generation: UUID) async {
        guard let script = Self.resourceURL("station-layouts", extension: "js") else { layoutStatus = "站区读取组件缺失。"; return }
        loadingLayouts = true
        layoutNextRequest = Date().addingTimeInterval(5)
        layoutStatus = "正在查询地图中心附近的站区…"
        defer { if layoutGeneration == generation { loadingLayouts = false } }
        do {
            let data = try await StationLayoutFetch.load(bounds: cell.bounds, endpoint: endpoint.rawValue, script: script,
                                                        session: layoutSession)
            let additions = try JSONDecoder().decode([StationLayout].self, from: data)
            guard !Task.isCancelled, layoutGeneration == generation else { return }
            layoutVisits[cell] = StationLayoutVisit(date: Date(), features: additions)
            layoutRetry.removeValue(forKey: cell)
            let cache = layoutCacheDirectory?.appendingPathComponent("cells-v2", isDirectory: true)
            if let cache {
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try? data.write(to: cache.appendingPathComponent(cell.filename).appendingPathExtension("json"), options: .atomic)
            }
            if layoutVisits.count > 32, let oldest = layoutVisits.min(by: { $0.value.date < $1.value.date })?.key {
                layoutVisits.removeValue(forKey: oldest)
                if let cache { try? FileManager.default.removeItem(at: cache.appendingPathComponent(oldest.filename).appendingPathExtension("json")) }
            }
            rebuildStationLayouts()
            layoutStatus = layoutResult(additions)
        } catch {
            guard !Task.isCancelled, layoutGeneration == generation else { return }
            layoutRetry = layoutRetry.filter { $0.value > Date() }
            layoutRetry[cell] = Date().addingTimeInterval(90)
            layoutStatus = "本次未能联网读取站区。已保存的图形仍可查看，稍后可点「重新查询当前站区」。"
        }
    }
    var layoutCacheDirectory: URL? {
        guard !CommandLine.arguments.contains("--ui-smoke") else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RailwayAtlas/StationLayouts-v1", isDirectory: true)
    }
    func rebuildStationLayouts() {
        var byID = Dictionary(layoutBase.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for visit in layoutVisits.values.sorted(by: { $0.date < $1.date }) {
            for f in visit.features { byID[f.id] = f }
        }
        layoutFeatures = byID.values.sorted { ($0.kind.minimumZoom, $0.id) < ($1.kind.minimumZoom, $1.id) }
    }
    func restoreStationLayouts() {
        guard let dir = layoutCacheDirectory, let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let filesByDate = files.filter { $0.pathExtension == "json" }.sorted {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast <
            (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }.suffix(32)
        let extra = filesByDate.flatMap { url -> [StationLayout] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            // Version-one caches stored raw refs and paths. Recreate the same labels as the live extractor.
            if let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               rows.contains(where: { $0["kind"] as? String == "platform" && $0["platformLabel"] == nil &&
                   ($0["ref"] != nil || $0["name"] != nil || $0["local_ref"] != nil) }),
               let script = Self.resourceURL("station-layouts", extension: "js"),
               let migrated = try? StationLayoutFetch.run(script, method: "prepareFeatures", arguments: [rows]).toArray(),
               let json = try? JSONSerialization.data(withJSONObject: migrated),
               let result = try? JSONDecoder().decode([StationLayout].self, from: json) { return result }
            return (try? JSONDecoder().decode([StationLayout].self, from: data)) ?? []
        }
        layoutBase.append(contentsOf: extra.filter { f in !layoutBase.contains(where: { $0.id == f.id }) })
        let cells = dir.appendingPathComponent("cells-v2", isDirectory: true)
        let recent = (try? FileManager.default.contentsOfDirectory(at: cells, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in recent where url.pathExtension == "json" {
            guard let cell = StationLayoutCell(filename: url.deletingPathExtension().lastPathComponent),
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  let data = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([StationLayout].self, from: data) else { continue }
            layoutVisits[cell] = .init(date: date, features: rows)
        }
        if !extra.isEmpty || !layoutVisits.isEmpty { rebuildStationLayouts() }
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
    static func load(bounds: MapBounds, endpoint: String, script: URL, session: URLSession) async throws -> Data {
        let q = try run(script, method: "query", arguments: [bounds.south,bounds.west,bounds.north,bounds.east]).toString()!
        let center = bounds.center
        guard let sources = try run(script, method: "sources",
            arguments: [center.latitude, center.longitude, endpoint]).toArray() as? [String] else {
            throw URLError(.cannotParseResponse)
        }
        for source in sources {
            try Task.checkCancellation()
            guard let url = URL(string: source) else { continue }
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "data", value: q)]
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("RailwayAtlas/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "local") (+https://github.com/WonGary/railway-atlas)", forHTTPHeaderField: "User-Agent")
            request.setValue("https://wongary.github.io/railway-atlas/", forHTTPHeaderField: "Referer")
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8_000_000 else { continue }
                let document = try JSONSerialization.jsonObject(with: data)
                guard let rows = try run(script, method: "extract", arguments: [document]).toArray() else { continue }
                return try JSONSerialization.data(withJSONObject: rows)
            } catch { try Task.checkCancellation() }
        }
        throw URLError(.badServerResponse)
    }
}
