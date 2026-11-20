import Foundation
import RailwayCore

enum InspectorPane: String, CaseIterable, Identifiable {
    case feature, assistant
    var id: String { rawValue }
    var title: String { self == .feature ? "要素" : "问答" }
}

enum DesktopPanelSide {
    case left, right

    var title: String { self == .left ? "左侧面板" : "右侧面板" }
    var widthRange: ClosedRange<Double> { self == .left ? 250...560 : 200...560 }
}

/// All dimensions are native points. The map is resized, never raster-scaled.
enum DesktopPanelLayout {
    struct Resolved {
        let leftLayout: MapPanelLayout
        let rightLayout: MapPanelLayout
        let leftWidth: Double
        let rightWidth: Double
        let leftFloatingFrame: CGRect
        let rightFloatingFrame: CGRect

        var leftVisible: Bool { leftWidth > 0 }
        var rightVisible: Bool { rightWidth > 0 }
        var leftDockWidth: Double { leftLayout == .docked ? leftWidth : 0 }
        var rightDockWidth: Double { rightLayout == .docked ? rightWidth : 0 }
        var floatingFrames: [CGRect] {
            [leftFloatingFrame, rightFloatingFrame].filter { !$0.isEmpty }
        }
    }

    /// A single budget covers docked and floating panels, leaving an unobscured
    /// map strip. Temporary suppression never changes the saved user preferences.
    static func resolve(viewport: CGSize, scale: Double,
                        leftVisible: Bool, leftLayout: MapPanelLayout, leftWidth: Double, leftSize: MapPanelSize,
                        rightVisible: Bool, rightLayout: MapPanelLayout, rightWidth: Double,
                        priority: DesktopPanelSide = .right) -> Resolved {
        let scale = scale.isFinite ? min(1.6, max(0.75, scale)) : 1
        let width = viewport.width.isFinite ? max(0, viewport.width) : 0
        let height = viewport.height.isFinite ? max(0, viewport.height) : 0
        let margin = 20 * scale, top = 70 * scale
        // Leave the zoom buttons and attribution accessible beside / below floats.
        let rightGutter = 78 * scale
        let floatingHeight = max(0, height - top - 110 * scale)
        let minimumMapWidth = max(260, 280 * scale)
        let leftMinimum = max(250, 250 * scale)
        let rightMinimum = max(200, 200 * scale)
        let leftOverhead = leftLayout == .floating ? margin : 0
        let rightOverhead = rightLayout == .floating ? rightGutter : 0
        let floatsFitVertically = floatingHeight >= 220 * scale
        var showLeft = leftVisible && (leftLayout == .docked || floatsFitVertically)
        var showRight = rightVisible && (rightLayout == .docked || floatsFitVertically)
        let budget = max(0, width - minimumMapWidth)
        let leftCost = leftMinimum + leftOverhead
        let rightCost = rightMinimum + rightOverhead

        if showLeft && showRight && leftCost + rightCost > budget {
            // Prefer the most recently opened panel; selection / GPT opens the right.
            if priority == .left && leftCost <= budget { showRight = false }
            else if rightCost <= budget { showLeft = false }
            else { showRight = false }
        }
        if showLeft && leftCost > budget { showLeft = false }
        if showRight && rightCost > budget { showRight = false }

        func requested(_ value: Double, side: DesktopPanelSide, minimum: Double) -> Double {
            let bounded = value.isFinite
                ? min(side.widthRange.upperBound, max(side.widthRange.lowerBound, value))
                : side.widthRange.lowerBound
            return max(minimum, bounded * scale)
        }
        var left = showLeft ? requested(leftWidth, side: .left, minimum: leftMinimum) : 0
        var right = showRight ? requested(rightWidth, side: .right, minimum: rightMinimum) : 0
        let available = max(0, budget - (showLeft ? leftOverhead : 0) - (showRight ? rightOverhead : 0))
        let leftSlack = showLeft ? left - leftMinimum : 0
        let rightSlack = showRight ? right - rightMinimum : 0
        let slack = leftSlack + rightSlack
        if left + right > available && slack > 0 {
            let fraction = min(1, (left + right - available) / slack)
            left -= leftSlack * fraction
            right -= rightSlack * fraction
        }

        let mapWidth = width - (leftLayout == .docked ? left : 0) - (rightLayout == .docked ? right : 0)
        let desiredLeftHeight: Double
        switch leftSize {
        case .small: desiredLeftHeight = 250 * scale
        case .medium: desiredLeftHeight = 480 * scale
        case .large: desiredLeftHeight = floatingHeight
        }
        let leftFrame = showLeft && leftLayout == .floating
            ? CGRect(x: margin, y: top, width: left, height: min(desiredLeftHeight, floatingHeight)) : .zero
        let rightFrame = showRight && rightLayout == .floating
            ? CGRect(x: mapWidth - rightGutter - right, y: top, width: right, height: floatingHeight) : .zero
        return Resolved(leftLayout: leftLayout, rightLayout: rightLayout,
                        leftWidth: left, rightWidth: right,
                        leftFloatingFrame: leftFrame, rightFloatingFrame: rightFrame)
    }
}
