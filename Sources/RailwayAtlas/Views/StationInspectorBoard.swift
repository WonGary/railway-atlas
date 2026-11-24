#if os(macOS)
import AppKit
import RailwayCore
import SwiftUI
import WebKit

enum NationalDirectoryPins {
    static let all: [RailStation] = {
        guard let file = Bundle.main.url(forResource: "map-points", withExtension: "json", subdirectory: "station-directory"),
              let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([RailStation].self, from: data)) ?? []
    }()
}

struct StationInspectorBoard: View {
    let name: String
    @State private var online = false
    @State private var localRevision = 0
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("车站资料", selection: $online) {
                Text("线路与车次").tag(false)
                Text("原站查询").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if online {
                StationDirectoryView(name: name, inline: true).frame(height: 465)
            } else {
                StationInspectorWeb(name: name, revision: localRevision) { message = $0 }
                    .frame(maxWidth: .infinity).frame(height: 465)
                Button("读取本机时刻库与列车径路") { localRevision += 1 }
                    .accessibilityIdentifier("station-load-local-library")
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }.accessibilityIdentifier("geo-station-directory")
    }
}

struct StationInspectorWeb: NSViewRepresentable {
    let name: String
    let revision: Int
    let report: (String?) -> Void

    final class Coordinator: NSObject, WKNavigationDelegate {
        var selection: String
        var revision = 0
        var ready = false
        var request: Task<Void, Never>?
        let report: (String?) -> Void
        let page: URL?

        init(_ parent: StationInspectorWeb) {
            selection = parent.name
            report = parent.report
            // The release installer and Xcode copy the same web assets. In a SwiftPM
            // development checkout the original directory can be used directly.
            let checkout = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            page = Bundle.main.url(forResource: "native", withExtension: "html", subdirectory: "station-directory")
                ?? [checkout.appendingPathComponent("Web/station-directory/native.html")].first {
                    FileManager.default.fileExists(atPath: $0.path)
                }
        }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            render(view)
        }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report("站表未能打开：\(error.localizedDescription)")
        }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.isFileURL, url.standardizedFileURL == page?.standardizedFileURL { return .allow }
            if action.navigationType == .linkActivated, ["http","https"].contains(url.scheme),
               ["cnrail.geogv.org","github.com","creativecommons.org","www.openstreetmap.org"].contains(url.host) {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
        func render(_ view: WKWebView) {
            guard ready else { return }
            request?.cancel()
            let station = RailJourneyMatcher.normalized(selection), useLibrary = revision > 0
            request = Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                do {
                    var args: [String: Any] = ["name":station, "archive":NSNull()]
                    if useLibrary {
                        let text = try await Task.detached(priority: .userInitiated) { try Self.readLibrary() }.value
                        args["archive"] = text
                    }
                    try Task.checkCancellation()
                    _ = try await view.callAsyncJavaScript("nativeStation(name, archive);", arguments: args, in: nil, contentWorld: .page)
                    if !Task.isCancelled { report(nil) }
                } catch {
                    if !Task.isCancelled { report(error.localizedDescription) }
                }
            }
        }
        nonisolated private static func readLibrary() throws -> String {
            let args = CommandLine.arguments
            let directory: URL
            if let i = args.firstIndex(of: "--ui-smoke"), args.indices.contains(i+1) {
                directory = URL(fileURLWithPath: args[i+1]).appendingPathComponent("experiences/TimetableLibrary")
            } else {
                directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: false).appendingPathComponent("RailwayAtlas/Experiences/TimetableLibrary")
            }
            for file in ["lulutong.json","library.json"] {
                let url = directory.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 80_000_000 else {
                    throw DataError.invalid("本机时刻库超过 80 MB。")
                }
                return try String(contentsOf: url, encoding: .utf8)
            }
            throw DataError.invalid("请先在「铁道漫游 → 沿线旅行」同步或导入时刻库。")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setAccessibilityIdentifier("station-inspector-web")
        if let url = context.coordinator.page {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent().deletingLastPathComponent())
        } else {
            Task { @MainActor in report("安装包缺少车站资料。") }
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let c = context.coordinator
        guard c.selection != name || c.revision != revision else { return }
        c.selection = name; c.revision = revision
        c.render(view)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.request?.cancel()
        view.navigationDelegate = nil
        view.stopLoading()
    }
}
#endif
