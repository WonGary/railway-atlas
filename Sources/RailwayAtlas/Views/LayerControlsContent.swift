import RailwayCore
import SwiftUI

/// The host owns scrolling. Short titles are prepared with the map data and
/// published as store.urbanRouteTitles, keyed by the unchanged visibilityKey.
struct LayerControlsContent: View {
    @Environment(\.atlasUIScale) private var uiScale
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: RailwayMapStore
    @State private var collapsedSections: Set<LayerControlsSection>
    @State private var routeFilter = ""
    let compactLabels: Bool

    init(compactLabels: Bool = false) {
        self.compactLabels = compactLabels
        // Smoke launches neither read nor write the user's disclosure choices.
        let saved = CommandLine.arguments.contains("--ui-smoke") ? [] :
            UserDefaults.standard.stringArray(forKey: Self.collapsePreferenceKey) ?? []
        _collapsedSections = State(initialValue: Set(saved.compactMap(LayerControlsSection.init(rawValue:))))
    }

    private static let collapsePreferenceKey = "railway.layers.collapsedSections.v1"

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            section(.basemap) { basemapControls }
            Divider()
            section(.visibility) { visibilityControls }
            Divider()
            section(.national) { nationalOverviewControls }
            Divider()
            section(.speeds) {
                ForEach(RailCategory.speedCategories) { category in categoryToggle(category) }
            }
            Divider()
            section(.purpose) {
                ForEach(RailCategory.allCases.filter { !RailCategory.speedCategories.contains($0) }) { category in
                    categoryToggle(category)
                }
            }
            Divider()
            section(.networks) {
                urbanTransitControls
                ForEach(RailNetwork.allCases) { network in networkToggle(network) }
            }
            Divider()
            section(.colours) { colourControls }
            Divider()
            section(.routes) { routeControls }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .atlasFont(.subheadline)
        .onChange(of: collapsedSections) { _, value in
            guard !CommandLine.arguments.contains("--ui-smoke") else { return }
            UserDefaults.standard.set(value.map(\.rawValue).sorted(), forKey: Self.collapsePreferenceKey)
        }
        .accessibilityIdentifier("layer-controls-content")
    }

    private func section<Content: View>(
        _ section: LayerControlsSection, @ViewBuilder content: () -> Content
    ) -> some View {
        let collapsed = collapsedSections.contains(section)
        return VStack(alignment: .leading, spacing: 10 * uiScale) {
            Button {
                // Disclosure actions must never touch category/network/route
                // visibility, automatic detail, or forced-visibility overrides.
                if collapsed { collapsedSections.remove(section) }
                else { collapsedSections.insert(section) }
            } label: {
                HStack(spacing: 7 * uiScale) {
                    Image(systemName: collapsed ? "plus" : "minus")
                        .atlasFont(.system(size: 11, weight: .semibold))
                        .atlasFrame(width: 18, height: 22)
                        .foregroundStyle(.secondary)
                    LayerControlsText(value: section.title, font: .subheadline.weight(.semibold))
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(collapsed ? "展开" : "收起")\(section.title)")
            .accessibilityValue(collapsed ? "已折叠" : "已展开")
            .accessibilityIdentifier("layer-section-\(section.rawValue)")
            .help("只\(collapsed ? "展开" : "收起")控件，不改变图层显示")
            if !collapsed { content() }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var basemapControls: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            Picker("底图", selection: $store.basemapStyle) {
                ForEach(BasemapStyle.allCases) { Text($0.title).tag($0) }
            }
            .foregroundStyle(.primary)
            // AppKit menu cells can retain their old text colour after an
            // appearance change. Refresh only this control, never the map.
            .id(colorScheme)
            .disabled(store.mapMode != .apple)
            Picker("标准地图来源", selection: $store.standardBasemapSource) {
                ForEach(BasemapSource.standardChoices) { source in
                    Text(source.title).tag(source)
                }
            }
            .foregroundStyle(.primary)
            .id(colorScheme)
            .disabled(store.mapMode != .apple)
            if store.standardBasemapSource == .custom {
                BasemapTemplateEditor(title: "标准地图瓦片地址", value: $store.customStandardTileTemplate)
                    .disabled(store.mapMode != .apple)
            }
            Picker("卫星地图来源", selection: $store.satelliteBasemapSource) {
                ForEach(BasemapSource.satelliteChoices) { source in
                    Text(source.title).tag(source)
                }
            }
            .foregroundStyle(.primary)
            .id(colorScheme)
            .disabled(store.mapMode != .apple)
            if store.satelliteBasemapSource == .custom {
                BasemapTemplateEditor(title: "卫星地图瓦片地址", value: $store.customSatelliteTileTemplate)
                    .disabled(store.mapMode != .apple)
            }
            Text(store.activeBasemapStatus)
                .atlasFont(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4 * uiScale) {
                HStack {
                    Text("底图暗化").atlasFont(.caption)
                    Spacer(minLength: 0)
                    Text("\(Int(store.basemapDarkness * 100))%")
                        .atlasFont(.caption.monospacedDigit())
                }
                Slider(value: $store.basemapDarkness, in: 0...1, step: 0.01)
                    .accessibilityLabel("底图暗化")
            }
            .disabled(store.mapMode != .apple)
            settingToggle("车站位置", isOn: $store.showsStations)
            settingToggle("站区细节", isOn: $store.showsStationLayouts)
            if store.showsStationLayouts {
                VStack(alignment: .leading, spacing: 5 * uiScale) {
                    settingToggle("车站轮廓 · Z14", isOn: $store.showsStationOutlines)
                    settingToggle("站厅轮廓 · Z15", isOn: $store.showsConcourses)
                    settingToggle("站台（面、线或点）· Z15", isOn: $store.showsPlatforms)
                    settingToggle("乘客通道 · Z16", isOn: $store.showsPassengerPassages)
                    settingToggle("站台号 · Z16", isOn: $store.showsPlatformNumbers)
                    settingToggle("出入口与方向 · Z16", isOn: $store.showsStationEntrances)
                    settingToggle("通道标识 · Z16", isOn: $store.showsPassageSigns)
                }.padding(.leading, 10 * uiScale)
                Text(store.stationLayoutHint).atlasFont(.caption2).foregroundStyle(.secondary)
                if store.displayZoom >= 16 && store.mapMode == .apple {
                    Button("重新查询当前站区") { store.scheduleStationLayouts(force: true) }.disabled(store.loadingLayouts || store.stationLayoutTarget == nil)
                    if store.currentLayoutStatus != "" { Text(store.currentLayoutStatus).atlasFont(.caption2) }
                }
            }
            settingToggle("放大后显示站名", isOn: $store.showsLabels)
            Picker("坐标对齐", selection: Binding<String>(get: {
                store.automaticAlignment ? "auto" : store.alignment.rawValue
            }, set: { choice in
                store.automaticAlignment = choice == "auto"
                store.alignment = MapAlignment(rawValue: choice) ?? store.activeBasemapSource.defaultAlignment
            })) {
                Text("随底图来源").tag("auto")
                ForEach(MapAlignment.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .foregroundStyle(.primary)
            .id(colorScheme)
            .atlasFont(.caption)
            .help("Apple 底图默认对大陆及港澳纠偏；无需港澳纠偏时可选“仅大陆”。台湾及境外保持原样，缓存始终为 WGS84。")
        }
    }

    private var visibilityControls: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            settingToggle("随缩放自动调整图层", isOn: $store.automaticDetail)
            HStack(spacing: 8 * uiScale) {
                Button("全部显示") {
                    store.forcedCategories = Set(RailCategory.allCases)
                    store.categories = Set(RailCategory.allCases)
                }
                .help("打开全部速度、用途与状态类别；网络和整线开关保持独立")
                Spacer(minLength: 0)
                Button("仅高铁") {
                    store.categories = [.speed350, .speed300, .speed250, .speed200]
                }
                .help("选择高铁速度类别；都市轨道交通优先显示和整线开关保持独立")
            }
            .atlasFont(.caption)
            .atlasControlSize(.small)
        }
    }

    private var nationalOverviewControls: some View {
        VStack(alignment: .leading, spacing: 7 * uiScale) {
            Toggle(isOn: $store.showsNationalMetroOverview) {
                LayerControlsText(value: "全国城市轨道概览", font: .subheadline)
            }
            .toggleStyle(.switch)
            .atlasControlSize(.small)
            .accessibilityIdentifier("layer-national-metro-overview")
            note("全国简化线路的数据加载与绘制总开关。关闭后，都市轨道交通优先显示也不会重新开启概览；详细轨道继续按网络分类和都市优先设置显示。")
            if store.mapMode == .offline {
                note("本地地图包不包含全国概览，请切换到全国在线或缓存模式。")
            } else {
                HStack(alignment: .top, spacing: 6 * uiScale) {
                    if store.nationalMetroLoading { ProgressView().atlasControlSize(.mini) }
                    note(store.nationalMetroStatus)
                }
            }
        }
    }

    private var urbanTransitControls: some View {
        VStack(alignment: .leading, spacing: 7 * uiScale) {
            Toggle(isOn: $store.prioritizesUrbanTransit) {
                HStack(alignment: .top, spacing: 7 * uiScale) {
                    Image(systemName: "tram.fill")
                        .foregroundStyle(Color.railwayAccent)
                    LayerControlsText(value: "都市轨道交通", font: .subheadline.weight(.semibold))
                }
            }
            .toggleStyle(.switch)
            .atlasControlSize(.small)
            .tint(.railwayAccent)
            .accessibilityIdentifier("layer-urban-transit-priority")
            .help("优先显示地铁、轻轨、单轨、电车及有明确都市／通勤服务标记的铁路，可越过网络和速度分类。全国概览、整线隐藏、站点、缩放和线路状态仍由各自开关控制。")
            note("开启时优先显示都市交通；关闭后恢复各分类设置。")
        }
        .atlasPadding(10)
        .atlasPanelDecoration(Color.railwayAccent.opacity(store.prioritizesUrbanTransit ? 0.16 : 0.08),
                              in: RoundedRectangle(cornerRadius: 9 * uiScale), border: Color.railwayAccent.opacity(0.3))
    }

    private func categoryToggle(_ category: RailCategory) -> some View {
        Toggle(isOn: Binding(
            get: { store.categoryVisible(category) },
            set: { store.setCategory(category, visible: $0) }
        )) {
            HStack(alignment: .top, spacing: 7 * uiScale) {
                LayerControlsLegendSample(category: category)
                    .atlasFrame(width: 28, height: 14)
                VStack(alignment: .leading, spacing: 2 * uiScale) {
                    LayerControlsText(value: category.title, font: .caption)
                    if category == .construction {
                        note("铁路黄色虚线 · 城市轨道灰白虚线")
                    }
                    if store.automaticDetail && store.categories.contains(category) && !store.categoryVisible(category) {
                        note("自动隐藏 · Z\(RailDisplayPolicy.minimumZoom(category))+ 显示")
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .atlasControlSize(.small)
        .tint(category.tint)
        .accessibilityIdentifier("layer-category-\(category.rawValue)")
    }

    private func networkToggle(_ network: RailNetwork) -> some View {
        Toggle(isOn: Binding(
            get: { store.networkVisible(network) },
            set: { store.setNetwork(network, visible: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2 * uiScale) {
                LayerControlsText(value: network.title, font: .subheadline)
                if store.automaticDetail && store.networks.contains(network) && !store.networkVisible(network) {
                    note("自动隐藏 · Z\(RailDisplayPolicy.minimumZoom(network))+ 显示")
                }
            }
        }
        .toggleStyle(.switch)
        .atlasControlSize(.small)
        .accessibilityIdentifier("layer-network-\(network.rawValue)")
    }

    private var colourControls: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            settingToggle("地铁线路色", isOn: $store.showsMetroColors)
            settingToggle("自动补充百科线路色", isOn: $store.enrichWikiColours)
            HStack(alignment: .top, spacing: 6 * uiScale) {
                if store.wikiColourLoading { ProgressView().atlasControlSize(.mini) }
                note(store.wikiColourStatus)
            }
        }
    }

    private var routeControls: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            if store.urbanRoutes.isEmpty {
                note("当前没有已载入的城市轨道线路，放大到城市后可逐线开关。")
            } else {
                Button {
                    store.hiddenRoutes = []
                    store.categories.insert(.urban)
                    store.networks.formUnion([.metro, .lightRail, .tram])
                } label: {
                    LayerControlsText(value: "显示全部地铁线路", font: .caption)
                }
                .atlasControlSize(.small)
                if store.urbanRoutes.count > 30 {
                    TextField("搜索城市或线路", text: $routeFilter)
                        .textFieldStyle(.roundedBorder)
                        .atlasFont(.caption)
                }
                LazyVStack(alignment: .leading, spacing: 8 * uiScale) {
                    ForEach(filteredRoutes, id: \.visibilityKey) { route in
                        routeToggle(route)
                    }
                }
            }
        }
    }

    private var filteredRoutes: [RailRoute] {
        let query = routeFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.urbanRoutes }
        return store.urbanRoutes.filter {
            (store.urbanRouteTitles[$0.visibilityKey] ?? "").localizedCaseInsensitiveContains(query)
                || $0.name.localizedCaseInsensitiveContains(query)
                || ($0.tags["network"] ?? "").localizedCaseInsensitiveContains(query)
                || ($0.tags["atlas:overviewCity"] ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private func routeToggle(_ route: RailRoute) -> some View {
        // No city/palette matching here. A missing cached label falls back to
        // the full name, so incomplete hooks cannot invent a disambiguation.
        let title = compactLabels ? store.urbanRouteTitles[route.visibilityKey] ?? route.name : route.name
        let fullTitle = MetroRouteTitle.full(route)
        return Toggle(isOn: Binding(
            get: { !store.hiddenRoutes.contains(route.visibilityKey) },
            set: { visible in
                if visible {
                    store.hiddenRoutes.remove(route.visibilityKey)
                    store.categories.insert(.urban)
                } else {
                    store.hiddenRoutes.insert(route.visibilityKey)
                }
            }
        )) {
            HStack(alignment: .top, spacing: 7 * uiScale) {
                Circle()
                    .fill(route.color?.tint ?? .clear)
                    .atlasFrame(width: 11, height: 11)
                    .overlay(Circle().stroke(.secondary.opacity(0.5), lineWidth: 0.5))
                    .atlasPadding(.top, 2)
                    .accessibilityLabel(route.color.map { "线路色 \($0.hex)" } ?? "线路色未提供")
                LayerControlsText(value: title.isEmpty ? "未命名线路" : title,
                                  font: .subheadline.monospacedDigit())
            }
        }
        .toggleStyle(.switch)
        .atlasControlSize(.small)
        .tint(route.color?.tint ?? .railwayAccent)
        .help(fullTitle)
        .accessibilityLabel(fullTitle)
        .accessibilityIdentifier("layer-route-\(route.visibilityKey)")
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { LayerControlsText(value: title, font: .subheadline) }
            .toggleStyle(.switch)
            .atlasControlSize(.small)
    }

    private func note(_ value: String) -> some View {
        LayerControlsText(value: value, font: .caption2)
            .foregroundStyle(.secondary)
    }
}

private struct BasemapTemplateEditor: View {
    let title: String
    @Binding var value: String
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $draft, prompt: Text("https://example.com/{z}/{x}/{y}.png"))
                .textFieldStyle(.roundedBorder).onSubmit { apply() }
            if draft != value {
                if BasemapSource.validatedTemplate(draft) != nil {
                    Button("使用这个地址") { apply() }
                } else {
                    Text("使用含 {z}、{x}、{y} 的 HTTPS 地址，请移除账号和密钥。").foregroundStyle(.secondary)
                }
            }
        }.atlasFont(.caption)
            .onAppear { draft = value }
            .onChange(of: value) { _, newValue in draft = newValue }
    }
    private func apply() {
        if let valid = BasemapSource.validatedTemplate(draft) { value = valid }
    }
}

private enum LayerControlsSection: String, CaseIterable {
    case basemap, visibility, national, speeds, purpose, networks, colours, routes
    var title: String {
        switch self {
        case .basemap: "底图与站点"
        case .visibility: "自动显示与预设"
        case .national: "全国城市轨道"
        case .speeds: "铁路速度"
        case .purpose: "用途与状态"
        case .networks: "轨道网络"
        case .colours: "线路配色"
        case .routes: "城市轨道线路"
        }
    }
}

private struct LayerControlsText: View {
    let value: String
    let font: AtlasFont
    var body: some View {
        Text(verbatim: value)
            .atlasFont(font)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

private struct LayerControlsLegendSample: View {
    @Environment(\.atlasUIScale) private var uiScale
    @EnvironmentObject private var store: RailwayMapStore
    let category: RailCategory
    var body: some View {
        Canvas { context, size in
            let samples: [(RailAppearance, CGFloat)] = category == .construction
                ? [(RailAppearance(category: .construction, colors: []), size.height * 0.28),
                   (RailAppearance(category: .construction, colors: [], isUrbanLifecycle: true), size.height * 0.72)]
                : [(RailAppearance(category: category, colors: []), size.height / 2)]
            for (appearance, y) in samples {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                for stroke in appearance.strokes(zoom: 12, settings: store.renderSettings) {
                    context.stroke(path, with: .color(stroke.color.tint),
                                   style: StrokeStyle(lineWidth: stroke.width * uiScale,
                                                      dash: stroke.dash.map { CGFloat($0) * uiScale }))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
