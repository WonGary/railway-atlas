#if os(macOS)
import Combine
import RailwayCore
import SwiftUI

struct DesktopMapWorkspace: View {
    @EnvironmentObject private var map: RailwayMapStore
    @EnvironmentObject private var configuration: ConfigurationStore
    @State private var compactPriority = DesktopPanelSide.right
    @State private var leftTemporarilyCollapsed = false
    @State private var rightTemporarilyCollapsed = false

    var body: some View {
        GeometryReader { geometry in
            let layout = DesktopPanelLayout.resolve(
                viewport: geometry.size, scale: map.uiScale,
                leftVisible: map.panelVisible && !leftTemporarilyCollapsed, leftLayout: map.panelLayout,
                leftWidth: map.panelWidth, leftSize: map.panelSize,
                rightVisible: map.inspectorVisible && !rightTemporarilyCollapsed, rightLayout: map.inspectorLayout,
                rightWidth: map.inspectorWidth, priority: compactPriority)
            HStack(spacing: 0) {
                // The three slots are unconditional. Only their contents / widths
                // change, keeping MapScreen and its MKMapView at the same identity.
                ZStack {
                    if layout.leftDockWidth > 0 {
                        DesktopSidebarPanel(onRequestClose: { collapse(.left) })
                            .modifier(DesktopPanelSurface(cornerRadius: 0, opacity: map.panelBackgroundOpacity,
                                                          mode: configuration.interfaceSettings.surfaceMode))
                            .overlay(alignment: .trailing) {
                                DesktopPanelResizeHandle(side: .left, displayedWidth: layout.leftWidth) {
                                    compactPriority = .left
                                }
                            }
                    }
                }
                .frame(width: layout.leftDockWidth)
                .clipped()
                MapScreen(desktopPanels: layout,
                          onToggleDesktopPanel: { toggle($0, layout: layout) },
                          onActivateDesktopPanel: { compactPriority = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ZStack {
                    if layout.rightDockWidth > 0 {
                        AtlasInspectorView(onRequestClose: { collapse(.right) })
                            .modifier(DesktopPanelSurface(cornerRadius: 0, opacity: map.inspectorBackgroundOpacity,
                                                          mode: configuration.interfaceSettings.surfaceMode))
                            .overlay(alignment: .leading) {
                                DesktopPanelResizeHandle(side: .right, displayedWidth: layout.rightWidth) {
                                    compactPriority = .right
                                }
                            }
                    }
                }
                .frame(width: layout.rightDockWidth)
                .clipped()
            }
            .coordinateSpace(name: "atlas-panel-workspace")
        }
        // Published events also cover reselecting the same feature / reopening
        // GPT when the requested inspector is already true but space-suppressed.
        .onReceive(map.$panelVisible.dropFirst()) {
            leftTemporarilyCollapsed = false
            if $0 { compactPriority = .left }
        }
        .onReceive(map.$inspectorVisible.dropFirst()) {
            rightTemporarilyCollapsed = false
            if $0 { compactPriority = .right }
        }
        .onChange(of: map.panelLayout) { _, _ in if map.panelVisible { compactPriority = .left } }
        .onChange(of: map.inspectorLayout) { _, _ in
            rightTemporarilyCollapsed = false
            if map.inspectorVisible { compactPriority = .right }
        }
        .onChange(of: map.inspectorPane) { _, _ in
            rightTemporarilyCollapsed = false
            if map.inspectorVisible { compactPriority = .right }
        }
    }

    private func toggle(_ side: DesktopPanelSide, layout: DesktopPanelLayout.Resolved) {
        compactPriority = side
        if side == .left {
            if map.panelVisible {
                leftTemporarilyCollapsed = layout.leftVisible
            } else {
                leftTemporarilyCollapsed = false
                map.panelVisible = true
            }
        } else {
            if map.inspectorVisible {
                // Keep the selected line and inspector pane alive while the
                // right panel is temporarily out of the way.
                rightTemporarilyCollapsed = layout.rightVisible
            } else {
                rightTemporarilyCollapsed = false
                map.inspectorVisible = true
            }
        }
    }

    private func collapse(_ side: DesktopPanelSide) {
        compactPriority = side
        if side == .left {
            leftTemporarilyCollapsed = true
        } else if map.inspectorVisible {
            rightTemporarilyCollapsed = true
        } else {
            map.inspectorVisible = false
        }
    }
}

/// Adds layout controls without changing SidebarView's existing size menu.
struct DesktopSidebarPanel: View {
    var onRequestClose: (() -> Void)?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("左侧面板").atlasFont(.caption).foregroundStyle(.secondary)
                Spacer()
                DesktopPanelMenu(side: .left, onRequestHide: onRequestClose)
            }
            .atlasPadding(.horizontal, 14).atlasPadding(.vertical, 6)
            Divider()
            SidebarView(floating: true, onRequestClose: onRequestClose)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(PanelLayoutProbe(id: "left-map-panel"))
    }
}

struct DesktopPanelMenu: View {
    let side: DesktopPanelSide
    var onRequestHide: (() -> Void)?
    @EnvironmentObject private var map: RailwayMapStore
    @EnvironmentObject private var assistant: AssistantStore

    private var layout: Binding<MapPanelLayout> {
        if side == .left { return $map.panelLayout }
        return Binding(get: { map.inspectorLayout }, set: { value in
            if map.inspectorPane == .assistant && assistant.settings.presentation != .window {
                assistant.setPresentation(value == .docked ? .sidebar : .floating, map: map)
            } else { map.inspectorLayout = value }
        })
    }
    private var width: Binding<Double> {
        side == .left ? $map.panelWidth : $map.inspectorWidth
    }

    var body: some View {
        Menu {
            Picker("布局", selection: layout) {
                ForEach(MapPanelLayout.allCases) { Text($0.title).tag($0) }
            }
            Menu("宽度") {
                Button("较窄") { width.wrappedValue = side.widthRange.lowerBound }
                Button("默认") { width.wrappedValue = side == .left ? 320 : 380 }
                Button("较宽") { width.wrappedValue = 560 }
            }
            Divider()
            Button("隐藏" + side.title) {
                if let onRequestHide {
                    onRequestHide()
                } else if side == .left {
                    map.panelVisible = false
                } else {
                    map.inspectorVisible = false
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3").atlasFrame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(side.title + "：布局、宽度与隐藏")
        .accessibilityLabel(side.title + "布局")
        .atlasMapActionID(side == .left ? "left-panel-layout" : "right-panel-layout")
    }
}

struct DesktopPanelResizeHandle: View {
    let side: DesktopPanelSide
    let displayedWidth: Double
    var onActivate: () -> Void = {}
    @EnvironmentObject private var map: RailwayMapStore
    @State private var resizeStart: Double?

    var body: some View {
        Color.clear.frame(width: 10)
            .overlay {
                Capsule().fill(.secondary.opacity(0.45)).frame(width: 3, height: 30)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if resizeStart == nil {
                        resizeStart = displayedWidth / map.uiScale
                        onActivate()
                    }
                    let delta = value.translation.width / map.uiScale * (side == .left ? 1 : -1)
                    let width = min(side.widthRange.upperBound,
                                    max(side.widthRange.lowerBound, (resizeStart ?? 0) + delta))
                    if side == .left { map.panelWidth = width }
                    else { map.inspectorWidth = width }
                }
                .onEnded { _ in resizeStart = nil })
            .onDisappear { resizeStart = nil }
            .help("拖动调整" + side.title + "宽度")
            .accessibilityLabel(side.title + "宽度")
            .accessibilityValue("\(Int(displayedWidth)) 点")
            .accessibilityAdjustableAction { direction in
                let current = side == .left ? map.panelWidth : map.inspectorWidth
                let delta: Double
                switch direction {
                case .increment: delta = 10
                case .decrement: delta = -10
                @unknown default: return
                }
                let width = min(side.widthRange.upperBound, max(side.widthRange.lowerBound, current + delta))
                onActivate()
                if side == .left { map.panelWidth = width }
                else { map.inspectorWidth = width }
            }
            .accessibilityIdentifier(side == .left ? "left-panel-resize" : "right-panel-resize")
    }
}

struct DesktopFloatingPanelSurface: ViewModifier {
    let opacity: Double
    var surfaceMode: AtlasSurfaceMode = .glass
    @Environment(\.atlasUIScale) private var scale
    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: 18 * scale))
            .modifier(DesktopPanelSurface(cornerRadius: 18 * scale, opacity: opacity, mode: surfaceMode))
    }
}

struct AtlasInspectorView: View {
    var onRequestClose: (() -> Void)?
    @Environment(\.atlasUIScale) private var scale
    @EnvironmentObject private var map: RailwayMapStore
    @EnvironmentObject private var assistant: AssistantStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10 * scale) {
              HStack(spacing: 8 * scale) {
                if assistant.settings.presentation == .window {
                  Label("要素信息", systemImage: "info.circle")
                    .atlasFont(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("feature-inspector-title")
                    .accessibilityIdentifier("inspector-pane")
                    .accessibilityAddTraits(.isHeader)
                } else {
                    Text("信息与对话").atlasFont(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                DesktopPanelMenu(side: .right, onRequestHide: onRequestClose)
                Button {
                    if let onRequestClose {
                        onRequestClose()
                    } else {
                        map.inspectorVisible = false
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.plain).help("隐藏右侧栏")
                .accessibilityLabel("隐藏右侧栏")
              }
              if assistant.settings.presentation != .window {
                Picker("右侧内容", selection: $map.inspectorPane) {
                    ForEach(InspectorPane.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
                    .accessibilityIdentifier("inspector-pane-tabs")
              }
            }
            .atlasPadding(14)
            Divider()
            if map.inspectorPane == .assistant && assistant.settings.presentation != .window {
                AtlasAssistantView(embedded: true)
            } else {
              ScrollView {
                if let focus = map.lineFocus, focus.inspectionOwner != nil {
                    VStack(alignment: .leading, spacing: 9 * scale) {
                        Text(focus.title).atlasFont(.headline)
                        if let note = focus.inspectionSummary {
                            Text(note).atlasFont(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                        if let line = focus.inspectionDirectory {
                            InspectionStationSequence(line: line, map: map).id(focus.revision)
                        }
                        Button("恢复全图") { map.clearLineFocus() }
                    }.atlasPadding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let selection = map.selection {
                    FeatureDetails(item: selection)
                        .atlasPadding(14)
                } else if let id=map.lineFocus?.directionID, let entry=map.directions.entries[id] {
                    MetroDirectionInspector(entry:entry).atlasPadding(14)
                } else if map.lineFocus?.inspectionOwner == nil {
                    VStack(alignment: .leading, spacing: 12 * scale) {
                        Image(systemName: "cursorarrow.click.2")
                            .atlasFont(.system(size: 28)).foregroundStyle(.secondary)
                        Text("查看线路与车站").atlasFont(.headline)
                        Text("点选地图上的要素，查看名称、线路色、速度、运营方和原始字段。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .atlasPadding(24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("feature-inspector")
            }
        }
        .accessibilityIdentifier("right-map-inspector")
        .modifier(PanelLayoutProbe(id: "right-map-inspector"))
    }
}

/// Measures the actual SwiftUI layout only during local UI validation. Native
/// accessibility trees are not always materialized in an unattended QA launch.
struct PanelLayoutProbe: ViewModifier {
    let id: String
    @State private var instanceID = UUID()
    private static let enabled = CommandLine.arguments.contains("--v020-panel-layout-check")

    func body(content: Content) -> some View {
        if Self.enabled {
            content.background {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .named("atlas-panel-workspace"))
                    Color.clear
                        .onAppear { PanelLayoutMeasurements.frames[id, default: [:]][instanceID] = frame }
                        .onChange(of: frame) { _, value in
                            PanelLayoutMeasurements.frames[id, default: [:]][instanceID] = value
                        }
                        .onDisappear { PanelLayoutMeasurements.frames[id]?[instanceID] = nil }
                }
            }
        } else {
            content
        }
    }
}

@MainActor
enum PanelLayoutMeasurements {
    static var frames: [String: [UUID: CGRect]] = [:]
}
#endif
