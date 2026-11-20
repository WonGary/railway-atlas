#if os(macOS)
import AppKit
import MapKit
import RailwayCore

/// Explicit QA snapshots of the real basemap with cached OSM rail geometry.
@MainActor
enum BorderUIValidation {
    static func inspectMacao(data: URL, directory: URL, hongKong: Bool = false, satellite: Bool = false) async throws {
        let features = try MetroRouteDecoder.decode(Data(contentsOf: data))
        let lines = features.lines.filter { !($0.routes ?? []).isEmpty }
        guard !lines.isEmpty else { throw DataError.invalid("Macao OSM routes missing") }
        var notes: [String] = []
        let places = hongKong ? [
            ("hongkong-luohu", Coordinate(22.5315, 114.1138), 0.024),
            ("hongkong-lok-ma-chau", Coordinate(22.5185, 114.0658), 0.024),
            ("hongkong-hung-hom", Coordinate(22.3065, 114.183), 0.025),
            ("hongkong-airport", Coordinate(22.315, 113.938), 0.04)
        ] : [
            ("macao-taipa", Coordinate(22.154, 113.568), 0.045),
            ("macao-barra", Coordinate(22.181, 113.531), 0.022),
            ("macao-hengqin", Coordinate(22.137, 113.546), 0.025)
        ]
        for (name, centre, span) in places {
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: centre.location, span: .init(latitudeDelta: span, longitudeDelta: span * 1.3))
            options.size = CGSize(width: 1000, height: 750)
            options.pointOfInterestFilter = .excludingAll
            options.appearance = NSAppearance(named: .aqua)
            options.mapType = satellite ? .satellite : .standard
            let snapshotter = MKMapSnapshotter(options: options)
            let timeout = Task { @MainActor in try await Task.sleep(for: .seconds(35)); snapshotter.cancel() }
            defer { timeout.cancel() }
            let snapshot = try await snapshotter.start()
            for mode in ["wgs84", "mainland-mask", "china-basemap", "unmasked-gcj-probe"] {
                func display(_ point: Coordinate) -> Coordinate {
                    switch mode {
                    case "wgs84": point
                    case "mainland-mask": MapAlignment.mainlandOnlyGCJ.display(point)
                    case "china-basemap": MapAlignment.mainlandGCJ.display(point)
                    default: MapAlignment.gcj02Projection(point)
                    }
                }
                let image = NSImage(size: options.size)
                image.lockFocus()
                snapshot.image.draw(in: CGRect(origin: .zero, size: options.size))
                NSColor.systemRed.setStroke()
                for line in lines {
                    let path = NSBezierPath()
                    let segments = mode == "mainland-mask" ? MapAlignment.mainlandOnlyGCJ.displaySegments(line.coordinates)
                        : mode == "china-basemap" ? MapAlignment.mainlandGCJ.displaySegments(line.coordinates)
                        : [line.coordinates.map(display)]
                    for points in segments {
                        guard let first = points.first else { continue }
                        path.move(to: snapshot.point(for: first.location))
                        for point in points.dropFirst() { path.line(to: snapshot.point(for: point.location)) }
                    }
                    path.lineWidth = 2; path.stroke()
                }
                for station in features.stations {
                    let point = snapshot.point(for: display(station.coordinate).location)
                    guard CGRect(origin: .zero, size: options.size).contains(point) else { continue }
                    NSColor.white.setFill()
                    let marker = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                    marker.fill(); NSColor.systemRed.setStroke(); marker.stroke()
                    (station.name as NSString).draw(at: CGPoint(x: point.x + 5, y: point.y + 3), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black,
                        .backgroundColor: NSColor.white.withAlphaComponent(0.85)
                    ])
                }
                ("\(name) · \(mode)" as NSString).draw(at: CGPoint(x: 16, y: 18), withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.black,
                    .backgroundColor: NSColor.white.withAlphaComponent(0.9)
                ])
                image.unlockFocus()
                guard let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    throw DataError.invalid("Macao snapshot encoding")
                }
                try png.write(to: directory.appendingPathComponent("\(name)-\(mode).png"))
            }
            let delta = MapAlignment.distance(centre, MapAlignment.mainlandGCJ.display(centre))
            notes.append("\(name): real Apple \(satellite ? "satellite" : "standard") basemap; WGS84, old mainland-only mask, corrected China-domain mask, unmasked control. Projection at centre: \(String(format: "%.1f", delta)) m; this is transform distance, not residual error.")
        }
        try Data(notes.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("coordinate-comparison.txt"))
    }

    static func run(repository: RailwayTileRepository, directory: URL) async throws -> [String] {
        let keys = (6691...6693).flatMap { x in (3568...3570).flatMap { y in
            [RailTileKey(layer: .tracks, tile: RailTile(z: 13, x: x, y: y)),
             RailTileKey(layer: .stations, tile: RailTile(z: 13, x: x, y: y))]
        } }
        let tiles = try await repository.cached(keys, source: RailwayTileRepository.defaultSource)
        let lines = tiles.flatMap { $0.features.lines }, stations = tiles.flatMap { $0.features.stations }
        guard lines.count > 100 else { throw DataError.invalid("Shenzhen–Hong Kong actual rail geometry missing") }
        let started = Date()
        let parts = lines.map { MapAlignment.mainlandGCJ.displaySegments($0.coordinates) }
        var notes = [String(format: "Shenzhen/Hong Kong: %d cached real OSM fragments (%d vertices), projected/split in %.3fs.",
                            lines.count, lines.reduce(0) { $0 + $1.coordinates.count }, Date().timeIntervalSince(started))]
        for (name, centre) in [("luohu", Coordinate(22.5315, 114.1138)), ("lok-ma-chau", Coordinate(22.5185, 114.0658))] {
            let options = MKMapSnapshotter.Options()
            let shown = MapAlignment.mainlandGCJ.display(centre)
            options.region = MKCoordinateRegion(center: shown.location, span: .init(latitudeDelta: 0.024, longitudeDelta: 0.032))
            options.size = CGSize(width: 1000, height: 750)
            options.pointOfInterestFilter = .excludingAll
            options.appearance = NSAppearance(named: .aqua)
            let snapshotter = MKMapSnapshotter(options: options)
            let timeout = Task { @MainActor in try await Task.sleep(for: .seconds(40)); snapshotter.cancel() }
            defer { timeout.cancel() }
            let snapshot = try await snapshotter.start()
            for alignment in [MapAlignment.wgs84, .mainlandGCJ] {
                let image = NSImage(size: options.size)
                image.lockFocus()
                snapshot.image.draw(in: CGRect(origin: .zero, size: options.size))
                for (index, line) in lines.enumerated() {
                    let path = NSBezierPath()
                    for segment in alignment == .wgs84 ? [line.coordinates] : parts[index] {
                        guard let first = segment.first else { continue }
                        path.move(to: snapshot.point(for: first.location))
                        for point in segment.dropFirst() { path.line(to: snapshot.point(for: point.location)) }
                    }
                    for stroke in line.appearance.strokes(zoom: 14) {
                        NSColor(stroke.color.tint).setStroke()
                        path.lineWidth = stroke.width
                        path.setLineDash(stroke.dash.map { CGFloat($0) }, count: stroke.dash.count, phase: stroke.phase)
                        path.stroke()
                    }
                }
                for station in stations {
                    let point = snapshot.point(for: alignment.display(station.coordinate).location)
                    guard CGRect(origin: .zero, size: options.size).contains(point) else { continue }
                    NSColor.white.setFill()
                    let circle = NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                    circle.fill(); NSColor.systemBlue.setStroke(); circle.lineWidth = 1.7; circle.stroke()
                    (station.name as NSString).draw(at: CGPoint(x: point.x + 8, y: point.y + 2), withAttributes: [
                        .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
                        .backgroundColor: NSColor.white.withAlphaComponent(0.85)
                    ])
                }
                ("\(name) · \(alignment.title)" as NSString).draw(at: CGPoint(x: 18, y: 20), withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.black,
                    .backgroundColor: NSColor.white.withAlphaComponent(0.9)
                ])
                image.unlockFocus()
                guard let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    throw DataError.invalid("Border snapshot encoding failed")
                }
                try png.write(to: directory.appendingPathComponent("border-\(name)-\(alignment.rawValue).png"))
            }
            notes.append("\(name): real MapKit basemap captured with raw/corrected OSM overlays; visual comparison required.")
        }
        return notes
    }
}
#endif
