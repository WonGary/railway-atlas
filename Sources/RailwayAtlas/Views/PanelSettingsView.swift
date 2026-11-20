import RailwayCore
import SwiftUI

/// Embed in AtlasSettingsView's interface page; inherits RailwayMapStore.
struct PanelSettingsView: View {
    @EnvironmentObject private var map: RailwayMapStore
    @Environment(\.atlasUIScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * scale) {
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
            VStack(alignment: .leading, spacing: 4 * scale) {
                Text("玻璃背景透明度 \(Int(((1 - opacity.wrappedValue) * 100).rounded()))%")
                    .monospacedDigit()
                Slider(value: Binding(get: { 1 - opacity.wrappedValue },
                                      set: { opacity.wrappedValue = 1 - $0 }), in: 0...1, step: 0.05)
                    .accessibilityLabel(side.title + "玻璃背景透明度")
            }
            .disabled(layout.wrappedValue != .floating)
        }
    }
}
