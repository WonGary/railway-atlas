import Foundation
import RailwayCore

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
    var directory = false

    func includes(_ line: RailLine) -> Bool {
        if line.id == featureID { return true }
        if let routeKey, line.routes?.contains(where: { $0.visibilityKey == routeKey }) == true { return true }
        guard let trackName else { return false }
        return (line.tags["name:zh"] ?? line.tags["name"]) == trackName
    }

    func includes(_ station: RailStation) -> Bool {
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
        guard let file = index[name],
              let data = try? Data(contentsOf: directory.appendingPathComponent("lines").appendingPathComponent(file)),
              let rows = (try? JSONDecoder().decode([String: [[String]]].self, from: data))?[name] else { return [] }
        return rows.compactMap {
            guard $0.count == 3, stops?.contains($0[0]) != false, stops?.contains($0[1]) != false else { return nil }
            return try? NationalJourneyPaths.decode($0[2], densify: false)
        }
    }
}
