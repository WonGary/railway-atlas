#if os(macOS)
import RailwayCore
import SwiftUI

struct DesktopPanelSurface: ViewModifier {
    let cornerRadius: CGFloat
    let opacity: Double
    let mode: AtlasSurfaceMode
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.atlasMapSurface(mode: mode, opacity: opacity, cornerRadius: cornerRadius)
            .overlay {
                if mode != .textOnly, opacity > 0, cornerRadius > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.primary.opacity((contrast == .increased ? 0.35 : 0.14) * opacity),
                                      lineWidth: (contrast == .increased ? 2 : 1) / max(1, displayScale))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
}
#endif
