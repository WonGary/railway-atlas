import CoreText
import Foundation
import RailwayCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PostcardStyle: String, CaseIterable, Identifiable {
    case red, blue, map, paper, magnetic, voucher, night, inkMap
    case redReplica, blueReplica, voucherReplica
    case stockRed, stockBlue, stockReceipt

    var usesTicketStock: Bool { self == .stockRed || self == .stockBlue || self == .stockReceipt }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: "经典红票"
        case .blue: "磁介蓝票"
        case .map: "路线明信片"
        case .paper: "旧式红纸票"
        case .magnetic: "蓝色磁介票"
        case .voucher: "报销凭证纪念版"
        case .night: "夜行线路卡"
        case .inkMap: "黑白线路卡"
        case .redReplica: "国铁红票复刻样张"
        case .blueReplica: "国铁蓝票复刻样张"
        case .voucherReplica: "电子报销凭证复刻样张"
        case .stockRed: "红色纸票 · 参考票面"
        case .stockBlue: "蓝色磁介票 · 参考票面"
        case .stockReceipt: "历史纸质报销凭证 · 蓝票收藏版"
        }
    }
}

struct PostcardMapLayers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let provinceBoundaries = Self(rawValue: 1 << 0)
    static let nationalBoundaries = Self(rawValue: 1 << 1)
    static let majorCities = Self(rawValue: 1 << 2)
    static let allStations = Self(rawValue: 1 << 3)
    static let standard: Self = [.provinceBoundaries, .nationalBoundaries, .majorCities]

    var summary: String {
        if isEmpty { return "仅线路" }
        var values = ["线路"]
        if contains(.provinceBoundaries) { values.append("省界") }
        if contains(.nationalBoundaries) { values.append("国界") }
        if contains(.majorCities) { values.append("主要城市") }
        if contains(.allStations) { values.append("全站点") }
        return values.joined(separator: " · ")
    }
}

struct RailwayPostcardTicket: Equatable, Sendable {
    var ticketNumber = ""
    var passengerName = ""
    var identityNumber = ""
    var fare = ""
    var seatClass = "二等座"
    var coachNumber = "01"
    var seatNumber = "01A号"
    var date = ""
    var departureTime = ""
    var route = ""
    var originLatin = ""
    var destinationLatin = ""
    var checkNumber = ""
    var ticketMark = "成人"
    var serialNumber = ""
    var notice = "仅供收藏使用"
    var secondNotice = "铁路图鉴祝您旅途愉快"
    var issuer = ""

    mutating func randomizeNumbers() {
        ticketNumber = "R\(String(format: "%06d", Int.random(in: 0...999_999)))"
        serialNumber = "ATLAS-\(String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)))"
    }

    mutating func randomizePassenger() {
        passengerName = ["林", "陈", "许", "李", "周"].randomElement()! + ["小舟", "青禾", "晓宁", "文远"].randomElement()!
        identityNumber = "RA\(Int.random(in: 10...99))****\(String(format: "%04d", Int.random(in: 0...9_999)))"
    }

    static func forJourney(_ journey: RailJourney) -> Self {
        var value = Self()
        value.date = journey.date
        value.departureTime = journey.departure
        value.route = routeText(from: journey.from, to: journey.to)
        value.originLatin = TicketText.stationLatin(for: journey.from)
        value.destinationLatin = TicketText.stationLatin(for: journey.to)
        return value
    }

    static func randomSample(for journey: RailJourney) -> Self {
        var value = forJourney(journey)
        value.randomizeNumbers()
        value.randomizePassenger()
        value.fare = String(format: "%.2f", Double.random(in: 12...699))
        value.seatClass = ["二等座", "一等座", "软卧", "硬卧"].randomElement() ?? "二等座"
        value.coachNumber = String(format: "%02d", Int.random(in: 1...16))
        value.seatNumber = "\(String(format: "%02d", Int.random(in: 1...20)))\(["A", "B", "C", "D", "F"].randomElement() ?? "A")号"
        value.checkNumber = "\(Int.random(in: 1...9))A\(Int.random(in: 1...9))"
        value.ticketMark = ["成人", "学惠", "学生"].randomElement() ?? "成人"
        value.notice = "仅供收藏使用"
        return value
    }

    static func routeText(from: String, to: String) -> String {
        let start = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = to.trimmingCharacters(in: .whitespacesAndNewlines)
        if start.isEmpty && end.isEmpty { return "" }
        if start.isEmpty { return "出发站 → \(end)" }
        if end.isEmpty { return "\(start) → 到达站" }
        return "\(start) → \(end)"
    }
}

enum TicketTypography {
    static func chinese(_ style: PostcardStyle, size: Double) -> Font {
        let serif = [.red, .paper, .voucher, .redReplica, .voucherReplica].contains(style)
        let candidates = serif
            ? ["STSongti-SC-Bold", "STSongtiSC-Bold", "Songti SC"]
            : ["STHeitiSC-Medium", "STHeitiSC-Light", "Heiti SC", "PingFang SC"]
        return resolved(candidates, size: size, fallbackWeight: serif ? .semibold : .medium,
                        design: serif ? .serif : .default)
    }

    static func digits(_ size: Double) -> Font {
        resolved(["Menlo-Regular", "Menlo"], size: size, fallbackWeight: .regular, design: .monospaced)
    }

    static func latin(_ size: Double, weight: Font.Weight = .regular) -> Font {
        resolved(["HelveticaNeue", "Helvetica"], size: size, fallbackWeight: weight, design: .default)
    }

    private static func resolved(
        _ names: [String],
        size: Double,
        fallbackWeight: Font.Weight,
        design: Font.Design
    ) -> Font {
        for name in names {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            if String(CTFontCopyPostScriptName(font)) == name {
                return .custom(name, fixedSize: size)
            }
        }
        return .system(size: size, weight: fallbackWeight, design: design)
    }
}

enum TicketText {
    static func stationLatin(for station: String) -> String {
        let clean = station.replacingOccurrences(of: "站", with: "")
        let known: [String: String] = [
            "北京": "Beijing", "上海": "Shanghai", "广州": "Guangzhou", "深圳": "Shenzhen",
            "天津": "Tianjin", "重庆": "Chongqing", "西安": "Xi'an", "成都": "Chengdu",
            "武汉": "Wuhan", "南京": "Nanjing", "杭州": "Hangzhou", "郑州": "Zhengzhou",
            "济南": "Jinan", "青岛": "Qingdao", "长沙": "Changsha", "昆明": "Kunming",
            "福州": "Fuzhou", "厦门": "Xiamen", "沈阳": "Shenyang", "长春": "Changchun",
            "哈尔滨": "Harbin", "太原": "Taiyuan", "南昌": "Nanchang", "合肥": "Hefei",
            "贵阳": "Guiyang", "兰州": "Lanzhou", "乌鲁木齐": "Urumqi", "香港西九龙": "Hong Kong",
            "澳门": "Macao", "苏州": "Suzhou", "宁波": "Ningbo", "石家庄": "Shijiazhuang"
        ]
        if let value = known[clean] {
            return value
        }
        let transliterated = clean
            .applyingTransform(.toLatin, reverse: false)?
            .folding(options: .diacriticInsensitive, locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return transliterated?.isEmpty == false ? transliterated! : "Station"
    }

    static func displayed(_ value: String, placeholder: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? placeholder : clean
    }

    static func maskedIdentityNumber(_ value: String, placeholder: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return placeholder }

        let characters = clean.filter { !$0.isWhitespace && $0 != "-" }
        guard characters.count > 4 else {
            return String(repeating: "*", count: characters.count)
        }

        return String(characters.prefix(characters.count >= 12 ? 4 : 1)) + "****"
            + String(characters.suffix(characters.count >= 12 ? 4 : 2))
    }
}

struct RailwayPostcardView: View {
    @EnvironmentObject private var model: ExperienceStore
    @EnvironmentObject private var passport: JourneyStore

    private var style: PostcardStyle { model.postcardStyle }
    private var journey: RailJourney { model.postcardDraft }
    private var caption: String { model.postcardCaption }

    @State private var exporting = false
    @State private var format = PostcardOutput.png
    @State private var shareURL: URL?
    @State private var shareCode: CGImage?
    @State private var shareKey = ""
    @State private var printShareCode = false
    @State private var output = PostcardDocument(Data())
    @State private var error: String?
    @State private var route: RailTrackJourney?
    @State private var loadedKey = ""
    @State private var preparing = false
    @State private var retry = 0
    @State private var ticket = RailwayPostcardTicket()
    @State private var ticketSeedKey = ""
    @State private var mapLayers = PostcardMapLayers.standard

    private var routeKey: String {
        journey.duplicateKey
            + (journey.timetable?.id ?? "")
            + (journey.timetable?.routing?.providerID ?? "")
    }

    private var currentRoute: RailTrackJourney? {
        loadedKey == routeKey ? route : nil
    }

    private var canExport: Bool {
        currentRoute != nil || (style == .stockReceipt && [journey.train, journey.date, journey.from, journey.to]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private var ticketCode: CGImage? { printShareCode && shareKey == routeKey ? shareCode : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TimetableLibraryPanel(library: model.library) {
                    model.postcardDraft = $0.draftJourney
                }

                HStack(alignment: .center, spacing: 12) {
                    Picker("样式", selection: $model.postcardStyle) {
                        ForEach(PostcardStyle.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 330)

                    Menu("路线图层", systemImage: "square.3.layers.3d") {
                        Toggle("省界", isOn: layerBinding(.provinceBoundaries))
                        Toggle("国界", isOn: layerBinding(.nationalBoundaries))
                        Toggle("主要城市", isOn: layerBinding(.majorCities))
                        Toggle("全站点", isOn: layerBinding(.allStations))
                        Divider()
                        Button("恢复标准图层") { mapLayers = .standard }
                        Button("仅显示线路") { mapLayers = [] }
                    }
                    .help("当前图层：\(mapLayers.summary)")

                    Text(mapLayers.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 12)

                    Button("随机生成样张", systemImage: "dice") {
                        ticket = .randomSample(for: journey)
                    }
                    .buttonStyle(.bordered)

                    Menu("导出", systemImage: "square.and.arrow.up") {
                        ForEach(PostcardOutput.allCases, id:\.self) { item in
                            Button(item.title) { export(item) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canExport)
                }

                GeometryReader { proxy in
                    TicketPostcardArt(
                        style: style,
                        journey: journey,
                        caption: caption,
                        legs: currentRoute?.legs,
                        stations: currentRoute?.stations ?? [],
                        ticket: ticket,
                        mapLayers: mapLayers,
                        shareCode: ticketCode
                    )
                    .frame(width: 760, height: 440)
                    .scaleEffect(min(proxy.size.width / 760, 1), anchor: .topLeading)
                }
                .frame(maxWidth: 900)
                .aspectRatio(760.0 / 440, contentMode: .fit)
                .accessibilityIdentifier("postcard-preview")

                HStack {
                    Button("生成区间分享码", systemImage:"qrcode") {
                        let key = routeKey, draft = journey
                        Task {
                            do {
                                let url = try await PostcardRouteShare.url(draft)
                                guard key == routeKey else { return }
                                shareCode = PostcardRouteShare.qr(url)
                                shareURL = url
                                shareKey = key
                                error = nil
                            } catch { if key == routeKey { self.error = error.localizedDescription } }
                        }
                    }.disabled(currentRoute == nil)
                    if shareKey == routeKey, let shareURL, let shareCode {
                        Image(decorative:shareCode, scale:1).interpolation(.none).resizable().frame(width:120,height:120)
                        ShareLink("分享公开车次区间", item:shareURL)
                        if style.usesTicketStock {
                            Toggle("印在票面上", isOn: $printShareCode)
                        }
                        Button("保存分享码") {
                            do { format = .png; output = PostcardDocument(try format.encode(shareCode)); exporting = true }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }

                HStack {
                    Menu("使用护照中的旅程") {
                        ForEach(passport.journeys.prefix(100)) { item in
                            Button("\(item.date) \(item.from) → \(item.to)") {
                                model.postcardDraft = item
                            }
                        }
                    }
                    .disabled(passport.journeys.isEmpty)

                    Button("按乘车记录同步票面") {
                        synchronizeTicket()
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button("重新匹配乘车路线", systemImage: "arrow.clockwise") {
                        retry += 1
                    }
                    .disabled(preparing)
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        Text("出发站")
                        TextField("出发站", text: $model.postcardDraft.from)
                        Text("到达站")
                        TextField("到达站", text: $model.postcardDraft.to)
                    }
                    GridRow {
                        Text("车次")
                        TextField("车次", text: $model.postcardDraft.train)
                        Text("乘车日期")
                        TextField("YYYY-MM-DD", text: $model.postcardDraft.date)
                    }
                    GridRow {
                        Text("发车")
                        TextField("HH:mm", text: $model.postcardDraft.departure)
                        Text("寄语")
                        TextField("写一句旅途寄语", text: $model.postcardCaption)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)

                PostcardTicketEditor(ticket: $ticket)

                if preparing {
                    ProgressView("正在匹配并截取乘车区间…")
                        .font(.caption)
                }

                if let route = currentRoute {
                    Text("实际乘车区间 \(journey.from) → \(journey.to) · \(Int(route.distance / 1000)) km 地图轨道 · \(route.stations.count) 个经停站")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if style == .stockReceipt && canExport {
                    Text("可按手填行程导出收藏票。路线图和区间分享码需要匹配铁路径路。").font(.caption).foregroundStyle(.secondary)
                }

                Text("分享码打开所选乘车区间。姓名、票号、证件号和备注留在本机。纪念票不可乘车或报销。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("打印时选择 100% 比例。票据 PDF 为 85.6 × 54 毫米，A4 版将票面放在纸张中央。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(24)
        }
        .onChange(of: journey.from) { _, _ in
            model.postcardDraft.updateBoardingTime()
        }
        .task(id: routeKey + "/\(retry)") {
            let key = routeKey
            let draft = journey
            if ticketSeedKey != key {
                synchronizeTicket()
                shareCode = nil
                shareURL = nil
                shareKey = ""
                printShareCode = false
                ticketSeedKey = key
            }
            route = nil
            loadedKey = ""
            error = nil
            preparing = true
            do {
                try await Task.sleep(for: .milliseconds(100))
                let result = try await model.passengerRoute(draft, retryMissing: retry > 0)
                try Task.checkCancellation()
                route = result
                loadedKey = key
                preparing = false
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                    preparing = false
                }
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: output,
            contentType: format.type,
            defaultFilename: "铁道漫游-\(style.title)"
        ) { result in
            if case .failure(let error) = result {
                self.error = error.localizedDescription
            }
        }
    }

    private func layerBinding(_ layer: PostcardMapLayers) -> Binding<Bool> {
        Binding(
            get: { mapLayers.contains(layer) },
            set: { enabled in
                if enabled {
                    mapLayers.insert(layer)
                } else {
                    mapLayers.remove(layer)
                }
            }
        )
    }

    private func synchronizeTicket() {
        ticket.date = journey.date
        ticket.departureTime = journey.departure
        ticket.route = RailwayPostcardTicket.routeText(from: journey.from, to: journey.to)
        ticket.originLatin = TicketText.stationLatin(for: journey.from)
        ticket.destinationLatin = TicketText.stationLatin(for: journey.to)
    }

    private func export(_ selected: PostcardOutput) {
        guard canExport else {
            error = "请先完成实际乘车区间匹配"
            return
        }

        let renderer = ImageRenderer(
            content: TicketPostcardArt(
                style: style,
                journey: journey,
                caption: caption,
                legs: currentRoute?.legs,
                stations: currentRoute?.stations ?? [],
                ticket: ticket,
                mapLayers: mapLayers,
                shareCode: ticketCode
            )
            .frame(width: 760, height: 440)
            .environment(\.colorScheme, .light)
        )
        renderer.scale = 2

        guard let cgImage = renderer.cgImage else {
            error = "图片生成失败"
            return
        }

        do {
            let stock = style.usesTicketStock
            let w = Int((Double(cgImage.height) * 85.6 / 54).rounded())
            let crop = CGRect(x:(cgImage.width-w)/2,y:0,width:w,height:cgImage.height)
            let image = stock ? (cgImage.cropping(to:crop) ?? cgImage) : cgImage
            output = PostcardDocument(try selected.encode(image))
            format = selected
            error = nil
            exporting = true
        } catch { self.error = error.localizedDescription }
    }
}

struct PostcardTicketEditor: View {
    @Binding var ticket: RailwayPostcardTicket

    var body: some View {
        DisclosureGroup("票面字段") {
            HStack {
                Button("随机上下票号") { ticket.randomizeNumbers() }
                Button("随机乘车人和证件") { ticket.randomizePassenger() }
            }.buttonStyle(.bordered)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("票号（样张）")
                    TextField("A000000", text: $ticket.ticketNumber)
                    Text("乘车人姓名")
                    TextField("可留空或自行填写", text: $ticket.passengerName)
                }
                GridRow {
                    Text("证件号（样张）")
                    TextField("SAMPLE-ID-0000", text: $ticket.identityNumber)
                    Text("票价")
                    TextField("699.00", text: $ticket.fare)
                }
                GridRow {
                    Text("席别")
                    TextField("二等座", text: $ticket.seatClass)
                    Text("票面标记")
                    TextField("成人 / 学惠", text: $ticket.ticketMark)
                }
                GridRow {
                    Text("车厢号")
                    TextField("01", text: $ticket.coachNumber)
                    Text("席位号")
                    TextField("01A号", text: $ticket.seatNumber)
                }
                GridRow {
                    Text("票面日期")
                    TextField("YYYY-MM-DD", text: $ticket.date)
                    Text("票面时间")
                    TextField("HH:mm", text: $ticket.departureTime)
                }
                GridRow {
                    Text("出发站拼音")
                    TextField("Beijing", text: $ticket.originLatin)
                    Text("到达站拼音")
                    TextField("Shanghai", text: $ticket.destinationLatin)
                }
                GridRow {
                    Text("票面径路")
                    TextField("出发站 → 到达站", text: $ticket.route)
                    Text("检票信息")
                    TextField("1A2A", text: $ticket.checkNumber)
                }
                GridRow {
                    Text("底部样张流水号")
                    TextField("ATLAS-SAMPLE", text: $ticket.serialNumber)
                    Text("提示文字")
                    TextField("仅供收藏使用", text: $ticket.notice)
                }
                GridRow {
                    Text("第二行说明")
                    TextField("铁路图鉴祝您旅途愉快", text: $ticket.secondNotice)
                    Text("发售处")
                    TextField("车站或收藏地", text: $ticket.issuer)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.subheadline)

            Text("票面字段仅用于本机制作。建议直接填写脱敏证件号。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .font(.subheadline)
    }
}

struct TicketPostcardArt: View {
    let style: PostcardStyle
    let journey: RailJourney
    let caption: String
    let legs: [[Coordinate]]?
    var stations: [String] = []
    let ticket: RailwayPostcardTicket
    let mapLayers: PostcardMapLayers
    let shareCode: CGImage?

    init(
        style: PostcardStyle,
        journey: RailJourney,
        caption: String,
        legs: [[Coordinate]]?,
        stations: [String] = [],
        ticket: RailwayPostcardTicket? = nil,
        mapLayers: PostcardMapLayers = .standard,
        shareCode: CGImage? = nil
    ) {
        self.style = style
        self.journey = journey
        self.caption = caption
        self.legs = legs
        self.stations = stations
        self.ticket = ticket ?? .forJourney(journey)
        self.mapLayers = mapLayers
        self.shareCode = shareCode
    }

    private func routeMap(
        _ legs: [[Coordinate]],
        ink: Color,
        paper: Color,
        layers: PostcardMapLayers? = nil
    ) -> some View {
        PostcardRouteMap(
            legs: legs,
            from: journey.from,
            to: journey.to,
            ink: ink,
            paper: paper,
            stations: stations,
            layers: layers ?? mapLayers
        )
    }

    private var red: Bool {
        [.red, .paper, .redReplica, .voucherReplica].contains(style)
    }

    private var ink: Color {
        red
            ? Color(red: 0.23, green: 0.13, blue: 0.13)
            : Color(red: 0.09, green: 0.19, blue: 0.27)
    }

    private var accent: Color {
        red
            ? Color(red: 0.66, green: 0.18, blue: 0.22)
            : Color(red: 0.12, green: 0.38, blue: 0.57)
    }

    private var paper: Color {
        red
            ? Color(red: 0.98, green: 0.83, blue: 0.79)
            : Color(red: 0.77, green: 0.88, blue: 0.94)
    }

    var body: some View {
        Group {
            switch style {
            case .stockBlue, .stockRed, .stockReceipt:
                ReferenceTicketFace(blue:style != .stockRed, receipt:style == .stockReceipt,
                                    ticket:ticket, journey:journey, shareCode:shareCode)
            case .redReplica:
                replicaTicket(theme: .red)
            case .blueReplica:
                replicaTicket(theme: .blue)
            case .voucherReplica:
                reimbursementVoucher
            case .map, .night, .inkMap:
                mapCard
            case .paper, .magnetic, .voucher:
                keepsakeTicket
            case .red, .blue:
                classicTicket
            }
        }
        .frame(width: 760, height: 440)
        .clipped()
        .overlay {
            if !style.usesTicketStock {
                TicketSampleWatermark(dark: style == .night || style == .inkMap)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func replicaTicket(theme: TicketReplicaTheme) -> some View {
        ZStack {
            theme.paper
            TicketPaperTexture(color: theme.accent)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(TicketText.displayed(ticket.ticketNumber, placeholder: "A000000"))
                        .font(TicketTypography.digits(25))
                        .foregroundStyle(theme.ticketNumber)
                    Spacer()
                    Text("检票：\(TicketText.displayed(ticket.checkNumber, placeholder: "样张"))")
                        .font(TicketTypography.chinese(.blue, size: 17))
                        .foregroundStyle(theme.ink)
                }

                HStack(alignment: .bottom, spacing: 14) {
                    officialStation(
                        journey.from,
                        latin: ticket.originLatin,
                        theme: theme,
                        alignment: .leading
                    )
                    VStack(spacing: 3) {
                        Text(TicketText.displayed(journey.train, placeholder: "车次"))
                            .font(TicketTypography.digits(31))
                            .foregroundStyle(theme.ink)
                            .underline()
                        Text("次")
                            .font(TicketTypography.chinese(.blue, size: 13))
                            .foregroundStyle(theme.ink)
                    }
                    .frame(width: 125)
                    officialStation(
                        journey.to,
                        latin: ticket.destinationLatin,
                        theme: theme,
                        alignment: .trailing
                    )
                }
                .padding(.top, 10)

                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(TicketText.displayed(ticket.date, placeholder: "日期待填"))
                    Text(TicketText.displayed(ticket.departureTime, placeholder: "时间待填") + " 开")
                    Spacer()
                    Text(TicketText.displayed(ticket.fare, placeholder: "0.00") + " 元")
                }
                .font(TicketTypography.digits(21))
                .foregroundStyle(theme.ink)
                .padding(.top, 12)

                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(TicketText.displayed(ticket.ticketMark, placeholder: "成人"))
                    Text(TicketText.displayed(ticket.seatClass, placeholder: "二等座"))
                    Text("\(TicketText.displayed(ticket.coachNumber, placeholder: "01"))车")
                    Text(TicketText.displayed(ticket.seatNumber, placeholder: "01A号"))
                    Spacer()
                }
                .font(TicketTypography.chinese(.blue, size: 18))
                .foregroundStyle(theme.ink)
                .padding(.top, 5)

                Rectangle()
                    .fill(theme.accent.opacity(0.34))
                    .frame(height: 1)
                    .padding(.top, 13)

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(TicketText.displayed(ticket.notice, placeholder: "仅供收藏使用"))
                            .font(TicketTypography.chinese(.red, size: 17))
                        Text("\(TicketText.maskedIdentityNumber(ticket.identityNumber, placeholder: "SAMPLE-ID-0000"))  \(TicketText.displayed(ticket.passengerName, placeholder: "乘车人待填"))")
                            .font(TicketTypography.digits(15))
                            .lineLimit(1)
                        Text("票面径路　\(TicketText.displayed(ticket.route, placeholder: "出发站 → 到达站"))")
                            .font(TicketTypography.chinese(.blue, size: 14))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    DecorativeTicketCode(tint: theme.accent)
                        .frame(width: 74, height: 74)
                }
                .padding(.top, 10)

                if let legs {
                    routeMap(legs, ink: theme.ink, paper: theme.paper)
                        .frame(height: 66)
                        .padding(.top, 4)
                }

                Spacer(minLength: 2)

                HStack {
                    Text("铁路旅客车票纪念样张")
                    Spacer()
                    Text(TicketText.displayed(ticket.serialNumber, placeholder: "ATLAS-SAMPLE"))
                        .font(TicketTypography.digits(11))
                }
                .font(TicketTypography.chinese(.blue, size: 12))
                .foregroundStyle(theme.ink.opacity(0.72))
            }
            .padding(.horizontal, 31)
            .padding(.vertical, 20)
        }
        .overlay(Rectangle().stroke(theme.accent.opacity(0.72), lineWidth: 1.4))
        .foregroundStyle(theme.ink)
    }

    private func officialStation(
        _ value: String,
        latin: String,
        theme: TicketReplicaTheme,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(TicketText.displayed(value, placeholder: "车站"))
                .font(TicketTypography.chinese(.blue, size: 37))
                .lineLimit(1)
                .minimumScaleFactor(0.45)
            Text(TicketText.displayed(latin, placeholder: "Station"))
                .font(TicketTypography.latin(13))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    private var reimbursementVoucher: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.88, green: 0.97, blue: 0.98),
                    Color(red: 0.72, green: 0.91, blue: 0.93)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            TicketPaperTexture(color: Color(red: 0.1, green: 0.48, blue: 0.55))

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(TicketText.displayed(ticket.ticketNumber, placeholder: "A000000"))
                        .font(TicketTypography.digits(22))
                        .foregroundStyle(.red)
                    Spacer()
                    Text("铁路电子客票")
                        .font(TicketTypography.chinese(.voucherReplica, size: 24))
                        .foregroundStyle(.black)
                    Spacer()
                    Text("票面：\(TicketText.displayed(ticket.checkNumber, placeholder: "样张"))")
                        .font(TicketTypography.digits(15))
                        .foregroundStyle(.black)
                }

                HStack(alignment: .bottom, spacing: 14) {
                    voucherStation(journey.from, latin: ticket.originLatin)
                    VStack(spacing: 1) {
                        Text(TicketText.displayed(journey.train, placeholder: "车次"))
                            .font(TicketTypography.digits(30))
                            .underline()
                        Text("次")
                            .font(TicketTypography.chinese(.blue, size: 13))
                    }
                    .frame(width: 116)
                    voucherStation(journey.to, latin: ticket.destinationLatin)
                }
                .padding(.top, 7)

                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(TicketText.displayed(ticket.date, placeholder: "日期待填"))
                    Text(TicketText.displayed(ticket.departureTime, placeholder: "时间待填") + " 开")
                    Spacer()
                    Text("¥\(TicketText.displayed(ticket.fare, placeholder: "0.00"))")
                }
                .font(TicketTypography.digits(20))
                .padding(.top, 9)

                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(TicketText.displayed(ticket.ticketMark, placeholder: "成人"))
                    Text(TicketText.displayed(ticket.seatClass, placeholder: "二等座"))
                    Text("\(TicketText.displayed(ticket.coachNumber, placeholder: "01"))车")
                    Text(TicketText.displayed(ticket.seatNumber, placeholder: "01A号"))
                    Spacer()
                }
                .font(TicketTypography.chinese(.blue, size: 17))
                .padding(.top, 4)

                HStack(alignment: .top, spacing: 15) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(TicketText.displayed(ticket.notice, placeholder: "仅供收藏使用"))
                            .font(TicketTypography.chinese(.red, size: 20))
                            .foregroundStyle(.black)
                        Text("\(TicketText.maskedIdentityNumber(ticket.identityNumber, placeholder: "SAMPLE-ID-0000"))  \(TicketText.displayed(ticket.passengerName, placeholder: "乘车人待填"))")
                            .font(TicketTypography.digits(14))
                            .lineLimit(1)
                        Text("实际乘车区间　\(TicketText.displayed(ticket.route, placeholder: "出发站 → 到达站"))")
                            .font(TicketTypography.chinese(.blue, size: 14))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    DecorativeTicketCode(tint: Color(red: 0.03, green: 0.22, blue: 0.25))
                        .frame(width: 78, height: 78)
                }
                .padding(.top, 10)

                HStack {
                    Text("纪念样张　不可报销或乘车")
                    Spacer()
                    Text(TicketText.displayed(ticket.serialNumber, placeholder: "ATLAS-SAMPLE"))
                        .font(TicketTypography.digits(11))
                }
                .font(TicketTypography.chinese(.voucherReplica, size: 13))
                .padding(.top, 8)

                if let legs {
                    routeMap(
                        legs,
                        ink: Color(red: 0.04, green: 0.28, blue: 0.31),
                        paper: Color(red: 0.88, green: 0.97, blue: 0.98)
                    )
                    .frame(height: 48)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 19)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(red: 0.05, green: 0.42, blue: 0.46).opacity(0.72), lineWidth: 1.2)
        )
        .foregroundStyle(.black)
    }

    private func voucherStation(_ value: String, latin: String) -> some View {
        VStack(spacing: 0) {
            Text(TicketText.displayed(value, placeholder: "车站"))
                .font(TicketTypography.chinese(.voucherReplica, size: 35))
                .lineLimit(1)
                .minimumScaleFactor(0.42)
            Text(TicketText.displayed(latin, placeholder: "Station"))
                .font(TicketTypography.latin(12))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private var keepsakeTicket: some View {
        ZStack {
            LinearGradient(
                colors: [paper, .white.opacity(0.8), paper],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            TicketPaperTexture(color: accent)

            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text(style == .voucher ? "铁路电子客票 · 报销凭证纪念版" : "铁路旅客车票")
                        .font(TicketTypography.chinese(style, size: 22))
                    Spacer()
                    Text("留　念")
                        .font(TicketTypography.chinese(style, size: 18))
                        .foregroundStyle(accent)
                }

                HStack {
                    Text(TicketText.displayed(journey.from, placeholder: "出发站"))
                        .font(TicketTypography.chinese(style, size: 35))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    VStack(spacing: 2) {
                        Text(TicketText.displayed(journey.train, placeholder: "车次"))
                            .font(TicketTypography.digits(24))
                        Text("⟶")
                    }
                    .frame(width: 110)
                    Text(TicketText.displayed(journey.to, placeholder: "到达站"))
                        .font(TicketTypography.chinese(style, size: 35))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }

                HStack(spacing: 18) {
                    Text(TicketText.displayed(ticket.date, placeholder: "日期待填"))
                    Text(TicketText.displayed(ticket.departureTime, placeholder: "时间待填") + " 开")
                    Text("¥\(TicketText.displayed(ticket.fare, placeholder: "0.00"))")
                    Spacer()
                    Text(TicketText.displayed(ticket.seatClass, placeholder: "二等座"))
                }
                .font(TicketTypography.digits(17))

                Divider()

                HStack(alignment: .top, spacing: 14) {
                    if let legs {
                        routeMap(legs, ink: accent, paper: paper)
                            .frame(width: 205, height: 88)
                    } else {
                        Text("乘车路线待匹配")
                            .font(TicketTypography.chinese(style, size: 15))
                            .frame(width: 205, height: 88)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(caption.isEmpty ? "一路山河，一程记忆。" : String(caption.prefix(100)))
                            .font(TicketTypography.chinese(style, size: 18))
                            .lineLimit(2)
                        Text("\(TicketText.displayed(ticket.passengerName, placeholder: "旅客姓名待填")) · \(TicketText.displayed(ticket.coachNumber, placeholder: "01"))车 \(TicketText.displayed(ticket.seatNumber, placeholder: "01A号"))")
                            .font(TicketTypography.chinese(style, size: 13))
                            .lineLimit(1)
                        Text(TicketText.displayed(ticket.route, placeholder: "出发站 → 到达站"))
                            .font(TicketTypography.chinese(style, size: 13))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                HStack {
                    Text("旅行纪念　不可报销或乘车")
                    Spacer()
                    Text(TicketText.displayed(ticket.serialNumber, placeholder: "ATLAS-SAMPLE"))
                        .font(TicketTypography.digits(10))
                }
                .font(.system(size: 11))
                .foregroundStyle(ink.opacity(0.68))
            }
            .padding(.horizontal, 38)
            .padding(.vertical, 25)
        }
        .foregroundStyle(ink)
    }

    private var classicTicket: some View {
        ZStack {
            paper
            TicketPaperTexture(color: accent, opacity: 0.48)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("RAILWAY ATLAS")
                        .font(TicketTypography.digits(15))
                        .tracking(2)
                        .foregroundStyle(accent)
                    Spacer()
                    Text("铁 道 漫 游")
                        .font(TicketTypography.chinese(style, size: 17))
                        .foregroundStyle(accent)
                }

                HStack(spacing: 16) {
                    station(journey.from.isEmpty ? "出发站" : journey.from)
                    VStack(spacing: 7) {
                        Text(journey.train.isEmpty ? "车次" : String(journey.train.prefix(20)))
                            .font(TicketTypography.digits(24))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 30, weight: .light))
                    }
                    .frame(width: 140)
                    station(journey.to.isEmpty ? "到达站" : journey.to)
                }
                .padding(.top, 34)

                HStack(spacing: 18) {
                    Text(TicketText.displayed(ticket.date, placeholder: "日期待填写"))
                    Text(TicketText.displayed(ticket.departureTime, placeholder: "时间待填写") + " 开")
                    Text("¥\(TicketText.displayed(ticket.fare, placeholder: "0.00"))")
                    Spacer()
                    Text(TicketText.displayed(ticket.seatClass, placeholder: "二等座"))
                        .font(TicketTypography.chinese(style, size: 18))
                }
                .font(TicketTypography.digits(17))
                .padding(.top, 22)

                Rectangle()
                    .fill(accent.opacity(0.25))
                    .frame(height: 1)
                    .padding(.top, 16)

                HStack(spacing: 20) {
                    if let legs {
                        routeMap(legs, ink: accent, paper: paper)
                            .frame(width: 178, height: 116)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(caption.isEmpty ? "一路山河，一程记忆。" : String(caption.prefix(100)))
                            .font(TicketTypography.chinese(style, size: 19))
                            .lineLimit(2)
                        Text("\(TicketText.displayed(ticket.passengerName, placeholder: "旅客姓名待填")) · \(TicketText.displayed(ticket.coachNumber, placeholder: "01"))车 \(TicketText.displayed(ticket.seatNumber, placeholder: "01A号"))")
                            .font(TicketTypography.chinese(style, size: 13))
                            .lineLimit(1)
                        Text(TicketText.displayed(ticket.route, placeholder: "乘车区间待填"))
                            .font(TicketTypography.chinese(style, size: 13))
                            .lineLimit(2)
                        Text(legs == nil ? "乘车路线待匹配" : "实际乘车径路 · \(CardGeography.credit)")
                            .font(.system(size: 10))
                            .foregroundStyle(ink.opacity(0.65))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 1) {
                        ForEach(["旅", "行", "纪", "念"], id: \.self) { glyph in
                            Text(glyph)
                                .font(TicketTypography.chinese(style, size: 15))
                                .fixedSize()
                                .frame(width: 22, height: 18)
                        }
                    }
                    .padding(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(accent.opacity(0.7), lineWidth: 1.4)
                    )
                    .foregroundStyle(accent)
                    .rotationEffect(.degrees(-6))
                }
                .padding(.top, 4)

                Spacer(minLength: 8)

                HStack {
                    Text("纪念设计 · 非乘车凭证")
                    Spacer()
                    Text(TicketText.displayed(ticket.serialNumber, placeholder: "ATLAS-SAMPLE"))
                        .font(TicketTypography.digits(10))
                        .tracking(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(ink.opacity(0.6))
            }
            .padding(30)
            .foregroundStyle(ink)
        }
        .overlay(Rectangle().stroke(accent.opacity(0.25), lineWidth: 1))
    }

    private func station(_ text: String) -> some View {
        Text(String(text.prefix(40)))
            .font(TicketTypography.chinese(style, size: 40))
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .frame(maxWidth: .infinity)
    }

    private var mapCard: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                style == .night
                    ? Color(red: 0.07, green: 0.14, blue: 0.24)
                    : style == .inkMap
                        ? Color(white: 0.18)
                        : Color(red: 0.07, green: 0.19, blue: 0.21)

                if let legs {
                    routeMap(
                        legs,
                        ink: style == .night ? .yellow : .white,
                        paper: Color(white: 0.15)
                    )
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                    .padding(.bottom, 91)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(journey.train.isEmpty ? "乘车路线" : journey.train)
                        .font(TicketTypography.chinese(.blue, size: 34))
                    Text(legs == nil ? "路线待匹配" : "乘车 ━　国界 ━·━　省界 ···")
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .padding(26)
            }
            .frame(width: 365)

            VStack(alignment: .leading, spacing: 17) {
                Text("POSTCARD / 铁道漫游")
                    .font(TicketTypography.digits(12))
                    .foregroundStyle(accent)
                Text("\(journey.from.isEmpty ? "出发站" : String(journey.from.prefix(40)))\n↓\n\(journey.to.isEmpty ? "到达站" : String(journey.to.prefix(40)))")
                    .font(TicketTypography.chinese(.red, size: 30))
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
                Text([
                    ticket.date,
                    journey.train,
                    ticket.departureTime,
                    ticket.seatClass
                ]
                .filter { !$0.isEmpty }
                .joined(separator: " · "))
                .font(TicketTypography.digits(13))
                .foregroundStyle(ink.opacity(0.7))
                Divider()
                Text(String(caption.prefix(100)))
                    .font(TicketTypography.chinese(.red, size: 20))
                    .lineLimit(3)
                Text(TicketText.displayed(ticket.route, placeholder: "出发站 → 到达站"))
                    .font(TicketTypography.chinese(.red, size: 13))
                    .lineLimit(2)
                Spacer()
                Text("\(CardGeography.credit)\n实际径路 · 非乘车凭证\n\(TicketText.displayed(ticket.serialNumber, placeholder: "ATLAS-SAMPLE"))")
                    .font(.system(size: 10))
                    .foregroundStyle(ink.opacity(0.6))
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(red: 0.98, green: 0.96, blue: 0.91))
        .foregroundStyle(ink)
    }
}

private enum TicketReplicaTheme {
    case red
    case blue

    var paper: Color {
        switch self {
        case .red:
            Color(red: 0.98, green: 0.89, blue: 0.86)
        case .blue:
            Color(red: 0.79, green: 0.92, blue: 0.95)
        }
    }

    var accent: Color {
        switch self {
        case .red:
            Color(red: 0.72, green: 0.13, blue: 0.16)
        case .blue:
            Color(red: 0.04, green: 0.42, blue: 0.55)
        }
    }

    var ink: Color {
        switch self {
        case .red:
            Color(red: 0.16, green: 0.07, blue: 0.07)
        case .blue:
            Color(red: 0.03, green: 0.15, blue: 0.20)
        }
    }

    var ticketNumber: Color {
        switch self {
        case .red:
            .red
        case .blue:
            Color(red: 0.06, green: 0.32, blue: 0.44)
        }
    }
}

private struct TicketPaperTexture: View {
    let color: Color
    var opacity: Double = 0.13

    var body: some View {
        Canvas { context, size in
            for row in 0..<44 {
                var path = Path()
                for x in stride(from: 0, through: Int(size.width), by: 4) {
                    let y = Double(row) * 10
                        + sin(Double(x) / 26 + Double(row) / 3) * 5
                    let point = CGPoint(x: CGFloat(x), y: y)
                    if x == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: 0.6)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct DecorativeTicketCode: View {
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(0.62))
            Canvas { context, size in
                let columns = 13
                let rows = 13
                let cell = min(size.width / CGFloat(columns), size.height / CGFloat(rows))
                for row in 0..<rows {
                    for column in 0..<columns {
                        let filled = ((row * 19 + column * 11 + row * column * 3) % 7) < 3
                        if filled {
                            let rect = CGRect(
                                x: CGFloat(column) * cell,
                                y: CGFloat(row) * cell,
                                width: cell * 0.75,
                                height: cell * 0.75
                            )
                            context.fill(Path(rect), with: .color(tint.opacity(0.85)))
                        }
                    }
                }
                var diagonal = Path()
                diagonal.move(to: CGPoint(x: 3, y: size.height - 3))
                diagonal.addLine(to: CGPoint(x: size.width - 3, y: 3))
                context.stroke(diagonal, with: .color(.white.opacity(0.9)), lineWidth: 2)
            }
            .padding(4)
            Text("非二维码")
                .font(TicketTypography.chinese(.blue, size: 8))
                .foregroundStyle(tint)
                .padding(2)
                .background(.white.opacity(0.82), in: Rectangle())
        }
        .overlay(Rectangle().stroke(tint.opacity(0.65), lineWidth: 1))
        .accessibilityLabel("不可识别的装饰码区域")
    }
}

private struct TicketSampleWatermark: View {
    let dark: Bool

    var body: some View {
        Text("纪念样张 · 不可乘车或报销")
            .font(TicketTypography.chinese(.voucherReplica, size: 27))
            .foregroundStyle((dark ? Color.white : Color.red).opacity(dark ? 0.23 : 0.18))
            .rotationEffect(.degrees(-17))
            .allowsHitTesting(false)
    }
}

private struct PostcardRouteMap: View {
    let legs: [[Coordinate]]
    let from: String
    let to: String
    let ink: Color
    let paper: Color
    let stations: [String]
    let layers: PostcardMapLayers

    var body: some View {
        Canvas { context, size in
            guard let first = legs.first?.first, let last = legs.last?.last else { return }
            let points = legs.flatMap { $0 }
            guard !points.isEmpty else { return }

            let bounds = MapBounds(points: points)
            let center = bounds.center
            let cosine = max(0.1, cos(center.latitude * .pi / 180))
            let horizontalSpan = max(0.012, (bounds.east - bounds.west) * cosine)
            let verticalSpan = max(0.012, bounds.north - bounds.south)
            let scale = min(
                max(1, size.width) / horizontalSpan,
                max(1, size.height) / verticalSpan
            ) * 0.80
            guard scale.isFinite, scale > 0 else { return }

            func project(_ latitude: Double, _ longitude: Double) -> CGPoint {
                CGPoint(
                    x: size.width / 2 + (longitude - center.longitude) * cosine * scale,
                    y: size.height / 2 - (latitude - center.latitude) * scale
                )
            }

            func linePath(_ parts: [[CGPoint]]) -> Path {
                Path { output in
                    for part in parts {
                        guard let first = part.first else { continue }
                        output.move(to: first)
                        for point in part.dropFirst() {
                            output.addLine(to: point)
                        }
                    }
                }
            }

            func contourPath(_ runs: [CardGeography.Contours.Run]) -> Path {
                let halfLatitude = size.height / (2 * scale)
                let halfLongitude = size.width / (2 * scale * cosine)
                return linePath(runs.compactMap { run in
                    let box = run.bounds
                    guard box.count == 4,
                          box[0] <= center.latitude + halfLatitude,
                          box[2] >= center.latitude - halfLatitude,
                          box[1] <= center.longitude + halfLongitude,
                          box[3] >= center.longitude - halfLongitude else {
                        return nil
                    }
                    return run.points.map { project($0[0], $0[1]) }
                })
            }

            let screen = CGRect(origin: .zero, size: size)
            context.clip(to: Path(screen))
            let geography = CardGeography.shared
            let contours = CardGeography.Contours.shared

            if layers.contains(.nationalBoundaries), let contours {
                let national = contours.settled + contours.undelimited
                context.stroke(
                    contourPath(national),
                    with: .color(ink.opacity(0.62)),
                    style: StrokeStyle(lineWidth: 0.8, dash: [4, 3])
                )
                context.stroke(
                    contourPath(contours.coastLines),
                    with: .color(ink.opacity(0.42)),
                    lineWidth: 0.75
                )
            }

            if layers.contains(.provinceBoundaries), let contours {
                context.stroke(
                    contourPath(contours.provinceLines),
                    with: .color(ink.opacity(0.43)),
                    style: StrokeStyle(lineWidth: 0.7, dash: [2.5, 2.5])
                )
            }

            let projectedLegs = legs.map { leg in
                leg.map { project($0.latitude, $0.longitude) }
            }
            let route = linePath(projectedLegs)
            context.stroke(
                route,
                with: .color(paper.opacity(0.92)),
                style: StrokeStyle(lineWidth: 5.2, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                route,
                with: .color(ink),
                style: StrokeStyle(lineWidth: 2.9, lineCap: .round, lineJoin: .round)
            )

            let firstPoint = project(first.latitude, first.longitude)
            let lastPoint = project(last.latitude, last.longitude)
            drawDot(context: context, at: firstPoint, radius: 3.2, fill: paper, stroke: ink)
            drawDot(context: context, at: lastPoint, radius: 3.2, fill: ink, stroke: paper)

            var occupied = [CGRect]()
            var labels = Set<String>()
            let fontSize = min(11.0, max(7.0, size.width / 22))

            func drawLabel(_ name: String, at point: CGPoint, font: CGFloat) {
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, labels.insert(clean).inserted else { return }
                let text = Text(verbatim: clean)
                    .font(.system(size: font, weight: .semibold))
                let resolved = context.resolve(text.foregroundStyle(ink))
                let measured = resolved.measure(in: size)
                let origin = CGPoint(
                    x: max(2, min(size.width - measured.width - 2, point.x + 6)),
                    y: max(1, min(size.height - measured.height - 1, point.y - measured.height / 2))
                )
                let rect = CGRect(origin: origin, size: measured)
                if occupied.contains(where: { $0.intersects(rect.insetBy(dx: -2, dy: -1)) }) {
                    labels.remove(clean)
                    return
                }
                occupied.append(rect)
                let halo = context.resolve(text.foregroundStyle(paper))
                for offset in [
                    CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1),
                    CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0)
                ] {
                    context.draw(
                        halo,
                        at: CGPoint(x: origin.x + offset.x, y: origin.y + offset.y),
                        anchor: .topLeading
                    )
                }
                context.draw(resolved, at: origin, anchor: .topLeading)
            }

            drawLabel(from, at: firstPoint, font: min(12, fontSize + 1))
            drawLabel(to, at: lastPoint, font: min(12, fontSize + 1))

            func distanceToRoute(_ point: CGPoint) -> CGFloat {
                projectedLegs.reduce(CGFloat.greatestFiniteMagnitude) { current, line in
                    guard line.count >= 2 else { return current }
                    let nearest = zip(line, line.dropFirst()).reduce(CGFloat.greatestFiniteMagnitude) {
                        best, pair in
                        let a = pair.0
                        let b = pair.1
                        let dx = b.x - a.x
                        let dy = b.y - a.y
                        let denominator = max(0.000001, dx * dx + dy * dy)
                        let fraction = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / denominator))
                        let x = a.x + fraction * dx
                        let y = a.y + fraction * dy
                        return min(best, hypot(point.x - x, point.y - y))
                    }
                    return min(current, nearest)
                }
            }

            if layers.contains(.majorCities), let geography {
                let limit = max(3, min(10, Int(size.width / 25)))
                let cityCandidates = geography.cities
                    .map { city in
                        (city, distanceToRoute(project(city.lat, city.lon)))
                    }
                    .filter { $0.1 <= max(12, size.width * 0.085) }
                    .sorted { $0.1 < $1.1 }
                for item in cityCandidates.prefix(limit) {
                    let name = item.0.name.hasSuffix("市")
                        ? String(item.0.name.dropLast())
                        : item.0.name
                    let point = project(item.0.lat, item.0.lon)
                    drawDot(context: context, at: point, radius: 1.6, fill: paper, stroke: ink)
                    drawLabel(name, at: point, font: max(7, fontSize - 1))
                }
            }

            if layers.contains(.allStations), stations.count == legs.count + 1 {
                let stationPoints = legs.map { leg in
                    leg.first.map { project($0.latitude, $0.longitude) }
                } + [legs.last?.last.map { project($0.latitude, $0.longitude) }]
                for (index, point) in stationPoints.enumerated() {
                    guard let point, stations.indices.contains(index) else { continue }
                    drawDot(context: context, at: point, radius: 1.8, fill: paper, stroke: ink)
                    drawLabel(stations[index], at: point, font: max(6.5, fontSize - 1.5))
                }
            }
        }
        .clipped()
        .accessibilityLabel("实际乘车区间地图，\(from)至\(to)")
    }

    private func drawDot(
        context: GraphicsContext,
        at point: CGPoint,
        radius: CGFloat,
        fill: Color,
        stroke: Color
    ) {
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let dot = Path(ellipseIn: rect)
        context.fill(dot, with: .color(fill))
        context.stroke(dot, with: .color(stroke), lineWidth: 1)
    }
}
