import RailwayCore
import SwiftUI

struct PassportTrainLookup: View {
    var select: (RailTimetable) -> Void
    @State private var train = ""
    @State private var date: String = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "Asia/Shanghai")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Date())
    }()
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("随附全国时刻快照").font(.headline)
            TextField("车次", text: $train).accessibilityLabel("车次").accessibilityIdentifier("snapshot-train")
                .inspectionProbe("snapshot-train")
            TextField("始发日期 YYYY-MM-DD", text: $date).accessibilityLabel("始发日期").accessibilityIdentifier("snapshot-date")
                .inspectionProbe("snapshot-date")
            Button("查找车次") {
                let number = train.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), day = date
                busy = true; message = nil
                Task {
                    defer { busy = false }
                    do {
                        if let table = try await NationalJourneyPaths.shared.timetable(train: number, date: day) {
                            select(table)
                        } else { message = "快照里没有 \(day) 始发的 \(number)。可改查下方离线时刻库。" }
                    } catch { message = error.localizedDescription }
                }
            }.disabled(busy || train.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !RailCivilDate.valid(date))
            .accessibilityIdentifier("snapshot-find")
            .inspectionProbe("snapshot-find")
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.textFieldStyle(.roundedBorder)
    }
}

struct PassportSectionRequest: Identifiable {
    let id = UUID()
    let table: RailTimetable
    let limits: ClosedRange<Int>
    let source: String
    init(_ table: RailTimetable) {
        self.table = table
        limits = 0...max(0, table.stops.count - 1)
        source = "时刻表区间"
    }
    init?(_ journey: RailJourney) {
        guard let table = journey.timetable,
              (try? table.passengerSection(from: journey.from, to: journey.to)) != nil,
              let first = table.stops.firstIndex(where: { $0.station == journey.from }),
              let last = table.stops.indices.last(where: { $0 > first && table.stops[$0].station == journey.to })
        else { return nil }
        self.table = table; limits = first...last; source = journey.source
    }
}

struct PassportSectionPicker: View {
    enum Sheet: Identifiable {
        case route(RailJourney), review(JourneyImportBatch)
        var id: UUID {
            switch self { case .route(let journey): journey.id; case .review(let batch): batch.id }
        }
    }
    @EnvironmentObject private var model: ExperienceStore
    @EnvironmentObject private var passport: JourneyStore
    @Environment(\.dismiss) private var dismiss
    let request: PassportSectionRequest
    @State private var first: Int
    @State private var last: Int
    @State private var sheet: Sheet?
    @State private var error: String?

    init(request: PassportSectionRequest) {
        self.request = request
        _first = State(initialValue: request.limits.lowerBound)
        _last = State(initialValue: request.limits.upperBound)
    }

    var body: some View {
        let stops = request.table.stops
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(request.table.train) · 选择区间").font(.title2.weight(.semibold))
                Text("\(request.table.serviceDate) 始发").foregroundStyle(.secondary)
                if stops.indices.contains(first), stops.indices.contains(last), first < last {
                    Picker("上车站", selection: Binding(get: { first }, set: { next in
                        if next >= last { last = request.limits.upperBound }
                        first = next; error = nil
                    })) {
                        ForEach(request.limits.dropLast().filter { stops[$0].departure != nil }, id: \.self) { i in
                            Text(stops[i].station).tag(i)
                        }
                    }
                    Picker("下车站", selection: $last) {
                        ForEach(request.limits.filter { $0 > first && stops[$0].arrival != nil }, id: \.self) { i in
                            Text(stops[i].station).tag(i)
                        }
                    }
                    if let a = stops[first].departure, let b = stops[last].arrival {
                        Text("\(dayTime(a)) 上车\n\(dayTime(b)) 下车").font(.subheadline.monospacedDigit())
                    }
                    Text(stops[first...last].map(\.station).joined(separator: " → "))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("查看区间路线", systemImage: "map") { choose(review: false) }
                    Button("导入护照待核对", systemImage: "book") { choose(review: true) }
                        .buttonStyle(.borderedProminent).disabled(passport.readOnly)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(macOS)
        .frame(minWidth: 390, idealWidth: 480, minHeight: 350)
        #endif
        .sheet(item: $sheet) { page in
            switch page {
            case .route(let journey): PassengerRouteView(journey: journey).environmentObject(model)
            case .review(let batch): JourneyImportReviewView(batch: batch).environmentObject(passport)
            }
        }
    }

    private func dayTime(_ minute: Int) -> String {
        let date = RailCivilDate.addingDays(minute / 1440, to: request.table.serviceDate) ?? request.table.serviceDate
        return "\(date) \(RailTimetable.clock(Double((minute % 1440) * 60), includeSeconds: false))"
    }

    private func choose(review: Bool) {
        do {
            let stops = request.table.stops
            var section = try PassportActivity.segment(request.table, from: stops[first].station, to: stops[last].station)
            section.source = request.source
            if review { sheet = .review(.section(section)) }
            else {
                model.passportActivity.record(section, as: .browsed)
                sheet = .route(section)
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct PassportActivityList: View {
    @ObservedObject var store: PassportActivityStore
    var kind: PassportActivityKind
    var review: (RailJourney) -> Void
    var adjust: (PassportSectionRequest) -> Void
    var preview: (RailJourney) -> Void
    var canImport: Bool
    @State private var removing: PassportActivity?

    var body: some View {
        let entries = store.entries.filter { $0.kind == kind }
        LazyVStack(alignment: .leading, spacing: 14) {
            Text(kind == .browsed ? "在主地图点过的站线、查看过的乘车区间都保存在这里。"
                  : "这里记录你在主地图启动过的列车和区间。").font(.subheadline).foregroundStyle(.secondary)
            if let message = store.message { Text(message).font(.caption).foregroundStyle(.orange) }
            if entries.isEmpty {
                ContentUnavailableView("还没有\(kind.title)记录", systemImage: kind == .browsed ? "map" : "tram")
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(entry.opened, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { removing = entry } label: { Image(systemName: "trash") }
                            .accessibilityLabel("移除这条\(kind.title)记录").buttonStyle(.borderless).disabled(store.readOnly)
                    }
                    switch entry.subject {
                    case let .feature(_, name, station):
                        Label(name, systemImage: station ? "tram" : "point.topleft.down.to.point.bottomright.curvepath")
                    case .segment(let segment):
                        Text("\(segment.from) → \(segment.to)").font(.headline)
                        Text("\(segment.train) · \(segment.date) \(segment.departure) 上车").font(.caption)
                        ViewThatFits {
                            HStack { segmentActions(entry, segment) }
                            VStack(alignment: .leading) { segmentActions(entry, segment) }
                        }
                    }
                }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
        }.confirmationDialog("移除这条\(kind.title)记录？", isPresented: Binding(get: { removing != nil },
            set: { if !$0 { removing = nil } }), presenting: removing) { entry in
                Button("移除记录", role: .destructive) { store.remove(entry) }
            }
    }

    @ViewBuilder private func segmentActions(_ entry: PassportActivity, _ segment: RailJourney) -> some View {
        Button("查看路线") {
            store.record(segment, as: .browsed)
            preview(segment)
        }
        if let request = PassportSectionRequest(segment) { Button("调整区间") { adjust(request) } }
        Button("导入护照待核对") { if let candidate = entry.candidate { review(candidate) } }
            .disabled(!canImport)
    }
}
