import Foundation
import RailwayCore
import SwiftUI
import WebKit

struct RailGameAssets {
    let page: URL
    let webRoot: URL
    let scripts: [String]

    init(page: URL, webRoot: URL) throws {
        guard FileManager.default.isReadableFile(atPath: page.path) else { throw CocoaError(.fileNoSuchFile) }
        self.page = page.standardizedFileURL
        self.webRoot = webRoot.standardizedFileURL
        func read(_ path: String) throws -> String {
            try String(contentsOf: webRoot.appendingPathComponent(path), encoding: .utf8)
        }
        scripts = [try read("station-directory/national.js"), "globalThis.railGameOutlinePack = " + (try read("games/outlines.json")) + ";",
                   try read("rail-games.js")]
    }

    static let bundled: Result<Self, Error> = Result {
        if let root = Bundle.main.resourceURL {
            for page in ["Resources/RailGames/native.html", "RailGames/native.html"] {
                let url = root.appendingPathComponent(page)
                if FileManager.default.isReadableFile(atPath: url.path) { return try Self(page: url, webRoot: root) }
            }
        }
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Self(page: source.appendingPathComponent("Resources/RailGames/native.html"),
                        webRoot: source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web"))
        #else
        throw DataError.invalid("安装包缺少铁路游戏页面或题库。")
        #endif
    }
}

/// Only the app's bundled page can request a verified journey or present a PNG export.
@MainActor
final class RailGameWebSession: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    typealias Open = (RailTimetable, RailTrackJourney) throws -> Void
    typealias Export = (String, Data) -> Void
    private var game: String
    private(set) var ready = false
    private var page: URL?
    private var request: Task<Void, Never>?
    var open: Open
    var export: Export
    var report: (String) -> Void

    init(game: String, open: @escaping Open, export: @escaping Export, report: @escaping (String) -> Void) {
        self.game = game; self.open = open; self.export = export; self.report = report
    }

    func makeView(assets: RailGameAssets) -> WKWebView {
        page = assets.page
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        if RailGamesAcceptance.requested {
            config.websiteDataStore = .nonPersistent()
            controller.addUserScript(WKUserScript(source: "Date.now = () => 1795827600000; Math.random = () => 0.999999;",
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        for script in assets.scripts {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        for name in ["railGameTravel", "railGameCard"] { controller.addScriptMessageHandler(self, contentWorld: .page, name: name) }
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.loadFileURL(assets.page, allowingReadAccessTo: assets.page)
        return view
    }

    func select(_ id: String, in view: WKWebView) {
        guard id != game else { return }
        request?.cancel()
        game = id
        if ready { render(view) }
    }
    private func render(_ view: WKWebView) {
        let current = game
        Task { @MainActor [weak self, weak view] in
            guard let self, let view, self.ready, self.game == current else { return }
            do {
                _ = try await view.callAsyncJavaScript("selectRailGame(game)", arguments: ["game": current], in: nil, contentWorld: .page)
            } catch { if self.ready, self.game == current { self.report(error.localizedDescription) } }
        }
    }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render(view) }
    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error.localizedDescription)
    }
    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.targetFrame?.isMainFrame == true && action.request.url?.standardizedFileURL == page ? .allow : .cancel
    }
    func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
        ready = false; request?.cancel()
        if let page { view.loadFileURL(page, allowingReadAccessTo: page) }
    }
    func stop(_ view: WKWebView) {
        ready = false; request?.cancel()
        for name in ["railGameTravel", "railGameCard"] {
            view.configuration.userContentController.removeScriptMessageHandler(forName: name, contentWorld: .page)
        }
        view.navigationDelegate = nil; view.stopLoading()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard ready, message.frameInfo.isMainFrame, message.frameInfo.request.url?.standardizedFileURL == page,
              let body = message.body as? [String: Any] else { replyHandler(nil, "游戏页面已关闭。"); return }
        if message.name == "railGameCard" {
            guard let name = body["name"] as? String, name.count <= 100, !name.contains("/"), name.hasSuffix(".png"),
                  let encoded = body["png"] as? String, encoded.utf8.count < 2_000_000,
                  let data = Data(base64Encoded: encoded), data.starts(with: [137,80,78,71,13,10,26,10]) else {
                replyHandler(nil, "完成卡图像无效。"); return
            }
            export(name, data); replyHandler(true, nil); return
        }
        guard message.name == "railGameTravel", JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count < 4096,
              let journey = try? JSONDecoder().decode(RailGameJourney.self, from: data)
        else { replyHandler(nil, "乘车区间无效。"); return }
        request?.cancel()
        request = Task { @MainActor [weak self] in
            do {
                let (table, route) = try await journey.resolve()
                try Task.checkCancellation()
                guard let self, self.ready else { throw CancellationError() }
                try self.open(table, route)
                replyHandler(true, nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        }
    }
}

struct RailGamesWebView {
    let game: String
    let assets: RailGameAssets
    let open: RailGameWebSession.Open
    let export: RailGameWebSession.Export
    let report: (String) -> Void
    @MainActor func makeCoordinator() -> RailGameWebSession {
        RailGameWebSession(game: game, open: open, export: export, report: report)
    }
    @MainActor func update(_ view: WKWebView, _ session: RailGameWebSession) {
        session.open = open; session.export = export; session.report = report; session.select(game, in: view)
    }
}
#if os(macOS)
extension RailGamesWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView(assets: assets) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: RailGameWebSession) { coordinator.stop(view) }
}
#else
extension RailGamesWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView(assets: assets) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context.coordinator) }
    static func dismantleUIView(_ view: WKWebView, coordinator: RailGameWebSession) { coordinator.stop(view) }
}
#endif
