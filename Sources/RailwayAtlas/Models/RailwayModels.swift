import MapKit
import RailwayCore
import SwiftUI
import UniformTypeIdentifiers

enum MapMode: String, CaseIterable, Identifiable {
    case apple, cached, offline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "全国在线"
        case .cached: "仅使用缓存"
        case .offline: "本地地图包"
        }
    }
    var icon: String { self == .apple ? "globe.asia.australia" : "internaldrive" }
}

struct RailwaySelection: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let tags: [String: String]
    let coordinate: Coordinate
    var isStation: Bool { ["station", "halt", "tram_stop"].contains(tags["railway"] ?? "") }
    var osmReference: String? {
        if let value = tags["atlas:osm"] { return value }
        let parts = id.split(separator: "/")
        return parts.count == 2 && ["way", "node", "relation"].contains(parts[0]) ? id : nil
    }
}

extension RailCategory {
    var tint: Color { color.tint }
    var icon: String {
        switch self {
        case .speed350, .speed300, .speed250, .speed200, .speed160, .below160: "tram.fill"
        case .unknown: "questionmark.circle"
        case .urban: "tram"
        case .freight: "shippingbox"
        case .branch, .service: "arrow.triangle.branch"
        case .construction: "hammer"
        case .disused, .abandoned: "clock"
        }
    }
}

extension RailColor {
    var tint: Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1) }
}

struct RailRenderGroup {
    let appearance: RailAppearance
    let lines: [RailLine]
    let path: CGPath
    let geometryToken: UUID
}

extension Coordinate {
    var location: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var mapPoint: MKMapPoint { MKMapPoint(location) }
}

extension MapBounds {
    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: center.location,
            span: MKCoordinateSpan(latitudeDelta: north - south, longitudeDelta: east - west)
        )
    }

    init(region: MKCoordinateRegion) {
        self.init(
            south: max(-84.9, region.center.latitude - region.span.latitudeDelta / 2),
            west: max(-180, region.center.longitude - region.span.longitudeDelta / 2),
            north: min(84.9, region.center.latitude + region.span.latitudeDelta / 2),
            east: min(180, region.center.longitude + region.span.longitudeDelta / 2)
        )
    }
}

struct RailwayFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct RailwayCacheFile: FileDocument {
    static var readableContentTypes: [UTType] { [.railwayCache, .data] }
    var file: URL?
    var data: Data?
    init(file: URL) { self.file = file }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let file { return try FileWrapper(url: file, options: []) }
        return FileWrapper(regularFileWithContents: data ?? Data())
    }
}

extension UTType {
    static let railwayCache = UTType(exportedAs: "app.railwayatlas.cache", conformingTo: .database)
}
