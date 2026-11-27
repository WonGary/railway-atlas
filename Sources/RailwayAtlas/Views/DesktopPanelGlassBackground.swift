#if os(macOS)
import RailwayCore
import SwiftUI

/// A live, panel-sized backdrop; panel content stays in its existing SwiftUI tree.
struct DesktopPanelGlassBackground: View {
    let cornerRadius: CGFloat
    let opacity: Double
    var mode: AtlasSurfaceMode = .glass

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        switch mode {
        case .glass:
            if #available(macOS 26.0, *) {
                // Let SwiftUI own the material's ordering and inherited
                // appearance. A separate NSGlassEffectView only guarantees
                // ordering for its own contentView.
                Color.clear
                    .glassEffect(.regular, in: shape)
                    .opacity(clampedOpacity)
            } else {
                shape.fill(.regularMaterial).opacity(clampedOpacity)
            }
        case .translucent:
            shape.fill(.thinMaterial).opacity(clampedOpacity)
        case .textOnly:
            Color.clear
        }
    }

    private var clampedOpacity: Double {
        min(1, max(0, opacity))
    }
}
#endif
