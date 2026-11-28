import RailwayCore
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Drop-in content for the existing inspector's vertical ScrollView.
/// The host owns panel sizing; this view also fits a 200pt panel with its padding.
struct FeatureInspectorContent: View {
    #if os(iOS)
    @EnvironmentObject private var configuration: ConfigurationStore
    #endif
    @Environment(\.atlasUIScale) private var uiScale
    @EnvironmentObject private var store: RailwayMapStore
    @EnvironmentObject private var assistant: AssistantStore
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var showsInformation = false
    #if !os(macOS)
    @State private var showsStationDirectory = false
    @State private var returnToTrainMap = false
    private var stationBoardInitialDate: Date {
        #if os(iOS) && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--station-board-ui"), arguments.contains("--ui-smoke"),
           let date = ISO8601DateFormatter().date(from: "2026-11-26T12:00:00+08:00") {
            return date
        }
        #endif
        return .now
    }
    #endif
    @State private var showsRawFields = false
    let item: RailwaySelection

    var body: some View {
        let model = FeatureInspectorModel(
            item: item,
            line: store.line(withID: item.id),
            station: store.station(withID: item.id),
            interchange: store.interchange(forStationID: item.id)
        )
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            heading(model)
            if model.isStation {
                if !store.historyMapActive {
                    Button("查看站区细节", systemImage: "map") {
                        store.focusStationLayouts(at: item.coordinate)
                    }
                    .accessibilityIdentifier("focus-station-layouts")
                    .help("放大到本站，查看已收录的站厅、站台和通道")
                }
                if !["subway", "tram", "light_rail", "monorail"].contains(model.tags["station"] ?? model.tags["railway"] ?? "") {
                    let name = model.tags["name:zh-Hans"] ?? model.tags["name:zh"] ?? model.name
                    #if os(macOS)
                    StationInspectorBoard(name: name).id(item.id)
                    #else
                    Button {
                        showsStationDirectory = true
                    } label: {
                        Label("全线站点与本站车次", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("open-station-directory")
                    .sheet(isPresented: $showsStationDirectory, onDismiss: {
                        if returnToTrainMap {
                            returnToTrainMap = false
                            NotificationCenter.default.post(name: .railGameDidOpenMap, object: nil)
                        }
                    }) {
                        StationTravelDirectory(name: name, initialDate: stationBoardInitialDate) { timetable, track in
                            try store.journeyPlayer.start(timetable, route: track)
                            returnToTrainMap = true
                            showsStationDirectory = false
                        }
                        .atlasMapSheet(mode: configuration.interfaceSettings.surfaceMode,
                                      opacity: configuration.interfaceSettings.stationBoardOpacity)
                    }
                    #endif
                }
            }
            Divider()
            if let id = store.lineFocus?.directionID, let entry = store.directions.entries[id] {
                MetroDirectionInspector(entry: entry)
                Divider()
            } else if let focus = store.lineFocus, focus.routeKey != nil, !focus.paths.isEmpty {
                FeatureInspectorText(value: "已显示线路走向。这个方向暂无详细站序。", font: .caption)
            }
            essentials(model)
            routeSection(model)
            interchangeSection(model)
            if !model.countries.isEmpty {
                ForEach(model.countries) { country in
                    FeatureInspectorFact(title: country.title, value: country.displayValue)
                }
            }
            actions(model)
            Divider()
            rawFields(model)
        }
        .atlasPadding(10)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .accessibilityIdentifier("feature-inspector-content")
        #endif
        .onChange(of: item.id) { _, _ in
            showsInformation = false
            showsRawFields = false
        }
    }

    private func heading(_ model: FeatureInspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 5 * uiScale) {
            FeatureInspectorText(value: model.name, font: .system(size: 17, weight: .semibold))
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if !model.subtitle.isEmpty {
                FeatureInspectorText(value: model.subtitle, font: .caption)
                    .foregroundStyle(.secondary)
            }
            // A separate, bounded row keeps the name readable at minimum width.
            HStack(spacing: 2 * uiScale) {
                Button { store.toggleFavorite(item.id) } label: {
                    toolbarIcon(store.isFavorite(item) ? "star.fill" : "star")
                        .foregroundStyle(.orange)
                }
                .accessibilityLabel(store.isFavorite(item) ? "取消收藏" : "收藏")
                .help(store.isFavorite(item) ? "取消收藏" : "收藏")
                .accessibilityIdentifier("feature-inspector-favorite")
                Button { showsInformation.toggle() } label: {
                    toolbarIcon("questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("查看关联依据、数据说明与来源")
                .help("关联依据、数据缺失、坐标纠偏与来源")
                .accessibilityIdentifier("feature-inspector-information")
                .popover(isPresented: $showsInformation, arrowEdge: .leading) {
                    information(model)
                        .presentationCompactAdaptation(.popover)
                }
                Spacer(minLength: 0)
                Button { store.selection = nil } label: {
                    toolbarIcon("xmark")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("关闭详情")
                .help("关闭详情")
            }
            .buttonStyle(.plain)
        }
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .atlasFont(.system(size: 13))
            .frame(width: max(24, 22 * uiScale), height: max(24, 24 * uiScale))
            .contentShape(Rectangle())
    }

    private func essentials(_ model: FeatureInspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            VStack(alignment: .leading, spacing: 2 * uiScale) {
                FeatureInspectorText(value: "最高标注速度", font: .caption2)
                    .foregroundStyle(.secondary)
                // Text can wrap the unit, unlike an intrinsic-width metric HStack.
                (
                    Text(verbatim: model.speedText)
                        .atlasFont(.system(size: model.speed == nil ? 14 : 23, weight: .semibold).monospacedDigit(),
                                   scale: uiScale)
                    + Text(model.speed == nil ? "" : " km/h")
                        .atlasFont(.caption, scale: uiScale)
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 3 * uiScale) {
                FeatureInspectorText(value: model.usesRouteOperators ? "所属线路运营方" : "运营方", font: .caption2)
                    .foregroundStyle(.secondary)
                FeatureInspectorText(value: model.operators.isEmpty ? "未标注" : model.operators.joined(separator: "\n"),
                                     font: .subheadline.weight(.semibold))
                    .textSelection(.enabled)
                if let mark = model.operatorMark {
                    FeatureInspectorText(value: "标记 · \(mark)", font: .caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func routeSection(_ model: FeatureInspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 6 * uiScale) {
            FeatureInspectorText(value: model.interchange != nil ? "换乘关联线路" : model.featureColor != nil ? "要素标注色" :
                                    (model.isStation ? "关联线路" : "所属线路"), font: .caption2)
                .foregroundStyle(.secondary)
            if let id = model.item.osmReference, model.isStation,
               let directions = store.directions.byStop[id] {
                ForEach(directions.filter { d in
                    !(model.interchange?.documentedRoutes ?? model.routes).contains { $0.id == d.id }
                }) { direction in focusButton(direction.route, compact: false) }
            }
            if let group = model.interchange {
                ForEach(group.documentedRoutes, id: \.visibilityKey) { route in
                    focusButton(route, compact: true)
                }
                if !group.possibleRoutes.isEmpty {
                    FeatureInspectorText(value: "同名邻近站 · 换乘待核实", font: .caption2)
                        .foregroundStyle(.secondary)
                    ForEach(group.possibleRoutes, id: \.visibilityKey) { route in
                        focusButton(route, compact: true)
                    }
                }
            } else if !model.routes.isEmpty {
                // Do not truncate to the first four routes or join by route name.
                ForEach(Array(model.routes.enumerated()), id: \.offset) { _, route in
                    focusButton(route, compact: false)
                }
            } else if let color = model.featureColor {
                HStack(alignment: .top, spacing: 7 * uiScale) {
                    FeatureInspectorSwatch(color: color)
                    FeatureInspectorText(value: color.hex, font: .caption.monospaced())
                        .textSelection(.enabled)
                }
            } else if store.directions.byStop[model.item.osmReference ?? ""] == nil {
                FeatureInspectorText(value: "未提供线路记录", font: .caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func routeTitle(_ route: RailRoute) -> String {
        store.urbanRouteTitles[route.visibilityKey] ?? MetroRouteTitle.short(route)
    }

    private func focusButton(_ route: RailRoute, compact: Bool) -> some View {
        Button { store.focusRelation(route) } label: {
            FeatureInspectorRouteMarker(route: route, compactTitle: compact ? routeTitle(route) : nil)
        }.buttonStyle(.plain).help("查看\(routeTitle(route))的线路走向和站点")
    }

    @ViewBuilder
    private func interchangeSection(_ model: FeatureInspectorModel) -> some View {
        if let group = model.interchange {
            VStack(alignment: .leading, spacing: 7 * uiScale) {
                FeatureInspectorText(value: "关联站点", font: .caption2)
                    .foregroundStyle(.secondary)
                ForEach(group.peers) { peer in
                    Button {
                        store.select(RailwayMapStore.item(peer.station))
                    } label: {
                        VStack(alignment: .leading, spacing: 3 * uiScale) {
                            HStack(alignment: .top, spacing: 5 * uiScale) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .atlasFont(.caption)
                                FeatureInspectorText(value: peer.station.name, font: .caption.weight(.medium))
                            }
                            let titles = Array(Set((peer.station.routes ?? []).map(routeTitle)))
                                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                            if !titles.isEmpty {
                                FeatureInspectorText(value: titles.joined(separator: " · "), font: .caption)
                            }
                            let distance = MapAlignment.distance(item.coordinate, peer.station.coordinate)
                            FeatureInspectorText(
                                value: "\(Int(distance.rounded())) m · " +
                                    (peer.confidence == .possible ? "同名邻近站" :
                                        peer.evidence.contains(where: { $0.kind == .official }) ? "官方换乘资料" : "站区关联"),
                                font: .caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .atlasPadding(7)
                        .atlasPanelDecoration(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("定位此独立站点；关联依据见问号")
                }
                FeatureInspectorText(value: group.passageNotice, font: .caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("feature-interchange")
        }
    }

    private func actions(_ model: FeatureInspectorModel) -> some View {
        VStack(spacing: 6 * uiScale) {
            Button {
                assistant.focus(map: store, scope: .feature)
                #if os(macOS)
                assistant.show(map: store)
                if assistant.settings.presentation == .window { openWindow(id: "railway-assistant") }
                #else
                store.showAssistant = true
                #endif
            } label: {
                actionLabel("询问 GPT", icon: "sparkles")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("feature-inspector-ask-gpt")
            if let url = model.osmURL {
                Link(destination: url) {
                    actionLabel("查看 OSM", icon: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("在 OpenStreetMap 查看")
            }
        }
        .atlasControlSize(.small)
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 5 * uiScale) {
            Image(systemName: icon)
            FeatureInspectorText(value: title, font: .caption)
        }
        .atlasFont(.caption)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func rawFields(_ model: FeatureInspectorModel) -> some View {
        DisclosureGroup(isExpanded: $showsRawFields) {
            VStack(alignment: .leading, spacing: 10 * uiScale) {
                FeatureInspectorTagList(title: "要素 OSM 标签", tags: FeatureInspectorModel.osmTags(model.tags))
                ForEach(Array(model.routes.enumerated()), id: \.offset) { _, route in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6 * uiScale) {
                            FeatureInspectorText(value: route.id, font: .caption2.monospaced())
                                .textSelection(.enabled)
                            FeatureInspectorTagList(title: "线路 OSM 标签",
                                                    tags: FeatureInspectorModel.osmTags(route.tags))
                        }
                    } label: {
                        FeatureInspectorText(value: route.name, font: .caption)
                    }
                }
            }
            .atlasPadding(.top, 6)
        } label: {
            FeatureInspectorText(value: "原始 OSM 字段", font: .caption)
        }
        .atlasFont(.caption)
        .id(item.id)
        .accessibilityIdentifier("feature-inspector-raw-fields")
    }

    private func information(_ model: FeatureInspectorModel) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14 * uiScale) {
                FeatureInspectorText(value: "要素资料说明", font: .headline)
                    .accessibilityAddTraits(.isHeader)
                if let group = model.interchange {
                    informationSection("换乘与站区关联依据") {
                        FeatureInspectorText(value: "各站点保留自己的位置、线路和收藏；此处汇总可关联的线路与站点。",
                                             font: .caption)
                        ForEach(Array(group.evidence.enumerated()), id: \.offset) { _, evidence in
                            VStack(alignment: .leading, spacing: 4 * uiScale) {
                                FeatureInspectorFact(title: evidenceTitle(evidence.kind), value: evidence.value)
                                FeatureInspectorText(value: evidence.stationIDs.joined(separator: "\n"),
                                                     font: .caption2.monospaced())
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                                if let url = evidence.sourceURL {
                                    informationLink("查看官方资料", url: url)
                                } else if let url = FeatureInspectorModel.osmURL(reference: evidence.value) {
                                    informationLink("查看 OSM 站区关系", url: url)
                                }
                                ForEach(evidence.supportingURLs, id: \.absoluteString) { url in
                                    informationLink("查看补充来源", url: url)
                                }
                            }
                        }
                        FeatureInspectorText(value: group.passageNotice, font: .caption)
                    }
                }
                informationSection("线路关联依据") {
                    FeatureInspectorText(value: model.associationExplanation, font: .caption)
                    FeatureInspectorText(value: "只展示选中要素已载入的线路记录。共线、多重身份及方向关系分别保留；记录可能不完整。",
                                         font: .caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(model.routes.enumerated()), id: \.offset) { _, route in
                        VStack(alignment: .leading, spacing: 4 * uiScale) {
                            FeatureInspectorRouteMarker(route: route)
                            FeatureInspectorText(value: route.id, font: .caption2.monospaced())
                                .textSelection(.enabled)
                            if let evidence = FeatureInspectorModel.nonempty(route.tags["atlas:routeMatch"]) {
                                FeatureInspectorText(value: evidence, font: .caption)
                            }
                            if let url = FeatureInspectorModel.osmURL(reference: route.id) {
                                informationLink("查看 OSM 线路关系", url: url)
                            }
                        }
                    }
                }
                informationSection("数据缺失与字段含义") {
                    FeatureInspectorText(value: "“未标注”表示当前数据没有该字段，不表示实际不存在。名称、属性和线路关联均可能缺失或过时。",
                                         font: .caption)
                    FeatureInspectorText(value: "速度取 maxspeed、maxspeed:forward、maxspeed:backward 中可解析数值的最大值，默认 km/h，mph 换算后显示；不从地图分级或设计速度推断运营速度。",
                                         font: .caption)
                    if !model.speedFields.isEmpty {
                        FeatureInspectorTagList(title: "速度原值", tags: model.speedFields)
                    }
                    if model.usesRouteOperators {
                        FeatureInspectorText(value: "所选要素没有运营方字段，主页面显示的是其关联线路的运营方，不能据此确认该要素的运营归属。",
                                             font: .caption)
                    }
                    FeatureInspectorText(value: "国旗仅由明确国家字段中的有效两位国家代码生成。运营方仅显示已有名称和文字标记；当前没有接入经核实的运营方图标资源。",
                                         font: .caption)
                    FeatureInspectorText(value: "原始字段区展示当前载入的 OSM 标签。数据处理可能补充或归一化字段；atlas: 补充记录（含可用的原始色）列在下方。",
                                         font: .caption)
                }
                informationSection("坐标纠偏") {
                    coordinateInformation
                }
                informationSection("数据与线路色来源") {
                    FeatureInspectorFact(title: "要素来源", value: model.sourceName)
                    if model.tags["atlas:nationalOverview"] == "yes" {
                        FeatureInspectorText(value: "概览为简化后的地理线路，不含车站及完整轨道标签。运营状态以最新运营方资料为准；放大可载入详细 OSM 要素。",
                                             font: .caption)
                    }
                    if let source = FeatureInspectorModel.nonempty(model.tags["source"]) {
                        FeatureInspectorFact(title: "source 字段", value: source)
                    }
                    if let url = model.osmURL {
                        informationLink("OpenStreetMap 要素", url: url)
                    } else {
                        FeatureInspectorText(value: "未提供有效 OSM 要素编号。", font: .caption)
                    }
                    if let url = FeatureInspectorModel.webURL(model.tags["atlas:snapshotURL"]) {
                        informationLink("内置快照来源", url: url)
                    }
                    if store.mapMode == .offline, let dataset = store.dataset {
                        FeatureInspectorFact(title: "本地地图包", value: dataset.name)
                        if let url = FeatureInspectorModel.webURL(dataset.sourceURL) {
                            informationLink("地图包数据来源", url: url)
                        }
                    }
                    if model.routes.isEmpty, let color = model.featureColor {
                        FeatureInspectorFact(title: "要素 colour / color 字段", value: color.hex)
                    }
                    ForEach(Array(model.routes.enumerated()), id: \.offset) { _, route in
                        VStack(alignment: .leading, spacing: 4 * uiScale) {
                            FeatureInspectorText(value: route.name, font: .caption.weight(.semibold))
                            if let color = route.color {
                                FeatureInspectorText(value: color.hex, font: .caption.monospaced())
                                    .textSelection(.enabled)
                                if let url = FeatureInspectorModel.webURL(route.colorSourceURL.absoluteString) {
                                    informationLink(route.colorSourceName, url: url)
                                } else {
                                    FeatureInspectorText(value: route.colorSourceName, font: .caption)
                                }
                            } else {
                                FeatureInspectorText(value: "线路色未提供；空心标记仅表示缺失。", font: .caption)
                            }
                        }
                    }
                }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10 * uiScale) {
                        FeatureInspectorFact(title: "要素 ID", value: item.id)
                        FeatureInspectorTagList(title: "要素补充记录",
                                                tags: FeatureInspectorModel.applicationTags(model.tags))
                        ForEach(Array(model.routes.enumerated()), id: \.offset) { _, route in
                            FeatureInspectorTagList(title: "\(route.name) · \(route.id)",
                                                    tags: FeatureInspectorModel.applicationTags(route.tags))
                        }
                    }
                } label: {
                    FeatureInspectorText(value: "应用补充字段", font: .caption)
                }
            }
            .atlasPadding(14)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .atlasFont(.caption)
        .frame(width: 300 * min(uiScale, 1.3), height: 440 * min(uiScale, 1.3))
        .accessibilityIdentifier("feature-inspector-information-popover")
    }

    private var coordinateInformation: some View {
        VStack(alignment: .leading, spacing: 6 * uiScale) {
            if item.coordinate.isValid {
                FeatureInspectorFact(title: "原始 WGS84 纬度",
                                     value: String(format: "%.6f", item.coordinate.latitude))
                FeatureInspectorFact(title: "原始 WGS84 经度",
                                     value: String(format: "%.6f", item.coordinate.longitude))
                if store.mapMode == .apple {
                    let display = store.alignment.display(item.coordinate)
                    FeatureInspectorFact(title: "显示策略", value: store.alignment.title)
                    FeatureInspectorFact(title: "显示偏移",
                                         value: String(format: "%.0f m", MapAlignment.distance(item.coordinate, display)))
                    FeatureInspectorFact(title: "底图显示坐标",
                                         value: String(format: "%.6f\n%.6f", display.latitude, display.longitude))
                    FeatureInspectorText(value: "纠偏只作用于 Apple 底图显示，原始坐标和缓存保持 WGS84。显示偏移不代表测量误差。",
                                         font: .caption)
                } else {
                    FeatureInspectorText(value: "当前地图模式使用原始 WGS84 坐标，未应用 Apple 底图纠偏。", font: .caption)
                }
            } else {
                FeatureInspectorText(value: "所选要素没有有效坐标，无法计算显示偏移。", font: .caption)
            }
        }
    }

    private func informationSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7 * uiScale) {
            FeatureInspectorText(value: title, font: .subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func informationLink(_ title: String, url: URL) -> some View {
        Link(destination: url) {
            FeatureInspectorText(value: title, font: .caption)
        }
    }

    private func evidenceTitle(_ kind: StationInterchangeEvidence.Kind) -> String {
        switch kind {
        case .official: "官方换乘资料"
        case .stopArea: "OSM 站区"
        case .stopAreaGroup: "OSM 换乘站组"
        case .wikidata: "同一站点 Wikidata 条目"
        case .wikipedia: "同一站点百科条目"
        case .nameContextNearby: "同名、同城市或网络、邻近位置 · 待核实"
        }
    }
}

/// All data text accepts the parent's proposed width, including long OSM keys,
/// URLs, unspaced names and copyable values. No raster or root view scaling.
private struct FeatureInspectorText: View {
    let value: String
    let font: AtlasFont
    var body: some View {
        Text(verbatim: value)
            .atlasFont(font)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

private struct FeatureInspectorFact: View {
    @Environment(\.atlasUIScale) private var scale
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            FeatureInspectorText(value: title, font: .caption2)
                .foregroundStyle(.secondary)
            FeatureInspectorText(value: value, font: .caption)
                .textSelection(.enabled)
        }
    }
}

private struct FeatureInspectorRouteMarker: View {
    @Environment(\.atlasUIScale) private var scale
    let route: RailRoute
    var compactTitle: String? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 7 * scale) {
            FeatureInspectorSwatch(color: route.color)
            VStack(alignment: .leading, spacing: 2 * scale) {
                FeatureInspectorText(value: compactTitle ?? FeatureInspectorModel.nonempty(route.name) ?? "未命名线路",
                                     font: .caption.weight(.semibold))
                    .textSelection(.enabled)
                if compactTitle == nil, let ref = FeatureInspectorModel.nonempty(route.tags["ref"]), ref != route.name {
                    FeatureInspectorText(value: ref, font: .caption2)
                        .foregroundStyle(.secondary)
                }
                if route.color == nil {
                    FeatureInspectorText(value: "颜色未标注", font: .caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

private struct FeatureInspectorSwatch: View {
    let color: RailColor?
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color?.tint ?? .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.secondary.opacity(color == nil ? 0.6 : 0.3), lineWidth: 0.5)
            }
            .atlasFrame(width: 10, height: 18)
            .accessibilityLabel(color.map { "线路色 \($0.hex)" } ?? "颜色未标注")
    }
}

private struct FeatureInspectorTagList: View {
    @Environment(\.atlasUIScale) private var scale
    let title: String
    let tags: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            FeatureInspectorText(value: title, font: .caption.weight(.semibold))
            if tags.isEmpty {
                FeatureInspectorText(value: "没有可用字段", font: .caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    FeatureInspectorClipboard.copy(FeatureInspectorModel.tagJSON(tags))
                } label: {
                    Label {
                        FeatureInspectorText(value: "复制全部", font: .caption)
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                .buttonStyle(.borderless)
                .atlasControlSize(.small)
                .accessibilityLabel("复制\(title)的全部字段")
                .help("复制这一组完整字段，保留原始键和值")
                ForEach(tags.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 2 * scale) {
                        FeatureInspectorText(value: key, font: .caption2.monospaced())
                            .foregroundStyle(.secondary)
                        FeatureInspectorText(value: tags[key] ?? "", font: .caption)
                    }
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("复制字段") { FeatureInspectorClipboard.copy("\(key)=\(tags[key] ?? "")") }
                        Button("复制值") { FeatureInspectorClipboard.copy(tags[key] ?? "") }
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private enum FeatureInspectorClipboard {
    static func copy(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = value
        #endif
    }
}
