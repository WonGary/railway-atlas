import Foundation
import MapKit
import RailwayCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum JourneyInspectionValidation {
    static let flag = "--route-inspector-check"
    private struct Pair: Encodable {
        let other: String
        let coverage: [Int]
        let sharedMetres, uniqueMetres: [Double]
        let mapLayers: [String]
        let inkPixels: [String: Int]
    }
    private struct Receipt: Encodable {
        var status = "FAIL"
        let bundle = Bundle.main.bundleURL.path
        let day = "2026-11-26"
        var pairs: [Pair] = []
        var physicalLine = "", station = "", source = "", lineCoverage = "", stage = "包内目录"
        var stationCount = 0, pinnedStations = 0, lineParts = 0, legVertices = 0
        var error: String?
    }

    static func run(map: RailwayMapStore, directory: URL) async {
        var record = Receipt()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let bundle = Bundle.main.resourceURL?.resolvingSymlinksInPath(),
                  MapContextFiles.directory.resolvingSymlinksInPath().path == bundle.appendingPathComponent("station-directory").path,
                  ["national.js", "map-points.json", "lines/index.json", "paths/index.json"].allSatisfy({
                      FileManager.default.isReadableFile(atPath: MapContextFiles.directory.appendingPathComponent($0).path)
                  }) else { throw DataError.invalid("安装包内缺少铁路站线资料") }
            map.mapMode = .offline
            let model = map.journeyWorkspace
            await model.load()
            let table = try await model.inspectionTimetable(train: "D174", date: record.day)
            let primary = try await model.inspectJourney(table)
            guard primary.complete, primary.legs.count == 14,
                  let leg = primary.legs.first(where: { $0.from == "陇南" && $0.to == "广元" }),
                  leg.source.contains("OSM"), leg.points.count > 2, leg.metres > 100_000,
                  let physical = leg.viaLines.first(where: { $0.title == "兰渝线兰渭段" }) else {
                throw DataError.invalid("D174 陇南到广元的质量或经由不符")
            }
            record.source = leg.source; record.legVertices = leg.points.count
            record.stage = "选车与区间报告"
            #if os(macOS)
            let window = try await simulationWindow()
            try await enter("snapshot-train", placeholder: "车次", value: "D174", window)
            try await enter("snapshot-date", placeholder: "始发日期 YYYY-MM-DD", value: record.day, window)
            try await press("snapshot-find", label: "查找车次", window)
            try await until("D174 已选") { model.selectedTrainID == table.id }
            try await press("inspection-quality", label: "逐段质量", window)
            try await press("inspection-leg-\(leg.id)", label: "\(leg.from) → \(leg.to)", window)
            try await press("inspection-show-leg", label: "主地图查看此区间", window)
            try await until("区间图层") { map.lineFocus?.inspectionLayers.first?.parts == [leg.points] && mainFront }
            window.makeKeyAndOrderFront(nil)
            try await press("inspection-line-\(physical.title)", label: "\(physical.title)全线", window)
            #else
            map.showInspectionLayers([.init(ink: .first, parts: [leg.points])], title: "\(leg.from) → \(leg.to)", owner: table.id)
            try await map.showInspectionLine(physical, report: primary)
            #endif
            record.stage = "线路全线与站所"
            try await until("全线站序") { map.lineFocus?.inspectionDirectory?.title == physical.title }
            record.physicalLine = physical.title; record.stationCount = physical.stops.count
            record.lineCoverage = map.lineFocus?.inspectionSummary ?? ""
            record.lineParts = map.lineFocus?.paths.count ?? 0; record.pinnedStations = map.stationBoardPins.count
            guard record.stationCount == 20, record.lineParts > 0, record.pinnedStations > 1,
                  let station = map.stationBoardPins.first(where: { $0.name == "广元" }) else {
                throw DataError.invalid("全线站序、车站坐标或轨迹缺失")
            }
            #if os(macOS)
            guard let main = mainWindow else { throw DataError.invalid("主地图窗口未打开") }
            _ = try await OnlineUIValidation.capture("physical-line", directory: directory, window: main)
            // Use a visible station at the top of the scrollable full-line list.
            guard let first = physical.stops.prefix(4).compactMap({ NationalDirectoryPins.byName[$0.name] }).first else {
                throw DataError.invalid("站序开头没有可定位车站")
            }
            try await press("inspection-station-\(first.name)", label: "", main)
            try await until("主图车站定位") { map.selection?.name == first.name && map.lineFocus?.title == physical.title }
            record.station = first.name
            window.makeKeyAndOrderFront(nil)
            try await press("inspection-compare", label: "比较两趟车的径路", window)
            #else
            map.select(RailwayMapStore.item(station))
            guard map.selection?.name == station.name else { throw DataError.invalid("全线站所无法定位") }
            record.station = station.name
            #endif
            for number in ["D176", "D2236"] {
                record.stage = "D174 / \(number)"
                let second = try await model.inspectionTimetable(train: number, date: record.day)
                let other = try await model.inspectJourney(second)
                let comparison = try await JourneyTrackComparison.compare(primary.paths, other.paths)
                let keys = comparison.layers.map(\.ink.rawValue)
                let expected = number == "D176" ? ["shared"] : ["first", "second", "shared"]
                guard keys == expected, other.complete, comparison.a.sharedMetres > 1000, comparison.b.sharedMetres > 1000,
                      number == "D176" ? comparison.a.uniqueMetres == 0 && comparison.b.uniqueMetres == 0 :
                                        comparison.a.uniqueMetres > 1_000 && comparison.b.uniqueMetres > 1_000 else {
                    throw DataError.invalid("双向几何分类不符 \(keys)")
                }
                #if os(macOS)
                window.makeKeyAndOrderFront(nil)
                try await enter("inspection-second-train", placeholder: "比较车次", value: number, window)
                try await press("inspection-show-comparison", label: "在主地图比较", window)
                try await until("主地图打开 \(number)") { mainFront && map.lineFocus?.title == "D174 / \(number)" }
                #else
                map.showInspectionLayers(comparison.layers, title: "D174 / \(number)", owner: table.id)
                // A station tap presents the detail sheet. The comparison button normally
                // returns to the main map before the user sees the new layers.
                NotificationCenter.default.post(name: .railGameDidOpenMap, object: nil)
                #endif
                guard map.lineFocus?.inspectionLayers.map(\.ink.rawValue) == keys else { throw DataError.invalid("主图未采用比较结果") }
                try mapKitInk(map, expected: keys)
                let pixels = try await visibleInk(map, number: number, directory: directory)
                guard keys.allSatisfy({ (pixels[$0] ?? 0) > 10 }) else {
                    throw DataError.invalid("离线主地图未绘全图层 \(pixels)")
                }
                record.pairs.append(.init(other: number, coverage: [primary.paths.count, other.paths.count],
                    sharedMetres: [comparison.a.sharedMetres, comparison.b.sharedMetres],
                    uniqueMetres: [comparison.a.uniqueMetres, comparison.b.uniqueMetres], mapLayers: keys, inkPixels: pixels))
            }
            record.stage = "交叉、断轨、清除"
            let p = Coordinate(31, 110), q = Coordinate(31, 110.01), r = Coordinate(31, 110.02), s = Coordinate(31, 110.03)
            let crossing = try await JourneyTrackComparison.compare([[p,s]], [[.init(30.99,110.015), .init(31.01,110.015)]])
            let gap = try await JourneyTrackComparison.compare([[p,q],[r,s]], [[p,s]])
            var traces = primary.legs.map { JourneyInspection.Trace(points: $0.points, source: $0.source) }
            traces[leg.id] = .init()
            let damaged = try JourneyInspection.make(table, traces: traces, library: nil, notice: nil)
            guard crossing.a.sharedMetres == 0, gap.a.uniqueMetres == 0, gap.b.uniqueMetres > 700,
                  gap.a.shared.count == 2, !damaged.complete, damaged.paths.count == 13,
                  damaged.legs[leg.id].status == "缺少区间轨迹" else { throw DataError.invalid("交叉或缺轨被误画为连续共线") }
            map.clearLineFocus()
            guard map.lineFocus == nil, map.journeyPlayer.mode == nil else { throw DataError.invalid("比较改变了播放器") }
            record.stage = "完成"; record.status = "PASS"
        } catch { record.error = error.localizedDescription }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(record).write(to: directory.appendingPathComponent("route-inspector.json"), options: .atomic) }
        catch { print("径路验收报告写入失败 \(error.localizedDescription)") }
    }

    private static func mapKitInk(_ store: RailwayMapStore, expected: [String]) throws {
        let view = MKMapView(frame: .zero)
        let coordinator = AppleRailwayMap(store: store).makeCoordinator()
        coordinator.updateFocus(store.lineFocus, on: view)
        let inks = view.overlays.compactMap { $0 as? MKMultiPolyline }.filter { $0.title?.hasPrefix("inspection/") == true }
        let names = inks.compactMap { $0.title?.components(separatedBy: "/").last }.sorted()
        guard names == expected.sorted(), inks.allSatisfy({ ink in
            guard !ink.polylines.isEmpty, let renderer = coordinator.mapView(view, rendererFor: ink) as? MKOverlayPathRenderer else { return false }
            return renderer.strokeColor != nil && renderer.lineWidth > 0 && (renderer.lineDashPattern?.isEmpty == false) == (ink.title == "inspection/second")
        }) else { throw DataError.invalid("MapKit 实际绘制的线条或虚线不符 \(names)") }
    }

    private static func visibleInk(_ store: RailwayMapStore, number: String, directory: URL) async throws -> [String: Int] {
        try await Task.sleep(for: .milliseconds(350))
        #if os(macOS)
        guard let window = mainWindow else { throw DataError.invalid("没有主地图窗口") }
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let filename = "D174-\(number)"
        _ = try await OnlineUIValidation.capture(filename, directory: directory, window: window)
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: directory.appendingPathComponent(filename + ".png")))?.cgImage
        else { throw DataError.invalid("地图截图编码失败") }
        #else
        let file = directory.appendingPathComponent("D174-\(number).png")
        if CommandLine.arguments.contains("--simulator-display-capture") {
            try await Task.sleep(for: .milliseconds(700))
            try Data().write(to: directory.appendingPathComponent("D174-\(number).request"), options: .atomic)
            for _ in 0..<300 {
                if FileManager.default.fileExists(atPath: file.path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        } else {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) else { throw DataError.invalid("没有主地图窗口") }
            window.layoutIfNeeded()
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            guard let png = screenshot.pngData() else { throw DataError.invalid("地图截图编码失败") }
            try png.write(to: file, options: .atomic)
        }
        guard let image = UIImage(contentsOfFile: file.path)?.cgImage else { throw DataError.invalid("没有取得主地图截图") }
        #endif
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { storage in
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue) else { throw DataError.invalid("截图像素不可读") }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let rgb = [("first",8,124,186), ("second",192,57,119), ("shared",23,128,90)]
        var hits = [String: Int]()
        for p in stride(from: 0, to: rgba.count, by: 4) {
            for (key,r,g,b) in rgb where abs(Int(rgba[p])-r) < 6 && abs(Int(rgba[p+1])-g) < 6 && abs(Int(rgba[p+2])-b) < 6 {
                hits[key, default: 0] += 1
            }
        }
        return hits
    }

    private static func until(_ title: String, _ check: () -> Bool) async throws {
        for _ in 0..<65 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DataError.invalid("等待\(title)超时")
    }

    #if os(macOS)
    private static var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "main-map" } }
    private static var mainFront: Bool {
        let front = NSApp.keyWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeMain }
        return front === mainWindow && front != nil
    }
    private static func simulationWindow() async throws -> NSWindow {
        guard let menu = NSApp.mainMenu?.item(withTitle: "漫游")?.submenu else { throw DataError.invalid("漫游菜单缺失") }
        menu.update()
        let index = menu.indexOfItem(withTitle: ExperienceTab.simulation.title)
        guard index >= 0 else { throw DataError.invalid("漫游入口缺失") }
        menu.performActionForItem(at: index)
        func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "railway-experiences" } }
        try await until("铁道漫游窗口") { window() != nil }
        guard let win = window() else { throw DataError.invalid("漫游窗口缺失") }
        return win
    }
    private static func attribute(_ key: String, _ node: NSObject) -> Any? {
        node.responds(to: NSSelectorFromString(key)) ? node.value(forKey: key) : nil
    }
    private static func controls(_ window: NSWindow) -> [NSObject] {
        window.contentView?.layoutSubtreeIfNeeded()
        var todo: [NSObject] = [window], seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        if let content = window.contentView { todo.append(content) }
        while let node = todo.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            result.append(node)
            if let view = node as? NSView { todo += view.subviews }
            todo += attribute("accessibilityChildren", node) as? [NSObject] ?? []
        }
        return result
    }
    private static func press(_ id: String, label: String, _ window: NSWindow) async throws {
        var labels = Set<String>()
        do { try await until("按钮 \(id.isEmpty ? label : id)") {
            if clickProbe(id, in: window) { return true }
            for node in controls(window) {
                let name = [attribute("accessibilityLabel", node) as? String, attribute("accessibilityTitle", node) as? String,
                            (node as? NSButton)?.title, attribute("accessibilityValue", node) as? String]
                    .compactMap { $0 }.joined(separator: " ")
                if !name.isEmpty { labels.insert(String(name.prefix(60))) }
                guard (!id.isEmpty && attribute("accessibilityIdentifier", node) as? String == id) ||
                        (!label.isEmpty && name.contains(label)) else { continue }
                if let view = node as? NSView { view.scrollToVisible(view.bounds) }
                if let b = node as? NSButton, b.isEnabled { b.performClick(nil); return true }
                if let control = node as? NSAccessibilityProtocol, control.accessibilityPerformPress() { return true }
            }
            return false
        } } catch { throw DataError.invalid("\(error.localizedDescription)（\(labels.sorted().prefix(24).joined(separator: "、"))）") }
    }
    private static func enter(_ id: String, placeholder: String, value: String, _ window: NSWindow) async throws {
        try await until("输入框 \(id)") {
            if clickProbe(id, in: window), let editor = window.firstResponder as? NSTextView {
                editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                window.makeFirstResponder(nil)
                return true
            }
            let fields = controls(window).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            guard let field = fields.first(where: { $0.accessibilityIdentifier() == id })
                    ?? fields.first(where: { $0.placeholderString == placeholder }) else { return false }
            field.scrollToVisible(field.bounds)
            guard window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { return false }
            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            window.makeFirstResponder(nil)
            return field.stringValue == value
        }
    }
    private static func clickProbe(_ id: String, in window: NSWindow) -> Bool {
        func find(_ node: NSView) -> NSView? {
            if node.identifier?.rawValue == "check/" + id { return node }
            for child in node.subviews {
                if let result = find(child) { return result }
            }
            return nil
        }
        guard let root = window.contentView, let marker = find(root), marker.bounds.width > 0 else { return false }
        marker.scrollToVisible(marker.bounds)
        root.layoutSubtreeIfNeeded()
        let point = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
        guard window.contentLayoutRect.contains(point) else { return false }
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
            window.sendEvent(event)
        }
        return true
    }
    #endif
}

// SwiftUI does not publish its complete accessibility tree until a system accessibility
// client connects. In a self-contained package check, locate controls and send window
// mouse events without granting Accessibility permission or changing the action.
extension View {
    @ViewBuilder func inspectionProbe(_ name: String) -> some View {
        #if os(macOS)
        if CommandLine.arguments.contains(JourneyInspectionValidation.flag) {
            background(InspectionControlMarker(name: name).allowsHitTesting(false))
        } else { self }
        #else
        self
        #endif
    }
}
#if os(macOS)
private struct InspectionControlMarker: NSViewRepresentable {
    let name: String
    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.identifier = .init("check/" + name) }
}
#endif
