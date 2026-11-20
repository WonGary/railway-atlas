import RailwayCore
import SwiftUI
import UniformTypeIdentifiers

struct ExperienceFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .png, .plainText] }
    var data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct JourneyImportBatch: Identifiable {
    let id = UUID()
    var journeys: [RailJourney]
    var notes: [String]
}

struct RailwayPassportView: View {
    @EnvironmentObject private var passport: JourneyStore
    @EnvironmentObject private var model: ExperienceStore
    @State private var importing = false
    @State private var reading = false
    @State private var batch: JourneyImportBatch?
    @State private var editing: RailJourney?
    @State private var routeJourney: RailJourney?
    @State private var exporting = false
    @State private var exportFile = ExperienceFile(Data())
    @State private var exportType = UTType.json
    @State private var exportName = "铁路护照"
    @State private var query = ""
    @State private var statusFilter: RailJourney.Status?

    private var filtered: [RailJourney] {
        passport.journeys.filter {
            (statusFilter == nil || statusFilter == $0.status)
            && (query.isEmpty || "\($0.date) \($0.train) \($0.from) \($0.to) \($0.note)".localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TimetableLibraryPanel(library: model.library) { editing = $0.draftJourney }
            HStack(spacing: 12) {
                metric("\(passport.travelled.count)", label: "已乘坐")
                metric("\(passport.visitedStations)", label: "到访车站")
                metric("\(passport.pendingCount)", label: "待核对")
            }
            ViewThatFits {
                HStack { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            .disabled(reading || passport.readOnly)
            if reading { ProgressView("正在本机读取与识别票据…").font(.caption) }
            if let error = passport.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            DisclosureGroup("粘贴短信或邮件文字") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.pastedJourneyText).font(.system(.body, design: .monospaced))
                        .frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text("保留日期、车次和“出发站→到达站”。只提取候选字段，缺项请在核对页补全。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("提取并核对") {
                        batch = JourneyImportBatch(journeys: JourneyImport.text(model.pastedJourneyText), notes: [])
                    }.disabled(model.pastedJourneyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || passport.readOnly)
                }.padding(.top, 8)
            }.font(.subheadline)
            if passport.deleted != nil {
                HStack {
                    Text("已移除一条记录").font(.caption).foregroundStyle(.secondary)
                    Button("撤销") { passport.undoRemoval() }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("搜索车次、车站或年份", text: $query).textFieldStyle(.roundedBorder)
                Picker("状态", selection: $statusFilter) {
                    Text("全部记录").tag(Optional<RailJourney.Status>.none)
                    ForEach(RailJourney.Status.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.frame(maxWidth: 150)
            }
            if passport.journeys.isEmpty {
                ContentUnavailableView("你的第一枚旅程印章", systemImage: "book.closed",
                    description: Text("导入已保存的车票、截图、PDF 或 CSV，也可以补记一段旧旅程。\n确认已乘坐后，才会计入护照。"))
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else if filtered.isEmpty {
                Text("没有符合筛选条件的记录。").foregroundStyle(.secondary).padding(.vertical)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filtered) { journey in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 3) {
                                Text(journey.date.prefix(4)).font(.system(.caption, design: .monospaced))
                                Text(journey.date.suffix(5)).font(.system(.title3, design: .monospaced).weight(.semibold))
                            }.foregroundStyle(Color.railwayAccent).frame(width: 66).padding(.vertical, 8)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(journey.from) → \(journey.to)").font(.headline).lineLimit(2)
                                Text([journey.train.isEmpty ? "车次未记" : journey.train,
                                      journey.departure, journey.source].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if !journey.note.isEmpty { Text(journey.note).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                                Button("查看乘车路线", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                                    routeJourney = journey
                                }.font(.caption).buttonStyle(.borderless)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 8) {
                                Text(journey.status.title).font(.caption2.weight(.medium))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(journey.status == .travelled ? Color.green.opacity(0.12) : Color.orange.opacity(0.12),
                                                in: Capsule())
                                Menu {
                                    Button("核对或编辑") { editing = journey }
                                    Button("查看乘车路线") { routeJourney = journey }
                                    Button("制成明信片") { model.makePostcard(journey) }
                                    Divider()
                                    Button("移除记录", role: .destructive) { passport.remove(journey) }
                                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                                .menuStyle(.borderlessButton).fixedSize()
                                .accessibilityLabel("管理 \(journey.date) \(journey.from) 至 \(journey.to)")
                            }
                        }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Label("个人记录保存在本机，可随时导出备份。", systemImage: "internaldrive").font(.caption)
                Text("12306 网站订单保存 30 日。符合条件的电子发票可在行程结束等情形后 180 天内开具；这不等于能恢复多年前的乘车历史。旧记录可来自已留存的票据、邮箱、报销资料和购票平台。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link("12306 订单说明", destination: URL(string: "https://kyfw.12306.cn/otn/view/train_order.html")!)
                    Link("电子发票说明", destination: URL(string: "https://kyfw.12306.cn/otn/view/invoice_index.html")!)
                }.font(.caption2)
            }.padding(14).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.json, .commaSeparatedText, .plainText, .pdf, .image],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                reading = true
                Task {
                    let result = await JourneyDocumentImport.read(urls)
                    batch = JourneyImportBatch(journeys: result.journeys, notes: result.notes)
                    reading = false
                }
            case .failure(let error): passport.error = error.localizedDescription
            }
        }
        .sheet(item: $batch) { batch in
            JourneyImportReviewView(batch: batch).environmentObject(passport)
        }
        .sheet(item: $editing) { journey in
            JourneyEditorView(journey: journey).environmentObject(passport).environmentObject(model)
        }
        .sheet(item: $routeJourney) { journey in
            PassengerRouteView(journey: journey).environmentObject(model)
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: exportType,
                      defaultFilename: exportName) { result in
            if case .failure(let error) = result { passport.error = error.localizedDescription }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("导入票据", systemImage: "square.and.arrow.down") { importing = true }.buttonStyle(.borderedProminent)
        Button("补记旅程", systemImage: "plus") { editing = RailJourney() }
        Menu("备份与模板") {
            Button("导出完整护照 JSON") {
                do {
                    exportFile = ExperienceFile(try RailJourneyArchive(journeys: passport.journeys).encode())
                    exportType = .json; exportName = "铁路护照"; exporting = true
                } catch { passport.error = error.localizedDescription }
            }
            Button("导出 CSV 空白模板") {
                exportFile = ExperienceFile(Data("date,train,from,to,departure,note\r\n".utf8))
                exportType = .commaSeparatedText; exportName = "乘车记录模板"; exporting = true
            }
        }
    }
    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value).font(.system(size: 30, weight: .medium, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color.railwayAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct JourneyFields: View {
    @Binding var journey: RailJourney
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow { Text("乘车日期"); TextField("YYYY-MM-DD", text: $journey.date) }
            GridRow { Text("车次"); TextField("可留空", text: $journey.train) }
            GridRow { Text("出发站"); TextField("车站名称", text: $journey.from) }
            GridRow { Text("到达站"); TextField("车站名称", text: $journey.to) }
            GridRow { Text("发车时间"); TextField("HH:mm，可留空", text: $journey.departure) }
            GridRow {
                Text("是否乘坐")
                Picker("是否乘坐", selection: $journey.status) {
                    ForEach(RailJourney.Status.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            GridRow { Text("备注"); TextField("可留空", text: $journey.note, axis: .vertical).lineLimit(2...4) }
        }.textFieldStyle(.roundedBorder).font(.subheadline)
            .onChange(of: journey.from) { _, _ in journey.updateBoardingTime() }
    }
}

struct JourneyEditorView: View {
    @EnvironmentObject private var passport: JourneyStore
    @EnvironmentObject private var model: ExperienceStore
    @Environment(\.dismiss) private var dismiss
    @State var journey: RailJourney
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("核对旅程").font(.title2.weight(.semibold))
            JourneyFields(journey: $journey)
            Text("购票、截图或发票不能单独证明已经乘坐，请自行核对。").font(.caption).foregroundStyle(.secondary)
            if let message = journey.validationMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            if let error = passport.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let train = try? model.timetable(for: journey) { journey.timetable = train }
                    if passport.save(journey) { dismiss() }
                }.buttonStyle(.borderedProminent)
                    .disabled(journey.validationMessage != nil || passport.readOnly).keyboardShortcut(.defaultAction)
            }
        }.padding(28)
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 500)
        #endif
    }
}

struct JourneyImportReviewView: View {
    @EnvironmentObject private var passport: JourneyStore
    @Environment(\.dismiss) private var dismiss
    let batch: JourneyImportBatch
    @State private var drafts: [RailJourney]
    @State private var selected: Set<UUID> = []
    @State private var duplicates: Set<UUID> = []
    @State private var initialized = false

    init(batch: JourneyImportBatch) {
        self.batch = batch
        // Normalize repeated file UUIDs before SwiftUI evaluates ForEach.
        var ids = Set<UUID>()
        let drafts = batch.journeys.map { input -> RailJourney in
            var item = input
            if !ids.insert(item.id).inserted { item.id = UUID(); ids.insert(item.id) }
            return item
        }
        _drafts = State(initialValue: drafts)
    }
    private var chosen: [RailJourney] { drafts.filter { selected.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入前核对").font(.title2.weight(.semibold))
            Text("识别结果先作为待核对记录；缺项可展开补全。重复候选默认不选，勾选后会保留为独立记录。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(batch.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach($drafts) { $journey in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("选入", isOn: Binding(get: { selected.contains(journey.id) }, set: { value in
                                if value { selected.insert(journey.id) } else { selected.remove(journey.id) }
                            })).labelsHidden().padding(.top, 3)
                            DisclosureGroup {
                                JourneyFields(journey: $journey).padding(.top, 14)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(journey.date.isEmpty ? "日期待补" : journey.date) · \(journey.train)")
                                        .font(.subheadline.weight(.medium))
                                    Text("\(journey.from.isEmpty ? "出发站待补" : journey.from) → \(journey.to.isEmpty ? "到达站待补" : journey.to)")
                                        .font(.subheadline)
                                    if duplicates.contains(journey.id) { Text("重复候选 · 默认跳过").font(.caption).foregroundStyle(.orange) }
                                    if let message = journey.validationMessage { Text(message).font(.caption).foregroundStyle(.orange) }
                                }
                            }
                        }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(minHeight: 180, idealHeight: 360, maxHeight: 500)
            if let error = passport.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("\(drafts.count) 条候选 · 已选 \(selected.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入所选") { if passport.importReviewed(chosen) { dismiss() } }.buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || chosen.contains { $0.validationMessage != nil } || passport.readOnly)
            }
        }.padding(24)
        #if os(macOS)
        .frame(minWidth: 530, idealWidth: 660)
        #endif
        .onAppear {
            guard !initialized else { return }; initialized = true
            var keys = Set(passport.journeys.map(\.duplicateKey))
            let knownIDs = Set(passport.journeys.map(\.id))
            for i in drafts.indices {
                let duplicateKey = !keys.insert(drafts[i].duplicateKey).inserted
                if duplicateKey || knownIDs.contains(drafts[i].id) { duplicates.insert(drafts[i].id) }
                else if drafts[i].validationMessage == nil { selected.insert(drafts[i].id) }
            }
        }
    }
}
