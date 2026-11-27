import RailwayCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AtlasSettingsView: View {
    enum Page: String, CaseIterable { case drawing = "绘制", layers = "图层", interface = "界面", gpt = "问答", config = "配置" }
    var initialPage: Page = .drawing
    private var uiScale: Double { map.uiScale }
    @EnvironmentObject private var map: RailwayMapStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var configuration: ConfigurationStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AssistantSettings()
    @State private var key = ""
    @State private var claudeKey = ""
    @State private var compatibleKeys: [AssistantProvider: String] = [:]
    @State private var notice = ""
    @State private var page = Page.drawing
    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            HStack {
                Text("设置").atlasFont(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }
            }
            Picker("设置分类", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 18 * uiScale) {
                  switch page {
                  case .drawing:
                    Text("线路与站点").atlasFont(.headline)
                    parameter("地铁线宽倍率", value: $map.renderSettings.metroWidthScale, range: 0.5...2, step: 0.05)
                    parameter("铁路线宽倍率", value: $map.renderSettings.railwayWidthScale, range: 0.5...2, step: 0.05)
                    parameter("站点半径 ÷ 线宽", value: $map.renderSettings.stationRadiusMultiplier, range: 0.5...3, step: 0.05)
                    Text("默认半径 = 线宽 × 1.25，直径 = 线宽 × 2.5。跟随当前地图比例尺，界面缩放只影响文字与控件。")
                        .atlasFont(.caption).foregroundStyle(.secondary)
                    StationProportionPreview(settings: map.renderSettings).atlasFrame(height: 100)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    FocusColourPicker(hex: $map.renderSettings.focusColor)
                    Toggle("铁路使用空实相间线型", isOn: $map.renderSettings.railwayPattern)
                    parameter("车辆段亮度", value: $map.renderSettings.depotBrightness, range: 0.1...1, step: 0.05)
                    HStack {
                        Text("视野预绘制边距 \(Int(map.renderSettings.viewportBuffer * 100))%")
                        Slider(value: $map.renderSettings.viewportBuffer, in: 0...0.5, step: 0.05)
                    }
                    Text("只绘制当前窗口与四边缓冲区。默认每边 20%，移动到边缘时补充线路，已下载的数据仍保留。")
                        .atlasFont(.caption).foregroundStyle(.secondary)
                    Toggle("地铁使用线路色", isOn: $map.showsMetroColors)
                    Toggle("在线补充百科线路色", isOn: $map.enrichWikiColours)
                    Text("有线路归属时，站点使用同线路色；换乘站保留多色环。不同等级车站通过填充、内环区分，站点不合并。")
                        .atlasFont(.caption).foregroundStyle(.secondary)
                    Button("恢复默认绘制参数") { map.renderSettings = RailRenderSettings() }
                  case .layers:
                    LayerControls()
                  case .interface:
                    Text("界面与布局").atlasFont(.headline)
                    HStack {
                        Text("界面缩放 \(Int(map.uiScale * 100))%")
                        Slider(value: $map.uiScale, in: 0.75...1.6, step: 0.05)
                        Button("100%") { map.uiScale = 1 }
                    }
                    #if os(macOS)
                    PanelSettingsView()
                    #else
                    InterfaceSurfaceSettingsView()
                    HStack {
                        Text("侧栏宽度 \(Int(map.panelWidth))")
                        Slider(value: $map.panelWidth, in: 250...560)
                    }
                    #endif
                    Toggle("显示地图状态卡", isOn: $map.statusVisible)
                    Button("重置状态卡位置") { map.statusOffset = .zero; map.statusVisible = true }
                    Toggle("随比例尺自动隐藏次要线路", isOn: $map.automaticDetail)
                    Button("恢复自动图层规则") {
                        map.forcedCategories = []; map.forcedNetworks = []
                        map.categories = Set(RailCategory.allCases); map.networks = Set(RailNetwork.allCases)
                        map.automaticDetail = true
                    }
                  case .gpt:
                    assistantSettings
                  case .config:
                    Text("配置文件").atlasFont(.headline)
                    Text("设置会自动写入 config.json。也可以直接编辑 JSON，保存后自动应用；省略的字段采用默认值。升级应用会保留这份文件。")
                        .atlasFont(.caption).foregroundStyle(.secondary)
                    Text(configuration.url.path).atlasFont(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        #if os(macOS)
                        Button("打开配置文件") { NSWorkspace.shared.open(configuration.url) }
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([configuration.url]) }
                        #else
                        ShareLink("导出配置", item: configuration.url)
                        #endif
                        Button("重新载入") { configuration.reload() }
                    }
                    Text(configuration.notice).atlasFont(.caption).foregroundStyle(configuration.hasError ? .orange : .secondary)
                        .textSelection(.enabled)
                    Divider()
                    Picker("浏览方式", selection: Binding(get: { map.mapMode }, set: { map.changeMode($0) })) {
                        ForEach(MapMode.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("铁路矢量源 URL 模板", text: $map.sourceDraft)
                    Button("应用数据源") { map.applySource() }
                    Text("更换地址后仍按现有规则尝试备用源。API key 不包含在配置文件中；仅本机钥匙串保存。铁路缓存上限 8 GB，Apple 底图和卫星影像不写入铁路缓存。")
                        .atlasFont(.caption).foregroundStyle(.secondary)
                  }
                  Divider()
                  mapCredits
                }.textFieldStyle(.roundedBorder).atlasPadding(4)
            }
            if configuration.hasError && page != .config {
                Button("配置文件有错误，点击查看") { page = .config }.foregroundStyle(.orange)
            }
            if page == .gpt {
                HStack {
                    Button("保存问答设置", action: saveAssistantSettings)
                        .buttonStyle(.borderedProminent).disabled(assistant.busy)
                    Spacer()
                    Text("Key 分别存于钥匙串").atlasFont(.caption2).foregroundStyle(.secondary)
                }
                if !notice.isEmpty { Text(notice).atlasFont(.caption).textSelection(.enabled) }
            } else {
                Text("调整立即生效，自动保存。").atlasFont(.caption2).foregroundStyle(.secondary)
            }
        }.atlasPadding(24)
        .modifier(AtlasSheetLayout(scale: map.uiScale, width: 620, height: 680))
        .onAppear { draft = assistant.settings; page = initialPage }
    }

    private var mapCredits: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("地图来源与版权").atlasFont(.headline)
            if map.mapMode == .apple {
                if let url = map.activeBasemapAttributionURL {
                    Link("当前底图 · \(map.activeBasemapAttributionTitle)", destination: url)
                } else { Text("当前底图 · \(map.activeBasemapAttributionTitle)") }
            }
            Text("[© OpenStreetMap contributors](https://www.openstreetmap.org/copyright) · [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/)")
            Text("铁路瓦片与底图 · [OpenRailwayMap](https://openrailwaymap.app/) · [VersaTiles](https://versatiles.org/) · [OpenFreeMap](https://openfreemap.org/) · [© OpenMapTiles](https://openmaptiles.org/) · [Apple 地图](https://www.apple.com/maps/) · [高德地图](https://lbs.amap.com/)")
            Text("新加坡车站出口 · [Land Transport Authority](https://data.gov.sg/datasets/d_b39d3a0871985372d7e1637193335da5/view) · [Singapore Open Data Licence](https://data.gov.sg/open-data-licence)")
            Text("车次与径路 · [中国铁路地图](https://cnrail.geogv.com/) · [Jeremy Gao](https://github.com/wensimehrp/chinese-railway-gtfs)（[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)）。本机时刻库 · [路路通](http://www.lltskb.com/)")
            Text("沿线地理 · [Natural Earth](https://www.naturalearthdata.com/) · 天地图 / 干旱区生态与资源科学数据中心")
            Text("城轨配色 · [RMG Palette](https://github.com/railmapgen/rmg-palette)（[GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html)）· [Wikidata](https://www.wikidata.org/) · [Wikipedia](https://www.wikipedia.org/)")
        }
        .atlasFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        .accessibilityIdentifier("settings-map-credits")
    }

    private var assistantSettings: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            Text("地图问答").atlasFont(.headline)
            Picker("当前服务", selection: $draft.provider) {
                ForEach(AssistantProvider.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
            #if os(macOS)
            Picker("显示位置", selection: $draft.presentation) {
                ForEach(AssistantPresentation.allCases) { Text($0.title).tag($0) }
            }
            #endif
            if draft.provider == .gpt { GroupBox("GPT") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("API 协议", selection: $draft.apiProtocol) {
                        Text("Responses").tag(AssistantProtocol.responses)
                        Text("Chat Completions").tag(AssistantProtocol.chat)
                    }.onChange(of: draft.apiProtocol) { old, new in
                        if draft.endpoint.hasSuffix(old.suffix) {
                            draft.endpoint = String(draft.endpoint.dropLast(old.suffix.count)) + new.suffix
                        }
                    }
                    TextField("GPT API 地址", text: $draft.endpoint)
                        .onChange(of: draft.endpoint) { _, _ in key = "" }
                    TextField("当前 GPT 模型 ID", text: $draft.model)
                    SecureField("GPT API Key（留空保留）", text: $key)
                        .accessibilityIdentifier("gpt-api-key")
                    Stepper("输出上限 \(draft.maxOutputTokens)", value: $draft.maxOutputTokens, in: 200...16000, step: 200)
                    Toggle("联网搜索（Responses）", isOn: $draft.webSearch)
                    Button("删除 GPT Key") { deleteKey(.gpt) }
                }.atlasPadding(6)
            } }
            if draft.provider == .claude { GroupBox("Claude · Messages") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Claude API 地址", text: $draft.claude.endpoint)
                        .onChange(of: draft.claude.endpoint) { _, _ in claudeKey = "" }
                    if let address = draft.messagesEndpointForGPTGateway {
                        Button("套用 GPT 网关的 Messages 地址") { draft.claude.endpoint = address.absoluteString }
                            .help("仅填写同一网关的 /messages 地址，请确认服务商支持；Claude Key 仍需单独填写。")
                    }
                    Text("Claude 地址须与 Key 的签发服务一致。使用中转服务时，请填写该服务的 Messages 地址。")
                        .atlasFont(.caption).foregroundStyle(.secondary)
                    TextField("当前 Claude 模型 ID", text: $draft.claude.model)
                    SecureField("Claude API Key（留空保留）", text: $claudeKey)
                        .accessibilityIdentifier("claude-api-key")
                    Stepper("输出上限 \(draft.claude.maxOutputTokens)", value: $draft.claude.maxOutputTokens, in: 200...16000, step: 200)
                    Toggle("联网搜索", isOn: $draft.claude.webSearch)
                        .accessibilityIdentifier("claude-web-search-setting")
                    Toggle("读取网页", isOn: $draft.claude.webFetch)
                        .accessibilityIdentifier("claude-web-fetch-setting")
                    Text("开启后由 Claude 按需搜索或读取链接，回答附来源。需服务商支持，可能产生工具及内容费用。")
                        .atlasFont(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("接口兼容设置") {
                        Picker("认证方式", selection: $draft.claude.authentication) {
                            ForEach(ClaudeAuthentication.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        TextField("anthropic-version", text: $draft.claude.apiVersion)
                    }
                    Button("删除 Claude Key") { deleteKey(.claude) }
                }.atlasPadding(6)
            } }
            if draft.provider.compatibleDefault != nil {
                GroupBox(draft.provider.title + " · Chat Completions") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("API 地址", text: $draft.compatibleProfile.endpoint)
                            .onChange(of: draft.compatibleProfile.endpoint) { _, _ in compatibleKeys[draft.provider] = nil }
                        TextField("模型 ID", text: $draft.compatibleProfile.model)
                        SecureField("API Key（留空保留）", text: Binding(
                            get: { compatibleKeys[draft.provider] ?? "" },
                            set: { compatibleKeys[draft.provider] = $0 }))
                        Stepper("输出上限 \(draft.compatibleProfile.maxOutputTokens)",
                                value: $draft.compatibleProfile.maxOutputTokens, in: 200...16000, step: 200)
                        Text(draft.provider == .doubao ? "填写火山方舟已开通的模型 ID 或 ep- 开头的推理接入点 ID。"
                             : "可填写完整 HTTPS 接口地址及服务商提供的模型 ID。")
                            .atlasFont(.caption).foregroundStyle(.secondary)
                        Button("删除此地址的 Key") { deleteKey(draft.provider) }
                    }.atlasPadding(6)
                }.id(draft.provider)
            }
            Text("模型列表").atlasFont(.headline)
            Text("模型 ID 按服务商填写；显示名和备注可自定义。选择模型时自动使用对应服务与 Key。")
                .atlasFont(.caption).foregroundStyle(.secondary)
            ForEach($draft.models) { $entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("服务", selection: $entry.provider) {
                            ForEach(AssistantProvider.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 95)
                        TextField("模型 ID", text: $entry.name)
                        Button(role: .destructive) {
                            draft.models.removeAll { $0.id == entry.id }
                        } label: { Image(systemName: "minus.circle") }.help("移除此模型")
                    }
                    HStack {
                        TextField("显示名（可选）", text: $entry.label)
                        TextField("备注（可选）", text: $entry.note)
                    }
                }.atlasPadding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("添加模型", systemImage: "plus") {
                    draft.models.append(.init(provider: draft.provider, name: ""))
                }
                Button("补回预置模型") {
                    for entry in AssistantModel.defaults where !draft.models.contains(where: { $0.provider == entry.provider && $0.name == entry.name }) {
                        draft.models.append(entry)
                    }
                }
            }
            Text("只有发送时才请求服务商；模型和工具是否可用取决于你的 API。Key 不写入配置或会话。GPT 搜索使用 Responses，Claude 搜索与网页读取使用 Messages。")
                .atlasFont(.caption).foregroundStyle(.secondary)
        }
    }

    private func saveAssistantSettings() {
        do {
            let moved = assistant.settings.presentation != draft.presentation
            var keys = compatibleKeys
            keys[.gpt] = key; keys[.claude] = claudeKey
            try assistant.save(draft, keys: keys)
            if moved { assistant.setPresentation(draft.presentation, map: map) }
            key = ""; claudeKey = ""; compatibleKeys = [:]; notice = "已保存。Key 按服务和地址分别存于钥匙串。"
        } catch { notice = error.localizedDescription }
    }

    private func deleteKey(_ provider: AssistantProvider) {
        do {
            try AtlasKeychain.removeAssistantKey(for: draft.selecting(provider))
            switch provider { case .gpt: key = ""; case .claude: claudeKey = ""; default: compatibleKeys[provider] = nil }
            notice = "已删除 \(provider.title) 的凭据。"
        } catch { notice = error.localizedDescription }
    }

    private func parameter(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 6 * uiScale) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

private struct FocusColourPicker: View {
    @Binding var hex: String
    @Environment(\.self) private var environment
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("旅行与无配色要素的高亮色")
                Spacer()
                ColorPicker("自定义高亮色", selection: Binding(get: {
                    (RailColor(hex) ?? RailRenderSettings().focusInk).tint
                }, set: { value in
                    let c = value.resolve(in: environment)
                    func byte(_ channel: Float) -> Int { Int((min(1, max(0, channel)) * 255).rounded()) }
                    hex = String(format: "#%02X%02X%02X", byte(c.red), byte(c.green), byte(c.blue))
                }), supportsOpacity: false).labelsHidden()
            }
            HStack {
                ForEach(RailColor.focusPresets, id: \.hex) { preset in
                    Button {
                        hex = preset.hex
                    } label: {
                        Circle().fill(RailColor(preset.hex)!.tint).frame(width: 24, height: 24)
                            .overlay { if hex.uppercased() == preset.hex { Image(systemName: "checkmark").foregroundStyle(.white) } }
                    }.buttonStyle(.plain).help(preset.name).accessibilityLabel(preset.name)
                    .accessibilityAddTraits(hex.uppercased() == preset.hex ? .isSelected : [])
                }
            }
        }
    }
}

struct StationProportionPreview: View {
    let settings: RailRenderSettings
    @Environment(\.atlasUIScale) private var scale
    var body: some View {
        Canvas { context, size in
            for (index, category) in [RailCategory.urban, .speed350].enumerated() {
                let appearance = RailAppearance(category: category, colors: [RailColor("#008F62")!])
                let y = size.height * (index == 0 ? 0.3 : 0.7)
                let label = category == .urban ? "地铁" : "高速铁路"
                context.draw(Text(label).atlasFont(.caption, scale: scale), at: CGPoint(x: 18 * scale, y: y), anchor: .leading)
                var path = Path()
                path.move(to: CGPoint(x: size.width * 0.3, y: y)); path.addLine(to: CGPoint(x: size.width - 25, y: y))
                for stroke in appearance.strokes(zoom: 12, settings: settings) {
                    context.stroke(path, with: .color(stroke.color.tint), style: StrokeStyle(lineWidth: stroke.width, dash: stroke.dash.map { CGFloat($0) }))
                }
                let radius = appearance.lineWidth(zoom: 12, settings: settings) * settings.stationRadiusMultiplier
                let circle = CGRect(x: size.width * 0.65 - radius, y: y - radius, width: 2 * radius, height: 2 * radius)
                let ring = min(1.2, radius * 0.36)
                context.fill(Path(ellipseIn: circle), with: .color(.white))
                context.stroke(Path(ellipseIn: circle.insetBy(dx: ring / 2, dy: ring / 2)),
                               with: .color(category == .urban ? RailColor("#008F62")!.tint : category.tint), lineWidth: ring)
            }
        }
        .accessibilityLabel("线路与站点比例实时预览")
    }
}

private struct AssistantControlsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct AtlasAssistantView: View {
    var embedded = false
    private var uiScale: Double { map.uiScale }
    @EnvironmentObject private var map: RailwayMapStore
    @EnvironmentObject private var assistant: AssistantStore
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif
    @State private var previewExpanded = false
    @State private var historyPresented = false
    @State private var settingsPresented = false
    @State private var controlsHeight: CGFloat = 200
    var body: some View {
        Group {
            if embedded {
                content
            } else {
                content.modifier(AtlasSheetLayout(scale: map.uiScale, width: 650, height: assistant.height))
            }
        }
        .onAppear { if assistant.context.isEmpty { assistant.prepare(map: map) } }
        .onDisappear { assistant.flushPendingDraft() }
        .sheet(isPresented: $historyPresented) { AssistantHistoryView() }
        .sheet(isPresented: $settingsPresented) { AtlasSettingsView(initialPage: .gpt) }
        #if os(macOS)
        .onChange(of: assistant.settings.presentation) { _, position in
            if !embedded && position != .window {
                assistant.show(map: map)
                openWindow(id: "main-map")
                dismissWindow(id: "railway-assistant")
            }
        }
        #endif
        .accessibilityIdentifier("gpt-map-inspector")
    }

    private var content: some View {
        GeometryReader { geometry in
          VStack(alignment: .leading, spacing: (embedded ? 8 : 12) * uiScale) {
            ScrollView {
                controls
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: AssistantControlsHeight.self, value: proxy.size.height)
                    })
            }
            .frame(height: min(controlsHeight, max(60, geometry.size.height * (embedded ? 0.28 : 0.35))))
            .onPreferenceChange(AssistantControlsHeight.self) {
                if $0 > 0 && controlsHeight != $0 { controlsHeight = $0 }
            }
            conversation
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = assistant.error {
                ScrollView { Text(error).atlasFont(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    .frame(maxHeight: 92 * uiScale)
            }
            if let error = assistant.persistenceError {
                VStack(alignment: .leading, spacing: 2) {
                    ScrollView { Text(error).atlasFont(.caption2).foregroundStyle(.orange).textSelection(.enabled) }
                        .frame(maxHeight: 36 * uiScale)
                    Button("重试保存") { assistant.persistCurrent() }.atlasFont(.caption)
                }
            }
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                HStack {
                    Text("附带地图信息").atlasFont(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if assistant.contextMode != .none {
                        Text("\(assistant.sendingContext.count) 字符").atlasFont(.caption2).foregroundStyle(.secondary)
                    }
                }
                Picker("附带地图信息", selection: Binding(get: { assistant.contextMode }, set: {
                    assistant.setContextMode($0)
                    if $0 != .none && assistant.reference == nil { assistant.prepare(map: map) }
                })) {
                    ForEach(AssistantContextMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).disabled(assistant.busy)
                    .help(assistant.contextMode.explanation).accessibilityIdentifier("assistant-context-mode")
                if assistant.contextMode == .none {
                    Text("不附地图材料，仍保留聊天正文").atlasFont(.caption2).foregroundStyle(.secondary)
                }
                // Keep the active field editor alive while a reply is pending.
                // Disabling it during a SwiftUI update aborts Chinese IME editing
                // and can re-enter AttributeGraph layout on macOS 26.
                TextField("输入问题", text: $assistant.question, axis: .vertical)
                    .atlasFont(.body)
                    .lineLimit(embedded ? 4 : 6, reservesSpace: true)
                    .textFieldStyle(.plain)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8 * uiScale)
                    .frame(minHeight: (embedded ? 76 : 108) * uiScale, alignment: .topLeading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8 * uiScale))
                    .overlay(RoundedRectangle(cornerRadius: 8 * uiScale).stroke(.secondary.opacity(0.3)))
                    .accessibilityIdentifier("gpt-question")
                    .help("回答期间可以继续编辑下一条草稿；完成后再发送。")
                HStack(spacing: 6 * uiScale) {
                    Menu {
                        Button("对话历史", systemImage: "clock.arrow.circlepath") {
                            assistant.flushPendingDraft()
                            historyPresented = true
                        }
                        Button("新建对话", systemImage: "plus") { assistant.newConversation() }.disabled(assistant.busy)
                        Button("复制整会话（Markdown）", systemImage: "doc.on.doc") {
                            AssistantClipboard.copy(assistant.conversationMarkdown)
                        }
                        Button("复制整会话（纯文本）", systemImage: "doc.plaintext") {
                            AssistantClipboard.copy(assistant.conversationPlainText)
                        }
                        Button("复制整会话（格式化文本）", systemImage: "doc.richtext") {
                            AssistantClipboard.copyFormatted(assistant.conversationMarkdown)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }.menuStyle(.borderlessButton).fixedSize().help("历史、新建或复制整会话").accessibilityLabel("会话操作")
                        .accessibilityIdentifier("gpt-conversation-menu")
                    Spacer(minLength: 0)
                    if assistant.busy {
                        ProgressView().atlasControlSize(.small)
                        Button("停止") { assistant.cancel() }
                            .accessibilityIdentifier("gpt-stop")
                    } else {
                        Button("发送") { assistant.send() }.buttonStyle(.borderedProminent)
                            .disabled(!assistant.canSend)
                            .accessibilityIdentifier("gpt-send")
                    }
                }
            }.fixedSize(horizontal: false, vertical: true).layoutPriority(2)
            #if os(macOS)
            if !embedded {
                HStack {
                    Text("面板高度").atlasFont(.caption2)
                    Slider(value: $assistant.height, in: 480...820, step: 20)
                }
            }
            #endif
          }
        }
        .atlasPadding(embedded ? 14 : 20)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            HStack {
                Label("地图问答", systemImage: "sparkles")
                    .atlasFont(embedded ? .headline : .title2.bold()).lineLimit(1)
                Spacer(minLength: 0)
                Button { settingsPresented = true } label: {
                    Image(systemName: "gearshape")
                }.help("问答设置").accessibilityLabel("问答设置")
                #if os(macOS)
                AssistantPlacementMenu()
                #endif
                if !embedded { Button("关闭") { dismiss() } }
            }
            Text(assistant.current.title).atlasFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help("对话自动保存在本机；新引用不会替换之前提问的材料")
            HStack(spacing: 8 * uiScale) {
                Label("模型", systemImage: "cpu")
                    .atlasFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(AssistantProvider.allCases) { provider in
                        Section(provider.title) {
                            ForEach(assistant.settings.models.filter { $0.provider == provider }) { model in
                                Button { assistant.selectModel(model) } label: {
                                    Label(model.title, systemImage: assistant.settings.provider == provider && assistant.settings.selectedModel == model.name ? "checkmark" : "cpu")
                                    if !model.note.isEmpty { Text(model.note) }
                                }.help(model.name + (model.note.isEmpty ? "" : "\n" + model.note))
                            }
                            Button("使用 \(provider.title) 当前模型") { assistant.selectProvider(provider) }
                        }
                    }
                    Divider()
                    Button("管理模型…") { settingsPresented = true }
                } label: {
                    Text(assistant.settings.provider.title + " · " + assistant.settings.selectedModel)
                        .lineLimit(1).truncationMode(.middle)
                }.accessibilityIdentifier("gpt-model-menu").disabled(assistant.busy)
            }
            .fixedSize(horizontal: false, vertical: true)
            if assistant.contextMode != .none {
            ViewThatFits(in: .horizontal) {
                scopePicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                scopePicker.pickerStyle(.menu)
            }.disabled(assistant.busy)
            if assistant.scope == .route {
                Picker("线路", selection: Binding(get: { assistant.routeKey }, set: {
                    guard !assistant.busy, assistant.routeKey != $0 else { return }
                    assistant.routeKey = $0; assistant.prepare(map: map)
                })) {
                    Text("选择线路").tag("")
                    if !assistant.routeKey.isEmpty, !map.assistantRoutes.contains(where: { $0.id == assistant.routeKey }) {
                        Text("已保存 · \(assistant.contextTitle)").tag(assistant.routeKey)
                    }
                    ForEach(map.assistantRoutes) { route in Text(route.name).tag(route.id) }
                }.disabled(assistant.busy)
            }
            HStack {
                Text(assistant.contextTitle).atlasFont(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                Button { assistant.prepare(map: map) } label: {
                    Label("使用当前地图", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }.disabled(assistant.busy).help("使用当前地图更新材料，保留对话")
            }
            DisclosureGroup("\(assistant.contextMode.title)材料 · \(assistant.sendingContext.count) 字符", isExpanded: $previewExpanded) {
                ScrollView { Text(assistant.sendingContext).atlasFont(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    .atlasFrame(height: embedded ? 90 : 140)
            }.atlasFont(.caption)
            Text(assistant.contextMode.explanation).atlasFont(.caption2).foregroundStyle(.secondary)
            }
            if assistant.settings.provider == .gpt {
                Toggle("联网搜索", isOn: $assistant.settings.webSearch).disabled(assistant.busy)
            } else if assistant.settings.provider == .claude {
                Toggle("联网搜索", isOn: $assistant.settings.claude.webSearch)
                    .disabled(assistant.busy).accessibilityIdentifier("claude-web-search")
                Toggle("读取网页", isOn: $assistant.settings.claude.webFetch)
                    .disabled(assistant.busy).accessibilityIdentifier("claude-web-fetch")
            }
            if assistant.settings.webToolsEnabled {
                Text(assistant.settings.provider == .claude
                     ? "允许 Claude 按需使用已开启的工具；回答显示实际使用状态和来源，可能产生额外费用。"
                     : assistant.settings.apiProtocol == .responses
                         ? "允许按问题搜索外部资料；可能产生服务商搜索费用。"
                         : "请先在 GPT 设置中使用支持 web_search 的 Responses 端点与模型。")
                    .atlasFont(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18 * uiScale) {
                        if assistant.turns.isEmpty {
                            Text("例如：这条线路连接哪些地区？所选区段的速度与运营方是什么？")
                                .foregroundStyle(.secondary).atlasPadding(.vertical, 20)
                        }
                        ForEach(assistant.turns) { turn in
                            VStack(alignment: .leading, spacing: 6 * uiScale) {
                                Text(turn.role == "user" ? "你" : (turn.model ?? "GPT"))
                                    .atlasFont(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                if let reference = turn.reference {
                                    Text("\(turn.contextMode == .summary ? "精简引用" : "引用") · \(reference.title)")
                                        .atlasFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        .help("快照 \(reference.id.uuidString)\n\(reference.featureIDs.joined(separator: "\n"))")
                                }
                                if turn.role == "assistant" {
                                    AssistantMarkdownView(turn.text)
                                    if turn.searchRequested || turn.searched {
                                        Label(turn.searched ? "本次已联网搜索" : "本次未执行联网搜索",
                                              systemImage: turn.searched ? "globe" : "text.bubble")
                                            .atlasFont(.caption).foregroundStyle(.secondary)
                                    }
                                    if turn.fetchRequested || turn.fetched {
                                        Label(turn.fetched ? "本次已读取网页" : "本次未执行网页读取",
                                              systemImage: turn.fetched ? "doc.text.magnifyingglass" : "doc")
                                            .atlasFont(.caption).foregroundStyle(.secondary)
                                    }
                                    ForEach(turn.toolWarnings, id: \.self) { warning in
                                        Text(warning).atlasFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
                                    }
                                    if !turn.citations.isEmpty {
                                        Text("来源").atlasFont(.caption.weight(.semibold))
                                        ForEach(turn.citations, id: \.url) { citation in
                                            Link(destination: citation.url) {
                                                Text(citation.title + " · " + (citation.url.host ?? ""))
                                                    .atlasFont(.caption).lineLimit(2)
                                            }
                                        }
                                    }
                                    AssistantCopyMenu(turn: turn)
                                } else {
                                    AssistantMarkdownView(turn.text, plain: true)
                                    if turn.state != .complete {
                                        Text(turn.state == .pending ? "等待回答…" : turn.state == .failed ? "请求失败 · 问题已保留" : "请求已中止 · 问题已保留")
                                            .atlasFont(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }.atlasPadding(12).background(.quaternary.opacity(turn.role == "user" ? 0.7 : 0.25),
                                                       in: RoundedRectangle(cornerRadius: 12 * uiScale))
                                .id(turn.id)
                        }
                    }
                }.onChange(of: assistant.turns.count) { _, _ in
                    if let last = assistant.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
        }
    }

    private var scopePicker: some View {
        Picker("询问范围", selection: Binding(get: { assistant.scope }, set: {
            guard !assistant.busy, assistant.scope != $0 else { return }
            assistant.scope = $0; assistant.prepare(map: map)
        })) {
            ForEach(AssistantScope.allCases) { Text($0.title).tag($0) }
        }.labelsHidden()
    }
}

#if os(macOS)
struct AssistantPlacementMenu: View {
    @EnvironmentObject private var map: RailwayMapStore
    @EnvironmentObject private var assistant: AssistantStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        Menu {
            ForEach(AssistantPresentation.allCases) { position in
                Button {
                    assistant.setPresentation(position, map: map)
                    if position == .window { openWindow(id: "railway-assistant") }
                    else {
                        openWindow(id: "main-map")
                        dismissWindow(id: "railway-assistant")
                    }
                } label: {
                    Label(position.title, systemImage: assistant.settings.presentation == position ? "checkmark" : "rectangle")
                }
            }
        } label: { Image(systemName: "rectangle.on.rectangle") }
        .menuStyle(.borderlessButton).fixedSize()
        .help("助手显示位置").accessibilityLabel("助手显示位置")
    }
}
#endif

@MainActor
enum AssistantClipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
    static func copyFormatted(_ markdown: String) {
        let value = AssistantRichText.render(markdown, scale: 1)
        #if os(macOS)
        writeFormatted(value, to: .general)
        #else
        var item: [String: Any] = [UTType.utf8PlainText.identifier: value.string]
        if let rtf = AssistantRichText.documentData(value, type: .rtf) { item[UTType.rtf.identifier] = rtf }
        if let html = AssistantRichText.documentData(value, type: .html) { item[UTType.html.identifier] = html }
        UIPasteboard.general.setItems([item])
        #endif
    }
    #if os(macOS)
    @discardableResult
    static func writeFormatted(_ value: NSAttributedString, to board: NSPasteboard) -> Bool {
        board.clearContents()
        board.setString(value.string, forType: .string)
        guard let rtf = AssistantRichText.documentData(value, type: .rtf),
              let html = AssistantRichText.documentData(value, type: .html) else { return false }
        return board.setData(rtf, forType: .rtf) && board.setData(html, forType: .html)
    }
    #endif
}

struct AssistantCopyMenu: View {
    let turn: AssistantTurn
    @State private var copied = false

    var body: some View {
        Menu {
            Button("复制回答（Markdown）", systemImage: "doc.on.doc") {
                AssistantClipboard.copy(AssistantConversationMarkdown.turn(turn))
                copied = true
            }
            Button("复制回答（纯文本）", systemImage: "doc.plaintext") {
                AssistantClipboard.copy(AssistantConversationMarkdown.plainText(turn))
                copied = true
            }
            Button("复制回答（格式化文本）", systemImage: "doc.richtext") {
                AssistantClipboard.copyFormatted(AssistantConversationMarkdown.turn(turn))
                copied = true
            }
        } label: {
            Label(copied ? "已复制" : "复制回答",
                  systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .menuStyle(.borderlessButton)
        .atlasFont(.caption)
        .help("纯文本用于普通粘贴；格式化文本保留样式；Markdown 保留源语法。也可用鼠标选取部分正文复制。")
    }
}
