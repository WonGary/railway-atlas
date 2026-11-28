import RailwayCore
import SwiftUI

private enum RidePanel: String, Identifiable {
    case places = "沿线地点", relay = "同站车次接力"
    var id: Self { self }
}

struct RideGuideControls: View {
    @ObservedObject var player: RailMapPlayback
    @ObservedObject var guide: RideGuideStore
    @EnvironmentObject private var configuration: ConfigurationStore
    @State private var panel: RidePanel?
    @State private var kinds = Set(RideGuideStore.kinds.map(\.0))

    var body: some View {
        HStack {
            Button(player.follow ? "观光模式" : "回到列车") {
                if player.follow { player.browse() } else { player.resumeFollowing() }
            }
            Toggle("锁定缩放", isOn: Binding(get: { guide.zoomLocked }, set: { player.lockZoom($0) }))
                .disabled(!player.follow)
            Menu("途中") {
                Button("沿线地点") { panel = .places }
                Button("同站车次接力") { panel = .relay }
            }
        }
        .font(.caption)
        .accessibilityIdentifier("ride-guide-controls")
        .sheet(item: $panel) { selection in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selection.rawValue).font(.headline)
                    Spacer()
                    Button("返回地图") { panel = nil }
                }
                switch selection {
                case .places:
                    RidePlacesPanel(player: player, kinds: $kinds) { place in
                        player.inspectPlace(place); panel = nil
                    }
                case .relay: RideRelayPanel(player: player, guide: guide)
                }
            }
            .padding()
            #if os(macOS)
            .frame(minWidth: 420, idealWidth: 470, minHeight: 390, idealHeight: 500)
            #endif
            .atlasMapSheet(mode: configuration.interfaceSettings.surfaceMode,
                          opacity: selection == .places ? configuration.interfaceSettings.placesOpacity :
                            configuration.interfaceSettings.relayOpacity)
        }
    }
}

private struct RidePlacesPanel: View {
    @ObservedObject var player: RailMapPlayback
    @Binding var kinds: Set<String>
    let inspect: (RidePlace) -> Void
    @State private var rows: [RidePlace] = []
    @State private var message = "正在读取沿线地点…"
    @State private var retry = 0

    var body: some View {
        let point = player.playbackMap?.experienceMarker
        let phase = player.timetable?.position(at: player.seconds)
        let leg = min(phase?.from ?? 0, max(0,(player.playbackTrack?.legs.count ?? 1)-1))
        let key = "\(player.guide.session)|\(leg)|\(Int((point?.latitude ?? 0)*500))|\(Int((point?.longitude ?? 0)*500))|\(kinds.sorted())|\(retry)"
        VStack(alignment: .leading) {
            LazyVGrid(columns:[GridItem(.adaptive(minimum:100),alignment:.leading)]) {
                ForEach(RideGuideStore.kinds, id:\.0) { kind, title in
                    Toggle(title, isOn: Binding(get:{ kinds.contains(kind) }, set:{ on in
                        if on { kinds.insert(kind) } else { kinds.remove(kind) }
                    }))
                }
            }
            if rows.isEmpty { Text(message).font(.caption) }
            List(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Button(row.name) { inspect(row) }.buttonStyle(.borderless)
                    Text("\(RideGuideStore.kinds.first { $0.0 == row.kind }?.1 ?? "") · 距列车 \(row.metres) m · 距轨道 \(row.track) m").font(.caption)
                    if !row.note.isEmpty { Text(row.note).foregroundStyle(.secondary).font(.caption) }
                    if let url = URL(string: row.url) { Link(row.source, destination: url).font(.caption) }
                }.listRowBackground(Color.clear)
            }.scrollContentBackground(.hidden)
            Button("刷新地点") { retry += 1 }.font(.caption)
        }
        .task(id: key) {
            guard let route = player.playbackTrack, let point, phase?.phase != .unknown else {
                rows = []; message = "当前区间缺少可定位的轨迹或时刻。"; return
            }
            do {
                let result = try await player.guide.catalog.nearby(route:route, session:player.guide.session, leg:leg, coordinate:point, kinds:Array(kinds))
                try Task.checkCancellation()
                rows = result; message = kinds.isEmpty ? "已关闭全部地点类别。" : "这段轨道附近暂无已收录地点。"
            } catch { if !Task.isCancelled { rows = []; message = error.localizedDescription } }
        }
    }
}

private struct RideRelayPanel: View {
    @ObservedObject var player: RailMapPlayback
    @ObservedObject var guide: RideGuideStore
    @State private var stop = -1
    @State private var hours = 6
    @State private var end = -1
    @State private var choice = ""
    @State private var message = ""
    @State private var choices: [RideConnection] = []
    @State private var query: Task<Void,Never>?

    private var selected: RideConnection? { choices.first { $0.id == choice } }
    private func clear() {
        query?.cancel(); guide.invalidateBoarding()
        choices = []; choice = ""; end = -1; message = ""
    }

    var body: some View {
        let stops = player.timetable?.stops ?? []
        let options = stops.indices.dropFirst().filter { i in
            stops[i].arrival != nil && (i == stops.count-1 || player.seconds <= Double(stops[i].departure ?? -1)*60)
        }
        ScrollView {
            VStack(alignment:.leading, spacing:10) {
                Picker("换乘站", selection:$stop) {
                    ForEach(options,id:\.self) { i in Text(stops[i].station).tag(i) }
                }
                Picker("等候范围", selection:$hours) { Text("6 小时").tag(6); Text("24 小时").tag(24) }
                Button("查找同站车次") {
                    clear(); message = "正在读取站表…"
                    query = Task {
                        do {
                            let rows = try await guide.connections(player, stop:stop, hours:hours)
                            try Task.checkCancellation()
                            choices = rows; choice = rows.first?.id ?? ""; end = rows.first?.destinations.last?.index ?? -1
                            message = rows.isEmpty ? "所选时间内没有已收录的同站发车。" : "\(rows.count) 个同站班次 · 按图定时刻接力"
                        } catch { if !Task.isCancelled { message = error.localizedDescription } }
                    }
                }.disabled(!options.contains(stop))
                if !choices.isEmpty {
                    Picker("接续车次", selection:$choice) {
                        ForEach(choices) { c in
                            Text("\(c.boardDate) \(RailTimetable.clock(Double(c.departure % 1440 * 60), includeSeconds:false)) \(c.train) → \(c.destinations.last?.name ?? "") · \(c.wait) 分 · \(c.origin) 始发 · \(c.trip)").tag(c.id)
                        }
                    }
                    if let c = selected {
                        Picker("接力下车站", selection:$end) {
                            ForEach(c.destinations) { d in Text(d.name).tag(d.index) }
                        }
                        Button("跳到发车并接续") {
                            query?.cancel(); message = "正在核对乘车区间轨迹…"
                            query = Task {
                                do { try await guide.board(c, at:stop, through:end, player:player) }
                                catch { if !Task.isCancelled { message = error.localizedDescription } }
                            }
                        }
                    }
                }
                Text(message).font(.caption)
                if !guide.chain.isEmpty {
                    ForEach(Array(guide.chain.enumerated()),id:\.offset) { _, value in Text(value).font(.caption) }
                    if let train = player.timetable {
                        Text("\(train.train)　\(train.stops.first?.station ?? "") → \(train.stops.last?.station ?? "")（本程）").font(.caption)
                    }
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
        .onChange(of:options, initial:true) { _, values in if !values.contains(stop) { stop = values.first ?? -1 } }
        .onChange(of:stop) { clear() }
        .onChange(of:hours) { clear() }
        .onChange(of:choice) { end = selected?.destinations.last?.index ?? -1; guide.invalidateBoarding() }
        .onChange(of:end) { guide.invalidateBoarding() }
        .onChange(of:guide.session) { clear(); stop = options.first ?? -1 }
        .onDisappear { query?.cancel(); guide.invalidateBoarding() }
    }
}
