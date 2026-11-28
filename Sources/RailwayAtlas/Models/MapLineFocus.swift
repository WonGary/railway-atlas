import Foundation
import MapKit
import RailwayCore

/// Map-local dimensions. A docked pane is already outside this viewport.
struct LineFitViewport: Equatable {
    var size: CGSize
    var leftFloat: CGRect = .zero
    var rightFloat: CGRect = .zero

    var clearArea: CGRect {
        let viewport = CGRect(origin: .zero, size: size)
        let left = viewport.intersection(leftFloat), right = viewport.intersection(rightFloat)
        let start = left.isEmpty ? 0 : left.maxX
        let end = right.isEmpty ? size.width : right.minX
        guard end > start else { return viewport }
        return CGRect(x: start, y: 0, width: end - start, height: size.height)
    }

    func mapRect(for bounds: MKMapRect) -> MKMapRect? {
        let clear = clearArea
        guard clear.width > 0, clear.height > 0, !bounds.isNull else { return nil }
        // Fill 80% of the limiting dimension. Fractional margins also fit narrow screens.
        let world = MKMapSize.world.width
        let units = max(bounds.width / (clear.width * 0.8), bounds.height / (clear.height * 0.8),
                        world / 360 * 0.008 / size.width)
        let center = MKMapPoint(x: bounds.midX + (size.width / 2 - clear.midX) * units,
                                y: bounds.midY + (size.height / 2 - clear.midY) * units)
        return MKMapRect(x: center.x - size.width * units / 2, y: center.y - size.height * units / 2,
                         width: size.width * units, height: size.height * units)
    }

    func region(for bounds: MKMapRect) -> MKCoordinateRegion? {
        guard let rect = mapRect(for: bounds) else { return nil }
        let center = MKMapPoint(x: rect.midX, y: rect.midY)
        let world = MKMapSize.world.width
        let north = MKMapPoint(x: center.x, y: max(0, rect.minY)).coordinate.latitude
        let south = MKMapPoint(x: center.x, y: min(world, rect.maxY)).coordinate.latitude
        let location = center.coordinate
        // The Canvas fits a symmetric latitude span. Inscribe that span in the
        // projected rectangle so latitude cannot force a second zoom-out.
        return MKCoordinateRegion(center: location, span: MKCoordinateSpan(
            latitudeDelta: min(170, max(0.0001, 2 * min(north - location.latitude, location.latitude - south))),
            longitudeDelta: min(359, rect.width * 360 / world)))
    }
}

/// The focused route outlives the individual station being inspected.
struct MapLineFocus {
    let revision = UUID()
    let title: String
    var featureID: String?
    var stationID: String?
    var routeKey: String?
    var trackName: String?
    var stopNames = Set<String>()
    var paths: [[Coordinate]] = []
    var pathColor: RailColor?
    var directionID: String?
    var directionStops = Set<String>()
    var directory = false
    var inspectionOwner: String?
    var inspectionLayers: [InspectionLayer] = []
    var inspectionDirectory: InspectionLine?
    var inspectionSummary: String?

    func includes(_ line: RailLine) -> Bool {
        if line.id == featureID { return true }
        if let routeKey, line.routes?.contains(where: { $0.visibilityKey == routeKey }) == true { return true }
        guard let trackName else { return false }
        return (line.tags["name:zh"] ?? line.tags["name"]) == trackName
    }

    func includes(_ station: RailStation) -> Bool {
        if directionID != nil { return directionStops.contains(station.id) || directionStops.contains(station.tags["atlas:osm"] ?? "") }
        if let stationID { return station.id == stationID }
        if stopNames.contains(station.name) || stopNames.contains(String(station.name.dropLast(station.name.hasSuffix("站") ? 1 : 0))) { return true }
        guard let routeKey else { return false }
        return station.routes?.contains { $0.visibilityKey == routeKey } == true
    }
}

enum MapContextFiles {
    static let directory: URL = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("station-directory")
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("national.js").path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web/station-directory")
    }()
    private static let index: [String: String] = {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("lines/index.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()
    static func parts(_ name: String, stops: Set<String>? = nil) -> [[Coordinate]] {
        sections(name, stops: stops).map(\.points)
    }

    struct Section: Sendable {
        let from, to: String
        let points: [Coordinate]
    }
    static func sections(_ name: String, stops: Set<String>? = nil) -> [Section] {
        guard let file = index[name],
              let data = try? Data(contentsOf: directory.appendingPathComponent("lines").appendingPathComponent(file)),
              let rows = (try? JSONDecoder().decode([String: [[String]]].self, from: data))?[name] else { return [] }
        return rows.compactMap {
            guard $0.count == 3, stops?.contains($0[0]) != false, stops?.contains($0[1]) != false else { return nil }
            guard let path = try? NationalJourneyPaths.decode($0[2], densify: false), path.count > 1 else { return nil }
            return Section(from: $0[0], to: $0[1], points: path)
        }
    }
}
