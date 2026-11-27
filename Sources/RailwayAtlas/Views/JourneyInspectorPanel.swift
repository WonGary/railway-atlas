import RailwayCore
import SwiftUI

struct InspectionStationSequence: View {
    let line: InspectionLine
    @ObservedObject var map: RailwayMapStore
    @State private var expanded = true
    var body: some View {
        DisclosureGroup("全线 \(line.stops.count) 个站所", isExpanded: $expanded) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(line.stops.enumerated()), id: \.offset) { i, stop in
                        let station = NationalDirectoryPins.byName[stop.name]
                        Button {
                            if let station { map.select(RailwayMapStore.item(station)) }
                        } label: {
                            HStack {
                                Text("\(i + 1)").foregroundStyle(.secondary)
                                Text(stop.name)
                                Spacer()
                                if let km = stop.kilometre { Text("\(km) km").foregroundStyle(.secondary) }
                                if station == nil { Text("无坐标").foregroundStyle(.secondary) }
                            }.contentShape(Rectangle()).padding(.vertical, 3)
                        }.buttonStyle(.plain).disabled(station == nil)
                        .accessibilityIdentifier("inspection-station-\(stop.name)")
                        .inspectionProbe("inspection-station-\(stop.name)")
                    }
                }
            }.frame(maxHeight: 155)
            if map.lineFocus?.paths.isEmpty == true { Text("图集尚无这条线的轨迹，已标出有坐标的站所。") }
        }.font(.caption).frame(maxWidth: 236, alignment: .leading)
    }
}

struct JourneyInspectorPanel: View {
    @EnvironmentObject private var model: ExperienceStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let table: RailTimetable
    @State private var report: JourneyInspection?
    @State private var reportError: String?
    @State private var rowID: Int?
    @State private var qualityOpen = false
    @State private var compareOpen = false
    @State private var secondNumber = ""
    @State private var secondID = ""
    @State private var secondDate: String
    @State private var sameSection = false
    @State private var comparing = false
    @State private var work: Task<Void, Never>?
    @State private var result: Compared?
    @State private var comparisonError: String?
    @State private var openingLine: String?
    @State private var passengerRequest: PassportSectionRequest?

    private struct Compared {
        let other: JourneyInspection
        let geometry: JourneyTrackComparison
    }

    init(table: RailTimetable) {
        self.table = table
        _secondDate = State(initialValue: table.serviceDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report {
                disclosure("逐段质量 · \(report.legs.filter(\.drawable).count)/\(report.legs.count) 段有轨迹",
                           open: $qualityOpen, id: "inspection-quality")
                if qualityOpen {
                    VStack(alignment: .leading, spacing: 8) {
                        if let note = report.notice { Text(note).foregroundStyle(.secondary) }
                        ForEach(report.legs) { leg in
                            Button {
                                work?.cancel()
                                openingLine = nil
                                comparing = false
                                rowID = rowID == leg.id ? nil : leg.id
                            } label: {
                                HStack {
                                    Image(systemName: rowID == leg.id ? "chevron.down" : "chevron.right")
                                    Text("\(leg.from) → \(leg.to)")
                                    Spacer()
                                    Text(leg.status).foregroundStyle(.secondary)
                                }.contentShape(Rectangle()).padding(.vertical, 3)
                            }.buttonStyle(.plain).accessibilityIdentifier("inspection-leg-\(leg.id)")
                                .inspectionProbe("inspection-leg-\(leg.id)")
                            if rowID == leg.id { legDetail(leg, report: report) }
                        }
                    }.padding(.top, 6).font(.callout)
                }
                disclosure("比较两趟车的径路", open: $compareOpen, id: "inspection-compare")
                if compareOpen {
                    compareFields(report).padding(.top, 6)
                }
                if table.stops.count > 2 {
                    Button("选择乘车区间", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        passengerRequest = PassportSectionRequest(table)
                    }
                }
                if let reportError { Text(reportError).font(.caption).foregroundStyle(.orange) }
            } else if let reportError { Text(reportError).foregroundStyle(.orange) }
            else { ProgressView("正在读取逐段轨迹…").controlSize(.small) }
        }
        .task(id: table) {
            report = nil; reportError = nil
            do {
                let loaded = try await model.inspectJourney(table)
                try Task.checkCancellation()
                report = loaded
            } catch { if !Task.isCancelled { reportError = error.localizedDescription } }
        }
        .onDisappear { work?.cancel() }
        .sheet(item: $passengerRequest) { request in PassportSectionPicker(request: request).environmentObject(model) }
    }

    private func disclosure(_ title: String, open: Binding<Bool>, id: String) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack {
                Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                Text(title)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).font(.headline).accessibilityValue(open.wrappedValue ? "已展开" : "已收起")
            .accessibilityIdentifier(id).inspectionProbe(id)
    }

    @ViewBuilder private func legDetail(_ leg: InspectionLeg, report: JourneyInspection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if leg.drawable {
                Text("\(leg.source) · 轨道 \(km(leg.metres)) · \(leg.points.count) 个顶点")
            } else { Text(leg.status) }
            if let fare = leg.fareKilometres { Text("计价里程 \(fare) km") }
            if !leg.viaStations.isEmpty { Text(leg.viaStations.joined(separator: " → ")) }
            if leg.drawable {
                Button("主地图查看此区间") {
                    guard let map = model.map else { return }
                    work?.cancel(); openingLine = nil; comparing = false
                    map.showInspectionLayers([.init(ink: .first, parts: [leg.points])],
                        title: "\(table.train) · \(leg.from) → \(leg.to)", owner: table.id)
                    showMap()
                }.disabled(model.map == nil).accessibilityIdentifier("inspection-show-leg")
                    .inspectionProbe("inspection-show-leg")
            }
            let endpoints = [leg.from, leg.to].compactMap { NationalDirectoryPins.byName[$0] }
            if !endpoints.isEmpty {
                HStack {
                    ForEach(endpoints, id: \.id) { station in
                        Button(station.name) {
                            guard let map = model.map else { return }
                            work?.cancel(); openingLine = nil; comparing = false
                            map.select(RailwayMapStore.item(station))
                            showMap()
                        }
                    }
                }
            }
            ForEach(leg.viaLines) { line in
                Button("\(leg.planned ? "经由" : "线路目录候选") · \(line.title)全线") {
                    guard let map = model.map else { return }
                    work?.cancel()
                    openingLine = line.title; comparing = false; reportError = nil
                    work = Task {
                        do { try await map.showInspectionLine(line, report: report); openingLine = nil; showMap() }
                        catch { if !Task.isCancelled { openingLine = nil; reportError = error.localizedDescription } }
                    }
                }.disabled(model.map == nil).accessibilityIdentifier("inspection-line-\(line.title)")
                    .inspectionProbe("inspection-line-\(line.title)")
            }
            if let openingLine { ProgressView("正在核对\(openingLine)的轨迹…").controlSize(.small) }
            if leg.viaLines.isEmpty { Text("本机目录没有可展开的经由线路。").foregroundStyle(.secondary) }
        }.font(.caption).padding(.leading, 18).padding(.bottom, 6)
    }

    private func compareFields(_ report: JourneyInspection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let choices = model.timetables.filter { $0.id != table.id }
            if !choices.isEmpty {
                Picker("第二趟车", selection: Binding(get: { secondID }, set: { id in
                    invalidate(); secondID = id
                    if let item = choices.first(where: { $0.id == id }) {
                        secondNumber = item.train; secondDate = item.serviceDate
                    }
                })) {
                    Text("按车次和日期查找").tag("")
                    ForEach(choices) { Text("\($0.train) · \($0.serviceDate)").tag($0.id) }
                }
            }
            TextField("比较车次", text: Binding(get: { secondNumber }, set: {
                invalidate(); secondID = ""; secondNumber = $0
            })).accessibilityIdentifier("inspection-second-train")
                .inspectionProbe("inspection-second-train")
            TextField("始发日期 YYYY-MM-DD", text: Binding(get: { secondDate }, set: {
                invalidate(); secondID = ""; secondDate = $0
            })).accessibilityIdentifier("inspection-second-date")
            Toggle("只比较第一趟车起终点之间的区间", isOn: Binding(get: { sameSection }, set: {
                invalidate(); sameSection = $0
            }))
            Button("在主地图比较", systemImage: "map") { compare(report) }
                .buttonStyle(.borderedProminent)
                .disabled(comparing || secondNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !RailCivilDate.valid(secondDate) || model.map == nil)
                .accessibilityIdentifier("inspection-show-comparison")
                .inspectionProbe("inspection-show-comparison")
            if comparing { ProgressView("正在比较两趟车的轨迹…").controlSize(.small) }
            if let comparisonError { Text(comparisonError).font(.caption).foregroundStyle(.orange) }
            if let result {
                if result.geometry.layers.isEmpty {
                    Text("至少一趟车没有可比较的轨迹。")
                } else {
                    Text("\(table.train) 独有为蓝实线，\(result.other.table.train) 独有为紫虚线，共线为绿线。")
                }
                Text("按 45 m 间距和轨道走向判断，缺轨区间不参与。").font(.caption).foregroundStyle(.secondary)
                ForEach([0, 1], id: \.self) { i in
                    let item = i == 0 ? report : result.other, side = i == 0 ? result.geometry.a : result.geometry.b
                    Text("\(item.table.train) · \(item.table.stops.count) 站 · \(item.table.end - item.table.start) 分 · \(item.legs.filter(\.drawable).count)/\(item.legs.count) 段有轨迹\n共线 \(km(side.sharedMetres)) · 独有 \(km(side.uniqueMetres))")
                        .font(.caption.monospacedDigit())
                }
                Button("收起比较图层") { invalidate() }
            }
        }.textFieldStyle(.roundedBorder)
    }

    private func compare(_ first: JourneyInspection) {
        invalidate(); comparing = true
        let number = secondNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let date = secondDate, selected = model.timetables.first { $0.id == secondID }, crop = sameSection
        work = Task { @MainActor in
            do {
                let second: RailTimetable
                if let selected { second = selected }
                else { second = try await model.inspectionTimetable(train: number, date: date) }
                let full = try await model.inspectJourney(second)
                let other = crop ? try full.betweenEndpoints(of: first.table) : full
                let geometry = try await JourneyTrackComparison.compare(first.paths, other.paths)
                try Task.checkCancellation()
                comparing = false
                result = Compared(other: other, geometry: geometry)
                if let map = model.map, !geometry.layers.isEmpty {
                    let coverage = first.complete && other.complete ? "" : "\n仅比较有轨迹的区间"
                    let legend = geometry.layers.map { layer in
                        switch layer.ink {
                        case .first: return "蓝实线 \(table.train) 独有 \(km(geometry.a.uniqueMetres))"
                        case .second: return "紫虚线 \(other.table.train) 独有 \(km(geometry.b.uniqueMetres))"
                        case .shared: return "绿线 共线 \(km(geometry.a.sharedMetres))"
                        }
                    }.joined(separator: "\n")
                    map.showInspectionLayers(geometry.layers,
                        title: "\(table.train) / \(other.table.train)", owner: table.id, summary: legend + coverage)
                    showMap()
                }
            } catch {
                guard !Task.isCancelled else { return }
                comparisonError = error.localizedDescription
                comparing = false
            }
        }
    }

    private func invalidate() {
        work?.cancel(); work = nil; comparing = false; openingLine = nil; result = nil; comparisonError = nil
        if let map = model.map, map.lineFocus?.inspectionOwner == table.id,
           map.lineFocus?.inspectionLayers.isEmpty == false { map.clearLineFocus() }
    }

    private func showMap() {
        #if os(macOS)
        openWindow(id: "main-map")
        #else
        dismiss()
        NotificationCenter.default.post(name: .railGameDidOpenMap, object: nil)
        #endif
    }
    private func km(_ metres: Double) -> String { String(format: "%.1f km", metres / 1000) }
}
