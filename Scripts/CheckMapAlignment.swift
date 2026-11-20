import Foundation
import MapKit
import AppKit

// Read-only coordinate observation from the same MapKit service as the app.
@main struct CheckMapAlignment {
    @MainActor static func main() async {
        for query in ["南昌站", "南昌西站", "南昌地铁八一广场站"] {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(center: .init(latitude: 28.68, longitude: 115.86),
                                                span: .init(latitudeDelta: 0.5, longitudeDelta: 0.6))
            do {
                let response = try await MKLocalSearch(request: request).start()
                for item in response.mapItems.prefix(3) {
                    let p = item.placemark.coordinate
                    print("\(query)\t\(item.name ?? "")\t\(p.latitude)\t\(p.longitude)")
                }
            } catch { print("\(query): \(error)") }
        }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: .init(latitude: 28.6232, longitude: 115.7931),
                                            span: .init(latitudeDelta: 0.013, longitudeDelta: 0.017))
        options.size = CGSize(width: 1000, height: 800)
        options.pointOfInterestFilter = .excludingAll
        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            let image = snapshot.image
            image.lockFocus()
            for (coordinate, color, text) in [
                (CLLocationCoordinate2D(latitude: 28.6266186, longitude: 115.7882702), NSColor.systemRed, "OSM / WGS84"),
                (CLLocationCoordinate2D(latitude: 28.623377339, longitude: 115.793332319), NSColor.systemGreen, "GCJ-02"),
                (CLLocationCoordinate2D(latitude: 28.622886, longitude: 115.792938), NSColor.systemBlue, "Apple POI")
            ] {
                let point = snapshot.point(for: coordinate)
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)).fill()
                (text as NSString).draw(at: CGPoint(x: point.x + 9, y: point.y), withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: color,
                    .backgroundColor: NSColor.white.withAlphaComponent(0.85)
                ])
            }
            image.unlockFocus()
            if let data = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/atlas-alignment.png"))
            }
        } catch { print("Snapshot failed: \(error)") }
    }
}
