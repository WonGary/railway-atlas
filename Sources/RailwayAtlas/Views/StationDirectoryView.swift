import JavaScriptCore
import RailwayCore
import SwiftUI
import WebKit

struct StationDirectoryView: View {
    let name: String
    var inline = false
    var findJourney: ((GeoGVStations.Train) -> Void)?
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
                    else { StationBoardView(id: stationID, findJourney: findJourney).id(stationID) }
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
    let findJourney: ((GeoGVStations.Train) -> Void)?
    @State private var board: GeoGVStations.Board?
    @State private var filter = ""
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        Group {
            if let board {
                TextField("查车次、始发站或终到站", text: $filter).textFieldStyle(.roundedBorder)
                let rows = board.trains.indices.filter { index in
                    let row = board.trains[index]
                    return filter.isEmpty || row.number.localizedCaseInsensitiveContains(filter) ||
                        row.from.contains(filter) || row.to.contains(filter)
                }
                Text("原站 \(board.update) 更新 · 显示 \(rows.count) / \(board.trains.count) 条 · 出行请核对 12306")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(rows, id: \.self) { index in
                            StationRunRow(row: board.trains[index], findJourney: findJourney)
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

/// Keep the dated public trip and the occurrence of the station, including on overnight trains.
struct StationTravelRow: Decodable, Identifiable, Sendable {
    let train, trip, origin, edition: String
    let index: Int
    let stops: [RailTimetable.Stop]
    var id: String { "\(trip)/\(origin)/\(index)" }

    func matches(_ reference: GeoGVStations.Train) -> Bool {
        guard !LuluRouteDatabase.trainNames(reference.number).isDisjoint(with: LuluRouteDatabase.trainNames(train)),
              stops.first?.station == reference.from, stops.last?.station == reference.to else { return false }
        let stop = stops[index]
        for (published, minute) in [(reference.arrival, stop.arrival), (reference.departure, stop.departure)] {
            if published == "始发" || published == "终到" || published == "—" || published.isEmpty { continue }
            let clock = GeoGVStations.clock(published)
            guard let hhmm = clock.split(separator: " ").last, let value = RailCivilDate.minute(String(hhmm)),
                  let minute, minute % 1440 == value else { return false }
            if published.count == 5, published.allSatisfy(\.isNumber),
               let day = Int(published.prefix(1)), day != minute / 1440 + 1 { return false }
        }
        return true
    }

    func resolve(_ bounds: ClosedRange<Int>, paths: NationalJourneyPaths = .shared) async throws -> (RailTimetable, RailTrackJourney) {
        let evidence = RailTimetable(id: "national:\(trip):\(origin)", train: train, serviceDate: origin,
                                     source: .init(title: "中国铁路 GTFS · Jeremy Gao",
                                                   url: "https://github.com/wensimehrp/chinese-railway-gtfs", retrievedOn: edition),
                                     stops: stops)
        let expected = try evidence.passengerSection(indices: bounds)
        let (table, route) = try await paths.relaySection(train: train, origin: origin, trip: trip, indices: bounds)
        guard table.id == expected.id, table.serviceDate == expected.serviceDate, table.stops == expected.stops else {
            throw DataError.invalid("站表与径路库的班次、上下车站或到发时刻不一致。")
        }
        try route.validate(for: table)
        return (table, route)
    }
}

actor StationTravelCatalog {
    static let shared = StationTravelCatalog()
    private var lookup: JSValue?

    func rows(at station: String, on day: String) throws -> [StationTravelRow] {
        if lookup == nil {
            guard let js = JSContext() else { throw DataError.invalid("无法打开本机站表。") }
            for file in ["catalog.js", "national.js"] {
                let url = MapContextFiles.directory.appendingPathComponent(file)
                js.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
                if let error = js.exception { throw DataError.invalid(error.toString()) }
            }
            lookup = js.evaluateScript("""
                (() => {
                  const catalog = StationCatalog.national(globalThis.atlasRailDirectory);
                  return (name, day) => {
                    const station = StationCatalog.resolve(name, catalog);
                    const rows = catalog.board(station, day).map(row => {
                      const detail = row.detail();
                      const index = detail.stops.findIndex(([n,a,d]) => n === station && a === row.arr && d === row.dep);
                      return {train: row.number, trip: detail.id, origin: row.origin, index, edition: catalog.edition,
                              stops: detail.stops.map(([station,arrival,departure]) => ({station,arrival,departure}))};
                    });
                    return JSON.stringify(rows.filter(r => r.index >= 0));
                  };
                })()
                """)
            if let error = js.exception { lookup = nil; throw DataError.invalid(error.toString()) }
        }
        try Task.checkCancellation()
        guard let lookup, let text = lookup.call(withArguments: [station, day])?.toString(),
              lookup.context.exception == nil else { throw DataError.invalid("无法读取所选日期的站表。") }
        let rows = try JSONDecoder().decode([StationTravelRow].self, from: Data(text.utf8))
        func clock(_ row: StationTravelRow) -> Int {
            let stop = row.stops[row.index]
            return (stop.departure ?? stop.arrival ?? 0) % 1440
        }
        return rows.sorted { (clock($0), $0.train, $0.id) < (clock($1), $1.train, $1.id) }
    }
}

struct StationTravelDirectory: View {
    let name: String
    var open: (RailTimetable, RailTrackJourney) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var search = ""
    @State private var original = false
    @State private var reference: GeoGVStations.Train?
    @State private var selection: StationTravelRow?
    @State private var rows: [StationTravelRow] = []
    @State private var loaded: String?
    @State private var failure: String?

    init(name: String, initialDate: Date = .now, open: @escaping (RailTimetable, RailTrackJourney) throws -> Void) {
        self.name = name
        self.open = open
        _date = State(initialValue: initialDate)
    }

    static let zone = TimeZone(identifier: "Asia/Shanghai")!
    static func civilDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    private var key: String { "\(name)/\(Self.civilDay(date))" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(name) · 本站车次").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            if let selection {
                Button("返回本站车次") { self.selection = nil }
                StationTravelSection(row: selection, open: open).id(selection.id)
            } else {
                DatePicker("本站日期", selection: $date, displayedComponents: .date)
                    .environment(\.timeZone, Self.zone)
                    .accessibilityIdentifier("station-board-date")
                Button("查看原站线路和车次") { original = true }
                if let reference {
                    Text("原站 \(reference.number)　\(reference.from) → \(reference.to)").font(.caption)
                    Button("查看本站其他车次") { self.reference = nil; search = "" }
                }
                TextField("查车次、始发站或终到站", text: $search)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("station-board-search")
                if loaded != key { ProgressView("读取本机时刻表…") }
                else if let failure { Text(failure) }
                else {
                    let found = rows.filter { row in
                        (reference.map(row.matches) ?? true) &&
                        (search.isEmpty || [row.train, row.stops[0].station, row.stops[row.stops.count - 1].station]
                            .contains { $0.localizedCaseInsensitiveContains(search) })
                    }
                    if found.isEmpty { Text("该站、日期和筛选条件下没有匹配班次。").font(.callout) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(found) { row in
                                Button {
                                    selection = row
                                } label: {
                                    let call = row.stops[row.index]
                                    VStack(alignment: .leading) {
                                        Text("\(row.train)　\(row.stops[0].station) → \(row.stops[row.stops.count - 1].station)")
                                        if let minute = call.departure ?? call.arrival {
                                            Text("\(call.departure == nil ? "本站到达" : "本站开车") \(RailTimetable.clock(Double(minute % 1440) * 60, includeSeconds: false))")
                                                .font(.caption)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.accessibilityIdentifier("station-board-run-\(row.id)")
                                Divider()
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .sheet(isPresented: $original) {
            StationDirectoryView(name: name, findJourney: { train in
                reference = train; search = ""; original = false
            })
        }
        .task(id: key) {
            let request = key
            do {
                let result = try await StationTravelCatalog.shared.rows(at: name, on: Self.civilDay(date))
                try Task.checkCancellation()
                rows = result; failure = nil; loaded = request
            } catch {
                if !Task.isCancelled { rows = []; failure = error.localizedDescription; loaded = request }
            }
        }
    }
}

private struct StationTravelSection: View {
    let row: StationTravelRow
    let open: (RailTimetable, RailTrackJourney) throws -> Void
    @State private var from: Int
    @State private var to: Int
    @State private var request: UUID?
    @State private var failure: String?

    init(row: StationTravelRow, open: @escaping (RailTimetable, RailTrackJourney) throws -> Void) {
        self.row = row; self.open = open
        _from = State(initialValue: row.index == row.stops.count - 1 ? 0 : row.index)
        _to = State(initialValue: row.stops.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(row.train) · \(row.origin) 始发").font(.headline)
            Picker("上车站", selection: Binding(get: { from }, set: {
                from = $0; to = max(to, from + 1); failure = nil
            })) {
                ForEach(row.stops.indices.dropLast(), id: \.self) { i in Text(row.stops[i].station).tag(i) }
            }.accessibilityIdentifier("station-board-from")
            Picker("下车站", selection: $to) {
                ForEach((from + 1)..<row.stops.count, id: \.self) { i in Text(row.stops[i].station).tag(i) }
            }.accessibilityIdentifier("station-board-to").onChange(of: to) { failure = nil }
            if let minute = row.stops[from].departure, let day = RailCivilDate.addingDays(minute / 1440, to: row.origin) {
                Text("\(day) 上车　\(RailTimetable.clock(Double(minute % 1440) * 60, includeSeconds: false))")
                    .font(.callout)
            }
            Button("在主地图沿线旅行", systemImage: "play.fill") { failure = nil; request = UUID() }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("station-board-start")
            if request != nil { ProgressView("核对区间时刻和轨迹…") }
            if let failure { Text(failure).font(.callout).accessibilityIdentifier("station-board-error") }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(row.stops.indices, id: \.self) { i in
                        let stop = row.stops[i]
                        Text("\(stop.station)　\(clock(stop.arrival) ?? "始发") / \(clock(stop.departure) ?? "终到")")
                    }
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(request != nil)
        .task(id: request) {
            guard let request else { return }
            defer { if self.request == request { self.request = nil } }
            do {
                let (table, track) = try await row.resolve(from...to)
                try Task.checkCancellation()
                try open(table, track)
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    private func clock(_ minute: Int?) -> String? {
        minute.map { RailTimetable.clock(Double($0) * 60, includeSeconds: false) }
    }
}

private struct StationRunRow: View {
    let row: GeoGVStations.Train
    let findJourney: ((GeoGVStations.Train) -> Void)?
    @State private var expanded = false
    @State private var run: GeoGVStations.Run?
    @State private var failure: String?
    @State private var attempt = 0
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let findJourney {
                Button("选择本站日期与旅行区间") { findJourney(row) }
                    .accessibilityIdentifier("station-origin-journey-\(row.number)")
            }
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
