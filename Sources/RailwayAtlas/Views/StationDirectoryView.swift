import RailwayCore
import SwiftUI
import WebKit

struct StationDirectoryView: View {
    let name: String
    var inline = false
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [GeoGVStations.Choice] = []
    @State private var stationID = ""
    @State private var section = 0
    @State private var attempt = 0
    @State private var lookupError: String?
    @State private var searching = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !inline { HStack {
                Text(name).font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            } }
            if searching { ProgressView("查找车站…") }
            else if let lookupError {
                Text(lookupError)
                Button("重新查找") { attempt += 1 }
            } else if choices.isEmpty { Text("原站未收录这个站名。") }
            else {
                if choices.count > 1 {
                    Picker("选择原站记录", selection: $stationID) {
                        Text("请选择").tag("")
                        ForEach(choices) { Text($0.name).tag($0.id) }
                    }
                }
                if !stationID.isEmpty {
                    Picker("车站资料", selection: $section) {
                        Text("途经线路").tag(0); Text("本站车次").tag(1)
                    }.pickerStyle(.segmented)
                    if section == 0 { StationLinesView(id: stationID).id(stationID) }
                    else { StationBoardView(id: stationID).id(stationID) }
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Link("中国铁路地图 · Kejing Peng", destination: stationID.isEmpty ? GeoGVStations.website :
                        GeoGVStations.website.appendingPathComponent("geo/" + stationID))
                Spacer()
                Link("CC BY-SA 4.0", destination: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/deed.zh-hans")!)
            }.font(.caption)
        }
        .padding(inline ? 2 : 16)
        #if os(macOS)
        .frame(minWidth: inline ? 0 : 610, idealWidth: inline ? nil : 680, minHeight: inline ? 390 : 450, idealHeight: inline ? nil : 565)
        #endif
        .task(id: "\(name)/\(attempt)") {
            searching = true; lookupError = nil; stationID = ""
            do {
                let query = name.hasSuffix("站") ? String(name.dropLast()) : name
                let found = try await GeoGVStations.shared.search(query)
                try Task.checkCancellation()
                choices = found
                let exact = found.filter { $0.name == query }
                if exact.count == 1 { stationID = exact[0].id }
                else if found.count == 1, found[0].name == name { stationID = found[0].id }
                else if found.count == 1 { choices = [] }
            } catch { if Task.isCancelled { return }; lookupError = error.localizedDescription }
            searching = false
        }
    }
}

private struct StationLinesView: View {
    let id: String
    @State private var station: GeoGVStations.Station?
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        Group {
            if let station {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if station.lines.isEmpty { Text("原站未列出这座车站所属的线路。") }
                        ForEach(Array(station.lines.enumerated()), id: \.offset) { _, line in
                            StationLineRow(line: line)
                            Divider()
                        }
                    }.padding(.vertical, 4)
                }
            } else if let failure { Text(failure); Button("重试") { retry += 1 } }
            else { ProgressView("读取途经线路…") }
        }.task(id: retry) {
            failure = nil
            do { let result = try await GeoGVStations.shared.station(id); try Task.checkCancellation(); station = result }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

private struct StationLineRow: View {
    let line: GeoGVStations.Line
    @State private var expanded = false
    @State private var stops: [GeoGVStations.Stop]?
    @State private var failure: String?
    @State private var retry = 0
    @State private var showsDiagram = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let stops {
                    if line.eid != nil {
                        Button("查看原站全线图", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                            showsDiagram = true
                        }
                    }
                    if stops.isEmpty { Text("原站尚缺这条线路的站序。") }
                    ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                        HStack {
                            Canvas { context, size in
                                let x = size.width / 2, middle = size.height / 2
                                var segment = Path()
                                segment.move(to: CGPoint(x: x, y: index == 0 ? middle : -3))
                                segment.addLine(to: CGPoint(x: x, y: index == stops.count - 1 ? middle : size.height + 3))
                                context.stroke(segment, with: .color(.secondary), lineWidth: 1.5)
                                let dot = Path(ellipseIn: CGRect(x: x - 3, y: middle - 3, width: 6, height: 6))
                                context.fill(dot, with: .color(.accentColor))
                            }.frame(width: 12).accessibilityHidden(true)
                            Text(stop.name)
                            if !stop.note.isEmpty { Text(stop.note).foregroundStyle(.secondary) }
                            Spacer()
                            Text(Double(stop.mileage) == nil ? stop.mileage : "\(stop.mileage) km").monospacedDigit()
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                } else if let failure { Text(failure); Button("重试") { retry += 1 } }
                else { ProgressView("读取全线站点和线路所…") }
            }.font(.callout).padding(.leading, 10).textSelection(.enabled)
        } label: { Text(line.linename).font(.headline) }
        .sheet(isPresented: $showsDiagram) {
            if let lineID = line.eid {
                StationDiagramPage(name: line.linename, url: GeoGVStations.website.appendingPathComponent("rail").appendingPathComponent(lineID))
            }
        }
        .task(id: "\(expanded)/\(retry)") {
            guard expanded, stops == nil else { return }
            guard let eid = line.eid else { failure = "原站没有提供这条线路的详图。"; return }
            failure = nil
            do { let result = try await GeoGVStations.shared.line(eid); try Task.checkCancellation(); stops = result }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

private struct StationDiagramPage: View {
    let name: String
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var status: StationDiagramWebView.LoadStatus = .loading
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("返回站表") { dismiss() }.keyboardShortcut(.cancelAction)
                Text(name).font(.headline)
                Spacer()
                Link("在浏览器打开", destination: url)
            }.padding(12)
            Divider()
            ZStack {
                StationDiagramWebView(url: url) { status = $0 }.id(attempt)
                switch status {
                case .loading: ProgressView("正在打开原站线路图…").padding().background(.regularMaterial)
                case .loaded: EmptyView()
                case .failed(let message):
                    VStack(spacing: 10) {
                        Text(message)
                        Button("重新载入") { status = .loading; attempt += 1 }
                    }.padding().background(.regularMaterial)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 610, idealWidth: 760, minHeight: 450, idealHeight: 610)
        #endif
    }
}

#if os(macOS)
private typealias StationWebRepresentable = NSViewRepresentable
#else
private typealias StationWebRepresentable = UIViewRepresentable
#endif

private struct StationDiagramWebView: StationWebRepresentable {
    enum LoadStatus { case loading, loaded, failed(String) }
    let url: URL
    let updateStatus: (LoadStatus) -> Void

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let update: (LoadStatus) -> Void
        init(update: @escaping (LoadStatus) -> Void) { self.update = update }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url,
                  url.host == GeoGVStations.website.host,
                  ["http", "https"].contains(url.scheme),
                  !action.shouldPerformDownload else { return .cancel }
            return .allow
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { update(.loaded) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { update(.failed("原图页面已关闭。")) }
        private func report(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            update(.failed(error.localizedDescription))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(update: updateStatus) }

    private func makeView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = coordinator
        view.load(URLRequest(url: url, timeoutInterval: 18))
        return view
    }
    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.stopLoading()
    }
    #else
    func makeUIView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.stopLoading()
    }
    #endif
}

private struct StationBoardView: View {
    let id: String
    @State private var board: GeoGVStations.Board?
    @State private var filter = ""
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        Group {
            if let board {
                TextField("查车次、始发站或终到站", text: $filter).textFieldStyle(.roundedBorder)
                let rows = board.trains.filter { filter.isEmpty || $0.number.localizedCaseInsensitiveContains(filter) ||
                    $0.from.contains(filter) || $0.to.contains(filter) }
                Text("原站 \(board.update) 更新 · 显示 \(rows.count) / \(board.trains.count) 条 · 出行请核对 12306")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            StationRunRow(row: row)
                        }
                    }.textSelection(.enabled)
                }
            } else if let failure { Text(failure); Button("重试") { retry += 1 } }
            else { ProgressView("读取本站车次表…") }
        }.task(id: retry) {
            failure = nil
            do { let result = try await GeoGVStations.shared.board(id); try Task.checkCancellation(); board = result }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

private struct StationRunRow: View {
    let row: GeoGVStations.Train
    @State private var expanded = false
    @State private var run: GeoGVStations.Run?
    @State private var failure: String?
    @State private var attempt = 0
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let run {
                ForEach(Array(run.sections.enumerated()), id: \.offset) { _, section in
                    if let label = section.opid { Text(label).font(.caption.bold()) }
                    ForEach(Array(section.stops.enumerated()), id: \.offset) { _, stop in
                        Text("\(stop.name)　\(GeoGVStations.clock(stop.arr)) / \(GeoGVStations.clock(stop.dep))")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if let failure {
                Text(failure)
                if row.route != nil { Button("重试") { attempt += 1 } }
            } else { ProgressView("读取全程时刻…") }
        } label: {
            VStack(alignment: .leading) {
                Text(row.number).font(.callout.weight(.medium))
                Text("\(row.from) → \(row.to)")
                Text("\(row.arrival) / \(row.departure)").foregroundStyle(.secondary)
            }
        }
        .font(.caption).task(id: "\(expanded)-\(attempt)-\(row.route ?? "")") {
            guard expanded, run == nil else { return }
            guard let route = row.route else { failure = "原站未提供全程时刻。"; return }
            failure = nil
            do { let result = try await GeoGVStations.shared.run(route); try Task.checkCancellation(); run = result }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
