import SwiftUI
#if os(macOS)
import AppKit
#endif

extension Color {
    #if os(macOS)
    static let railwayAccent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            NSColor(srgbRed: 0.40, green: 0.72, blue: 0.90, alpha: 1)
        } else {
            NSColor(srgbRed: 0.14, green: 0.38, blue: 0.54, alpha: 1)
        }
    })
    #else
    static let railwayAccent = Color(red: 0.14, green: 0.38, blue: 0.54)
    #endif
    static let railwayCanvas = Color(red: 0.955, green: 0.957, blue: 0.95)
}
