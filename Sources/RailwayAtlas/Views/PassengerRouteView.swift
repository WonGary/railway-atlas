import RailwayCore
import SwiftUI

struct PassengerRouteView: View {
    @EnvironmentObject private var model: ExperienceStore
    @Environment(\.dismiss) private var dismiss
    let journey: RailJourney
    @State private var route: RailTrackJourney?
    @State private var error: String?
    @State private var retry = 0
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(journey.from) → \(journey.to)").font(.title2.weight(.semibold))
            Text("\(journey.date) · \(journey.train) · 乘车区间").font(.subheadline).foregroundStyle(.secondary)
            if let route {
                JourneyContextMap(legs:route.legs,from:journey.from,to:journey.to,ink:.railwayAccent,paper:Color.railwayCanvas,stations:route.stations)
                    .frame(height: 290).accessibilityLabel("沿\(journey.train)径路，从\(journey.from)至\(journey.to)")
                Text("\(route.stations.joined(separator: " → "))").font(.caption).fixedSize(horizontal: false, vertical: true)
                Text("地图轨道约 \(Int(route.distance / 1000)) km · \(CardGeography.credit) · © OpenStreetMap contributors").font(.caption).foregroundStyle(.secondary)
                ExperienceSourceView(source: route.source)
            } else if loading {
                ProgressView("正在按车次匹配乘车区间…").frame(maxWidth: .infinity, minHeight: 220)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("重试") { retry += 1 }.disabled(loading)
                Button("制成明信片") { model.makePostcard(journey); dismiss() }.disabled(route == nil)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24)
        #if os(macOS)
        .frame(width: 620)
        #endif
        .task(id: retry) {
            route = nil; error = nil; loading = true
            do {
                let value = try await model.passengerRoute(journey)
                try Task.checkCancellation(); route = value; loading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
        }
    }
}
