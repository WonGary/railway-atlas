import RailwayCore
import SwiftUI

struct RailwayTimeMachineView: View {
    @EnvironmentObject private var model: ExperienceStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "hongkong"
    private var region: RailHistoryRegion? {
        model.historyRegions.first { $0.id == selected } ?? model.historyRegions.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Picker("观察地区", selection: $selected) {
                    ForEach(model.historyRegions) { Text($0.title).tag($0.id) }
                }.frame(maxWidth: 300)
                Spacer()
                Button("读取当前地图区域") {
                    Task { if let region = await model.historyForCurrentMap() { selected = region.id } }
                }.disabled(model.map == nil)
            }
            if let region {
                SilhouetteCanvas(silhouette: RailSilhouette(coordinates: region.segments
                    .filter { $0.opened != nil }.map(\.coordinates)))
                    .frame(height: 280)
                    .background(Color(red: 0.06, green: 0.14, blue: 0.17), in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 24) {
                    metric("\(region.segments.count - region.unknownCount)", "有区段日期")
                    metric("\(region.dates.count)", "时间步")
                    metric("\(region.unknownCount)", "日期未知")
                }
                Button("在主地图播放线路建设", systemImage: "map") {
                    model.map?.journeyPlayer.start(region)
                    #if os(macOS)
                    openWindow(id: "main-map")
                    #else
                    dismiss()
                    #endif
                }.buttonStyle(.borderedProminent).disabled(model.map == nil)
                Text("拖动主地图下方的时间轴，已开通区段会逐步叠加；有施工起始日期的区段会先以橙色虚线出现。播放和缩放都在原地图完成。")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text("时间范围：\(region.dates.first ?? "—") 至 \(region.dates.last ?? "—")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("来源：OSM 具体轨道区段的 start_date / opening_date。这里只重放有日期的现存几何；未收录的旧线、改线和拆除记录仍有缺口。日期未知的轨道可另行显示，不会提前计入路网。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("查看区段日期和来源") {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(region.segments.filter { $0.opened != nil }.prefix(100)) { segment in
                            HStack {
                                Text(segment.opened ?? "").font(.caption.monospacedDigit()).frame(width: 90, alignment: .leading)
                                if let url = URL(string: segment.sourceURL) {
                                    Link(segment.name, destination: url).font(.caption).lineLimit(1)
                                }
                            }
                        }
                        Text("最多列出 100 个来源；全部区段参与地图播放。").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            } else {
                ContentUnavailableView("当前没有区段日期", systemImage: "clock.arrow.circlepath",
                    description: Text("需要带逐段开通日期的铁路几何数据。"))
            }
        }
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
