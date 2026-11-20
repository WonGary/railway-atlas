import Foundation
import MapKit
import Network
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
