import MapKit
import RailwayCore
import SwiftUI
#if os(iOS)
import UIKit.UIGestureRecognizerSubclass
#endif

/// Compare in logical screen points. Labels, dots, strokes, then filled interiors.
struct MapFeatureHit {
    enum Feature {
        case station(RailStation), line(RailLine), layout(StationLayout)
    }
    let point: CGPoint
    let zoom: Double
    let touch: Bool
    private(set) var feature: Feature?
    private var best = (Int.max, CGFloat.infinity)
    var detail: Bool { zoom >= RailDisplayPolicy.detailHitZoom }
    var reach: CGFloat { RailDisplayPolicy.trackHitTolerance(zoom: zoom, touch: touch) }
    var padding: CGFloat { RailDisplayPolicy.stationHitPadding(zoom: zoom, touch: touch) }

    init(_ point: CGPoint, zoom: Double, touch: Bool) {
        self.point = point
        self.zoom = zoom
        self.touch = touch
    }
    private mutating func offer(_ candidate: Feature, rank: Int, distance: CGFloat) {
        guard (rank, distance) < best else { return }
        best = (rank, distance)
        feature = candidate
    }
    mutating func station(_ station: RailStation, at center: CGPoint, style: StationAppearance,
                          label: CGRect?, focused: Bool, dimmed: Bool) {
        guard detail || !dimmed else { return }
        if label?.contains(point) == true {
            offer(.station(station), rank: 0, distance: 0)
        } else if detail || label != nil || (style.radius >= 3 && (focused || StationLabelStyle.emphasized(style.kind))) {
            let distance = hypot(point.x-center.x, point.y-center.y)
            if distance <= style.radius + padding { offer(.station(station), rank: focused ? 0 : 1, distance: distance) }
        }
    }
    mutating func line(_ line: RailLine, distance: CGFloat) {
        if detail, distance <= reach { offer(.line(line), rank: 3, distance: distance) }
    }
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
        let t = length > 0 ? max(0, min(1, ((p.x-a.x)*dx+(p.y-a.y)*dy)/length)) : 0
        return hypot(p.x-a.x-t*dx, p.y-a.y-t*dy)
    }
    mutating func layout(_ layout: StationLayout, pointRadius: CGFloat, project: (Coordinate) -> CGPoint) {
        guard detail, zoom + 1e-6 >= layout.kind.minimumZoom, let first = layout.paths.first?.first else { return }
        if !layout.hasShape {
            let center = project(first), distance = hypot(center.x-point.x, center.y-point.y)
            if distance <= pointRadius + padding { offer(.layout(layout), rank: 2, distance: distance) }
            return
        }
        let nw = project(.init(layout.bounds.north, layout.bounds.west)), se = project(.init(layout.bounds.south, layout.bounds.east))
        let bounds = CGRect(x: min(nw.x,se.x), y: min(nw.y,se.y), width: abs(nw.x-se.x), height: abs(nw.y-se.y))
        guard bounds.insetBy(dx: -reach, dy: -reach).contains(point) else { return }
        if layout.area {
            let path = CGMutablePath()
            for ring in layout.paths {
                guard let start = ring.first else { continue }
                path.move(to: project(start))
                for vertex in ring.dropFirst() { path.addLine(to: project(vertex)) }
                path.closeSubpath()
            }
            if path.contains(point, using: .evenOdd) { offer(.layout(layout), rank: 4, distance: bounds.width*bounds.height) }
        } else {
            for path in layout.paths {
                guard let first = path.first else { continue }
                var previous = project(first)
                for vertex in path.dropFirst() {
                    let next = project(vertex), distance = Self.distance(point, previous, next)
                    if distance <= reach { offer(.layout(layout), rank: 3, distance: distance) }
                    previous = next
                }
            }
        }
    }
}

extension StationLayout {
    var selection: RailwaySelection {
        let kindName = switch kind {
        case .outline: "车站轮廓"
        case .concourse: "站厅"
        case .platform: "站台"
        case .passage: "通道"
        case .entrance: "出入口"
        }
        var tags = ["类型": kindName, "网络": network.title, "来源要素": id]
        if let matchedOSM { tags["atlas:osm"] = matchedOSM }
        else if ["node/", "way/", "relation/"].contains(where: id.hasPrefix) { tags["atlas:osm"] = id }
        return RailwaySelection(id: "layout/" + id, name: accessTitle ?? [platformLabel,kindName].compactMap { $0 }.joined(separator: " "),
                                subtitle: kindName, tags: tags, coordinate: labelAnchors.first ?? bounds.center)
    }
}

// Keep MapKit's navigation gestures and SwiftUI's Canvas drag/magnify gestures.
// A pointer which has crossed the pan threshold cannot turn back into a tap.
#if os(macOS)
final class MapFeatureTap: NSGestureRecognizer {
    private var start: CGPoint?
    private var end: CGPoint = .zero
    private var pending: Task<Void,Never>?
    var usesTouch: Bool { false }
    var pickPoint: CGPoint { view?.convert(end, from: nil) ?? .zero }
    func cancelTracking() { start = nil; pending?.cancel(); pending = nil }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        cancelTracking()
        if event.clickCount == 1 { start = event.locationInWindow }
    }
    private func moved(_ event: NSEvent) -> Bool {
        guard let start else { return false }
        let p = event.locationInWindow
        return hypot(p.x-start.x,p.y-start.y) >= 3
    }
    override func mouseDragged(with event: NSEvent) {
        if moved(event) { cancelTracking() } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        let accept = start != nil && !moved(event) && event.clickCount == 1
        super.mouseUp(with: event)
        start = nil
        guard accept else { return }
        end = event.locationInWindow
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled, let self, self.view?.window != nil, let action = self.action else { return }
            NSApp.sendAction(action, to: self.target, from: self)
        }
    }
    override func magnify(with event: NSEvent) { cancelTracking(); super.magnify(with: event) }
    override func reset() { super.reset(); start = nil }
    override func canPrevent(_ preventedGestureRecognizer: NSGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: NSGestureRecognizer) -> Bool { false }
}
private final class CanvasTapView: NSView {
    override var isFlipped: Bool { true }
}
#else
final class MapFeatureTap: UITapGestureRecognizer {
    private var start: CGPoint?
    private(set) var usesTouch = true
    var pickPoint: CGPoint { location(in: view) }
    func cancelTracking() { if start != nil, state == .possible { state = .failed } }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard start == nil, touches.count == 1, let touch = touches.first, touch.tapCount < 2 else { state = .failed; return }
        start = touch.location(in: nil)
        usesTouch = touch.type != .indirectPointer
        super.touchesBegan(touches, with: event)
    }
    private func moved(_ touches: Set<UITouch>) -> Bool {
        guard let start, let p = touches.first?.location(in: nil) else { return true }
        return hypot(p.x-start.x,p.y-start.y) >= (usesTouch ? 5 : 3)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if moved(touches) { cancelTracking() } else { super.touchesMoved(touches, with: event) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if moved(touches) { cancelTracking() } else { super.touchesEnded(touches, with: event) }
    }
    override func reset() { super.reset(); start = nil }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of other: UIGestureRecognizer) -> Bool {
        (other as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 || super.shouldRequireFailure(of: other)
    }
}
#endif

struct CanvasTapSurface: PlatformMapRepresentable {
    var select: (CGPoint, Bool) -> Void
    @MainActor final class Coordinator: NSObject {
        var select: (CGPoint, Bool) -> Void
        init(_ select: @escaping (CGPoint, Bool) -> Void) { self.select = select }
        @objc func tap(_ recognizer: MapFeatureTap) {
            select(recognizer.pickPoint, recognizer.usesTouch)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(select) }
    #if os(macOS)
    func makeNSView(context: Context) -> NSView {
        let view = CanvasTapView()
        let tap = MapFeatureTap(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(tap)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.select = select }
    #else
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isMultipleTouchEnabled = true
        let tap = MapFeatureTap(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.select = select }
    #endif
}
