import Foundation
import MapKit
import Network
import RailwayCore
import SwiftUI

enum BasemapStyle: String, CaseIterable, Identifiable {
    case standard, satellite, hybrid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "标准地图"
        case .satellite: "卫星影像"
        case .hybrid: "卫星与地名"
        }
    }
    var mapType: MKMapType {
        switch self {
        case .standard: .standard
        case .satellite: .satellite
        case .hybrid: .hybrid
        }
    }
}

enum BasemapSource: String, CaseIterable, Identifiable {
    case apple
    case gaode
    case openStreetMap
    case openFreeMap
    case versaTiles
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple 地图"
        case .gaode: "高德地图"
        case .openStreetMap: "OpenStreetMap"
        case .openFreeMap: "OpenFreeMap · 矢量"
        case .versaTiles: "VersaTiles · 矢量"
        case .custom: "自定义栅格瓦片"
        }
    }

    var detail: String {
        switch self {
        case .apple: "MapKit 原生底图"
        case .gaode: "高德公开栅格瓦片"
        case .openStreetMap: "OSM 标准栅格地图"
        case .openFreeMap, .versaTiles: "街道、建筑和中文地名"
        case .custom: "填写带 {z}、{x}、{y} 的 HTTPS 地址"
        }
    }

    var defaultAlignment: MapAlignment {
        switch self {
        case .openStreetMap, .openFreeMap, .versaTiles, .custom: .wgs84
        case .apple: .mainlandGCJ
        case .gaode: .mainlandOnlyGCJ
        }
    }

    var attributionTitle: String {
        switch self {
        case .apple: "Apple 地图"
        case .gaode: "高德地图"
        case .openStreetMap: "© OpenStreetMap contributors"
        case .openFreeMap: "OpenFreeMap"
        case .versaTiles: "VersaTiles"
        case .custom: "自定义底图"
        }
    }

    var attributionURL: URL? {
        switch self {
        case .apple: URL(string: "https://www.apple.com/maps/")
        case .gaode: URL(string: "https://lbs.amap.com/")
        case .openStreetMap: URL(string: "https://www.openstreetmap.org/copyright")
        case .openFreeMap: URL(string:"https://openfreemap.org/")
        case .versaTiles: URL(string:"https://versatiles.org/")
        case .custom: nil
        }
    }

    var isVector: Bool { self == .openFreeMap || self == .versaTiles }
    static let standardChoices: [BasemapSource] = [.apple, .gaode, .openStreetMap, .versaTiles, .openFreeMap, .custom]
    static let satelliteChoices: [BasemapSource] = [.apple, .gaode, .custom]

    func template(for style: BasemapStyle, customStandard: String, customSatellite: String) -> String? {
        switch self {
        case .apple, .openFreeMap, .versaTiles:
            return nil
        case .gaode:
            switch style {
            case .standard:
                return "https://webrd01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=7&x={x}&y={y}&z={z}"
            case .satellite, .hybrid:
                return "https://webst01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=6&x={x}&y={y}&z={z}"
            }
        case .openStreetMap:
            guard style == .standard else { return nil }
            return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        case .custom:
            let value = style == .standard ? customStandard : customSatellite
            return Self.validatedTemplate(value)
        }
    }

    static func validatedTemplate(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return AtlasConfiguration.validStreetTemplate(value) ? value : nil
    }
}

@MainActor
final class Connectivity: ObservableObject {
    @Published var available = true
    private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.available = available }
        }
        monitor.start(queue: DispatchQueue(label: "app.railwayatlas.connectivity"))
    }
}

private struct AtlasUIScaleKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var atlasUIScale: Double {
        get { self[AtlasUIScaleKey.self] }
        set { self[AtlasUIScaleKey.self] = newValue }
    }
}

/// Change layout metrics, never the render surface or its displayScale.
/// MapKit, text and Canvas keep the window's native backing pixel density.
struct AtlasInterface<Content: View>: View {
    let scale: Double
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .font(AtlasFont.body.resolved(scale))
            .controlSize(scale >= 1.25 ? .large : scale < 0.9 ? .small : .regular)
            .environment(\.atlasUIScale, scale)
    }
}

struct AtlasFont {
    var size: Double
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    var digits = false
    static func system(size: Double, weight: Font.Weight = .regular, design: Font.Design = .default) -> Self {
        Self(size: size, weight: weight, design: design)
    }
    #if os(macOS)
    static let body = Self(size: 13)
    static let headline = Self(size: 13, weight: .semibold)
    static let subheadline = Self(size: 12)
    static let caption = Self(size: 11)
    static let caption2 = Self(size: 10)
    static let title2 = Self(size: 17)
    static let title3 = Self(size: 15)
    #else
    static let body = Self(size: 17)
    static let headline = Self(size: 17, weight: .semibold)
    static let subheadline = Self(size: 15)
    static let caption = Self(size: 12)
    static let caption2 = Self(size: 11)
    static let title2 = Self(size: 22)
    static let title3 = Self(size: 20)
    #endif
    func weight(_ value: Font.Weight) -> Self { var result = self; result.weight = value; return result }
    func bold() -> Self { weight(.bold) }
    func monospaced() -> Self { var result = self; result.design = .monospaced; return result }
    func monospacedDigit() -> Self { var result = self; result.digits = true; return result }
    func resolved(_ scale: Double) -> Font {
        let font = Font.system(size: size * scale, weight: weight, design: design)
        return digits ? font.monospacedDigit() : font
    }
}

private struct AtlasFontModifier: ViewModifier {
    @Environment(\.atlasUIScale) private var scale
    let font: AtlasFont
    func body(content: Content) -> some View { content.font(font.resolved(scale)) }
}
private struct AtlasPadding: ViewModifier {
    @Environment(\.atlasUIScale) private var scale
    let edges: Edge.Set
    let length: Double
    func body(content: Content) -> some View { content.padding(edges, length * scale) }
}
private struct AtlasFrame: ViewModifier {
    @Environment(\.atlasUIScale) private var scale
    let width: Double?
    let height: Double?
    let alignment: Alignment
    func body(content: Content) -> some View {
        content.frame(width: width.map { $0 * scale }, height: height.map { $0 * scale }, alignment: alignment)
    }
}
private struct AtlasControlSize: ViewModifier {
    @Environment(\.atlasUIScale) private var scale
    let size: ControlSize
    func body(content: Content) -> some View {
        content.controlSize(scale >= 1.25 ? (size == .mini ? .small : size == .small ? .regular : .large) : size)
    }
}
extension View {
    func atlasFont(_ font: AtlasFont) -> some View { modifier(AtlasFontModifier(font: font)) }
    func atlasPadding(_ edges: Edge.Set = .all, _ length: Double = 16) -> some View {
        modifier(AtlasPadding(edges: edges, length: length))
    }
    func atlasPadding(_ length: Double) -> some View { atlasPadding(.all, length) }
    func atlasFrame(width: Double? = nil, height: Double? = nil, alignment: Alignment = .center) -> some View {
        modifier(AtlasFrame(width: width, height: height, alignment: alignment))
    }
    func atlasControlSize(_ size: ControlSize) -> some View { modifier(AtlasControlSize(size: size)) }
}
extension Text {
    // Canvas needs Text, not an opaque ModifiedContent. It resolves glyphs at
    // the target point size directly into the native-resolution draw context.
    func atlasFont(_ font: AtlasFont, scale: Double) -> Text { self.font(font.resolved(scale)) }
}

struct AtlasSheetLayout: ViewModifier {
    let scale: Double
    let width: Double
    let height: Double
    func body(content: Content) -> some View {
        AtlasInterface(scale: scale) { content }
        #if os(macOS)
            .frame(width: min(width * scale, (NSScreen.main?.visibleFrame.width ?? 1200) - 80),
                   height: min(height * scale, (NSScreen.main?.visibleFrame.height ?? 900) - 90))
        #endif
    }
}
