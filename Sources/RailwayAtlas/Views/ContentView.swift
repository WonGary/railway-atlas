import MapKit
import RailwayCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif
    private var uiScale: Double { store.uiScale }
    @EnvironmentObject private var store: RailwayMapStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var configuration: ConfigurationStore
    @State private var showPanel = false

    var body: some View {
        Group {
            #if os(macOS)
            AtlasInterface(scale: store.uiScale) {
                DesktopMapWorkspace()
            }
            .frame(minWidth: 960, minHeight: 650)
            #else
            AtlasInterface(scale: store.uiScale) { MapScreen() }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        showPanel = true
                    } label: {
                        HStack(spacing: 12 * uiScale) {
                            RailwayAtlasMark(size: 42 * uiScale)
                            VStack(alignment: .leading, spacing: 3 * uiScale) {
                                Text(store.selection?.name ?? "探索铁道图鉴").atlasFont(.headline)
                                Text("搜索 · 图层 · 离线地图").atlasFont(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.up")
                        }
                        .atlasPadding(12)
                        .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                         opacity: configuration.interfaceSettings.bottomCounterOpacity,
                                         cornerRadius: 24 * uiScale)
                    }
                    .buttonStyle(.plain)
                    .atlasPadding(.horizontal, 12)
                    .atlasPadding(.bottom, 8)
                }
                .sheet(isPresented: $showPanel) {
                    AtlasInterface(scale: store.uiScale) { SidebarView() }
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
                .onChange(of: store.selection?.id) { _, value in
                    if value != nil { showPanel = true }
                }
                .onReceive(NotificationCenter.default.publisher(for: .railGameDidOpenMap)) { _ in showPanel = false }
            #endif
        }
        .tint(.railwayAccent)
        .sheet(isPresented: $store.showSettings) { AtlasSettingsView() }
        #if os(macOS)
        .onChange(of: assistant.settings.presentation) { _, position in
            assistant.setPresentation(position, map: store)
            if position == .window { openWindow(id: "railway-assistant") }
            else { dismissWindow(id: "railway-assistant") }
        }
        #endif
        #if !os(macOS)
        .sheet(isPresented: $store.showAssistant) { AtlasAssistantView() }
        #endif
        .task {
            await store.start()
            if RailGamesAcceptance.requested {
                await RailGamesAcceptance.run(store: store, showDiscovery: {
                    store.selectedTab = 0
                    showPanel = true
                })
                return
            }
            #if os(macOS)
            await OnlineUIValidation.runIfRequested(store: store, assistant: assistant)
            #endif
        }
        .fileImporter(isPresented: $store.showImporter, allowedContentTypes: [.json, .data]) { result in
            switch result {
            case .success(let url): store.importFile(url)
            case .failure(let error): store.showMessage(error.localizedDescription, error: true)
            }
        }
        .fileExporter(isPresented: $store.showExporter, document: store.exportFile,
                      contentType: .json, defaultFilename: "RailwayAtlas-区域地图") { result in
            switch result {
            case .success: store.showMessage("地图包已导出，可在另一台设备导入。")
            case .failure(let error): store.showMessage(error.localizedDescription, error: true)
            }
        }
        .fileImporter(isPresented: $store.showCacheImporter, allowedContentTypes: [.railwayCache, .database, .data]) { result in
            switch result {
            case .success(let url): store.importCache(url)
            case .failure(let error): store.showMessage(error.localizedDescription, error: true)
            }
        }
        .fileExporter(isPresented: $store.showCacheExporter, document: store.cacheFile,
                      contentType: .railwayCache, defaultFilename: "RailwayAtlas-浏览缓存") { result in
            switch result {
            case .success: store.showMessage("缓存数据库已导出，可在另一台设备导入。")
            case .failure(let error): store.showMessage(error.localizedDescription, error: true)
            }
        }
        .onOpenURL { url in
            if url.scheme == "railwayatlas", url.host == "map" { store.changeMode(.apple) }
            #if os(macOS)
            if url.scheme=="railwayatlas",url.host=="timetable-sync",let id=UUID(uuidString:url.lastPathComponent) {
                Task {
                    do {try await BrowserTimetableShare.shared.start(id:id,library:store.journeyWorkspace.library)}
                    catch {store.showMessage(error.localizedDescription,error:true)}
                }
            }
            #endif
        }
    }
}

struct SidebarView: View {
    var floating = false
    @Environment(\.atlasUIScale) private var uiScale
    @EnvironmentObject private var store: RailwayMapStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0 * uiScale) {
            HStack(spacing: (floating ? 8 : 10) * uiScale) {
                RailwayAtlasMark(size: (floating ? 26 : 51) * uiScale)
                VStack(alignment: .leading, spacing: 3 * uiScale) {
                    Text("铁道图鉴").atlasFont(.system(size: floating ? 15 : 22, weight: .semibold))
                    if !floating {
                        Text("RAILWAY ATLAS").tracking(2.5 * uiScale).atlasFont(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if floating {
                    Menu {
                        Picker("浮窗大小", selection: $store.panelSize) {
                            ForEach(MapPanelSize.allCases) { Text($0.title + "浮窗").tag($0) }
                        }
                        Divider()
                        Button("隐藏左侧浮窗") { store.panelVisible = false }
                    } label: {
                        Label(store.panelSize.title, systemImage: "rectangle.expand.vertical")
                            .atlasFont(.caption)
                    }.menuStyle(.borderlessButton).fixedSize()
                        .help("调整左侧浮窗大小")
                        .accessibilityIdentifier("left-panel-size")
                    Button { store.panelVisible = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).atlasFont(.caption)
                        .help("隐藏左侧浮窗").accessibilityLabel("隐藏左侧浮窗")
                } else {
                    Button { store.showSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("界面与问答设置")
                }
            }
            .atlasPadding(.top, floating ? 14 : 36)
            .atlasPadding(.bottom, floating ? 12 : 20)

            HStack(spacing: 8 * uiScale) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索城市、车站、线路", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let city = store.matchingPlaces.first { store.goTo(city) }
                        else if let first = store.results.first { store.select(first) }
                        else { store.searchPlaces() }
                    }
                    .onChange(of: store.searchText) { _, _ in store.placeResults = [] }
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .atlasPadding(11)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11 * uiScale))
            .atlasPadding(.bottom, floating ? 10 : 16)

            Picker("面板", selection: $store.selectedTab) {
                Text("探索").tag(0)
                Text("图层").tag(1)
                Text("缓存").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .atlasPadding(.bottom, floating ? 10 : 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 20 * uiScale) {
                    #if !os(macOS)
                    if let selection = store.selection { FeatureDetails(item: selection) }
                    #endif
                    if !store.searchText.isEmpty {
                        searchResults
                    } else {
                        switch store.selectedTab {
                        case 1: LayerControls()
                        case 2: DataControls()
                        default: DiscoveryView()
                        }
                    }
                    if let message = store.message {
                        HStack(alignment: .top, spacing: 8 * uiScale) {
                            Image(systemName: store.isError ? "exclamationmark.circle" : "checkmark.circle")
                                .foregroundStyle(store.isError ? .orange : .green)
                            Text(message).atlasFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button { store.message = nil } label: { Image(systemName: "xmark").atlasFont(.caption2) }
                                .buttonStyle(.plain).accessibilityLabel("关闭提示")
                        }
                        .atlasPadding(12)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12 * uiScale))
                    }
                }
                .atlasPadding(.vertical, 4)
            }
            .scrollIndicators(.hidden)

            if !floating {
              VStack(alignment: .leading, spacing: 6 * uiScale) {
                Divider().atlasPadding(.bottom, 6)
                HStack(spacing: 6 * uiScale) {
                    Image(systemName: store.mapMode.icon)
                    Text(store.mapMode.title)
                    Spacer()
                }
                .atlasFont(.caption2).foregroundStyle(.secondary)
            }
              .atlasPadding(.vertical, 12)
            }
        }
        .atlasPadding(.horizontal, floating ? 14 : 18)
        .atlasPadding(.bottom, floating ? 10 : 0)
        .accessibilityIdentifier("left-map-panel")
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            if !store.matchingPlaces.isEmpty {
                SectionCaption(title: "城市", detail: "点击查看轨道网络")
                ForEach(store.matchingPlaces) { place in
                    Button { store.goTo(place) } label: {
                        Label(place.name, systemImage: "building.2").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            SectionCaption(title: "车站与线路", detail: store.mapMode == .offline ? "当前地图包" : "已加载视野")
            if store.results.isEmpty {
                Text("没有找到匹配项。\n可尝试中文、拼音或线路编号。")
                    .atlasFont(.subheadline).foregroundStyle(.secondary).atlasPadding(.vertical, 12)
            }
            ForEach(store.results) { item in
                FeatureRow(item: item)
            }
            if store.mapMode == .apple {
                Button { store.searchPlaces() } label: {
                    Label(store.isSearchingPlaces ? "正在搜索…" : "联网搜索其他地点", systemImage: "magnifyingglass")
                }.disabled(store.isSearchingPlaces)
                ForEach(store.placeResults) { FeatureRow(item: $0) }
            }
        }
    }

}

struct SectionCaption: View {
    @Environment(\.atlasUIScale) private var uiScale
    let title: String
    var detail: String = ""
    var body: some View {
        HStack {
            Text(title).atlasFont(.system(size: 12, weight: .semibold))
            Spacer()
            Text(detail).atlasFont(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct FeatureRow: View {
    @Environment(\.atlasUIScale) private var uiScale
    @EnvironmentObject private var store: RailwayMapStore
    let item: RailwaySelection
    var body: some View {
        Button { store.select(item) } label: {
            HStack(spacing: 10 * uiScale) {
                Image(systemName: item.isStation ? "tram" : "point.topleft.down.to.point.bottomright.curvepath")
                    .atlasFont(.system(size: 15)).foregroundStyle(Color.railwayAccent)
                    .atlasFrame(width: 34, height: 34)
                    .background(Color.railwayAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10 * uiScale))
                VStack(alignment: .leading, spacing: 3 * uiScale) {
                    Text(item.name).atlasFont(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(item.subtitle).atlasFont(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 1)
                if store.isFavorite(item) {
                    Image(systemName: "star.fill").atlasFont(.caption2).foregroundStyle(.orange)
                }
                Image(systemName: "chevron.right").atlasFont(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .atlasPadding(.vertical, 7).atlasPadding(.horizontal, 4)
            .background(store.selection?.id == item.id ? Color.railwayAccent.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 10 * uiScale))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LayerControls: View {
    var body: some View { LayerControlsContent(compactLabels: true) }
}

struct DataControls: View {
    @Environment(\.atlasUIScale) private var uiScale
    @EnvironmentObject private var store: RailwayMapStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SectionCaption(title: "浏览方式", detail: "联网 / 本地")
            Picker("浏览方式", selection: Binding(get: { store.mapMode }, set: { store.changeMode($0) })) {
                ForEach(MapMode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            Text("在线浏览时自动保存铁路矢量数据。缓存模式完全不发起地图网络请求；Apple 街道底图不包含在铁路缓存中。")
                .atlasFont(.caption).foregroundStyle(.secondary)
            Divider()
            SectionCaption(title: "全国地铁概览", detail: "本地可用")
            Toggle("显示全国城市轨道概览", isOn: $store.showsNationalMetroOverview)
                .toggleStyle(.switch).atlasControlSize(.small)
                .help("独立控制全国地铁、轻轨、单轨和有轨电车的简化线路；详细城市轨道仍由图层开关控制")
            Text(store.nationalMetroStatus)
                .atlasFont(.caption).foregroundStyle(.secondary)
            if store.showsNationalMetroOverview, let snapshot = store.nationalMetroSnapshot {
                Text("已取得配色 \(snapshot.colouredRouteCount)/\(snapshot.routeCount) · 未知颜色保留中性色")
                    .atlasFont(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                if store.nationalMetroLoading { ProgressView().atlasControlSize(.small) }
                Button("检查城轨增量更新") { store.refreshNationalMetroOverview() }
                    .disabled(store.nationalMetroLoading || store.nationalMetroWork != nil)
            }
            Text("手动检查发布版本，只下载有变化的城市或网络。更新需要联网，下载中仍可使用地图。")
                .atlasFont(.caption2).foregroundStyle(.secondary)
            MetroCityBrowser()
            Divider()
            SectionCaption(title: "本地缓存数据库", detail: "自动保存")
            HStack(alignment: .firstTextBaseline) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(store.cacheStats.allocatedBytes), countStyle: .file))
                    .atlasFont(.title2.weight(.semibold))
                Spacer()
                Text("\(store.cacheStats.count) 块").atlasFont(.caption).foregroundStyle(.secondary)
            }
            if store.cacheStats.count > 0 {
                Text("已保存缩放层级 Z\(store.cacheStats.minimumZoom)–Z\(store.cacheStats.maximumZoom)")
                    .atlasFont(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { store.showCacheImporter = true } label: { Label("导入数据库", systemImage: "square.and.arrow.down") }
                Button { store.prepareCacheExport() } label: { Image(systemName: "square.and.arrow.up") }
                    .help("导出缓存数据库").accessibilityLabel("导出缓存数据库")
                    .disabled(store.cacheStats.count == 0)
            }.disabled(store.isLoading)
            Text("缓存数据库上限 8 GiB（含索引和可复用空间），只保存浏览过的范围和层级。导入合并数据库，达到上限时清理最旧条目。")
                .atlasFont(.caption2).foregroundStyle(.secondary)
            if store.mapMode != .offline {
                Text(store.onlineStatus).atlasFont(.caption)
                if store.fallbackTiles > 0 {
                    Text("已自动使用备用源。基础瓦片不包含完整速度、用途与历史状态；灰色代表未知，不能据此判断线路等级。")
                        .atlasFont(.caption).foregroundStyle(.secondary)
                }
                if let error = store.onlineError {
                    Text(error).atlasFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Button { store.refreshViewport(force: true) } label: {
                    Label("更新当前视野", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(store.mapMode != .apple)
            }
            DisclosureGroup("数据服务 · 自动切换备用源") {
                VStack(alignment: .leading, spacing: 10 * uiScale) {
                    ForEach(store.sourceStates) { source in
                        VStack(alignment: .leading, spacing: 3 * uiScale) {
                            Text(source.name).atlasFont(.caption.weight(.medium))
                            Text(source.status).atlasFont(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Text("铁路主源较慢时，约 1 秒后启动备用源并采用先到的数据。地铁整线与轨道并行加载，失败自动换源。\n配色：官方表、Wikidata / Wikipedia、RMG 中文服务与 GitHub Pages、OSM。")
                        .atlasFont(.caption2).foregroundStyle(.secondary)
                    Text("全国地铁概览可本地显示；其他全国铁路使用主源或其缓存。备用车站需进一步放大。")
                        .atlasFont(.caption2).foregroundStyle(.secondary)
                    Divider()
                    Text("OpenRailwayMap 兼容矢量服务").atlasFont(.caption)
                    TextField("https://…", text: $store.sourceDraft).textFieldStyle(.roundedBorder)
                    Button("使用此服务") { store.applySource() }
                    Link("服务与缓存使用说明", destination: URL(string: "https://github.com/hiddewie/OpenRailwayMap-vector/blob/master/USAGE.md")!)
                        .atlasFont(.caption2)
                }.atlasPadding(.top, 8)
            }
            Divider()
            DisclosureGroup("兼容本地区域地图包") {
                VStack(alignment: .leading, spacing: 10 * uiScale) {
                    Text(store.dataset?.name ?? "尚无地图包").atlasFont(.caption)
                    HStack {
                        Button("导入 .railmap") { store.showImporter = true }
                        Button("导出") { store.prepareExport() }.disabled(store.dataset == nil)
                    }.disabled(store.isLoading)
                    Text("旧版上海区域包仍可使用；全国在线浏览独立加载数据。").atlasFont(.caption2).foregroundStyle(.secondary)
                }.atlasPadding(.top, 8)
            }
            if store.isLoading { ProgressView().atlasControlSize(.small) }
        }
    }
}

struct FeatureDetails: View {
    let item: RailwaySelection
    var body: some View { FeatureInspectorContent(item: item) }
}
