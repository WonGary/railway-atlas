import RailwayCore
import SwiftUI

typealias MapControl = AtlasConfiguration.MapControl

/// A map window owns these overrides. Hiding a control does not edit startup preferences.
struct MapControlVisibility {
    private var overrides: [MapControl: Bool] = [:]
    func shows(_ control: MapControl, byDefault visible: Bool = true) -> Bool {
        overrides[control] ?? visible
    }
    mutating func set(_ control: MapControl, _ visible: Bool?) {
        overrides[control] = visible
    }
}

private struct MapDecorationOpacity: EnvironmentKey {
    static let defaultValue = 1.0
}

// An isolated UI test can locate the actual controls even when the macOS login
// screen suspends virtual accessibility elements. Ordinary windows do not measure them.
private struct MeasureMapActions: EnvironmentKey { static let defaultValue = false }
struct MapActionFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension EnvironmentValues {
    var measureMapActions: Bool {
        get { self[MeasureMapActions.self] }
        set { self[MeasureMapActions.self] = newValue }
    }
    var mapDecorationOpacity: Double {
        get { self[MapDecorationOpacity.self] }
        set { self[MapDecorationOpacity.self] = newValue }
    }
}

private struct MapActionIdentifier: ViewModifier {
    let id: String
    @Environment(\.measureMapActions) private var measure
    func body(content: Content) -> some View {
        content.accessibilityIdentifier(id).background {
            if measure {
                GeometryReader { proxy in
                    Color.clear.preference(key: MapActionFrames.self,
                                           value: [id: proxy.frame(in: .named("measured-map-controls"))])
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

struct AtlasMapBackdrop: View {
    let mode: AtlasSurfaceMode
    let opacity: Double
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if mode != .textOnly, opacity > 0 {
            if reduceTransparency {
                shape.fill(.background)
            } else if mode == .translucent {
                shape.fill(.thinMaterial).opacity(opacity)
            } else if #available(iOS 26, macOS 26, *) {
                Color.clear.glassEffect(.regular, in: shape).opacity(opacity)
            } else {
                shape.fill(.regularMaterial).opacity(opacity)
            }
        }
    }
}

struct AtlasGlassControls<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}

private struct ConfiguredMapSurface: ViewModifier {
    @EnvironmentObject private var configuration: ConfigurationStore
    let control: MapControl
    let radius: CGFloat
    func body(content: Content) -> some View {
        let settings = configuration.interfaceSettings
        content.atlasMapSurface(mode: settings.surfaceMode, opacity: settings[keyPath: control.opacity],
                                cornerRadius: radius)
    }
}

private struct MapPanelDecoration<Style: ShapeStyle, S: InsettableShape>: ViewModifier {
    @Environment(\.mapDecorationOpacity) private var opacity
    let style: Style
    let shape: S
    let border: Color?
    func body(content: Content) -> some View {
        content.background {
            if opacity > 0 {
                ZStack {
                    shape.fill(style)
                    if let border { shape.strokeBorder(border) }
                }.opacity(opacity).allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func atlasMapActionID(_ id: String) -> some View { modifier(MapActionIdentifier(id: id)) }

    func atlasMapSurface(mode: AtlasSurfaceMode, opacity: Double, cornerRadius: CGFloat) -> some View {
        environment(\.mapDecorationOpacity, mode == .textOnly ? 0 : opacity)
            .background {
                AtlasMapBackdrop(mode: mode, opacity: opacity, cornerRadius: cornerRadius)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }

    func atlasMapControl(_ control: MapControl, radius: CGFloat) -> some View {
        modifier(ConfiguredMapSurface(control: control, radius: radius))
    }

    func atlasPanelDecoration<S: InsettableShape>(_ style: some ShapeStyle, in shape: S,
                                                  border: Color? = nil) -> some View {
        modifier(MapPanelDecoration(style: style, shape: shape, border: border))
    }

    func atlasMapSheet(mode: AtlasSurfaceMode, opacity: Double) -> some View {
        environment(\.mapDecorationOpacity, mode == .textOnly ? 0 : opacity)
            .presentationBackground {
                ZStack {
                    Color.clear
                    AtlasMapBackdrop(mode: mode, opacity: opacity, cornerRadius: 0)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}
