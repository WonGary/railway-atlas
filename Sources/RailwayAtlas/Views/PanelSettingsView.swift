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
            Text("透明度只改变浮窗的玻璃背景，文字与控件保持清晰。分屏使用实色背景。窗口空间不足时先缩窄，再临时收起一侧；地图顶部按钮可切换要显示的面板，扩大窗口后自动恢复。")
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
            opacitySlider(side.title + "背景透明度", opacity: opacity)
                .disabled(layout.wrappedValue != .floating)
        }
    }

    private func opacitySlider(_ title: String, opacity: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text("\(title) \(Int(((1 - opacity.wrappedValue) * 100).rounded()))%")
                .monospacedDigit()
            Slider(value: Binding(get: { 1 - opacity.wrappedValue },
                                  set: { opacity.wrappedValue = 1 - $0 }),
                   in: 0...1, step: 0.05)
                .accessibilityLabel(title)
        }
    }
}

struct InterfaceSurfaceSettingsView: View {
    @EnvironmentObject private var configuration: ConfigurationStore
    @Environment(\.atlasUIScale) private var scale

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
            opacitySlider("顶部工具栏背景透明度",
                          opacity: $configuration.interfaceSettings.topControlsOpacity)
            opacitySlider("角落控件背景透明度",
                          opacity: $configuration.interfaceSettings.cornerControlsOpacity)
            opacitySlider("底部计数背景透明度",
                          opacity: $configuration.interfaceSettings.bottomCounterOpacity)
            opacitySlider("播放栏背景透明度",
                          opacity: $configuration.interfaceSettings.playbackOpacity)
            opacitySlider("状态卡背景透明度",
                          opacity: $configuration.interfaceSettings.statusBackgroundOpacity)
            Toggle("显示顶部地图控件",
                   isOn: $configuration.interfaceSettings.topControlsVisible)
            Toggle("显示底部地图控件",
                   isOn: $configuration.interfaceSettings.bottomControlsVisible)
            Toggle("显示沿线旅行控制条",
                   isOn: $configuration.interfaceSettings.experienceControlsVisible)
            Text("收起播放栏只隐藏控制面板，沿线旅行和线路时光机仍会继续运行；地图顶部和底部各保留恢复入口。")
                .atlasFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            opacitySlider("兼容地图控件背景透明度",
                          opacity: $configuration.interfaceSettings.mapControlsOpacity)
                .hidden()
        }
    }

    private func opacitySlider(_ title: String, opacity: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text("\(title) \(Int(((1 - opacity.wrappedValue) * 100).rounded()))%")
                .monospacedDigit()
            Slider(value: Binding(get: { 1 - opacity.wrappedValue },
                                  set: { opacity.wrappedValue = 1 - $0 }),
                   in: 0...1, step: 0.05)
                .accessibilityLabel(title)
        }
    }
}
