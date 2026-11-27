import RailwayCore
import SwiftUI

/// Shared surface treatment for controls that sit directly on the map.
/// The content remains fully opaque so lowering the background alpha does not
/// weaken labels or hit targets.
struct AtlasMapSurface: ViewModifier {
    let mode: AtlasSurfaceMode
    let opacity: Double
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.background {
            surface
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        switch mode {
        case .textOnly:
            Color.clear
        case .translucent:
            shape.fill(.thinMaterial).opacity(clampedOpacity)
        case .glass:
            #if os(macOS)
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular, in: shape)
                    .opacity(clampedOpacity)
            } else {
                shape.fill(.regularMaterial).opacity(clampedOpacity)
            }
            #elseif os(iOS)
            if #available(iOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular, in: shape)
                    .opacity(clampedOpacity)
            } else {
                shape.fill(.regularMaterial).opacity(clampedOpacity)
            }
            #else
            shape.fill(.regularMaterial).opacity(clampedOpacity)
            #endif
        }
    }

    private var clampedOpacity: Double {
        min(1, max(0, opacity))
    }
}

extension View {
    func atlasMapSurface(mode: AtlasSurfaceMode, opacity: Double,
                         cornerRadius: CGFloat) -> some View {
        modifier(AtlasMapSurface(mode: mode, opacity: opacity,
                                 cornerRadius: cornerRadius))
    }
}
