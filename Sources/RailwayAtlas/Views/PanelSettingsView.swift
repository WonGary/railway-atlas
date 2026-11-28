import RailwayCore
import SwiftUI

/// Embed in AtlasSettingsView's interface page; inherits RailwayMapStore.
struct PanelSettingsView: View {
    @EnvironmentObject private var map: RailwayMapStore
    @Environment(\.atlasUIScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * scale) {
            InterfaceSurfaceSettingsView()
            Divider()
            panelSettings(side: .left, visible: $map.panelVisible, layout: $map.panelLayout,
                          width: $map.panelWidth, opacity: $map.panelBackgroundOpacity)
            Divider()
            panelSettings(side: .right, visible: $map.inspectorVisible, layout: $map.inspectorLayout,
                          width: $map.inspectorWidth, opacity: $map.inspectorBackgroundOpacity)
            Text("左右面板可分别隐藏、浮动或贴边分屏；拖动面板朝向地图的一侧可调宽度。小、中、大只改变左侧浮窗高度，切换分屏后仍会保留。")
                .atlasFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("背景透明度也适用于贴边分屏。窗口太窄时，地图会暂时收起一侧面板，扩大窗口后恢复。")
                .atlasFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("panel-settings")
    }

    private func panelSettings(side: DesktopPanelSide, visible: Binding<Bool>, layout: Binding<MapPanelLayout>,
                               width: Binding<Double>, opacity: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            Toggle("显示" + side.title, isOn: visible).atlasFont(.headline)
            Picker(side.title + "布局", selection: layout) {
                ForEach(MapPanelLayout.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4 * scale) {
                Text("基准宽度 \(Int(width.wrappedValue)) 点").monospacedDigit()
                Slider(value: width, in: side.widthRange, step: 1)
                    .accessibilityLabel(side.title + "基准宽度")
            }
            if side == .left {
                Picker("左侧浮窗大小", selection: $map.panelSize) {
                    ForEach(MapPanelSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(layout.wrappedValue != .floating)
            }
            MapOpacitySlider(title: side.title + "背景透明度", opacity: opacity)
        }
    }

}

struct InterfaceSurfaceSettingsView: View {
    @EnvironmentObject private var configuration: ConfigurationStore
    @Environment(\.atlasUIScale) private var scale

    private var controls: [MapControl] {
        #if os(iOS)
        MapControl.allCases
        #else
        MapControl.allCases.filter { $0 != .launcher && $0 != .stationBoard }
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            Picker("浮窗表面", selection: $configuration.interfaceSettings.surfaceMode) {
                ForEach(AtlasSurfaceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(configuration.interfaceSettings.surfaceMode.detail)
                .atlasFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(controls) { control in
                MapOpacitySlider(title: control.title + "背景透明度",
                                 opacity: $configuration.interfaceSettings[dynamicMember: control.opacity])
                    .accessibilityIdentifier("opacity-" + control.rawValue)
            }
            Toggle("默认显示顶部地图控件",
                   isOn: $configuration.interfaceSettings.topControlsVisible)
            Toggle("默认显示底部地图控件",
                   isOn: $configuration.interfaceSettings.bottomControlsVisible)
            Toggle("默认显示播放栏",
                   isOn: $configuration.interfaceSettings.experienceControlsVisible)
            Text("地图工具栏的「地图浮窗」可暂时收起或恢复单个控件。播放栏收起后仍会继续播放。")
                .atlasFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

struct MapOpacitySlider: View {
    let title: String
    @Binding var opacity: Double
    @Environment(\.atlasUIScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text("\(title) \(Int(((1 - opacity) * 100).rounded()))%")
                .monospacedDigit()
                .accessibilityHidden(true)
            Slider(value: Binding(get: { 1 - opacity }, set: { opacity = 1 - $0 }),
                   in: 0...1, step: 0.05)
                .accessibilityLabel(title)
        }
    }
}
