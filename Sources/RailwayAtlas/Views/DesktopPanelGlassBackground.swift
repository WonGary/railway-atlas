#if os(macOS)
import SwiftUI

/// A live, panel-sized backdrop; panel content stays in its existing SwiftUI tree.
@available(macOS 26.0, *)
struct DesktopPanelGlassBackground: View {
    let cornerRadius: CGFloat
    let opacity: Double

    var body: some View {
        // Let SwiftUI own the material's ordering and inherited appearance.
        // A separate NSGlassEffectView only guarantees ordering for its own
        // contentView, not the SwiftUI panel drawn alongside that native view.
        Color.clear
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(min(1, max(0, opacity)))
    }
}
#endif
