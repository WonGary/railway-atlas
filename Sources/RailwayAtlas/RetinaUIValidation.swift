#if os(macOS)
import AppKit
import MapKit
import RailwayCore
import SwiftUI

@MainActor
enum RetinaUIValidation {
    static func run(store: RailwayMapStore, window: NSWindow?, directory: URL) async throws {
        guard let window, let view = window.contentView else { throw DataError.invalid("Retina QA has no window") }
        store.changeMode(.offline)
        store.selectedTab = 1
        store.panelWidth = 320
        var notes: [String] = []
        let station = try JSONDecoder().decode(RailStation.self, from: Data("""
        {"id":"qa/station","name":"罗湖","coordinate":{"latitude":22.5284,"longitude":114.1133},
         "tags":{"railway":"station","station":"subway","interchange":"yes"},
         "routes":[{"id":"qa/1","name":"一号线","tags":{"route":"subway","colour":"#E60039"}},
                   {"id":"qa/2","name":"二号线","tags":{"route":"subway","colour":"#0079C3"}}]}
        """.utf8))
        let style = station.appearance()
        for scale in [0.75, 1.0, 1.25, 1.6] {
            store.uiScale = scale
            try await Task.sleep(for: .milliseconds(400))
            view.layoutSubtreeIfNeeded()
            let density = window.backingScaleFactor
            let bitmap = try capture(view, name: "ui-\(Int(scale * 100))", directory: directory)
            let ratio = Double(bitmap.pixelsWide) / view.bounds.width
            guard abs(ratio - density) < 0.01 else {
                throw DataError.invalid("UI backing ratio \(ratio) differs from screen \(density) at \(scale)")
            }
            for backing in [1.0, 2.0, 3.0] {
                let symbol = StationSymbol.image(style, title: "罗湖 · Lo Wu", uiScale: scale, displayScale: backing)
                guard let image = symbol.representations.first as? NSBitmapImageRep,
                      image.pixelsWide == Int(ceil(172 * scale * backing)),
                      image.pixelsHigh == Int(ceil(24 * scale * backing)),
                      abs(symbol.size.width - 172 * scale) < 0.001 else {
                    throw DataError.invalid("Station bitmap resolution failed at \(scale) × \(backing)")
                }
                try image.representation(using: .png, properties: [:])?.write(
                    to: directory.appendingPathComponent("station-\(Int(scale * 100))-\(Int(backing))x.png"))
                // Check ink reaches the right half of the image, detecting an
                // accidental double CTM scale that clips the station name.
                let dot = StationSymbol.image(style, title: nil, uiScale: scale, displayScale: backing)
                guard let dotBitmap = dot.representations.first as? NSBitmapImageRep else { throw DataError.invalid("Missing station bitmap") }
                var ink: [CGPoint] = []
                for y in 0..<dotBitmap.pixelsHigh {
                    for x in 0..<dotBitmap.pixelsWide {
                        if (dotBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { ink.append(CGPoint(x: x, y: y)) }
                    }
                }
                guard let minX = ink.map(\.x).min(), let maxX = ink.map(\.x).max(),
                      abs((minX + maxX + 1) / 2 - 12 * scale * backing) <= 1,
                      abs((maxX - minX + 1) / backing - 2 * style.radius) <= 2 / backing else {
                    throw DataError.invalid("Station symbol is offset or clipped at \(scale) × \(backing)")
                }
            }
            notes.append("\(Int(scale * 100))%: window \(Int(view.bounds.width))pt → \(bitmap.pixelsWide)px (\(density)×); station glyphs at native 1×/2×/3× verified.")
        }
        for light in [false, true] {
            let sample = StationSymbol.image(style, title: "阜阳 · Fuyang", displayScale: 2, lightText: light)
            if let bitmap = sample.representations.first as? NSBitmapImageRep {
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: directory.appendingPathComponent(light ? "station-solid-night.png" : "station-solid-day.png"))
            }
        }
        store.uiScale = 1.25
        store.showSettings = true
        try await Task.sleep(for: .milliseconds(600))
        if let sheet = window.attachedSheet?.contentView {
            _ = try capture(sheet, name: "settings-125", directory: directory)
        } else { throw DataError.invalid("Settings sheet did not appear") }
        store.showSettings = false
        try await Task.sleep(for: .milliseconds(400))
        // The macOS assistant is a separate window; the main map keeps its
        // feature inspector contract. Render the assistant in an isolated
        // native window for the same Retina check.
        guard store.inspectorPane == .feature else {
            throw DataError.invalid("Main map inspector is not the feature inspector")
        }
        let assistantWindow = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 650, height: 650),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        let assistantView = NSHostingView(rootView: AtlasInterface(scale: 1.25) {
            AtlasAssistantView()
        }.environmentObject(store).environmentObject(AssistantStore())
            .background(Color(nsColor: .windowBackgroundColor)))
        assistantWindow.contentView = assistantView
        assistantWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        guard assistantWindow.isVisible, window.attachedSheet == nil else {
            throw DataError.invalid("GPT did not open as an independent window")
        }
        _ = try capture(assistantView, name: "gpt-125", directory: directory)
        assistantWindow.orderOut(nil)
        let markdown = NSHostingView(rootView: AtlasInterface(scale: 1.25) {
            AssistantMarkdownView("""
            ## 首尔地铁 · 线路说明
            **2 号线**采用绿色，线路与站点共用颜色。

            | 线路 | 颜色 | 运营方 |
            | --- | --- | --- |
            | 2 号线 | 绿色 | Seoul Metro |
            | 9 号线 | 金色 | Seoul Metro Line 9 |

            1. 从本地数据库取得已知线路色。
            2. 联网补齐线路归属。

            ```json
            {"network": "수도권 전철", "ref": "2"}
            ```

            > 配色来源会显示在要素元信息中。
            """).padding(24).frame(width: 620).background(Color(nsColor: .windowBackgroundColor))
        })
        let markdownWindow = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 620, height: 650),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        markdownWindow.contentView = markdown
        markdownWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        _ = try capture(markdown, name: "gpt-markdown-125", directory: directory)
        markdownWindow.orderOut(nil)
        notes.append("Native GPT Markdown fixture rendered at 125% with headings, numbered lists, table, quote, and selectable/copyable code; no API call.")
        // Verify MapKit's coordinate conversion has unit scale relative to its
        // window even at 160% UI size (a root scaleEffect would fail this).
        store.uiScale = 1.6
        store.changeMode(.apple)
        try await Task.sleep(for: .seconds(1))
        func mapIn(_ view: NSView) -> MKMapView? {
            if let map = view as? MKMapView { return map }
            return view.subviews.lazy.compactMap { mapIn($0) }.first
        }
        guard let map = mapIn(view) else { throw DataError.invalid("Native MapKit view missing") }
        let local = map.bounds.width, physical = map.convert(map.bounds, to: nil).width
        guard abs(local - physical) < 0.01 else { throw DataError.invalid("MapKit is stretched: \(local) vs \(physical)") }
        notes.append("MapKit at 160% UI: \(local)pt local = \(physical)pt in window; no root raster scaling.")
        store.changeMode(.offline)
        let report = notes.joined(separator: "\n")
        try Data(report.utf8).write(to: directory.appendingPathComponent("retina-qa.txt"))
        print(report)
    }
    static func capture(_ view: NSView, name: String, directory: URL) throws -> NSBitmapImageRep {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DataError.invalid("Retina capture allocation failed") }
        view.cacheDisplay(in: view.bounds, to: image)
        // Sheet snapshots contain transparent material. Composite on the
        // actual light window colour so PNG viewers do not show black-on-black.
        guard let solid = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.pixelsWide, pixelsHigh: image.pixelsHigh,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: solid) else { throw DataError.invalid("Retina capture allocation failed") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = CGRect(x: 0, y: 0, width: solid.pixelsWide, height: solid.pixelsHigh)
        NSColor.windowBackgroundColor.setFill(); rect.fill()
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = solid.representation(using: .png, properties: [:]) else { throw DataError.invalid("Retina capture failed") }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        return image
    }
}
#endif
