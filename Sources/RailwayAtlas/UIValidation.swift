#if os(macOS)
import AppKit
import Foundation
import RailwayCore

/// Explicit command-line smoke mode; never runs during a normal launch.
@MainActor
enum UIValidation {
    private static var started = false

    static func runIfRequested(store: RailwayMapStore) async {
        let arguments = CommandLine.arguments
        guard !started, let index = arguments.firstIndex(of: "--ui-smoke"), arguments.count > index + 1 else { return }
        started = true
        do {
            let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSApp.appearance = NSAppearance(named: .aqua)
            store.mapMode = .offline
            store.fitDataset()
            guard store.urbanRoutes.contains(where: { $0.tags["ref"] == "1" && $0.color?.hex == "#E6002A" }) else {
                throw DataError.invalid("Bundled metro route palette was not loaded")
            }
            try await Task.sleep(for: .seconds(1))
            let window = NSApp.windows.first { $0.contentView != nil && $0.isVisible }
            window?.setContentSize(NSSize(width: 1240, height: 820))
            window?.center()
            try await Task.sleep(for: .seconds(1))
            try capture("01-overview", directory: directory, window: window)

            store.searchText = "shanghaihongqiao"
            guard let station = store.results.first(where: { $0.name == "上海虹桥" }) else {
                throw DataError.invalid("Shanghai Hongqiao search failed")
            }
            store.select(station)
            guard abs(store.region.center.latitude - station.coordinate.latitude) < 0.00001 else {
                throw DataError.invalid("Search did not move camera")
            }
            try await Task.sleep(for: .milliseconds(700))
            try capture("02-search-station", directory: directory, window: window)
            store.searchText = ""
            store.selection = nil
            store.selectedTab = 1
            let filteredCategories: Set<RailCategory> = [.speed350, .speed300]
            store.categories = filteredCategories
            guard store.visibleLines.allSatisfy({ filteredCategories.contains($0.category) }) else {
                throw DataError.invalid("Layer filter failed")
            }
            try await Task.sleep(for: .milliseconds(500))
            try capture("03-layers", directory: directory, window: window)
            store.selectedTab = 2
            store.categories = Set(RailCategory.allCases)
            store.fitDataset()
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try await Task.sleep(for: .milliseconds(500))
            try capture("04-dark-packages", directory: directory, window: window)

            NSApp.appearance = NSAppearance(named: .aqua)
            store.mapMode = .apple
            try await Task.sleep(for: .seconds(8))
            try capture("05-apple-map", directory: directory, window: window)
            let report = """
            UI smoke passed:
            - Bundled OSM dataset loaded: \(store.dataset?.lines.count ?? 0) segments.
            - Pinyin search found 上海虹桥.
            - Shanghai Metro route relations use the official line palette.
            - Selection moved the camera to station coordinates.
            - Layer filter excluded non-selected categories.
            - Offline overview, station, layer, dark and MapKit views captured.
            Note: snapshots require visual inspection; MapKit network/basemap availability is not asserted.
            """
            try Data(report.utf8).write(to: directory.appendingPathComponent("ui-smoke.txt"))
            print(report)
            NSApp.terminate(nil)
        } catch {
            fputs("UI smoke FAILED: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ name: String, directory: URL, window: NSWindow?) throws {
        guard let view = window?.contentView,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw DataError.invalid("No visible app window")
        }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw DataError.invalid("Window capture failed")
        }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
#endif
