import Foundation
import RailwayCore

enum ExperienceCacheExport {
    static func run(_ database: String, output: String, zoom: Int) throws {
        let bounds = MapBounds(south: 22.25, west: 112.6, north: 23.25, east: 114.3)
        let data = try RailExperienceCache.read(URL(fileURLWithPath: database), bounds: bounds, metroOnly: false, zoom: zoom)
        struct Export: Encodable { let lines: [RailLine]; let stations: [RailStation] }
        try JSONEncoder().encode(Export(lines: data.lines, stations: data.stations))
            .write(to: URL(fileURLWithPath: output), options: .atomic)
        print("Exported read-only cached tracks: \(data.lines.count) lines; \(data.stations.count) stations; z\(zoom)")
    }
}
