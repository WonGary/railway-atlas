#if os(macOS)
import AppKit
import Foundation
import MapKit
import RailwayCore
import SwiftUI

/// Window-event coordinates include the title bar. Resolve them from the actual map view.
struct FramingEventSurface: NSViewRepresentable {
    final class Marker: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

/// Local QA only; no assistant request or credential access.
///
/// Main-thread hooks (not applied by this file):
/// 1. Add "--v020-panel-layout-check" to RailwayMapStore.start()'s offline QA flags.
/// 2. In OnlineUIValidation.runIfRequested, before the other QA branches:
///      if arguments.contains(PanelLayoutValidation.flag) {
///          try await PanelLayoutValidation.run(store: store, assistant: assistant,
///                                              window: window, directory: directory)
///          NSApp.terminate(nil)
///          return
///      }
/// 3. Include this file in the macOS Xcode Sources phase. Launch with
///      --ui-smoke <isolated-directory> --v020-panel-layout-check
///
/// MapKit / railway layers may perform their ordinary map refresh; network
/// completeness is never a success condition. GPT uses seeded text, never send().
/// Only the pre-build10 AssistantStore interface is required.
/// The native-map identity interval never changes map mode or replaces the root.
@MainActor
enum PanelLayoutValidation {
    static let flag = "--v020-panel-layout-check"
    private static let bodyMarker = "PANEL BODY VISIBLE"
    private static let tolerance = 1.5

    /// Pure layout contracts; callable independently without a window or files.
    static func validateAlgorithm() throws -> [String] {
        var notes: [String] = []
        let wide = CGSize(width: 1240, height: 820)
        for (left, right) in combinations {
            let layout = resolve(wide, left: left, right: right)
            try require(layout.leftVisible && layout.rightVisible,
                        "algorithm \(left)/\(right): both panels should fit")
            try require(near(layout.leftWidth, 320) && near(layout.rightWidth, 380),
                        "algorithm \(left)/\(right): sufficient space preserves preferred widths")
            try require(near(layout.leftDockWidth, left == .docked ? 320 : 0)
                        && near(layout.rightDockWidth, right == .docked ? 380 : 0),
                        "algorithm \(left)/\(right): only docked panels reserve map width")
            try require(layout.leftFloatingFrame.isEmpty == (left == .docked)
                        && layout.rightFloatingFrame.isEmpty == (right == .docked),
                        "algorithm \(left)/\(right): floating frames match presentation")
            try checkGeometry(layout, viewport: wide, scale: 1)
        }
        notes.append("PASS algorithm: all four floating/docked combinations, reservations and nonoverlap.")

        // 75% must not shrink the physical minimum below 250 / 200 points.
        let minimum = DesktopPanelLayout.resolve(
            viewport: wide, scale: 0.75,
            leftVisible: true, leftLayout: .floating, leftWidth: 250, leftSize: .medium,
            rightVisible: true, rightLayout: .floating, rightWidth: 200)
        try require(near(minimum.leftWidth, 250) && near(minimum.rightWidth, 200),
                    "algorithm: physical minimum widths at 75%")
        try checkGeometry(minimum, viewport: wide, scale: 0.75)

        let narrow = CGSize(width: 960, height: 650)
        for priority in [DesktopPanelSide.left, .right] {
            let layout = resolve(narrow, scale: 1.6, priority: priority)
            try require(layout.leftVisible == (priority == .left)
                        && layout.rightVisible == (priority == .right),
                        "algorithm: narrow window honors \(priority) priority")
            try checkGeometry(layout, viewport: narrow, scale: 1.6)
        }
        let restored = resolve(CGSize(width: 1920, height: 900), scale: 1.6)
        try require(restored.leftVisible && restored.rightVisible
                    && near(restored.leftWidth, 512) && near(restored.rightWidth, 608),
                    "algorithm: expanding restores both original preferred widths")
        let tiny = resolve(CGSize(width: 440, height: 650))
        let short = resolve(CGSize(width: 1240, height: 300))
        try require(!tiny.leftVisible && !tiny.rightVisible && tiny.floatingFrames.isEmpty,
                    "algorithm: extremely narrow viewport releases both panels")
        try require(!short.leftVisible && !short.rightVisible && short.floatingFrames.isEmpty,
                    "algorithm: insufficient height suppresses floating panels")
        notes.append("PASS algorithm: physical minima, 160% priority switching, expansion, tiny/short viewports.")

        let heights = MapPanelSize.allCases.map {
            DesktopPanelLayout.resolve(
                viewport: CGSize(width: 1240, height: 1000), scale: 1,
                leftVisible: true, leftLayout: .floating, leftWidth: 320, leftSize: $0,
                rightVisible: false, rightLayout: .docked, rightWidth: 380).leftFloatingFrame.height
        }
        try require(heights.count == 3 && near(heights[0], 250)
                    && near(heights[1], 480) && heights[2] > heights[1],
                    "algorithm: existing small / medium / large heights survive")
        notes.append("PASS algorithm: three left floating heights retain their distinct behavior.")
        return notes
    }

    static func run(store: RailwayMapStore, assistant: AssistantStore,
                    window: NSWindow?, directory: URL) async throws {
        let arguments = CommandLine.arguments
        guard arguments.contains(flag), let index = arguments.firstIndex(of: "--ui-smoke"),
              arguments.count > index + 1, !arguments[index + 1].hasPrefix("--") else {
            throw DataError.invalid("Panel layout QA requires --ui-smoke <isolated-directory> " + flag)
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let smokeRoot = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try require(root == smokeRoot && root.path != "/",
                    "QA output must match the isolated --ui-smoke directory")
        try require(!assistant.busy, "QA must not interrupt an assistant request")
        guard let window, let view = window.contentView else {
            throw DataError.invalid("Panel layout QA needs the application's actual window")
        }
        if arguments.contains("--line-framing-check") {
            try await checkLineClicks(store, window: window, view: view, directory: root)
            return
        }
        // A unique evidence directory avoids mistaking images from a previous run
        // for this run. The fixed report is immediately marked RUNNING.
        let evidence = root.appendingPathComponent("panel-layout-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let report = root.appendingPathComponent("panel-layout-qa.txt")
        var notes = ["RUNNING " + flag, "Evidence: " + evidence.path]
        func writeReport() throws {
            try Data(notes.joined(separator: "\n").utf8).write(to: report, options: .atomic)
        }
        try writeReport()
        let originalAppearance = window.appearance
        let originalAppAppearance = NSApp.appearance
        defer {
            store.changeMode(.offline) // Stop any ordinary railway refresh after QA.
            window.appearance = originalAppearance
            NSApp.appearance = originalAppAppearance
        }

        do {
            notes += try validateAlgorithm()
            try require(window.attachedSheet == nil, "QA starts without a modal sheet")
            window.appearance = NSAppearance(named: .aqua)
            window.makeKeyAndOrderFront(nil)
            store.changeMode(.offline)
            store.basemapStyle = .standard
            store.statusVisible = false
            store.showSettings = false
            store.searchText = ""
            store.selectedTab = 1
            store.uiScale = 1
            store.panelWidth = 320; store.inspectorWidth = 380
            store.panelSize = .medium
            store.panelLayout = .floating; store.inspectorLayout = .floating
            store.panelBackgroundOpacity = 1; store.inspectorBackgroundOpacity = 1

            // A self-contained station supplies the feature title and GPT context.
            let station = try JSONDecoder().decode(RailStation.self, from: Data("""
            {"id":"qa/panel-layout-station","name":"面板验证站",
             "coordinate":{"latitude":31.23,"longitude":121.47},
             "tags":{"railway":"station","station":"subway","operator":"本地布局验证"}}
            """.utf8))
            let selection = RailwayMapStore.item(station)
            store.selection = selection
            var settings = AssistantSettings()
            settings.endpoint = "https://panel-layout.invalid/v1/responses"
            settings.model = "local-panel-fixture"
            settings.webSearch = false
            assistant.settings = settings
            assistant.focus(map: store, scope: .feature)
            assistant.turns = [AssistantTurn(role: "assistant", text: bodyMarker + "\n\n这是本地模拟正文。")]
            assistant.question = "仅验证布局，不发送。"
            let turnIDs = assistant.turns.map(\.id)
            let draft = assistant.question, context = assistant.context

            window.setContentSize(CGSize(width: 1240, height: 820))
            store.panelVisible = true; store.inspectorVisible = true
            store.changeMode(.apple)
            var initialMaps: [MKMapView] = []
            for _ in 0..<25 {
                try await settle(view, milliseconds: 120)
                initialMaps = nativeMaps(in: view)
                if initialMaps.count == 1 && initialMaps[0].bounds.width > 0 { break }
            }
            try require(initialMaps.count == 1, "exactly one native MKMapView before transitions")
            let originalMap = initialMaps[0] // Retain it so pointer reuse cannot mask recreation.
            notes.append("Native MKMapView identity: \(ObjectIdentifier(originalMap))")

            // Retry layout/AX publication only; a replaced map is an immediate failure.
            func observe(_ label: String, priority: DesktopPanelSide = .right,
                         screenshot: Bool = false) async throws {
                var lastFailure = ""
                for _ in 0..<25 {
                    try await settle(view, milliseconds: 120)
                    let maps = nativeMaps(in: view)
                    if maps.count == 1 {
                        try require(maps[0] === originalMap, "\(label): MKMapView was recreated")
                    }
                    do {
                        try require(maps.count == 1, "\(label): expected one native MKMapView")
                        let mapFrame = originalMap.convert(originalMap.bounds, to: view)
                        let viewport = CGSize(width: view.bounds.width, height: mapFrame.height)
                        let layout = DesktopPanelLayout.resolve(
                            viewport: viewport, scale: store.uiScale,
                            leftVisible: store.panelVisible, leftLayout: store.panelLayout,
                            leftWidth: store.panelWidth, leftSize: store.panelSize,
                            rightVisible: store.inspectorVisible, rightLayout: store.inspectorLayout,
                            rightWidth: store.inspectorWidth, priority: priority)
                        try require(mapFrame.width > 0 && mapFrame.height > 0
                                    && abs(originalMap.bounds.width - mapFrame.width) < 0.01
                                    && abs(originalMap.bounds.height - mapFrame.height) < 0.01,
                                    "\(label): native map must remain at unit point scale")
                        try require(near(mapFrame.width, viewport.width - layout.leftDockWidth - layout.rightDockWidth)
                                    && near(mapFrame.minX - view.bounds.minX, layout.leftDockWidth),
                                    "\(label): actual native map frame does not match dock reservations")
                        let nodes = accessibilityNodes(in: view)
                        let left = panelFrame("left-map-panel", nodes: nodes, view: view)
                        let right = panelFrame("right-map-inspector", nodes: nodes, view: view)
                        try require((left != nil) == layout.leftVisible && (right != nil) == layout.rightVisible,
                                    "\(label): rendered panel visibility differs from resolved layout")
                        if let left {
                            try require(near(left.width, layout.leftWidth) && left.width >= 250 - tolerance,
                                        "\(label): actual left panel width")
                            let x = store.panelLayout == .docked ? view.bounds.minX
                                : mapFrame.minX + layout.leftFloatingFrame.minX
                            try require(near(left.minX, x), "\(label): actual left floating/docked position")
                        }
                        if let right {
                            try require(near(right.width, layout.rightWidth) && right.width >= 200 - tolerance,
                                        "\(label): actual right panel width")
                            let x = store.inspectorLayout == .docked ? mapFrame.maxX
                                : mapFrame.minX + layout.rightFloatingFrame.minX
                            try require(near(right.minX, x), "\(label): actual right floating/docked position")
                        }
                        try require((right?.minX ?? view.bounds.maxX) - (left?.maxX ?? view.bounds.minX)
                                    >= max(260, 280 * store.uiScale) - tolerance,
                                    "\(label): panels overlap or consume the map's clear strip")
                        try require(window.attachedSheet == nil, "\(label): panels must remain inline")
                    } catch {
                        lastFailure = error.localizedDescription
                        continue
                    }
                    // Capture failures are not transient layout failures.
                    if screenshot {
                        try await OnlineUIValidation.capture(label, directory: evidence, window: window)
                    }
                    notes.append("PASS \(label): same MKMapView, native scale and measured SwiftUI panel frames.")
                    return
                }
                try capture(view, name: "failure-" + label, directory: evidence)
                let diagnostics = accessibilityNodes(in: view).compactMap { node -> String? in
                    guard let id = attribute("accessibilityIdentifier", of: node) as? String else { return nil }
                    return "\(id): \(frame(of: node, in: view).map(String.init(describing:)) ?? "no visible frame")"
                }.joined(separator: "\n")
                try Data(diagnostics.utf8).write(to: evidence.appendingPathComponent("accessibility.txt"))
                throw DataError.invalid("\(label): layout did not settle: \(lastFailure)")
            }

            for (left, right) in combinations {
                store.panelLayout = left; store.inspectorLayout = right
                try await observe("layout-\(left.rawValue)-\(right.rawValue)", screenshot: true)
                if left == .floating && right == .floating {
                    // Compositor capture includes live Liquid Glass refraction,
                    // which NSView.cacheDisplay cannot reliably represent.
                    let lightCapture = try await OnlineUIValidation.capture(
                        "glass-panels-light", directory: evidence, window: window)
                    notes.append("GLASS light capture: \(lightCapture.rawValue)")
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    window.appearance = NSAppearance(named: .darkAqua)
                    try await settle(view, milliseconds: 500)
                    let darkCapture = try await OnlineUIValidation.capture(
                        "glass-panels-dark", directory: evidence, window: window)
                    notes.append("GLASS dark capture: \(darkCapture.rawValue)")
                    if lightCapture != .compositor || darkCapture != .compositor {
                        notes.append("LIMIT: view snapshots cannot validate live glass translucency or refraction.")
                    }
                    NSApp.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
                    window.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
                    try await settle(view, milliseconds: 500)
                    let contrastCapture = try await OnlineUIValidation.capture(
                        "glass-panels-high-contrast", directory: evidence, window: window)
                    notes.append("GLASS high-contrast capture: \(contrastCapture.rawValue)")
                    NSApp.appearance = NSAppearance(named: .aqua)
                    window.appearance = NSAppearance(named: .aqua)
                }
            }
            store.panelWidth = 250; store.inspectorWidth = 200
            try await observe("minimum-widths", screenshot: true)
            store.panelVisible = false
            try await observe("left-hidden")
            store.panelVisible = true; store.inspectorVisible = false
            try await observe("right-hidden")
            store.panelVisible = false
            try await observe("both-hidden")
            store.panelWidth = 320; store.inspectorWidth = 380
            store.panelLayout = .floating; store.inspectorLayout = .floating
            store.panelVisible = true; store.inspectorVisible = true

            // 160% forces horizontal suppression at the application's 960pt
            // minimum width. Extra height isolates horizontal from vertical limits.
            store.uiScale = 1.6
            window.setContentSize(CGSize(width: 960, height: 760))
            try await observe("narrow-right", screenshot: true)
            let narrowNodes = accessibilityNodes(in: view)
            try require(panelFrame("left-map-panel", nodes: narrowNodes, view: view) == nil
                        && panelFrame("right-map-inspector", nodes: narrowNodes, view: view) != nil,
                        "narrow UI must actually show only the right panel")
            store.panelVisible = true
            try await observe("narrow-left", priority: .left)
            // didSet fires even for the SAME selection and already-true visibility.
            store.selection = selection
            try await observe("same-selection-reopens-right")
            store.panelVisible = true
            try await observe("narrow-left-again", priority: .left)
            // The toolbar reuses an existing reference when reopening the assistant.
            try require(!context.isEmpty && assistant.context == context
                        && assistant.reference?.featureIDs.contains(selection.id) == true,
                        "the feature reference must survive the preceding layout changes")
            assistant.show(map: store)
            try await observe("gpt-window-keeps-panel-priority", priority: .left)
            try require(store.inspectorPane == .feature && store.selection?.id == selection.id,
                        "a separate assistant window must preserve the inspected feature")
            assistant.setPresentation(.floating, map: store)
            try await observe("gpt-floating-opens-right")
            try require(store.inspectorPane == .assistant && store.selection?.id == selection.id,
                        "the floating assistant must open on the right and retain the selection")
            assistant.setPresentation(.window, map: store)
            try require(store.panelVisible && store.inspectorVisible && store.panelWidth == 320
                        && store.inspectorWidth == 380 && store.panelSize == .medium,
                        "narrow UI must preserve requested map panel visibility, widths and size")

            // Widen without changing scale, so a scale reset cannot mask a
            // failure to restore space-suppressed panels on window expansion.
            window.setContentSize(CGSize(width: 1440, height: 820))
            try await observe("expanded-restored", screenshot: true)
            let expandedNodes = accessibilityNodes(in: view)
            try require(panelFrame("left-map-panel", nodes: expandedNodes, view: view) != nil
                        && panelFrame("right-map-inspector", nodes: expandedNodes, view: view) != nil,
                        "window expansion alone must restore both panels")
            try require(assistant.turns.map(\.id) == turnIDs && assistant.question == draft
                        && assistant.context == context && !assistant.busy,
                        "layout and visibility changes must preserve local GPT text, draft and reference")
            store.uiScale = 1
            window.setContentSize(CGSize(width: 1240, height: 820))
            store.panelBackgroundOpacity = 0; store.inspectorBackgroundOpacity = 0
            try await observe("zero-opacity-map", screenshot: true)
            notes += try await validateOpacityInk(store: store, assistant: assistant, directory: evidence)
            // The supplementary fixture must not affect the application's map.
            try await observe("identity-after-opacity-fixture")
            let sections = MapContextFiles.sections("陇海线")
            let stops = Set(sections.flatMap { [$0.from, $0.to] })
            store.focusDirectoryLine("陇海线", names: stops.sorted(), fit: true)
            let coordinates = (store.lineFocus?.paths ?? []).flatMap { $0 }.map { store.alignment.display($0).location }
            try require(coordinates.count > 100, "Longhai full-line fixture missing")
            for (left, right) in combinations {
                store.panelLayout = left
                store.inspectorLayout = right
                try await observe("longhai-\(left.rawValue)-\(right.rawValue)")
                notes.append(try await checkLonghaiFraming(coordinates, map: originalMap, view: view))
            }
            notes.append("PASS local assistant only: no send(), credential lookup or paid API request.")
            notes.append("REVIEW: inspect the four layout PNGs, narrow/expanded PNGs and zero-opacity PNGs for visual clipping/contrast. Basemap completeness is not tested.")
            notes[0] = "PASS " + flag
            try writeReport()
            print(notes.joined(separator: "\n"))
        } catch {
            notes[0] = "FAIL " + flag
            notes.append("FAIL " + error.localizedDescription)
            try? writeReport()
            throw error // Parent QA runner owns the nonzero exit.
        }
    }

    private static let combinations: [(MapPanelLayout, MapPanelLayout)] = [
        (.floating, .floating), (.floating, .docked), (.docked, .floating), (.docked, .docked)
    ]

    /// Send window events to the normal recognizers. Use the same short input way for both renderers.
    private static func checkLineClicks(_ store: RailwayMapStore, window: NSWindow, view: NSView,
                                        directory: URL) async throws {
        guard var pack = store.dataset, let rail = pack.lines.first(where: { $0.id == "way/24943912" }),
              let beijing = Bundle.main.url(forResource: "beijing", withExtension: "json", subdirectory: "metro") else {
            throw DataError.invalid("Framing QA needs the Shanghai pack and Beijing directions")
        }
        let city = try JSONDecoder().decode(MetroDirectionCatalog.City.self, from: Data(contentsOf: beijing))
        guard let direction = city.routes.first(where: { $0.id == "relation/20010805" }),
              let part = direction.paths.first, part.count > 12 else { throw DataError.invalid("Missing Beijing 18") }
        var metro = rail
        metro.id = "way/2"; metro.name = direction.name; metro.coordinates = Array(part[2...12])
        metro.tags = ["railway":"subway","name":direction.name]; metro.routes = [direction.route]
        pack.lines = [rail,metro]; pack.stations = []

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        store.alignment = .wgs84; store.automaticAlignment = false
        store.statusVisible = false; store.showsStations = false; store.automaticDetail = false
        store.panelWidth = 320; store.inspectorWidth = 380
        let output = directory.appendingPathComponent("line-framing.txt")
        var notes = [String]()
        func record(_ s: String) throws {
            notes.append(s)
            try Data((notes.joined(separator:"\n") + "\n").utf8).write(to: output, options:.atomic)
        }
        func measuredFrame(_ id: String) -> CGRect? {
            PanelLayoutMeasurements.frames[id]?.values.filter { !$0.isEmpty }.max { $0.width < $1.width }
        }
        func marker(in parent: NSView) -> NSView? {
            if parent is FramingEventSurface.Marker { return parent }
            return parent.subviews.lazy.compactMap { marker(in:$0) }.first
        }
        func canvasTap(in parent: NSView) -> (NSView, CanvasTapSurface.Coordinator)? {
            if let handler = parent.gestureRecognizers.compactMap({ $0.target as? CanvasTapSurface.Coordinator }).first {
                return (parent, handler)
            }
            return parent.subviews.lazy.compactMap { canvasTap(in:$0) }.first
        }
        func currentMap(_ mode: MapMode) throws -> CGRect {
            guard let marker = marker(in:view) else { throw DataError.invalid("Missing map in \(window.title), windows=\(NSApp.windows.map(\.title))") }
            let actual = marker.convert(marker.bounds,to:view)
            let frame = CGRect(x:actual.minX,y:0,width:actual.width,height:actual.height)
            if mode == .apple {
                guard let map = nativeMaps(in:view).first, abs(map.bounds.width-frame.width)<1,
                      abs(map.bounds.height-frame.height)<1 else { throw DataError.invalid("MapKit bounds / SwiftUI surface disagree") }
            }
            return frame
        }
        func projection(_ points: [Coordinate], _ frame: CGRect, _ mode: MapMode) -> [CGPoint] {
            if mode == .apple, let map = nativeMaps(in:view).first {
                return points.map { p in
                    let v = map.convert(store.alignment.display(p).location, toPointTo:map)
                    return CGPoint(x: frame.minX+v.x, y: frame.minY+(map.isFlipped ? v.y : map.bounds.height-v.y))
                }
            }
            let camera = RailProjection(region:store.region,size:frame.size)
            return points.map { p in let v=camera.screen(p); return CGPoint(x:frame.minX+v.x,y:frame.minY+v.y) }
        }
        func measure(_ label: String, _ points: [Coordinate], _ mode: MapMode) async throws {
            var last = label
            for _ in 0..<18 {
                try await settle(view,milliseconds:120)
                let map = try currentMap(mode)
                // The dock slot clips its content. Only a floating panel can paint over the map.
                let left = store.panelLayout == .docked ? map.minX : max(map.minX,measuredFrame("left-map-panel")?.maxX ?? map.minX)
                let right = store.inspectorLayout == .docked ? map.maxX : min(map.maxX,measuredFrame("right-map-inspector")?.minX ?? map.maxX)
                let clear = CGRect(x:left,y:map.minY,width:right-left,height:map.height)
                let pp = projection(points,map,mode)
                let xs=pp.map(\.x), ys=pp.map(\.y)
                let span = max((xs.max()!-xs.min()!)/clear.width,(ys.max()!-ys.min()!)/clear.height)
                let offset = max(abs((xs.max()!+xs.min()!)/2-clear.midX),abs((ys.max()!+ys.min()!)/2-clear.midY))
                let outside = pp.filter { !clear.contains($0) }.count
                last = "\(mode) \(label) points=\(pp.count) map=\(map.integral) clear=\(clear.integral) span=\(String(format:"%.4f",span)) outside=\(outside) offset=\(String(format:"%.1f",offset))"
                if outside == 0 && abs(span-0.8)<0.012 && offset<max(3,min(clear.width,clear.height)*0.02) { try record(last); return }
            }
            let actual = nativeMaps(in:view).first?.visibleMapRect
            throw DataError.invalid(last + " target=\(String(describing:store.fittedDisplayRect)) actual=\(String(describing:actual))")
        }
        func press(_ point: CGPoint, on surface: CGRect, mode: MapMode) async throws -> String {
            guard let marker = marker(in:view) else { throw DataError.invalid("Map event surface not mounted") }
            let p = marker.convert(CGPoint(x:point.x-surface.minX,y:point.y-surface.minY),to:nil)
            let screen = window.convertPoint(toScreen:p)
            let quartz = CGPoint(x:screen.x,y:CGDisplayBounds(CGMainDisplayID()).height-screen.y)
            let topWindow = NSWindow.windowNumber(at:screen,belowWindowWithWindowNumber:0)
            if !NSApp.isActive || topWindow != window.windowNumber {
                if mode == .apple, let map = nativeMaps(in:view).first,
                   let recognizer = map.gestureRecognizers.first(where: { $0.target is AppleRailwayMap.Coordinator }),
                   let coordinator = recognizer.target as? AppleRailwayMap.Coordinator {
                    coordinator.pickFeature(map.convert(p,from:nil),map:map,touch:false)
                } else if mode == .offline, let (canvas, handler) = canvasTap(in:view) {
                    handler.select(canvas.convert(p,from:nil),false)
                } else { throw DataError.invalid("Missing live map recognizer") }
                return "coordinate handler (background window)"
            }
            for type in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {
                guard let event = CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:quartz,mouseButton:.left)
                else { throw DataError.invalid("Missing mouse event") }
                event.setIntegerValueField(.mouseEventClickState,value:1)
                event.post(tap:.cgSessionEventTap)
                try await Task.sleep(for:.milliseconds(65))
            }
            return "window mouse"
        }
        for mode in [MapMode.offline,.apple] {
            store.selection = nil
            store.changeMode(mode)
            for line in [metro,rail] {
                window.setContentSize(CGSize(width:1240,height:820)); store.uiScale = 1
                store.panelVisible = false; store.inspectorVisible = false
                store.selection = nil; store.dataset = pack
                let p = line.coordinates[3]
                store.region = MKCoordinateRegion(center:p.location,span:.init(latitudeDelta:0.018,longitudeDelta:0.024))
                store.cameraRevision += 1
                try await settle(view,milliseconds:800)
                // Online mode uses the same source ways without depending on basemap / tile delivery.
                if mode == .apple { store.onlineLines = pack.lines; store.onlineStations = [] }
                store.rebuildIndex(); store.rebuildVisible()
                try await settle(view,milliseconds:120)
                try require(store.visibleLines.contains { $0.id == line.id }, "click fixture isn't rendered: \(line.name)")
                let surface = try currentMap(mode)
                let hit = projection([p],surface,mode)[0]
                let entry = try await press(hit,on:surface,mode:mode)
                for _ in 0..<35 {
                    try await settle(view,milliseconds:100)
                    if store.selection?.id == line.id && (line.id == rail.id || store.lineFocus?.directionID == direction.id) { break }
                }
                try require(store.selection?.id == line.id,"\(mode) \(entry) did not select \(line.name), got \(store.selection?.name ?? "nil")")
                let expected: [Coordinate]
                if line.id == metro.id {
                    try require(store.lineFocus?.directionID == direction.id && store.lineFocus?.paths == direction.paths,"clicked metro direction differs from source")
                    expected = direction.paths.flatMap { $0 } + direction.stops.compactMap(\.location)
                } else {
                    let paths = MapContextFiles.parts(rail.name)
                    try require(paths.count>1 && store.lineFocus?.paths == paths,"missing full named rail backing")
                    expected = paths.flatMap { $0 } + rail.coordinates
                }
                try await measure("\(line.name) \(entry)",expected,mode)
                store.panelVisible = true
                for (left,right) in combinations {
                    store.panelLayout=left; store.inspectorLayout=right
                    try await measure("\(line.name) \(left)/\(right)",expected,mode)
                }
                window.setContentSize(CGSize(width:960,height:700)); store.uiScale = 1.6
                try await measure("\(line.name) narrow",expected,mode)
            }
        }
        try record("PASS")
    }

    private static func resolve(_ viewport: CGSize, scale: Double = 1,
                                left: MapPanelLayout = .floating, right: MapPanelLayout = .floating,
                                priority: DesktopPanelSide = .right) -> DesktopPanelLayout.Resolved {
        DesktopPanelLayout.resolve(
            viewport: viewport, scale: scale,
            leftVisible: true, leftLayout: left, leftWidth: 320, leftSize: .medium,
            rightVisible: true, rightLayout: right, rightWidth: 380, priority: priority)
    }

    private static func checkGeometry(_ layout: DesktopPanelLayout.Resolved, viewport: CGSize, scale: Double) throws {
        let mapWidth = viewport.width - layout.leftDockWidth - layout.rightDockWidth
        let bounds = CGRect(x: 0, y: 0, width: mapWidth, height: viewport.height)
        for frame in layout.floatingFrames {
            try require(frame.width.isFinite && frame.height.isFinite && !frame.isEmpty && bounds.contains(frame),
                        "algorithm: float frame must be finite and inside the map")
        }
        if layout.leftVisible {
            try require(layout.leftWidth >= max(250, 250 * scale) - tolerance, "algorithm: left minimum width")
        }
        if layout.rightVisible {
            try require(layout.rightWidth >= max(200, 200 * scale) - tolerance, "algorithm: right minimum width")
        }
        let leftEdge = layout.leftFloatingFrame.isEmpty ? 0 : layout.leftFloatingFrame.maxX
        let rightEdge = layout.rightFloatingFrame.isEmpty ? mapWidth : layout.rightFloatingFrame.minX
        try require(rightEdge - leftEdge >= max(260, 280 * scale) - tolerance,
                    "algorithm: keep an unobscured map strip between panels")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw DataError.invalid(message) }
    }

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance }

    /// Measure the live MapKit camera and the actual panel edges after each dock transition.
    private static func checkLonghaiFraming(_ coordinates: [CLLocationCoordinate2D], map: MKMapView,
                                            view: NSView) async throws -> String {
        var result = ""
        for _ in 0..<15 {
            try await settle(view, milliseconds: 120)
            let nodes = accessibilityNodes(in: view)
            guard let left = panelFrame("left-map-panel", nodes: nodes, view: view),
                  let right = panelFrame("right-map-inspector", nodes: nodes, view: view) else { continue }
            let mapFrame = map.convert(map.bounds, to: view)
            let west = max(left.maxX, mapFrame.minX), east = min(right.minX, mapFrame.maxX)
            let points = coordinates.map { map.convert($0, toPointTo: view) }
            let xs = points.map(\.x)
            guard let minX = xs.min(), let maxX = xs.max() else { continue }
            let leftMargin = minX - west, rightMargin = east - maxX, width = east - west
            let outside = points.filter { !mapFrame.contains($0) || $0.x < west || $0.x > east }.count
            result = "陇海线 \(points.count) vertices, \(outside) outside clear map, margins \(Int(leftMargin.rounded())) / \(Int(rightMargin.rounded())) of \(Int(width.rounded())) pt"
            let target = 0.1 * width, slack = max(2, 0.012 * width)
            if outside == 0 && abs(leftMargin - target) <= slack && abs(rightMargin - target) <= slack {
                return "PASS " + result
            }
        }
        throw DataError.invalid("Live full-line framing: " + result)
    }

    private static func settle(_ view: NSView, milliseconds: Int = 350) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private static func nativeMaps(in view: NSView) -> [MKMapView] {
        if let map = view as? MKMapView { return [map] }
        return view.subviews.flatMap { nativeMaps(in: $0) }
    }

    // In-process AX inspection needs no Accessibility permission. SwiftUI may
    // expose virtual NSObject elements rather than individual NSView controls.
    private static func attribute(_ key: String, of node: NSObject) -> Any? {
        node.responds(to: NSSelectorFromString(key)) ? node.value(forKey: key) : nil
    }

    private static func accessibilityNodes(in view: NSView) -> [NSObject] {
        var pending: [NSObject] = [view], result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        while let node = pending.popLast() {
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            if let view = node as? NSView, view.isHiddenOrHasHiddenAncestor { continue }
            result.append(node)
            // Map annotations are unrelated to panel QA and can be numerous.
            if node is MKMapView { continue }
            pending += attribute("accessibilityChildren", of: node) as? [NSObject] ?? []
            if let view = node as? NSView { pending += view.subviews }
        }
        return result
    }

    private static func frame(of node: NSObject, in view: NSView) -> CGRect? {
        guard let window = view.window,
              let value = attribute("accessibilityFrame", of: node) as? NSValue else { return nil }
        let frame = view.convert(window.convertFromScreen(value.rectValue), from: nil)
        guard frame.width.isFinite, frame.height.isFinite, !frame.isEmpty,
              view.visibleRect.intersects(frame) else { return nil }
        return frame
    }

    private static func panelFrame(_ id: String, nodes: [NSObject], view: NSView) -> CGRect? {
        if let measured = PanelLayoutMeasurements.frames[id]?.values
            .filter({ !$0.isEmpty }).max(by: { $0.width * $0.height < $1.width * $1.height }) {
            return measured.offsetBy(dx: view.bounds.minX, dy: view.bounds.minY)
        }
        return nodes.filter { attribute("accessibilityIdentifier", of: $0) as? String == id }
            .compactMap { frame(of: $0, in: view) }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func press(_ id: String, in view: NSView) throws {
        for node in accessibilityNodes(in: view)
        where attribute("accessibilityIdentifier", of: node) as? String == id {
            if frame(of: node, in: view) != nil,
               let control = node as? NSAccessibilityProtocol, control.accessibilityPerformPress() { return }
        }
        throw DataError.invalid("Unable to press visible panel toggle: " + id)
    }

    private static func textFrame(_ text: String, in view: NSView) throws -> CGRect {
        let matches = accessibilityNodes(in: view).compactMap { node -> CGRect? in
            let role = attribute("accessibilityRole", of: node) as? String
            guard role == "AXStaticText" || role == "AXTextArea" else { return nil }
            let strings = ["accessibilityValue", "accessibilityLabel"].compactMap { key -> String? in
                let value = attribute(key, of: node)
                return (value as? String) ?? (value as? NSAttributedString)?.string
            }
            guard strings.contains(where: { $0.contains(text) }), let rect = frame(of: node, in: view),
                  view.visibleRect.insetBy(dx: -1, dy: -1).contains(rect) else { return nil }
            return rect
        }
        guard let rect = matches.min(by: { $0.width * $0.height < $1.width * $1.height }) else {
            throw DataError.invalid("Missing visible text: " + text)
        }
        return rect
    }

    private static func capture(_ view: NSView, name: String, directory: URL) throws {
        guard let window = view.window else { throw DataError.invalid("Capture has no window") }
        let bitmap = try RetinaUIValidation.capture(view, name: name, directory: directory)
        let scale = window.backingScaleFactor
        try require(abs(Double(bitmap.pixelsWide) - view.bounds.width * scale) <= 1
                    && abs(Double(bitmap.pixelsHigh) - view.bounds.height * scale) <= 1,
                    name + ": screenshot must use native backing pixels on both axes")
    }

    /// Use the real panel bodies on static light/dark backdrops, avoiding basemap
    /// animation and empty-material screenshots as false evidence of readable text.
    private static func validateOpacityInk(store: RailwayMapStore, assistant: AssistantStore,
                                           directory: URL) async throws -> [String] {
        let host = NSHostingView(rootView: PanelOpacityFixture(store: store, assistant: assistant))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 740, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        // Fixed fixture regions include the real title, controls and GPT body;
        // this check does not depend on virtual AX text publication.
        let regions: [(String, CGRect)] = [
            ("left panel", CGRect(x: 10, y: 25, width: 320, height: 650)),
            ("right GPT panel", CGRect(x: 350, y: 25, width: 380, height: 650))
        ]
        var notes: [String] = []
        for scheme in [ColorScheme.light, .dark] {
            let theme = scheme == .dark ? "dark" : "light"
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.rootView = PanelOpacityFixture(store: store, assistant: assistant, colorScheme: scheme)
            var before: [Int] = []
            for opacity in [1.0, 0.5, 0.0] {
                store.panelBackgroundOpacity = opacity; store.inspectorBackgroundOpacity = opacity
                try await settle(host)
                let name = "text-\(theme)-opacity-\(Int(opacity * 100))"
                try capture(host, name: name, directory: directory)
                let method = try await OnlineUIValidation.capture(name + "-compositor", directory: directory, window: window)
                let ink = try regions.map { try foregroundInk(in: host, rect: $0.1, light: scheme == .dark) }
                if opacity == 1 { before = ink }
                for (index, region) in regions.enumerated() {
                    try require(before[index] >= 40 && ink[index] >= Int(Double(before[index]) * 0.85),
                                "\(theme) opacity \(opacity) faded/disappeared text: \(region.0), pixels \(before[index]) -> \(ink[index])")
                    notes.append("PASS \(theme) opacity \(opacity) text \(region.0): foreground pixels \(before[index]) -> \(ink[index]); capture \(method.rawValue).")
                }
            }
        }
        return notes
    }

    private static func foregroundInk(in view: NSView, rect: CGRect, light: Bool) throws -> Int {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else {
            throw DataError.invalid("Text crop allocation failed")
        }
        view.cacheDisplay(in: rect, to: bitmap)
        var count = 0
        if bitmap.bitsPerSample == 8, !bitmap.isPlanar,
           bitmap.samplesPerPixel >= 3, let bytes = bitmap.bitmapData {
            let stride = bitmap.bitsPerPixel / 8
            let firstAlpha = bitmap.hasAlpha && bitmap.bitmapFormat.contains(.alphaFirst)
            let offset = firstAlpha ? 1 : 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let pixel = bytes + y * bitmap.bytesPerRow + x * stride
                    let alpha = bitmap.hasAlpha ? pixel[firstAlpha ? 0 : bitmap.samplesPerPixel - 1] : 255
                    let matches = light
                        ? min(pixel[offset], min(pixel[offset + 1], pixel[offset + 2])) > 178
                        : max(pixel[offset], max(pixel[offset + 1], pixel[offset + 2])) < 89
                    if alpha > 229 && matches {
                        count += 1
                    }
                }
            }
            return count
        }
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let matches = light
                    ? min(color.redComponent, min(color.greenComponent, color.blueComponent)) > 0.7
                    : max(color.redComponent, max(color.greenComponent, color.blueComponent)) < 0.35
                if color.alphaComponent > 0.9 && matches {
                    count += 1
                }
            }
        }
        return count
    }
}

@MainActor
private struct PanelOpacityFixture: View {
    @ObservedObject var store: RailwayMapStore
    @ObservedObject var assistant: AssistantStore
    var colorScheme: ColorScheme = .light

    var body: some View {
        AtlasInterface(scale: 1) {
            HStack(spacing: 20) {
                DesktopSidebarPanel().frame(width: 320, height: 650)
                    .modifier(DesktopFloatingPanelSurface(opacity: store.panelBackgroundOpacity))
                AtlasInspectorView().frame(width: 380, height: 650)
                    .modifier(DesktopFloatingPanelSurface(opacity: store.inspectorBackgroundOpacity))
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colorScheme == .dark ? Color(white: 0.08) : .white)
        }
        .environmentObject(store)
        .environmentObject(assistant)
        .environment(\.colorScheme, colorScheme)
        .tint(.railwayAccent)
    }
}
#endif
