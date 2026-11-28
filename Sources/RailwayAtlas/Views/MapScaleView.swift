import MapKit
import SwiftUI

/// Shared renderer-independent scale, with its own reserved corner.
struct MapScaleView: View {
    @Environment(\.atlasUIScale) private var uiScale
    @EnvironmentObject private var store: RailwayMapStore
    let width: Double
    let height: Double
    var body: some View {
        let projection = RailProjection(region: store.region, size: CGSize(width: width, height: height))
        let mapUnits = MKMapRect.world.width * store.region.span.longitudeDelta / 360 / max(1, width)
        let metersPerPoint = (store.mapMode == .apple ? mapUnits : projection.units)
            * MKMetersPerMapPointAtLatitude(store.region.center.latitude)
        let target = max(1, metersPerPoint * 100 * uiScale)
        let power = pow(10, floor(log10(target)))
        let distance = [1.0, 2.0, 5.0, 10.0].map { $0 * power }.last(where: { $0 <= target }) ?? power
        let length = distance / metersPerPoint
        VStack(alignment: .leading, spacing: 3 * uiScale) {
            Text(distance >= 1000 ? String(format: "%.0f km", distance / 1000) : String(format: "%.0f m", distance))
                .atlasFont(.caption2.monospacedDigit())
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: 0, y: 5 * uiScale))
                path.addLine(to: CGPoint(x: length, y: 5 * uiScale)); path.addLine(to: CGPoint(x: length, y: 0))
            }.stroke(.primary.opacity(0.8), lineWidth: 1.5).frame(width: length, height: 6 * uiScale)
        }
        .atlasPadding(8)
        .atlasMapControl(.scale, radius: 8 * uiScale)
            .allowsHitTesting(false)
            .accessibilityLabel("比例尺 \(Int(distance)) 米")
    }
}
