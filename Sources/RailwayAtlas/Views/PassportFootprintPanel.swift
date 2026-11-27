import RailwayCore
import SwiftUI

struct PassportFootprintPanel: View {
    @EnvironmentObject private var model: ExperienceStore
    let rides: [RailJourney]
    @ObservedObject var activity: PassportActivityStore
    @ObservedObject var library: TimetableLibraryStore
    @State private var snapshot: PassportFootprint?
    @State private var retry = 0
    @State private var focus: UUID?
    private struct Input: Equatable {
        let rides: [RailJourney]
        let catalogueCount, trackCount, retry: Int
        let lulu, archive: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("实乘足迹").font(.headline)
            if rides.isEmpty {
                Text("在护照里把记录确认为“已乘坐”，就能看到上下车站、区间里程和收藏章。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if let snapshot, snapshot.confirmed == rides {
                if !snapshot.sections.isEmpty {
                    Text("累计约 \(km(snapshot.metres)) km").font(.title3.weight(.semibold)).monospacedDigit()
                    Text("已匹配 \(snapshot.sections.count) / \(rides.count) 段。里程沿实际轨道估算，每次实乘分别累计。")
                        .font(.caption).foregroundStyle(.secondary)
                    if snapshot.sections.count > 1 {
                        Picker("地图区间", selection: $focus) {
                            Text("全部实乘区间").tag(Optional<UUID>.none)
                            ForEach(snapshot.sections) { s in
                                Text("\(s.journey.date) · \(s.journey.train) · \(s.journey.from) → \(s.journey.to)").tag(Optional(s.id))
                            }
                        }
                    }
                    let sections = focus.flatMap { id in snapshot.sections.first { $0.id == id }.map { [$0] } } ?? snapshot.sections
                    if let s = sections.first, sections.count == 1 {
                        JourneyContextMap(legs: s.legs, from: s.journey.from, to: s.journey.to,
                                         ink: .railwayAccent, paper: .railwayCanvas)
                            .frame(height: 200).accessibilityIdentifier("passport-section-map")
                        Text("\(s.journey.train) · \(s.journey.from) → \(s.journey.to) · 约 \(km(s.metres)) km")
                            .font(.caption)
                    } else {
                        PassportOverviewMap(sections: sections).frame(height: 225)
                    }
                    Text("\(CardGeography.credit) · 中国铁路 GTFS / © OpenStreetMap contributors").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("实乘里程待匹配").font(.subheadline)
                }
                if !snapshot.missing.isEmpty {
                    DisclosureGroup("缺少径路的 \(snapshot.missing.count) 段，暂未计入里程") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(snapshot.missing) { item in
                                Text("\(item.journey.date) · \(item.journey.train) · \(item.journey.from) → \(item.journey.to)\n\(item.reason)")
                            }
                            Button("重新检查本机径路") { retry += 1 }
                        }.font(.caption).padding(.top, 5)
                    }
                }
                stampCollection(snapshot)
            } else {
                ProgressView("正在本机按上下车站匹配区间…").controlSize(.small)
            }
            if let message = activity.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(Color.railwayAccent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .task(id: Input(rides: rides, catalogueCount: model.timetables.count, trackCount: model.trackJourneys.count,
                        retry: retry, lulu: library.lulu?.edition, archive: library.archive?.edition)) {
            do {
                let result = try await PassportFootprint.load(rides, reusing: snapshot) {
                    try await model.passengerRoute($0, allowNetwork: false)
                }
                try Task.checkCancellation()
                if !result.sections.contains(where: { $0.id == focus }) { focus = nil }
                snapshot = result
            } catch { /* A new selection or a closed passport cancelled this load. */ }
        }
    }

    private func km(_ metres: Double) -> String {
        (metres / 1000).formatted(.number.precision(.fractionLength(1)))
    }

    private func stampCollection(_ snapshot: PassportFootprint) -> some View {
        let stamps = snapshot.stamps
        let collected = stamps.filter { activity.pinned.contains($0.id) }
        return DisclosureGroup("收藏章 · 已解锁 \(stamps.count) 枚，已收藏 \(collected.count) 枚") {
            let others = stamps.filter { !activity.pinned.contains($0.id) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(collected + others) { stamp in
                    let pinned = activity.pinned.contains(stamp.id)
                    Button { activity.toggleStamp(stamp.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(stamp.name, systemImage: stamp.icon).font(.subheadline.weight(.medium))
                            Text("\(stamp.detail) · \(pinned ? "已收藏" : "可收藏")").font(.caption2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(.quaternary.opacity(pinned ? 0.7 : 0.25), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(activity.readOnly)
                    .accessibilityLabel("\(pinned ? "取消收藏" : "收藏")\(stamp.name)章")
                }
            }.padding(.top, 6)
        }
    }
}

private struct PassportOverviewMap: View {
    let sections: [PassportFootprint.Section]
    var body: some View {
        Canvas { context, size in
            let bounds = MapBounds(points: sections.flatMap { $0.legs.flatMap { $0 } })
            let center = bounds.center, cosine = max(0.1, cos(center.latitude * .pi / 180))
            let scale = min((size.width - 40) / max(0.02, (bounds.east - bounds.west) * cosine),
                            (size.height - 35) / max(0.02, bounds.north - bounds.south))
            func point(_ lat: Double, _ lon: Double) -> CGPoint {
                .init(x: size.width / 2 + (lon - center.longitude) * cosine * scale,
                      y: size.height / 2 - (lat - center.latitude) * scale)
            }
            let halfLat = size.height / (2 * scale), halfLon = size.width / (2 * scale * cosine)
            func contours(_ runs: [CardGeography.Contours.Run]) -> Path {
                Path { p in
                    for run in runs where run.bounds[0] <= center.latitude + halfLat && run.bounds[2] >= center.latitude - halfLat
                        && run.bounds[1] <= center.longitude + halfLon && run.bounds[3] >= center.longitude - halfLon {
                        if let start = run.points.first { p.move(to: point(start[0], start[1])) }
                        for xy in run.points.dropFirst() { p.addLine(to: point(xy[0], xy[1])) }
                    }
                }
            }
            let geography = CardGeography.shared
            if let c = CardGeography.Contours.shared {
                context.stroke(contours(c.provinceLines), with: .color(.secondary.opacity(0.4)), style: .init(lineWidth: 0.7, dash: [3, 2]))
                context.stroke(contours(c.coastLines + c.hainan), with: .color(.secondary), lineWidth: 0.8)
                context.stroke(contours(c.settled), with: .color(.secondary), style: .init(lineWidth: 1, dash: [6, 2, 1, 2]))
                context.stroke(contours(c.undelimited), with: .color(.secondary), style: .init(lineWidth: 1, dash: [4, 3]))
            } else if let geography {
                context.stroke(contours(geography.coastLines + geography.hainan), with: .color(.secondary), lineWidth: 0.8)
            }
            var labels = [(String, CGPoint)]()
            for section in sections {
                let track = Path { p in
                    for leg in section.legs {
                        guard let start = leg.first else { continue }
                        p.move(to: point(start.latitude, start.longitude))
                        for c in leg.dropFirst() { p.addLine(to: point(c.latitude, c.longitude)) }
                    }
                }
                context.stroke(track, with: .color(.railwayAccent), style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                for (name, c) in [(section.journey.from, section.legs.first?.first), (section.journey.to, section.legs.last?.last)] {
                    if let c { labels.append((name, point(c.latitude, c.longitude))) }
                }
            }
            var used = [CGRect](), usedNames = Set<String>()
            let screen = CGRect(origin: .zero, size: size)
            let cities = (geography?.cities ?? []).compactMap { city -> (String, CGPoint)? in
                let p = point(city.lat, city.lon)
                return screen.insetBy(dx: 12, dy: 10).contains(p) ? (city.name, p) : nil
            }
            for (i, item) in (labels + cities).enumerated() {
                let (name, location) = item, isStop = i < labels.count
                let dot = Path(ellipseIn: CGRect(x: location.x - 2, y: location.y - 2, width: 4, height: 4))
                if isStop { context.fill(dot, with: .color(.railwayAccent)) }
                guard used.count < 14, !usedNames.contains(name) else { continue }
                let label = context.resolve(Text(name).font(.caption2).foregroundStyle(isStop ? Color.primary : Color.secondary))
                let dim = label.measure(in: size)
                let position = CGPoint(x: max(2, min(size.width - dim.width - 2, location.x + 4)),
                                       y: max(1, min(size.height - dim.height - 1, location.y - dim.height)))
                let rect = CGRect(origin: position, size: dim).insetBy(dx: -2, dy: -1)
                if !used.contains(where: { $0.intersects(rect) }) {
                    used.append(rect); usedNames.insert(name)
                    if !isStop { context.fill(dot, with: .color(.secondary.opacity(0.65))) }
                    context.draw(label, at: position, anchor: .topLeading)
                }
            }
        }.background(Color.railwayCanvas).clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("实乘足迹地图，共 \(sections.count) 段，可用地图区间逐段查看")
    }
}
