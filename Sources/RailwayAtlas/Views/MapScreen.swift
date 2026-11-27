import MapKit
import RailwayCore
import SwiftUI

private struct MapControlFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct StatusContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MapScreen: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    var desktopPanels: DesktopPanelLayout.Resolved?
    var onToggleDesktopPanel: ((DesktopPanelSide) -> Void)?
    var onActivateDesktopPanel: ((DesktopPanelSide) -> Void)?
    #endif
    @Environment(\.atlasUIScale) private var uiScale
    @EnvironmentObject private var store: RailwayMapStore
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var connectivity: Connectivity
    @EnvironmentObject private var configuration: ConfigurationStore
    @GestureState private var statusDrag = CGSize.zero
    @State private var controlFrames: [String: CGRect] = [:]
    @State private var statusContentHeight: CGFloat = 120
    @State private var startupCredit = true
    var body: some View {
      GeometryReader { geometry in
        ZStack {
            Group {
                if store.mapMode == .apple { AppleRailwayMap(store: store) }
                else { OfflineRailwayMap() }
            }
            #if !os(macOS)
            .ignoresSafeArea(.container, edges: .top)
            #endif

            VStack {
                if configuration.interfaceSettings.topControlsVisible {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 12 * uiScale) {
                            HStack(spacing: 4 * uiScale) {
                                #if os(macOS)
                                desktopPanelButton(.left)
                                #endif
                                mapButton("gearshape", title: "设置") { store.showSettings = true }
                                mapButton("sparkles", title: "询问地图") {
                                    if assistant.context.isEmpty {
                                        assistant.focus(map: store, scope: store.selection == nil ? .region : .feature)
                                    }
                                    #if os(macOS)
                                    assistant.show(map: store)
                                    if assistant.settings.presentation == .window { openWindow(id: "railway-assistant") }
                                    #else
                                    store.showAssistant = true
                                    #endif
                                }
                                #if os(macOS)
                                desktopPanelButton(.right)
                                #endif
                                mapButton("chevron.up", title: "收起顶部地图控件") {
                                    configuration.interfaceSettings.topControlsVisible = false
                                }
                            }
                            .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                             opacity: configuration.interfaceSettings.topControlsOpacity,
                                             cornerRadius: 12 * uiScale)
                            if let focus = store.lineFocus {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(focus.title).atlasFont(.caption.weight(.semibold)).lineLimit(2)
                                        Button("恢复全图") { store.clearLineFocus() }
                                    }
                                    if let line = focus.inspectionDirectory {
                                        InspectionStationSequence(line: line, map: store).id(focus.revision)
                                    }
                                    if let note = focus.inspectionSummary {
                                        Text(note).atlasFont(.caption).fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: 236, alignment: .leading)
                                    }
                                }
                                .padding(7)
                                .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                                 opacity: configuration.interfaceSettings.topControlsOpacity,
                                                 cornerRadius: 8)
                            }
                            #if !os(macOS)
                            MapScaleView(width: geometry.size.width, height: geometry.size.height)
                            #endif
                            if store.activeBasemapNeedsNetwork && !connectivity.available {
                                Text(store.activeBasemapOfflineStatus).atlasFont(.caption).atlasPadding(8)
                                    .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                                     opacity: configuration.interfaceSettings.cornerControlsOpacity,
                                                     cornerRadius: 8 * uiScale)
                            }
                        }
                        .background(measureControl("scale"))
                        Spacer(minLength: 8)
                        VStack(spacing: 12 * uiScale) {
                            Menu {
                                ForEach(MapMode.allCases) { mode in
                                    Button { store.changeMode(mode) } label: {
                                        Label(mode.title, systemImage: store.mapMode == mode ? "checkmark" : mode.icon)
                                    }
                                }
                                Divider()
                                ForEach(BasemapStyle.allCases) { style in
                                    Button(style.title) {
                                        store.basemapStyle = style
                                        if store.mapMode != .apple { store.changeMode(.apple) }
                                    }
                                }
                                Divider()
                                Button(store.statusVisible ? "隐藏状态卡" : "显示状态卡") { store.statusVisible.toggle() }
                                Button("状态卡回到右上角") { store.statusOffset = .zero; store.statusVisible = true }
                            } label: { Image(systemName: "map").atlasFrame(width: 38, height: 38) }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                             opacity: configuration.interfaceSettings.cornerControlsOpacity,
                                             cornerRadius: 13 * uiScale)
                            .accessibilityLabel("切换地图模式")
                            .help("全国在线 / 缓存 / 本地地图包")

                            VStack(spacing: 0 * uiScale) {
                                mapButton("plus", title: "放大") { store.zoom(0.65) }
                                Divider().atlasFrame(width: 22)
                                mapButton("minus", title: "缩小") { store.zoom(1.55) }
                            }
                            .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                             opacity: configuration.interfaceSettings.cornerControlsOpacity,
                                             cornerRadius: 13 * uiScale)
                            mapButton("arrow.up.left.and.arrow.down.right", title: "显示全国 / 整个地图包") { store.fitDataset() }
                                .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                                 opacity: configuration.interfaceSettings.cornerControlsOpacity,
                                                 cornerRadius: 13 * uiScale)
                        }
                        .foregroundStyle(Color.railwayAccent)
                        .background(measureControl("navigation"))
                    }
                } else {
                    HStack {
                        mapButton("chevron.down", title: "显示顶部地图控件") {
                            configuration.interfaceSettings.topControlsVisible = true
                        }
                        .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                         opacity: configuration.interfaceSettings.cornerControlsOpacity,
                                         cornerRadius: 12 * uiScale)
                        Spacer()
                    }
                }
                Spacer()
                if configuration.interfaceSettings.bottomControlsVisible {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 9 * uiScale) {
                            #if os(macOS)
                            MapScaleView(width: geometry.size.width, height: geometry.size.height)
                            #endif
                            HStack(spacing: 7 * uiScale) {
                                Image(systemName: store.mapMode.icon)
                                Text("\(store.visibleLines.count) 区段 · \(store.visibleStations.count) 车站")
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .atlasFont(.system(size: 11, weight: .medium))
                            .atlasPadding(.horizontal, 12).atlasPadding(.vertical, 9)
                            .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                             opacity: configuration.interfaceSettings.bottomCounterOpacity,
                                             cornerRadius: 20 * uiScale)
                        }
                        Spacer()
                        mapButton("chevron.down", title: "收起底部地图控件") {
                            configuration.interfaceSettings.bottomControlsVisible = false
                        }
                        .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                         opacity: configuration.interfaceSettings.bottomCounterOpacity,
                                         cornerRadius: 12 * uiScale)
                        if store.mapMode != .apple {
                            VStack(alignment: .trailing, spacing: 4 * uiScale) {
                                Text("N ↑").atlasFont(.system(size: 12, weight: .semibold))
                                Text(store.mapMode == .cached ? "缓存铁路 · 无街道底图" : "本地地图包 · 无街道底图").atlasFont(.system(size: 9))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .background(measureControl("footer"))
                } else {
                    HStack {
                        Spacer()
                        mapButton("chevron.up", title: "显示底部地图控件") {
                            configuration.interfaceSettings.bottomControlsVisible = true
                        }
                        .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                         opacity: configuration.interfaceSettings.bottomCounterOpacity,
                                         cornerRadius: 12 * uiScale)
                    }
                }
            }
            .atlasPadding(20)
            // Reserve the MapKit attribution and compass areas.
            .atlasPadding(.bottom, store.mapMode == .apple ? 24 : 0)
            #if os(macOS)
            if let panels = desktopPanels {
                if !panels.leftFloatingFrame.isEmpty {
                    let frame = panels.leftFloatingFrame
                    DesktopSidebarPanel()
                        .frame(width: frame.width, height: frame.height)
                        .modifier(DesktopFloatingPanelSurface(
                            opacity: store.panelBackgroundOpacity,
                            surfaceMode: configuration.interfaceSettings.surfaceMode))
                        .overlay(alignment: .trailing) {
                            DesktopPanelResizeHandle(side: .left, displayedWidth: frame.width) {
                                onActivateDesktopPanel?(.left)
                            }
                        }
                        .position(x: frame.midX, y: frame.midY)
                }
                if !panels.rightFloatingFrame.isEmpty {
                    let frame = panels.rightFloatingFrame
                    AtlasInspectorView(onRequestClose: {
                        if let onToggleDesktopPanel { onToggleDesktopPanel(.right) }
                        else { store.inspectorVisible = false }
                    })
                        .frame(width: frame.width, height: frame.height)
                        .modifier(DesktopFloatingPanelSurface(
                            opacity: store.inspectorBackgroundOpacity,
                            surfaceMode: configuration.interfaceSettings.surfaceMode))
                        .overlay(alignment: .leading) {
                            DesktopPanelResizeHandle(side: .right, displayedWidth: frame.width) {
                                onActivateDesktopPanel?(.right)
                            }
                        }
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            #endif
            if store.statusVisible {
                let layout = statusLayout(size: geometry.size)
                if layout.frame.height >= 68 * uiScale {
                    statusCard(height: layout.frame.height, viewport: geometry.size)
                        .frame(width: layout.frame.width, height: layout.frame.height)
                        .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                         opacity: configuration.interfaceSettings.statusBackgroundOpacity,
                                         cornerRadius: 15 * uiScale)
                        .position(x: layout.frame.midX, y: layout.frame.midY)
                }
            }
            VStack {
                Spacer()
                if store.journeyPlayer.mode != nil {
                    if configuration.interfaceSettings.experienceControlsVisible {
                        MapExperienceControls(player: store.journeyPlayer)
                            .frame(maxWidth: 630).padding(.horizontal, 20).padding(.bottom, 76)
                    } else {
                        Button {
                            configuration.interfaceSettings.experienceControlsVisible = true
                        } label: {
                            Label("显示播放栏", systemImage: "chevron.up")
                                .atlasPadding(.horizontal, 12).atlasPadding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                                         opacity: configuration.interfaceSettings.playbackOpacity,
                                         cornerRadius: 12 * uiScale)
                        .padding(.bottom, 76)
                    }
                }
            }
        }
        .coordinateSpace(name: "railwayMapControls")
        .onPreferenceChange(MapControlFrames.self) { if controlFrames != $0 { controlFrames = $0 } }
        .onPreferenceChange(StatusContentHeight.self) {
            // Keep a point-size baseline so increasing UI scale cannot hide
            // a short card using its previous, smaller measurement.
            let height = $0 / uiScale
            if height > 0 && statusContentHeight != height { statusContentHeight = height }
        }
      }
        .clipped()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let source = store.mapMode == .apple ? store.activeBasemapSource : nil
            if startupCredit || source == .openStreetMap || source == .openFreeMap || source == .gaode {
                HStack(spacing: 8) {
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    if source == .openFreeMap {
                        Link("© OpenMapTiles", destination: URL(string: "https://openmaptiles.org/")!)
                    } else if source == .gaode {
                        Link("高德地图", destination: URL(string: "https://lbs.amap.com/")!)
                    }
                    Spacer()
                }
                .font(.caption2).padding(.horizontal, 8).padding(.vertical, 2)
                .background(.background).accessibilityIdentifier("basemap-credit-line")
            }
        }
        .simultaneousGesture(TapGesture().onEnded { startupCredit = false })
        .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in
            if startupCredit { startupCredit = false }
        })
        .task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { startupCredit = false }
        }
    }

    private func statusLayout(size: CGSize, drag: CGSize? = nil) -> MapStatusLayout {
        let delta = drag ?? statusDrag
        var obstacles = Array(controlFrames.values)
        #if os(macOS)
        // Use the current resolved frames, not measurements from the previous
        // layout pass, when either panel changes between floating and docked.
        obstacles.append(contentsOf: desktopPanels?.floatingFrames ?? [])
        #endif
        return MapStatusLayout(viewport: size, desired: CGSize(width: 260 * uiScale, height: (statusContentHeight + 57) * uiScale),
                               scale: uiScale, offset: CGSize(width: store.statusOffset.width + delta.width,
                                                             height: store.statusOffset.height + delta.height),
                               obstacles: obstacles)
    }

    #if os(macOS)
    private func desktopPanelButton(_ side: DesktopPanelSide) -> some View {
        let requested = side == .left ? store.panelVisible : store.inspectorVisible
        let visible = side == .left ? (desktopPanels?.leftVisible ?? false) : (desktopPanels?.rightVisible ?? false)
        let title = requested && !visible
            ? "优先显示" + side.title + "（当前窗口空间不足）"
            : (visible ? "隐藏" : "显示") + side.title
        return mapButton(side == .left ? "sidebar.left" : "sidebar.right", title: title) {
            if let onToggleDesktopPanel { onToggleDesktopPanel(side) }
            else if side == .left { store.panelVisible.toggle() }
            else { store.inspectorVisible.toggle() }
        }
        .accessibilityValue(visible ? "已显示" : (requested ? "空间不足，暂时收起" : "已隐藏"))
        .accessibilityIdentifier(side == .left ? "toggle-left-panel" : "toggle-right-panel")
    }
    #endif

    private func measureControl(_ key: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: MapControlFrames.self, value: [key: proxy.frame(in: .named("railwayMapControls"))])
        }
    }

    private func statusCard(height: Double, viewport: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 7 * uiScale) {
            HStack {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                Text(store.activeName).atlasFont(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Button { store.statusVisible = false } label: { Image(systemName: "xmark").atlasFont(.caption2) }
                    .buttonStyle(.plain).help("隐藏状态卡")
            }
            .frame(height: 24 * uiScale)
            .contentShape(Rectangle())
            .gesture(DragGesture().updating($statusDrag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    let layout = statusLayout(size: viewport, drag: value.translation)
                    store.statusOffset = CGSize(width: layout.frame.minX - layout.anchor.x, height: layout.frame.minY - layout.anchor.y)
                })
            ScrollView(.vertical) {
                statusDetails
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: StatusContentHeight.self, value: proxy.size.height)
                    })
            }
            .frame(height: max(0, height - 57 * uiScale))
        }.atlasPadding(13)
    }

    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: 7 * uiScale) {
            Text(store.mapMode == .offline ? "本地矢量地图" : store.onlineStatus).atlasFont(.caption2).foregroundStyle(.secondary)
            if store.mapMode != .offline && store.showsNationalMetroOverview
                && store.displayZoom < 8 && store.categories.contains(.urban) {
                Text(store.nationalMetroStatus).atlasFont(.caption2).foregroundStyle(.secondary)
            }
            if store.mapMode != .offline && store.tileZoom >= 10 {
                HStack(spacing: 5 * uiScale) {
                    if store.metroLoading { ProgressView().atlasControlSize(.mini) }
                    Text(store.metroStatus).atlasFont(.caption2).foregroundStyle(.secondary)
                }
            }
            if store.onlineLoading && store.mapMode == .apple {
                ProgressView(value: Double(store.tilesReady), total: Double(max(1, store.tilesExpected)))
            }
            if store.mapMode != .offline && (store.failedTiles > 0 || store.onlineError != nil || store.metroNeedsRetry) {
                HStack {
                    Label(store.mapMode == .cached ? "部分层级未缓存" : "部分数据待补齐", systemImage: "exclamationmark.circle")
                        .atlasFont(.caption2).foregroundStyle(.orange)
                    Spacer()
                    if store.mapMode == .apple { Button("重试") { store.retryViewport() }.atlasFont(.caption2) }
                }
            }
            if store.showsMetroPreview { Text("南昌整线预览 · 联网后更新").atlasFont(.caption2).foregroundStyle(.secondary) }
            if store.fallbackTiles > 0 { Text("备用源已启用，保留已知线路属性").atlasFont(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func mapButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).atlasFrame(width: 38, height: 38) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .help(title)
    }
}

struct OfflineRailwayMap: View {
    @Environment(\.atlasUIScale) private var uiScale
    @EnvironmentObject private var store: RailwayMapStore
    @Environment(\.colorScheme) private var scheme
    @GestureState private var drag = CGSize.zero
    @GestureState private var magnification = 1.0

    var body: some View {
        GeometryReader { geometry in
            let projection = RailProjection(region: store.region, size: geometry.size, drag: drag, magnification: magnification)
            Canvas { context, size in
                let background = scheme == .dark ? Color(red: 0.09, green: 0.12, blue: 0.15) : Color.railwayCanvas
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
                drawGrid(context: &context, size: size, projection: projection)
                if store.mapMode == .cached && store.region.span.longitudeDelta > 2 && store.showsLabels {
                    for city in AtlasPlace.presets {
                        let point = projection.screen(city.coordinate)
                        guard CGRect(origin: .zero, size: size).contains(point) else { continue }
                        context.draw(Text(city.name).atlasFont(.system(size: 11), scale: uiScale).foregroundStyle(.secondary),
                                     at: CGPoint(x: point.x + 5, y: point.y - 10), anchor: .leading)
                    }
                }
                let zoom = RailDisplayPolicy.zoom(longitudeSpan: projection.visibleRegion.span.longitudeDelta, width: size.width)
                if store.basemapDarkness > 0 {
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(store.basemapDarkness)))
                }
                let details = store.stationLayouts(in: projection.visibleBounds, zoom: zoom)
                for kind in [StationLayoutKind.outline, .concourse] {
                    for feature in details where feature.kind == kind {
                        feature.draw(&context, projection: projection, dark: scheme == .dark)
                    }
                }
                for group in store.historyMapActive ? [] : store.renderGroups {
                    let path = Path(group.path).applying(projection.transform)
                    draw(path, appearance: group.appearance, context: &context)
                }
                for feature in details where feature.kind == .platform || feature.kind == .passage || feature.kind == .entrance {
                    feature.draw(&context, projection: projection, dark: scheme == .dark)
                }
                let focus = store.historyMapActive ? nil : store.lineFocus
                if let focus {
                    context.fill(Path(CGRect(origin:.zero,size:size)), with:.color(background.opacity(0.75)))
                    var path = Path()
                    for part in focus.paths {
                        guard let first = part.first else { continue }
                        path.move(to: projection.screen(first))
                        for p in part.dropFirst() { path.addLine(to: projection.screen(p)) }
                    }
                    context.stroke(path, with:.color(.white), style:StrokeStyle(lineWidth:7,lineCap:.round,lineJoin:.round))
                    context.stroke(path, with:.color((focus.pathColor ?? store.renderSettings.focusInk).tint), style:StrokeStyle(lineWidth:4.4,lineCap:.round,lineJoin:.round))
                    for layer in focus.inspectionLayers {
                        var ink = Path()
                        for part in layer.parts {
                            guard let first = part.first else { continue }
                            ink.move(to: projection.screen(first))
                            for point in part.dropFirst() { ink.addLine(to: projection.screen(point)) }
                        }
                        let style = layer.ink.stroke
                        context.stroke(ink, with: .color(.white), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                        context.stroke(ink, with: .color(style.color.tint), style: StrokeStyle(lineWidth: style.width,
                                       lineCap: .round, lineJoin: .round, dash: style.dash.map { CGFloat($0) }))
                    }
                    let groups = Dictionary(grouping: store.focusedLines(focus), by: store.appearance)
                    let styled = groups.map { appearance, lines in
                        var track = Path()
                        for line in lines { addLine(line, to: &track, projection: projection) }
                        return (appearance, track)
                    }
                    for (_, track) in styled {
                        context.stroke(track, with:.color(.white), style:StrokeStyle(lineWidth:7,lineCap:.round,lineJoin:.round))
                    }
                    for (appearance, track) in styled {
                        draw(track, appearance: appearance, context: &context, focused: true)
                    }
                }
                let numbers = store.layoutLabels(in: projection.visibleBounds, zoom: zoom,
                    screen: CGRect(origin: .zero, size: size), project: projection.screen)
                for number in numbers {
                    var context = context
                    if focus != nil { context.opacity = 0.25 }
                    if number.kind != .platform {
                        let ink = number.kind.ink(dark: scheme == .dark)
                        if let start = number.leaderStart {
                            var leader = Path()
                            leader.move(to: start)
                            leader.addLine(to: number.point)
                            context.stroke(leader, with: .color(ink), lineWidth: uiScale)
                        }
                        let circle = Path(ellipseIn: number.frame)
                        context.fill(circle, with: .color(scheme == .dark ? Color(red: 0.10, green: 0.13, blue: 0.18) : .white))
                        context.stroke(circle, with: .color(ink), lineWidth: 1.5 * uiScale)
                        let text = Text(verbatim: number.text).font(.system(size: 10 * uiScale, weight: .bold).monospacedDigit()).foregroundStyle(ink)
                        context.draw(context.resolve(text), at: number.point)
                        continue
                    }
                    let ink: Color = scheme == .dark ? .white : Color(red: 0.05, green: 0.20, blue: 0.19)
                    let glyph = Text(verbatim: number.text).font(.system(size: 11 * uiScale, weight: .semibold).monospacedDigit())
                    let edge = context.resolve(glyph.foregroundStyle(scheme == .dark ? Color.black : Color.white))
                    for offset in [CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1), CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0)] {
                        context.draw(edge, at: CGPoint(x: number.point.x + offset.x, y: number.point.y + offset.y))
                    }
                    context.draw(context.resolve(glyph.foregroundStyle(ink)), at: number.point)
                }
                var labels = numbers.map(\.frame)
                let stations = (store.historyMapActive ? [] : store.visibleStations).sorted {
                    if let focus, focus.includes($0) != focus.includes($1) { return focus.includes($0) }
                    return ($0.id == store.selection?.id ? 0 : 1) < ($1.id == store.selection?.id ? 0 : 1)
                }
                for station in stations {
                    var context = context
                    let member = focus?.includes(station) == true
                    if focus != nil && !member { context.opacity = 0.25 }
                    let point = projection.screen(station.coordinate)
                    guard CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20).contains(point) else { continue }
                    let selected = station.id == store.selection?.id
                    let style = store.stationAppearance(station)
                    let radius = style.radius
                    let dot = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                    context.fill(dot, with: .color(style.filled ? style.colors[0].tint : background))
                    for (index, color) in style.colors.enumerated() {
                        var arc = Path()
                        arc.addArc(center: point, radius: radius - style.ringWidth / 2,
                                   startAngle: .degrees(Double(index) / Double(style.colors.count) * 360),
                                   endAngle: .degrees(Double(index + 1) / Double(style.colors.count) * 360), clockwise: false)
                        context.stroke(arc, with: .color(color.tint), lineWidth: style.ringWidth)
                    }
                    if style.doubleRing {
                        let inner = Path(ellipseIn: CGRect(x: point.x - radius * 0.45, y: point.y - radius * 0.45,
                                                         width: radius * 0.9, height: radius * 0.9))
                        context.stroke(inner, with: .color(style.filled ? .white : .secondary), lineWidth: style.ringWidth * 0.5)
                    }
                    guard store.showsLabels && (member || RailDisplayPolicy.labelVisible(station, zoom: store.displayZoom) || selected) else { continue }
                    let text = context.resolve(Text(station.name)
                        .atlasFont(StationLabelStyle.font(style.kind, selected: selected), scale: uiScale)
                        .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Color(red: 0.21, green: 0.28, blue: 0.30)))
                    let textSize = text.measure(in: CGSize(width: 180 * uiScale, height: 24 * uiScale))
                    let rect = CGRect(x: point.x + radius + 4 * uiScale, y: point.y - 11 * uiScale,
                                      width: textSize.width + 8 * uiScale, height: 22 * uiScale)
                    guard !labels.contains(where: { $0.intersects(rect.insetBy(dx: -5, dy: -4)) }) else { continue }
                    labels.append(rect)
                    context.draw(text, at: CGPoint(x: rect.minX + 4 * uiScale, y: rect.midY), anchor: .leading)
                }
                for line in store.experienceLines {
                    var context = context
                    if focus != nil { context.opacity = 0.25 }
                    guard let first = line.coordinates.first else { continue }
                    var path = Path()
                    path.move(to: projection.screen(first))
                    for p in line.coordinates.dropFirst() { path.addLine(to: projection.screen(p)) }
                    let color = (line.colour.flatMap(RailColor.init) ?? store.renderSettings.focusInk).tint
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: line.uncertain ? 2 : 4,
                        lineCap: .round, dash: line.uncertain ? [4, 5] : []))
                }
                if let place = store.ridePlace {
                    let p = projection.screen(.init(place.lat,place.lon))
                    context.draw(Text(Image(systemName:"mappin.circle.fill")).foregroundColor(.teal), at:p)
                    context.draw(Text(place.name).font(.caption).foregroundColor(.primary),
                                 at:CGPoint(x:p.x+10,y:p.y), anchor:.leading)
                }
                if let point = store.experienceMarker {
                    let p = projection.screen(point)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)), with: .color(store.renderSettings.focusInk.tint))
                    context.draw(Text(Image(systemName: "tram.fill")).font(.system(size: 18)).foregroundColor(.white), at: p)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onChanged { value in
                        store.journeyPlayer.userPanned()
                        let next = RailProjection(region: store.region, size: geometry.size, drag: value.translation)
                        store.rebuildVisible(in: next.visibleBounds)
                    }
                    .onEnded { value in
                        let next = RailProjection(region: store.region, size: geometry.size, drag: value.translation)
                        store.viewportChanged(next.visibleRegion, width: geometry.size.width, height: geometry.size.height)
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($magnification) { value, state, _ in
                        if !store.journeyPlayer.holdsZoom { state = value.magnification }
                    }
                    .onChanged { value in
                        guard !store.journeyPlayer.holdsZoom else { return }
                        let next = RailProjection(region: store.region, size: geometry.size, magnification: value.magnification)
                        store.rebuildVisible(in: next.visibleBounds)
                    }
                    .onEnded { value in store.zoom(1 / value.magnification) }
            )
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in selectNearest(value.location, projection: projection) }
            )
            .accessibilityLabel("离线铁路地图。可以拖动、捏合缩放，也可使用放大缩小按钮。")
            .task(id: geometry.size) {
                store.viewportChanged(store.region, width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private func draw(_ path: Path, appearance: RailAppearance, context: inout GraphicsContext, focused: Bool = false) {
        let strokes = focused ? appearance.focusStrokes(zoom: store.displayZoom, settings: store.renderSettings) :
            appearance.strokes(zoom: store.displayZoom, settings: store.renderSettings)
        for stroke in strokes {
            context.stroke(path, with: .color(stroke.color.tint),
                           style: StrokeStyle(lineWidth: stroke.width,
                                              lineCap: stroke.dash.isEmpty ? .round : .butt, lineJoin: .round,
                                              dash: stroke.dash.map { CGFloat($0) }, dashPhase: CGFloat(stroke.phase)))
        }
    }

    private func addLine(_ line: RailLine, to path: inout Path, projection: RailProjection) {
        guard let first = line.coordinates.first else { return }
        path.move(to: projection.screen(first))
        for coordinate in line.coordinates.dropFirst() { path.addLine(to: projection.screen(coordinate)) }
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize, projection: RailProjection) {
        let spacing: CGFloat = 80
        let origin = projection.screen(Coordinate(0, 0))
        var grid = Path()
        for x in stride(from: origin.x.truncatingRemainder(dividingBy: spacing), to: size.width, by: spacing) {
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: origin.y.truncatingRemainder(dividingBy: spacing), to: size.height, by: spacing) {
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.07)), lineWidth: 0.6)
    }

    private func selectNearest(_ point: CGPoint, projection: RailProjection) {
        guard !store.historyMapActive else { return }
        if let station = store.visibleStations.min(by: {
            distance(projection.screen($0.coordinate), point) < distance(projection.screen($1.coordinate), point)
        }), distance(projection.screen(station.coordinate), point) < 22 {
            store.select(RailwayMapStore.item(station))
            return
        }
        var nearest: (RailLine, CGFloat)?
        for line in store.visibleLines {
          for segment in store.clippedGeometry[line.id] ?? [] {
            for pair in zip(segment, segment.dropFirst()) {
                let value = segmentDistance(point, projection.screen(pair.0), projection.screen(pair.1))
                if value < 9 && value < (nearest?.1 ?? .infinity) { nearest = (line, value) }
            }
          }
        }
        if let nearest { store.select(RailwayMapStore.item(nearest.0)) }
        else { store.clearLineFocus() }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / denominator))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

struct RailProjection {
    let center: MKMapPoint
    let size: CGSize
    let units: Double

    init(region: MKCoordinateRegion, size: CGSize, drag: CGSize = .zero, magnification: Double = 1) {
        self.size = size
        let bounds = MapBounds(region: region)
        let nw = Coordinate(bounds.north, bounds.west).mapPoint
        let se = Coordinate(bounds.south, bounds.east).mapPoint
        units = max(se.x - nw.x, 1) / max(size.width, 1) > max(se.y - nw.y, 1) / max(size.height, 1)
            ? max(se.x - nw.x, 1) / max(size.width, 1) / magnification
            : max(se.y - nw.y, 1) / max(size.height, 1) / magnification
        let origin = MKMapPoint(region.center)
        center = MKMapPoint(x: origin.x - drag.width * units, y: origin.y - drag.height * units)
    }

    func screen(_ coordinate: Coordinate) -> CGPoint {
        let point = coordinate.mapPoint
        return CGPoint(x: (point.x - center.x) / units + size.width / 2,
                       y: (point.y - center.y) / units + size.height / 2)
    }

    var transform: CGAffineTransform {
        CGAffineTransform(a: 1 / units, b: 0, c: 0, d: 1 / units,
                          tx: size.width / 2 - center.x / units, ty: size.height / 2 - center.y / units)
    }

    var visibleBounds: MapBounds {
        let nw = MKMapPoint(x: max(0, center.x - size.width * units / 2),
                            y: max(0, center.y - size.height * units / 2)).coordinate
        let se = MKMapPoint(x: min(MKMapSize.world.width, center.x + size.width * units / 2),
                            y: min(MKMapSize.world.height, center.y + size.height * units / 2)).coordinate
        return MapBounds(south: max(-85, se.latitude), west: nw.longitude, north: min(85, nw.latitude), east: se.longitude)
    }

    var visibleRegion: MKCoordinateRegion {
        let nw = MKMapPoint(x: center.x - size.width * units / 2, y: center.y - size.height * units / 2).coordinate
        let se = MKMapPoint(x: center.x + size.width * units / 2, y: center.y + size.height * units / 2).coordinate
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: max(-80, min(80, center.coordinate.latitude)),
                                           longitude: center.coordinate.longitude),
            span: MKCoordinateSpan(latitudeDelta: min(100, abs(nw.latitude - se.latitude)),
                                   longitudeDelta: min(200, abs(nw.longitude - se.longitude)))
        )
    }
}
