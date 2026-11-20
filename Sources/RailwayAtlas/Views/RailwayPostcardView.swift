import CoreText
import RailwayCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PostcardStyle: String, CaseIterable, Identifiable {
    case red, blue, map
    var id: String { rawValue }
    var title: String {
        switch self { case .red: "经典红票"; case .blue: "磁介蓝票"; case .map: "路线明信片" }
    }
}

enum TicketTypography {
    static func chinese(_ style: PostcardStyle, size: Double) -> Font {
        let name = style == .red ? "STSongti-SC-Bold" : "STHeitiSC-Medium"
        let font = CTFontCreateWithName(name as CFString, size, nil)
        if CTFontCopyPostScriptName(font) as String == name { return .custom(name, fixedSize: size) }
        return .system(size: size, weight: .medium, design: style == .red ? .serif : .default)
    }
    static func digits(_ size: Double) -> Font { .custom("Menlo-Regular", fixedSize: size) }
}

struct RailwayPostcardView: View {
    @EnvironmentObject private var model: ExperienceStore
    @EnvironmentObject private var passport: JourneyStore
    private var style: PostcardStyle { model.postcardStyle }
    private var journey: RailJourney { model.postcardDraft }
    private var caption: String { model.postcardCaption }
    @State private var exporting = false
    @State private var output = ExperienceFile(Data())
    @State private var error: String?
    @State private var route: RailTrackJourney?
    @State private var loadedKey = ""
    @State private var preparing = false
    @State private var retry = 0
    private var routeKey: String { journey.duplicateKey + (journey.timetable?.id ?? "") + (journey.timetable?.routing?.providerID ?? "") }
    private var currentRoute: RailTrackJourney? { loadedKey == routeKey ? route : nil }
    private var silhouette: RailSilhouette? { currentRoute.map { RailSilhouette(coordinates: $0.legs) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TimetableLibraryPanel(library: model.library) { model.postcardDraft = $0.draftJourney }
            HStack {
                Picker("样式", selection: $model.postcardStyle) {
                    ForEach(PostcardStyle.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 360)
                Spacer()
                Button("导出 PNG", systemImage: "square.and.arrow.up") { export() }.buttonStyle(.borderedProminent)
                    .disabled(currentRoute == nil)
            }
            GeometryReader { proxy in
                TicketPostcardArt(style: style, journey: journey, caption: caption,
                                  city: "\(journey.from) → \(journey.to)", silhouette: silhouette)
                    .frame(width: 760, height: 440)
                    .scaleEffect(proxy.size.width / 760, anchor: .topLeading)
            }.aspectRatio(760.0 / 440, contentMode: .fit)
                .accessibilityIdentifier("postcard-preview")
            HStack {
                Menu("使用护照中的旅程") {
                    ForEach(passport.journeys.prefix(100)) { item in
                        Button("\(item.date) \(item.from) → \(item.to)") { model.postcardDraft = item }
                    }
                }.disabled(passport.journeys.isEmpty)
                Spacer()
                Button("重新匹配乘车路线", systemImage: "arrow.clockwise") { retry += 1 }.disabled(preparing)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("出发站"); TextField("出发站", text: $model.postcardDraft.from)
                    Text("到达站"); TextField("到达站", text: $model.postcardDraft.to)
                }
                GridRow {
                    Text("车次"); TextField("车次", text: $model.postcardDraft.train)
                    Text("日期"); TextField("YYYY-MM-DD", text: $model.postcardDraft.date)
                }
                GridRow {
                    Text("发车"); TextField("HH:mm", text: $model.postcardDraft.departure)
                    Text("寄语"); TextField("写一句旅途寄语", text: $model.postcardCaption)
                }
            }.textFieldStyle(.roundedBorder).font(.subheadline)
            if preparing { ProgressView("正在匹配并截取乘车区间…").font(.caption) }
            if let route = currentRoute {
                Text("乘车区间 \(journey.from) → \(journey.to) · \(Int(route.distance / 1000)) km 地图轨道 · \(route.stations.count) 个经停站")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("红票使用宋体，蓝票使用黑体；车次与时间用等宽数字。线形按所选车次径路截取乘车起终点之间的实际铁路。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("纪念卡的编辑不会改动护照记录。导出为 1520 × 880 像素图片。")
                .font(.caption2).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .onChange(of: journey.from) { _, _ in model.postcardDraft.updateBoardingTime() }
        .task(id: routeKey + "/\(retry)") {
            let key = routeKey, draft = journey
            route = nil; error = nil; preparing = true
            do {
                try await Task.sleep(for: .milliseconds(400))
                let result = try await model.passengerRoute(draft)
                try Task.checkCancellation()
                route = result; loadedKey = key; preparing = false
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; preparing = false }
            }
        }
        .fileExporter(isPresented: $exporting, document: output, contentType: .png,
                      defaultFilename: "铁道漫游-\(style.title)") { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
        }
    }

    private func export() {
        guard currentRoute != nil else { error = "请先完成乘车区间匹配"; return }
        let renderer = ImageRenderer(content:
            TicketPostcardArt(style: style, journey: journey, caption: caption,
                              city: "\(journey.from) → \(journey.to)", silhouette: silhouette)
                .frame(width: 760, height: 440).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { error = "图片生成失败"; return }
        #if os(macOS)
        let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        #else
        let data = UIImage(cgImage: cgImage).pngData()
        #endif
        guard let data else { error = "图片编码失败"; return }
        output = ExperienceFile(data); error = nil; exporting = true
    }
}

struct TicketPostcardArt: View {
    let style: PostcardStyle
    let journey: RailJourney
    let caption: String
    let city: String
    let silhouette: RailSilhouette?
    private var red: Bool { style == .red }
    private var ink: Color { red ? Color(red: 0.23, green: 0.13, blue: 0.13) : Color(red: 0.09, green: 0.19, blue: 0.27) }
    private var accent: Color { red ? Color(red: 0.66, green: 0.18, blue: 0.22) : Color(red: 0.12, green: 0.38, blue: 0.57) }
    private var paper: Color { red ? Color(red: 0.98, green: 0.83, blue: 0.79) : Color(red: 0.77, green: 0.88, blue: 0.94) }
    var body: some View {
        Group {
            if style == .map { mapCard }
            else { ticket }
        }
        .frame(width: 760, height: 440)
        .clipped()
        .accessibilityElement(children: .combine)
    }

    private var ticket: some View {
        ZStack {
            paper
            Canvas { context, size in
                for row in 0..<12 {
                    var path = Path()
                    for x in 0...150 {
                        let px = Double(x) * size.width / 150
                        let py = Double(row) * 40 + sin(px / 22 + Double(row)) * 8
                        if x == 0 { path.move(to: CGPoint(x: px, y: py)) }
                        else { path.addLine(to: CGPoint(x: px, y: py)) }
                    }
                    context.stroke(path, with: .color(accent.opacity(0.07)), lineWidth: 0.6)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("RAILWAY ATLAS").font(TicketTypography.digits(15)).tracking(2).foregroundStyle(accent)
                    Spacer()
                    Text("铁 道 漫 游").font(TicketTypography.chinese(style, size: 17)).foregroundStyle(accent)
                }
                HStack(spacing: 16) {
                    station(journey.from.isEmpty ? "出发站" : journey.from)
                    VStack(spacing: 7) {
                        Text(journey.train.isEmpty ? "车次" : String(journey.train.prefix(20))).font(TicketTypography.digits(24))
                        Image(systemName: "arrow.right").font(.system(size: 30, weight: .light))
                    }.frame(width: 140)
                    station(journey.to.isEmpty ? "到达站" : journey.to)
                }.padding(.top, 34)
                HStack(spacing: 20) {
                    Text(journey.date.isEmpty ? "日期待填写" : String(journey.date.prefix(20)))
                    Text(journey.departure.isEmpty ? "时间待填写" : "\(String(journey.departure.prefix(5))) 开")
                    Spacer()
                    Text("旅程典藏").font(TicketTypography.chinese(style, size: 18))
                }.font(TicketTypography.digits(20)).padding(.top, 26)
                Rectangle().fill(accent.opacity(0.25)).frame(height: 1).padding(.top, 20)
                HStack(spacing: 20) {
                    if let silhouette {
                        SilhouetteCanvas(silhouette: silhouette, ink: accent.opacity(0.6), grid: false)
                            .frame(width: 135, height: 112).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(caption.isEmpty ? "一路山河，一程记忆。" : String(caption.prefix(100)))
                            .font(TicketTypography.chinese(style, size: 21)).lineLimit(2)
                        Text(silhouette == nil ? "乘车路线待匹配" : "乘车区间 · © OpenStreetMap contributors")
                            .font(.system(size: 10)).foregroundStyle(ink.opacity(0.65))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 1) {
                        ForEach(["旅", "行", "纪", "念"], id: \.self) { glyph in
                            Text(glyph).font(TicketTypography.chinese(style, size: 15))
                                .fixedSize().frame(width: 22, height: 18)
                        }
                    }.padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent.opacity(0.7), lineWidth: 1.4))
                        .foregroundStyle(accent).rotationEffect(.degrees(-6))
                }.padding(.top, 4)
                Spacer(minLength: 8)
                HStack {
                    Text("纪念设计 · 非乘车凭证").font(.system(size: 11))
                    Spacer()
                    Text("KEEP THE JOURNEY").font(TicketTypography.digits(10)).tracking(2)
                }.foregroundStyle(ink.opacity(0.6))
            }.padding(30).foregroundStyle(ink)
        }.overlay(Rectangle().stroke(accent.opacity(0.25), lineWidth: 1))
    }
    private func station(_ text: String) -> some View {
        Text(String(text.prefix(40))).font(TicketTypography.chinese(style, size: 40))
            .lineLimit(1).minimumScaleFactor(0.45).frame(maxWidth: .infinity)
    }
    private var mapCard: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color(red: 0.07, green: 0.19, blue: 0.21)
                if let silhouette { SilhouetteCanvas(silhouette: silhouette).padding(10).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 7) {
                    Text(journey.train.isEmpty ? "乘车路线" : journey.train).font(TicketTypography.chinese(.blue, size: 34))
                    Text(silhouette == nil ? "路线待匹配" : "YOUR JOURNEY IN LINES").font(TicketTypography.digits(11)).tracking(2)
                }.foregroundStyle(.white).padding(26)
            }.frame(width: 365)
            VStack(alignment: .leading, spacing: 20) {
                Text("POSTCARD / 铁道漫游").font(TicketTypography.digits(12)).foregroundStyle(accent)
                Text("\(journey.from.isEmpty ? "出发站" : String(journey.from.prefix(40)))\n↓\n\(journey.to.isEmpty ? "到达站" : String(journey.to.prefix(40)))")
                    .font(TicketTypography.chinese(.red, size: 30)).lineLimit(4).minimumScaleFactor(0.7)
                Text([journey.date, journey.train, journey.departure].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(TicketTypography.digits(13)).foregroundStyle(ink.opacity(0.7))
                Divider()
                Text(String(caption.prefix(100))).font(TicketTypography.chinese(.red, size: 20)).lineLimit(3)
                Spacer()
                Text("乘车区间 © OpenStreetMap contributors\n旅行纪念 · 非乘车凭证")
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.6))
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.background(Color(red: 0.98, green: 0.96, blue: 0.91)).foregroundStyle(ink)
    }
}
