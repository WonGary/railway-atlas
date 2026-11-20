import RailwayCore
import SwiftUI

struct TimetableLibraryPanel: View {
    @ObservedObject var library: TimetableLibraryStore
    var select: (RailTimetable) -> Void
    @State private var importing = false
    @State private var expanded = true
    @State private var query = ""
    @State private var date = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: .now)
    }()
    var body: some View {
        DisclosureGroup(library.lulu.map { "路路通离线库 · \($0.services.count) 条车次 · 查询 / 更新" }
                        ?? "共享离线时刻库 · 查询 / 更新", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let lulu = library.lulu {
                    Text("路路通 · 数据库版本 \(lulu.edition) · \(lulu.services.count) 条车次 / \(lulu.stationCount) 个站名")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(lulu.routing.map { "含 \($0.lines.count) 条线路、\($0.routes.count) 条列车径路" }
                         ?? "旧库尚未包含径路；同步后可匹配沿线旅行及乘车区间")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let archive = library.archive {
                    Text("\(archive.provider) · \(archive.edition) · \(archive.timetables.count) 个日期车次")
                        .font(.caption).foregroundStyle(.secondary)
                } else if library.lulu == nil {
                    Text("点击同步，读取路路通官网公开安装包内的完整时刻数据；只下载和转换资料，不运行安装包。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("同步路路通离线库", systemImage: "arrow.clockwise") { Task { await library.synchronizeLulu() } }
                        .buttonStyle(.borderedProminent)
                    Button("导入离线库…", systemImage: "square.and.arrow.down") { importing = true }
                    if library.busy { ProgressView().controlSize(.small) }
                }.disabled(library.busy)
                DisclosureGroup("其他数据源") {
                    HStack {
                        TextField("HTTPS 离线库更新地址", text: $library.updateURL).textFieldStyle(.roundedBorder)
                        Button("同步") { Task { await library.synchronize() } }.disabled(library.busy)
                    }.padding(.top, 8)
                }
                Text("版本日不等于出行日。条件开行、停运等标记尚需核对。更新时刻与径路库，不修改护照记录。")
                    .font(.caption2).foregroundStyle(.secondary)
                if let message = library.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if library.archive != nil || library.lulu != nil {
                    HStack {
                        TextField("搜索车次或车站", text: $query)
                        TextField("始发日期 YYYY-MM-DD", text: $date).frame(maxWidth: 200)
                    }.textFieldStyle(.roundedBorder)
                    if !query.isEmpty {
                        let luluResults = (library.lulu?.services ?? []).lazy.filter {
                            $0.validFrom <= date && date <= $0.validThrough
                                && ($0.train.localizedCaseInsensitiveContains(query) || $0.stops.contains { $0.station.contains(query) })
                        }.prefix(20)
                        ForEach(Array(luluResults)) { service in
                            Button {
                                do {
                                    select(try library.lulu!.timetable(service, on: date))
                                }
                                catch { library.message = error.localizedDescription }
                            } label: {
                                HStack {
                                    Text(service.train).font(.caption.monospacedDigit())
                                    Text("\(service.stops.first!.station) → \(service.stops.last!.station)").font(.caption)
                                    if service.conditional { Text("开行规则待核对").font(.caption2).foregroundStyle(.orange) }
                                    Spacer()
                                    Image(systemName: "arrow.up.forward")
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(library.busy)
                        }
                        if let lulu = library.lulu, let first = query.first, first.isLetter,
                           query.dropFirst().allSatisfy(\.isNumber), query.count > 1,
                           !lulu.services.contains(where: { $0.validFrom <= date && date <= $0.validThrough &&
                               LuluRouteDatabase.trainNames($0.train).contains(query.uppercased()) }) {
                            let digits = query.dropFirst()
                            let options = Set(lulu.services.filter {
                                $0.train.count == query.count && $0.train.dropFirst() == digits &&
                                    $0.validFrom <= date && date <= $0.validThrough
                            }.map(\.train)).sorted()
                            Text(options.isEmpty ? "当天排图中没有完整车次 \(query.uppercased())。" :
                                    "当天没有完整车次 \(query.uppercased())。同号其他车种：" + options.joined(separator: "、"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let results = (library.archive?.timetables ?? []).lazy.filter {
                            (date.isEmpty || $0.serviceDate == date)
                            && (query.isEmpty || $0.train.localizedCaseInsensitiveContains(query)
                                || $0.stops.contains { $0.station.contains(query) })
                        }.prefix(20)
                        ForEach(Array(results)) { train in
                            Button {
                                select(train)
                            } label: {
                                HStack {
                                    Text("\(train.train) · \(train.serviceDate)").font(.caption.monospacedDigit())
                                    Text("\(train.stops.first!.station) → \(train.stops.last!.station)").font(.caption)
                                    Spacer()
                                    Image(systemName: "arrow.up.forward")
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(library.busy)
                        }
                        Text("按排图有效期筛选，最多显示 20 条；选择后填入待核对草稿，不代表确认开行。").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.padding(.top, 12)
        }
        .font(.subheadline)
        .padding(14).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { Task { await library.importFile(url) } }
            if case .failure(let error) = result { library.message = error.localizedDescription }
        }
    }
}

extension RailTimetable {
    var draftJourney: RailJourney {
        var draft = RailJourney(date: serviceDate, train: train, from: stops.first?.station ?? "", to: stops.last?.station ?? "",
                    departure: RailTimetable.clock(Double(start * 60), includeSeconds: false),
                    source: "离线时刻库 · 待核对")
        draft.timetable = self
        return draft
    }
}
