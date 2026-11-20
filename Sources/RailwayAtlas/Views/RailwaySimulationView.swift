import RailwayCore
import SwiftUI

struct RailwaySimulationView: View {
    @EnvironmentObject private var model: ExperienceStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = ""
    @State private var importing = false
    @State private var error: String?
    @State private var matchedRoute: RailTrackJourney?
    @State private var routeTimetableID = ""
    @State private var preparing = false
    @State private var retry = 0
    private var timetable: RailTimetable? { model.timetables.first { $0.id == selectedID } ?? model.timetables.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TimetableLibraryPanel(library: model.library) { item in
                if let index = model.timetables.firstIndex(where: { $0.id == item.id }) { model.timetables[index] = item }
                else { model.timetables.append(item) }
                selectedID = item.id
                model.selectedTrainID = item.id
                retry += 1
            }
            if let timetable {
                HStack {
                    Picker("已选车次", selection: $selectedID) {
                        ForEach(model.timetables) { Text("\($0.train) · \($0.serviceDate)").tag($0.id) }
                    }.frame(maxWidth: 350)
                    Spacer()
                    Button("导入时刻包", systemImage: "square.and.arrow.down") { importing = true }
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(timetable.train).font(.system(size: 32, weight: .semibold, design: .rounded))
                            Text("\(timetable.stops.first!.station) → \(timetable.stops.last!.station)").font(.headline)
                        }
                        Spacer()
                        Text("\(time(timetable.start)) — \(time(timetable.end))")
                            .font(.system(.title3, design: .monospaced))
                    }
                    Text("\(timetable.serviceDate) 始发 · \(timetable.stops.count) 站 · \(timetable.end - timetable.start) 分钟")
                        .font(.caption).foregroundStyle(.secondary)
                    if let route = matchedRoute, routeTimetableID == timetable.id {
                        Button("在主地图沿实际铁路出发", systemImage: "map") {
                            do {
                                try model.map?.journeyPlayer.start(timetable, route: route)
                                #if os(macOS)
                                openWindow(id: "main-map")
                                #else
                                dismiss()
                                #endif
                            } catch { self.error = error.localizedDescription }
                        }.buttonStyle(.borderedProminent).disabled(model.map == nil)
                        Text("已匹配 \(Int(route.distance / 1000)) km 铁路几何 · 主地图可跟随、停靠、拖动和倍速")
                            .font(.caption).foregroundStyle(.secondary)
                        ExperienceSourceView(source: route.source)
                    } else {
                        if preparing { ProgressView("正在按列车径路匹配沿线轨道…").font(.caption) }
                        else { Button("匹配径路并准备沿线旅行", systemImage: "arrow.clockwise") { retry += 1 } }
                    }
                }.padding(20).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("经停站").frame(maxWidth: .infinity, alignment: .leading)
                        Text("到达").frame(width: 90, alignment: .trailing)
                        Text("出发").frame(width: 90, alignment: .trailing)
                        Text("停站").frame(width: 70, alignment: .trailing)
                    }.font(.caption).foregroundStyle(.secondary).padding(.bottom, 9)
                    ForEach(Array(timetable.stops.enumerated()), id: \.offset) { index, stop in
                        HStack {
                            Text(String(format: "%02d", index + 1)).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary).frame(width: 25, alignment: .leading)
                            Text(stop.station).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                            Text(time(stop.arrival)).frame(width: 90, alignment: .trailing)
                            Text(time(stop.departure)).frame(width: 90, alignment: .trailing)
                            Text(dwell(stop, endpoint: index == 0 || index == timetable.stops.count - 1))
                                .frame(width: 70, alignment: .trailing)
                        }.font(.system(.caption, design: .monospaced)).padding(.vertical, 10).padding(.horizontal, 6)
                    }
                }
                ExperienceSourceView(source: timetable.source)
                Text("沿轨道按时刻插值，非实时列车定位；没有完整到发时刻时，不会猜测停站时间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .task(id: "\(timetable?.id ?? "")/\(retry)") {
            guard let timetable else { return }
            matchedRoute = nil; error = nil; preparing = true
            do {
                let result = try await model.prepareRoute(timetable)
                try Task.checkCancellation()
                matchedRoute = result; routeTimetableID = timetable.id; preparing = false
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; preparing = false }
            }
        }
        .onAppear { if selectedID.isEmpty { selectedID = model.selectedTrainID.isEmpty ? timetable?.id ?? "" : model.selectedTrainID } }
        .onChange(of: model.timetables.map(\.id)) { _, _ in
            if selectedID.isEmpty { selectedID = timetable?.id ?? "" }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(), scope = url.startAccessingSecurityScopedResource()
                defer { if scope { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else {
                    throw DataError.invalid("时刻包超过 5 MB")
                }
                let imported = try RailTimetableArchive.decode(Data(contentsOf: url)).timetables
                try model.addTimetables(imported); selectedID = imported[0].id
                error = "已保存 \(imported.count) 趟车的时刻快照。"
            } catch { self.error = error.localizedDescription }
        }
    }
    private func time(_ minute: Int?) -> String {
        minute.map { RailTimetable.clock(Double($0 * 60), includeSeconds: false) } ?? "—"
    }
    private func dwell(_ stop: RailTimetable.Stop, endpoint: Bool) -> String {
        guard !endpoint, let arrival = stop.arrival, let departure = stop.departure else { return "—" }
        return "\(departure - arrival) 分"
    }
}
