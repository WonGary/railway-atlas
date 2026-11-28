import RailwayCore
import SwiftUI

struct MapExperienceControls: View {
    @ObservedObject var player: RailMapPlayback
    @EnvironmentObject private var configuration: ConfigurationStore

    var body: some View {
        if let mode = player.mode {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(mode == .train ? (player.timetable?.train ?? "沿线旅行") : (player.region?.title ?? "线路时光机"),
                          systemImage: mode == .train ? "tram.fill" : "clock.arrow.circlepath").font(.headline)
                        .accessibilityIdentifier("map-playback-title")
                        .accessibilityValue(player.timetable.map { "\($0.serviceDate) \($0.stops.first?.station ?? "") → \($0.stops.last?.station ?? "")" } ?? "")
                    Text(mode == .train ? RailTimetable.clock(player.seconds) : player.date)
                        .font(.system(.title3, design: .monospaced).weight(.medium))
                    Spacer()
                    Button {
                        configuration.interfaceSettings.experienceControlsVisible = false
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .help("收起播放栏")
                    .accessibilityLabel("收起播放栏")
                    Button { player.stop() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("退出地图漫游")
                }
                if mode == .train, let train = player.timetable {
                    Text(player.trainStatus).font(.subheadline)
                    Text(player.runDetails).font(.caption.monospacedDigit())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("train-run-details")
                    Slider(value: Binding(get: { player.seconds }, set: { player.seek($0) }),
                           in: Double(train.start * 60)...Double(train.end * 60))
                    HStack {
                        playbackButton
                        Picker("倍速", selection: $player.speed) {
                            ForEach([1.0, 10, 60, 300, 900], id: \.self) { Text("\(Int($0))×").tag($0) }
                        }.frame(width: 140)
                        Toggle("跟随列车", isOn: Binding(get: { player.follow }, set: { value in
                            if value { player.resumeFollowing() } else { player.browse() }
                        })).font(.caption)
                        Spacer()
                    }
                    RideGuideControls(player: player, guide: player.guide)
                    Text("\(train.serviceDate) · 24 小时制 · 沿轨道按时刻插值，非实时定位")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Slider(value: Binding(get: { Double(player.historyIndex) }, set: { player.seek($0) }),
                           in: 0...Double(max(1, player.historyDates.count - 1)), step: 1)
                    HStack {
                        playbackButton
                        Text("\(player.visibleSegmentCount) 个已开通区段").font(.caption)
                        Spacer()
                        Toggle("显示日期未知区段", isOn: $player.showUnknown).font(.caption)
                    }
                    Text("OSM 区段开通日期 · 现存几何的建设演变视图 · 灰虚线为日期未知，不计入历史路网")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .atlasMapSurface(mode: configuration.interfaceSettings.surfaceMode,
                             opacity: configuration.interfaceSettings.playbackOpacity,
                             cornerRadius: 16)
            .accessibilityIdentifier("main-map-experience-controls")
        }
    }
    private var playbackButton: some View {
        Button { player.toggle() } label: {
            Label(player.playing ? "暂停" : "播放", systemImage: player.playing ? "pause.fill" : "play.fill")
        }.buttonStyle(.borderedProminent)
    }
}
