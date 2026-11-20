#if os(macOS)
import AppKit
import Foundation
import MapKit
import RailwayCore
import SwiftUI

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
            assistant.focus(map: store, scope: .feature)
            try await observe("gpt-keeps-feature-right")
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
