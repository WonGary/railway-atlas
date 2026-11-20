import RailwayCore
import SwiftUI

struct ExperienceRootView: View {
    @StateObject private var model: ExperienceStore
    @StateObject private var passport: JourneyStore
    @Environment(\.dismiss) private var dismiss
    private let map: RailwayMapStore?

    init(model: ExperienceStore? = nil, passport: JourneyStore? = nil, map: RailwayMapStore? = nil) {
        _model = StateObject(wrappedValue: model ?? ExperienceStore())
        _passport = StateObject(wrappedValue: passport ?? JourneyStore())
        self.map = map
    }
    var body: some View {
        Group {
            #if os(macOS)
            HStack(spacing: 0) {
                navigation.frame(width: 204)
                Divider()
                content
            }
            .frame(minWidth: 940, minHeight: 680)
            #else
            NavigationStack {
                VStack(spacing: 0) {
                    Picker("漫游项目", selection: $model.tab) {
                        ForEach(ExperienceTab.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                    }.pickerStyle(.menu).padding()
                    content
                }
                .navigationTitle("铁道漫游")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            }
            #endif
        }
        .environmentObject(model)
        .environmentObject(passport)
        .tint(.railwayAccent)
        .task { model.map = map; await model.load() }
        .accessibilityIdentifier("railway-experiences")
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                RailwayAtlasMark(size: 36)
                Text("铁道漫游").font(.system(size: 24, weight: .semibold, design: .serif))
                Text("RAILWAY STORIES").font(.system(size: 9, weight: .medium)).tracking(2)
                    .foregroundStyle(.secondary)
            }.padding(.top, 26)
            VStack(spacing: 6) {
                ForEach(ExperienceTab.allCases) { item in
                    Button { model.tab = item } label: {
                        Label(item.title, systemImage: item.icon)
                            .font(.system(size: 13, weight: model.tab == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(model.tab == item ? Color.railwayAccent.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.tab == item ? Color.railwayAccent : .primary)
                    .accessibilityIdentifier("experience-tab-\(item.rawValue)")
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(.secondary)
                Text("地图之外\n也有值得收藏的故事").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(.bottom, 24)
        }.padding(.horizontal, 18).background(.quaternary.opacity(0.2))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.tab.title).font(.system(size: 27, weight: .semibold, design: .serif))
                Text(model.tab.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 22)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                    .foregroundStyle(.orange).padding(.horizontal, 28).padding(.bottom, 12)
            }
            ScrollView {
                Group {
                    switch model.tab {
                    case .guess: CityGuessView()
                    case .passport: RailwayPassportView()
                    case .postcard: RailwayPostcardView()
                    case .history: RailwayTimeMachineView()
                    case .simulation: RailwaySimulationView()
                    }
                }.padding(.horizontal, 28).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ExperienceSourceView: View {
    let source: RailEvidence
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let url = URL(string: source.url), ["https", "http"].contains(url.scheme) {
                Link(destination: url) { Label(source.title, systemImage: "arrow.up.right.square") }
                    .font(.caption)
            }
            Text("查阅于 \(source.retrievedOn)").font(.caption2).foregroundStyle(.secondary)
            if !source.note.isEmpty { Text(source.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct SilhouetteCanvas: View {
    let silhouette: RailSilhouette
    var ink: Color = Color(red: 0.83, green: 0.93, blue: 0.89)
    var grid = true
    var body: some View {
        Canvas { context, size in
            if grid {
                var gridPath = Path()
                for x in stride(from: 0.0, through: size.width, by: 32) {
                    gridPath.move(to: CGPoint(x: x, y: 0)); gridPath.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: 0.0, through: size.height, by: 32) {
                    gridPath.move(to: CGPoint(x: 0, y: y)); gridPath.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(gridPath, with: .color(ink.opacity(0.06)), lineWidth: 0.5)
            }
            let side = max(1, min(size.width, size.height) - 44)
            func project(_ p: RailSilhouette.Point) -> CGPoint {
                CGPoint(x: (size.width - side) / 2 + p.x * side, y: (size.height - side) / 2 + p.y * side)
            }
            for points in silhouette.paths {
                guard let first = points.first else { continue }
                var path = Path(); path.move(to: project(first))
                for point in points.dropFirst() { path.addLine(to: project(point)) }
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("城市轨道线形，无底图、站名、线路颜色或地理坐标")
        .accessibilityIdentifier("anonymous-railway-shape")
    }
}

struct CityGuessView: View {
    @EnvironmentObject private var model: ExperienceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("形状挑战", systemImage: "puzzlepiece").font(.headline)
                Spacer()
                Text("\(model.correctAnswers) / \(model.roundsAnswered) 答对").font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("全国 \(model.cities.filter { !$0.cached }.count) 城 · 缓存扩展 \(model.cities.filter(\.cached).count) 城")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("加入世界缓存题库", isOn: $model.includesWorldCache).font(.caption)
                Button("读取缓存") { Task { await model.refreshCachedCities() } }
                    .disabled(model.quizLoading)
            }
            if let round = model.round {
                ZStack(alignment: .bottomLeading) {
                    SilhouetteCanvas(silhouette: round.silhouette)
                    Text("NETWORK / \(String(format: "%03d", model.roundsAnswered + (model.guessed == nil ? 1 : 0)))")
                        .font(.system(size: 10, design: .monospaced)).tracking(2)
                        .foregroundStyle(.white.opacity(0.65)).padding(18)
                }
                .frame(height: 350)
                .background(Color(red: 0.055, green: 0.13, blue: 0.17), in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(round.choices.enumerated()), id: \.offset) { index, city in
                        Button { model.answer(city) } label: {
                            HStack {
                                Text(String(UnicodeScalar(65 + index)!)).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary).frame(width: 24)
                                Text(city).font(.headline)
                                Spacer()
                                if model.guessed != nil, city == round.answer {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else if model.guessed == city {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                                }
                            }.padding(15).frame(maxWidth: .infinity)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(model.guessed != nil)
                            .accessibilityIdentifier("guess-option-\(index)")
                    }
                }
                if let guessed = model.guessed {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(guessed == round.answer ? "认出来了，是\(round.answer)。" : "答案是\(round.answer)。")
                                .font(.headline)
                            Text("OSM 城市轨道概览 · \(round.sourceDate) · 数据可能存在缺线")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("下一城", systemImage: "arrow.right") { model.nextRound() }.buttonStyle(.borderedProminent)
                    }.accessibilityIdentifier("guess-reveal")
                } else {
                    Text("只保留线形；隐藏底图、站名、线路颜色、坐标和真实比例。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Toggle("下一题随机旋转", isOn: $model.rotatesGuess).toggleStyle(.checkboxIfAvailable)
                        .font(.caption)
                    Spacer()
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption2)
                }
            } else {
                ContentUnavailableView("正在准备城市题库", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("使用随应用提供的轨道线形，游戏中无需联网。"))
            }
        }
    }
}

private struct AdaptiveCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        Toggle(configuration).toggleStyle(.checkbox)
        #else
        Toggle(configuration).toggleStyle(.switch)
        #endif
    }
}
private extension ToggleStyle where Self == AdaptiveCheckboxStyle {
    static var checkboxIfAvailable: Self { .init() }
}

#if os(macOS)
struct ExperienceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandMenu("漫游") {
            Button("打开铁道漫游") { openWindow(id: "railway-experiences") }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }
}
#endif
