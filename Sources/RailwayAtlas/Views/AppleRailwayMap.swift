import MapKit
import RailwayCore
import SwiftUI

#if os(macOS)
typealias PlatformMapRepresentable = NSViewRepresentable
typealias PlatformColor = NSColor
final class AtlasMapView: MKMapView {
    var densityChanged: (() -> Void)?
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        densityChanged?()
    }
}
#else
typealias PlatformMapRepresentable = UIViewRepresentable
typealias PlatformColor = UIColor
#endif

struct AppleRailwayMap: PlatformMapRepresentable {
    @ObservedObject var store: RailwayMapStore
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    #if os(macOS)
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ map: MKMapView, context: Context) { updateMap(map, context: context) }
    #else
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ map: MKMapView, context: Context) { updateMap(map, context: context) }
    #endif

    private func makeMap(context: Context) -> MKMapView {
        #if os(macOS)
        let map = AtlasMapView()
        map.densityChanged = { [weak map, weak coordinator = context.coordinator] in
            guard let map else { return }
            coordinator?.updateStationLabels(map)
        }
        #else
        let map = MKMapView()
        #endif
        map.delegate = context.coordinator
        // Keep both renderers north-up so switching modes preserves orientation.
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.pointOfInterestFilter = .excludingAll
        #if os(macOS)
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectTrack(_:)))
        #else
        let click = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectTrack(_:)))
        click.cancelsTouchesInView = false
        #endif
        map.addGestureRecognizer(click)
        return map
    }

    private func updateMap(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.historyActive != store.historyMapActive {
            coordinator.historyActive = store.historyMapActive
            coordinator.renderRevision = -1
        }
        let displayGroups = store.historyMapActive ? [] : store.renderGroups
        let renderingChanged = coordinator.renderRevision != store.renderRevision
        let lightLabels = colorScheme == .dark || store.basemapDarkness >= 0.35 || store.basemapStyle != .standard
        let labelContrastChanged = coordinator.lightStationLabels != lightLabels
        coordinator.lightStationLabels = lightLabels
        if map.mapType != store.basemapStyle.mapType { map.mapType = store.basemapStyle.mapType }
        if coordinator.shade == nil {
            let shade = BasemapShade()
            coordinator.shade = shade
            map.addOverlay(shade, level: .aboveLabels)
        }
        if let shade = coordinator.shade, let renderer = map.renderer(for: shade) as? BasemapShadeRenderer,
           renderer.darkness != store.basemapDarkness {
            renderer.darkness = store.basemapDarkness
            renderer.setNeedsDisplay()
        }
        let layoutChanged = coordinator.updateLayouts(map, dark: lightLabels)
        if coordinator.renderRevision != store.renderRevision {
            coordinator.renderRevision = store.renderRevision
            let inputs = Coordinator.RenderInputs(categories: store.categories, networks: store.networks,
                forcedCategories: store.forcedCategories, forcedNetworks: store.forcedNetworks,
                hiddenRoutes: store.hiddenRoutes, automaticDetail: store.automaticDetail,
                prioritizesUrbanTransit: store.prioritizesUrbanTransit,
                showsNationalMetroOverview: store.showsNationalMetroOverview,
                showsStations: store.showsStations, showsMetroColors: store.showsMetroColors,
                alignment: store.alignment, historyActive: store.historyMapActive)
            let userVisibilityChanged = coordinator.lastInputs.map { $0 != inputs } ?? false
            coordinator.lastInputs = inputs
            var wanted = Set<Coordinator.GroupKey>()
            for group in displayGroups {
                let key = Coordinator.GroupKey(token: group.geometryToken, alignment: store.alignment)
                let strokes = group.appearance.strokes(zoom: store.displayZoom, settings: store.renderSettings)
                wanted.insert(key)
                if let overlays = coordinator.groups[key], overlays.count == strokes.count {
                    // A zoom threshold or width preference changes the vector
                    // style without rehashing vertices or replacing geometry.
                    for (overlay, stroke) in zip(overlays, strokes) {
                        if coordinator.styles[ObjectIdentifier(overlay)] != stroke {
                            coordinator.styles[ObjectIdentifier(overlay)] = stroke
                            if let renderer = map.renderer(for: overlay) as? MKOverlayPathRenderer {
                                coordinator.apply(stroke, to: renderer)
                                renderer.setNeedsDisplay()
                            }
                        }
                    }
                    continue
                }
                let old = coordinator.groups.removeValue(forKey: key) ?? []
                let polylines = group.lines.flatMap { line -> [MKPolyline] in
                    let segments = store.clippedGeometry[line.id] ?? []
                    if let existing = coordinator.geometry[line.id],
                       existing.0 == segments, existing.1 == store.alignment { return existing.2 }
                    let parts = segments.flatMap { store.alignment.displaySegments($0) }.map { segment in
                        let points = segment.map(\.location)
                        return MKPolyline(coordinates: points, count: points.count)
                    }
                    coordinator.geometry[line.id] = (segments, store.alignment, parts)
                    return parts
                }
                var overlays: [MKMultiPolyline] = []
                for stroke in strokes {
                    let multi = MKMultiPolyline(polylines)
                    coordinator.styles[ObjectIdentifier(multi)] = stroke
                    overlays.append(multi)
                    // Put the replacement into MapKit before retiring its
                    // predecessor. The old vector remains visible until the
                    // new renderer has had a chance to paint.
                    map.addOverlay(multi, level: .aboveLabels)
                }
                coordinator.groups[key] = overlays
                coordinator.retire(old, immediately: userVisibilityChanged, on: map)
            }
            for key in Array(coordinator.groups.keys) where !wanted.contains(key) {
                coordinator.retire(coordinator.groups.removeValue(forKey: key) ?? [],
                                   immediately: userVisibilityChanged, on: map)
            }
            let ids = Set(store.visibleLines.map(\.id))
            coordinator.geometry = coordinator.geometry.filter { ids.contains($0.key) }
            let stations = Dictionary((store.historyMapActive ? [] : store.visibleStations).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, old) in coordinator.stations where stations[id] != old.station || old.alignment != store.alignment {
                map.removeAnnotation(old)
                coordinator.stations.removeValue(forKey: id)
            }
            var added: [StationAnnotation] = []
            for (id, station) in stations where coordinator.stations[id] == nil {
                let annotation = StationAnnotation(station, alignment: store.alignment)
                coordinator.stations[id] = annotation
                added.append(annotation)
            }
            map.addAnnotations(added)
            coordinator.scheduleStationLabels(map)
        }
        if renderingChanged || layoutChanged {
            // New groups arrive after retained overlays in MapKit. Restore
            // the prepared paint order so a late neutral track cannot cover
            // an already-coloured route. Reordering keeps vector geometry.
            let ordered: [any MKOverlay] = (coordinator.shade.map { [$0 as any MKOverlay] } ?? [])
                + coordinator.overlays(for: .outline)
                + displayGroups.flatMap {
                    coordinator.groups[.init(token: $0.geometryToken, alignment: store.alignment), default: []]
                        .map { $0 as any MKOverlay }
                } + coordinator.overlays(for: .platform) + coordinator.overlays(for: .passage)
                + coordinator.highlights.map { $0 as any MKOverlay }
                + coordinator.experienceOverlays.map { $0 as any MKOverlay }
            var actual = map.overlays(in: .aboveLabels)
            var positions = Dictionary(uniqueKeysWithValues: actual.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
            for (target, overlay) in ordered.enumerated() {
                guard let current = positions[ObjectIdentifier(overlay)], current != target else { continue }
                // The legacy index-based API operates only above roads;
                // our rail layers are above labels. Exchange actual objects.
                map.exchangeOverlay(overlay, with: actual[target])
                positions[ObjectIdentifier(actual[target])] = current
                positions[ObjectIdentifier(overlay)] = target
                actual.swapAt(current, target)
            }
        }
        let numbersEnabled = store.showsPlatformNumbers && store.showsStationLayouts && !store.historyMapActive
        if coordinator.labelRevision != store.labelRevision || coordinator.uiScale != store.uiScale || labelContrastChanged
            || coordinator.layoutDataRevision != store.layoutDataRevision || coordinator.numbersEnabled != numbersEnabled
            || layoutChanged {
            coordinator.uiScale = store.uiScale
            coordinator.labelRevision = store.labelRevision
            coordinator.layoutDataRevision = store.layoutDataRevision
            coordinator.numbersEnabled = numbersEnabled
            coordinator.scheduleStationLabels(map)
        }
        if coordinator.cameraRevision != store.cameraRevision {
            let firstCamera = coordinator.cameraRevision < 0
            coordinator.cameraRevision = store.cameraRevision
            coordinator.cameraUpdatePending = true
            let target = store.displayRegion, revision = store.cameraRevision
            // MapKit forces an AppKit layout in setRegion. Calling it inside
            // updateNSView re-enters SwiftUI's layout graph on macOS.
            Task { @MainActor [weak map, weak coordinator] in
                guard let map, let coordinator, coordinator.cameraRevision == revision else { return }
                map.setRegion(target, animated: !firstCamera)
                coordinator.cameraUpdatePending = false
                if firstCamera { coordinator.updateViewport(map, final: true) }
            }
        }
        if coordinator.selectedID != store.selection?.id || renderingChanged {
            coordinator.selectedID = store.selection?.id
            map.removeOverlays(coordinator.highlights)
            for old in coordinator.highlights { coordinator.styles.removeValue(forKey: ObjectIdentifier(old)) }
            coordinator.highlights = []
            if !store.historyMapActive, let line = store.visibleLines.first(where: { $0.id == store.selection?.id }) {
                for part in (store.clippedGeometry[line.id] ?? []).flatMap({ store.alignment.displaySegments($0) }) {
                    let points = part.map(\.location)
                    let halo = MKPolyline(coordinates: points, count: points.count)
                    halo.title = "halo"
                    coordinator.highlights.append(halo)
                    map.addOverlay(halo, level: .aboveLabels)
                    for stroke in store.appearance(line).strokes(zoom: store.displayZoom, settings: store.renderSettings) {
                        let overlay = MKPolyline(coordinates: points, count: points.count)
                        coordinator.styles[ObjectIdentifier(overlay)] = stroke
                        coordinator.highlights.append(overlay)
                        map.addOverlay(overlay, level: .aboveLabels)
                    }
                }
            }
            if let annotation = map.annotations.first(where: { ($0 as? StationAnnotation)?.station.id == store.selection?.id }) {
                map.selectAnnotation(annotation, animated: true)
            }
        }
        if coordinator.experienceRevision != store.experienceGeometryRevision || coordinator.experienceAlignment != store.alignment {
            coordinator.experienceRevision = store.experienceGeometryRevision
            coordinator.experienceAlignment = store.alignment
            map.removeOverlays(coordinator.experienceOverlays)
            coordinator.experienceOverlays = []
            let groups = Dictionary(grouping: store.experienceLines, by: { "\($0.colour)|\($0.uncertain)" })
            for (key, lines) in groups.sorted(by: { $0.key < $1.key }) {
                let parts = lines.flatMap { store.alignment.displaySegments($0.coordinates) }.map { points in
                    let locations = points.map(\.location)
                    return MKPolyline(coordinates: locations, count: locations.count)
                }
                let overlay = MKMultiPolyline(parts)
                overlay.title = "experience|\(key)"
                coordinator.experienceOverlays.append(overlay)
                map.addOverlay(overlay, level: .aboveLabels)
            }
        }
        if let point = store.experienceMarker {
            let annotation: ExperienceTrainAnnotation
            if let existing = coordinator.train { annotation = existing }
            else {
                annotation = ExperienceTrainAnnotation()
                annotation.title = "模拟列车"
                annotation.coordinate = store.alignment.display(point).location
                coordinator.train = annotation; map.addAnnotation(annotation)
            }
            annotation.coordinate = store.alignment.display(point).location
        } else if let train = coordinator.train {
            map.removeAnnotation(train); coordinator.train = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        let store: RailwayMapStore
        var renderRevision = -1
        var cameraRevision = -1
        var cameraUpdatePending = false
        var selectedID: String?
        var highlights: [MKPolyline] = []
        var historyActive = false
        var experienceRevision = -1
        var experienceAlignment: MapAlignment?
        var experienceOverlays: [MKMultiPolyline] = []
        var train: ExperienceTrainAnnotation?
        var styles: [ObjectIdentifier: RailStroke] = [:]
        struct GroupKey: Hashable { let token: UUID; let alignment: MapAlignment }
        struct RenderInputs: Equatable {
            let categories: Set<RailCategory>
            let networks: Set<RailNetwork>
            let forcedCategories: Set<RailCategory>
            let forcedNetworks: Set<RailNetwork>
            let hiddenRoutes: Set<String>
            let automaticDetail: Bool
            let prioritizesUrbanTransit: Bool
            let showsNationalMetroOverview: Bool
            let showsStations: Bool
            let showsMetroColors: Bool
            let alignment: MapAlignment
            let historyActive: Bool
        }
        var groups: [GroupKey: [MKMultiPolyline]] = [:]
        var lastInputs: RenderInputs?
        var retiring: [ObjectIdentifier: MKMultiPolyline] = [:]
        var retirementTask: Task<Void, Never>?
        var geometry: [String: ([[Coordinate]], MapAlignment, [MKPolyline])] = [:]
        var stations: [String: StationAnnotation] = [:]
        var shade: BasemapShade?
        var labelRevision = -1
        var uiScale = 1.0
        var lightStationLabels = false
        var layoutDataRevision = -1
        var numbersEnabled = false
        private(set) var platformAnnotations: [String: PlatformNumberAnnotation] = [:]
        private var layouts: [String: (feature: StationLayout, overlay: any MKOverlay)] = [:]
        private var layoutKinds: [ObjectIdentifier: StationLayoutKind] = [:]
        private var layoutAlignment: MapAlignment?
        private var layoutDark = false
        func overlays(for kind: StationLayoutKind) -> [any MKOverlay] {
            layouts.values.filter { $0.feature.kind == kind }.sorted { $0.feature.id < $1.feature.id }.map(\.overlay)
        }
        func updateLayouts(_ map: MKMapView, dark: Bool) -> Bool {
            let visible = store.stationLayouts(in: store.viewportBounds, zoom: store.displayZoom)
            let wanted = Set(visible.map(\.id)), realign = layoutAlignment != store.alignment
            let recolor = layoutDark != dark
            layoutAlignment = store.alignment
            layoutDark = dark
            var changed = false
            for (key, item) in layouts where realign || !wanted.contains(key) {
                map.removeOverlay(item.overlay)
                layouts.removeValue(forKey: key)
                layoutKinds.removeValue(forKey: ObjectIdentifier(item.overlay))
                changed = true
            }
            for feature in visible {
                if let item = layouts[feature.id] {
                    if item.feature == feature {
                        if recolor, let renderer = map.renderer(for: item.overlay) as? MKOverlayPathRenderer {
                            paintLayout(feature.kind, renderer)
                            renderer.setNeedsDisplay()
                        }
                        continue
                    }
                    map.removeOverlay(item.overlay)
                    layoutKinds.removeValue(forKey: ObjectIdentifier(item.overlay))
                }
                let overlay = feature.overlay(alignment: store.alignment)
                layouts[feature.id] = (feature, overlay)
                layoutKinds[ObjectIdentifier(overlay)] = feature.kind
                map.addOverlay(overlay, level: .aboveLabels)
                changed = true
            }
            return changed
        }
        private func paintLayout(_ kind: StationLayoutKind, _ renderer: MKOverlayPathRenderer) {
            let color = PlatformColor(kind.ink(dark: layoutDark))
            renderer.strokeColor = color
            renderer.fillColor = color.withAlphaComponent(kind.opacity)
            renderer.lineWidth = kind.width
            renderer.lineJoin = .round
            renderer.lineCap = .round
            renderer.lineDashPattern = kind.dash.map { NSNumber(value: Double($0)) }
        }
        var viewportUpdate: Task<Void, Never>?
        var labelUpdate: Task<Void, Never>?
        private(set) var symbolUpdates = 0
        private(set) var labelPasses = 0
        private var stationStyleRevision = -1
        private var stationStyles: [String: StationAppearance] = [:]
        init(store: RailwayMapStore) { self.store = store }

        func retire(_ overlays: [MKMultiPolyline], immediately: Bool, on map: MKMapView) {
            guard !overlays.isEmpty else { return }
            if immediately {
                map.removeOverlays(overlays)
                for overlay in overlays {
                    styles.removeValue(forKey: ObjectIdentifier(overlay))
                    retiring.removeValue(forKey: ObjectIdentifier(overlay))
                }
                return
            }
            for overlay in overlays {
                retiring[ObjectIdentifier(overlay)] = overlay
            }
            retirementTask?.cancel()
            retirementTask = Task { @MainActor [weak self, weak map] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, let map, !Task.isCancelled else { return }
                let current = Set(self.groups.values.flatMap { $0 }.map(ObjectIdentifier.init))
                let old = self.retiring.values.filter { !current.contains(ObjectIdentifier($0)) }
                guard !old.isEmpty else { return }
                map.removeOverlays(old)
                for overlay in old {
                    self.styles.removeValue(forKey: ObjectIdentifier(overlay))
                    self.retiring.removeValue(forKey: ObjectIdentifier(overlay))
                }
            }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            updateViewport(mapView, final: false)
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            updateViewport(mapView, final: true)
            scheduleStationLabels(mapView)
        }
        func updateViewport(_ mapView: MKMapView, final: Bool) {
            guard store.mapMode == .apple, !cameraUpdatePending else { return }
            if final { viewportUpdate?.cancel(); viewportUpdate = nil }
            guard viewportUpdate == nil else { return }
            let revision = cameraRevision
            viewportUpdate = Task { @MainActor [weak self, weak mapView] in
                if !final { try? await Task.sleep(for: .milliseconds(40)) }
                guard !Task.isCancelled else { return }
                guard let self, let mapView else { return }
                defer { self.viewportUpdate = nil }
                guard !self.cameraUpdatePending,
                      self.store.mapMode == .apple,
                      self.cameraRevision == revision, self.store.cameraRevision == revision else { return }
                var value = mapView.region
                value.center = self.store.alignment.original(Coordinate(value.center.latitude, value.center.longitude),
                    near: Coordinate(self.store.region.center.latitude, self.store.region.center.longitude)).location
                self.store.viewportChanged(value, width: mapView.bounds.width, height: mapView.bounds.height)
                if final { self.scheduleStationLabels(mapView) }
            }
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let kind = layoutKinds[ObjectIdentifier(overlay)] {
                let renderer: MKOverlayPathRenderer
                if let polygon = overlay as? MKPolygon { renderer = MKPolygonRenderer(polygon: polygon) }
                else if let line = overlay as? MKMultiPolyline { renderer = MKMultiPolylineRenderer(multiPolyline: line) }
                else { return MKOverlayRenderer(overlay: overlay) }
                paintLayout(kind, renderer)
                return renderer
            }
            if overlay is BasemapShade {
                let renderer = BasemapShadeRenderer(overlay: overlay)
                renderer.darkness = store.basemapDarkness
                return renderer
            }
            let renderer: MKOverlayPathRenderer
            if let line = overlay as? MKPolyline {
                renderer = MKPolylineRenderer(polyline: line)
                if line.title == "halo" {
                    renderer.strokeColor = PlatformColor.systemOrange.withAlphaComponent(0.25)
                    renderer.lineWidth = 11
                    return renderer
                }
            } else if let multi = overlay as? MKMultiPolyline {
                renderer = MKMultiPolylineRenderer(multiPolyline: multi)
            } else {
                return MKOverlayRenderer(overlay: overlay)
            }
            if let title = (overlay as? MKMultiPolyline)?.title, title.hasPrefix("experience|") {
                let parts = title.components(separatedBy: "|")
                renderer.strokeColor = PlatformColor((RailColor(parts[1]) ?? RailColor("#2DAD87")!).tint)
                renderer.lineWidth = parts.last == "true" ? 2 : 4
                renderer.lineDashPattern = parts.last == "true" ? [4, 5] : nil
                renderer.lineCap = .round
                return renderer
            }
            guard let stroke = styles[ObjectIdentifier(overlay)] else { return renderer }
            apply(stroke, to: renderer)
            return renderer
        }
        func apply(_ stroke: RailStroke, to renderer: MKOverlayPathRenderer) {
            renderer.strokeColor = PlatformColor(stroke.color.tint)
            renderer.lineWidth = stroke.width
            renderer.lineCap = stroke.dash.isEmpty ? .round : .butt
            renderer.lineJoin = .round
            renderer.lineDashPattern = stroke.dash.map { NSNumber(value: $0) }
            renderer.lineDashPhase = stroke.phase
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let annotation = annotation as? PlatformNumberAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "platform-number")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "platform-number")
                view.annotation = annotation
                view.canShowCallout = false
                view.isEnabled = false
                view.displayPriority = .required
                view.image = annotation.image
                return view
            }
            if annotation is ExperienceTrainAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "experience-train") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "experience-train")
                view.annotation = annotation
                view.markerTintColor = .systemOrange
                view.glyphText = "🚆"
                view.displayPriority = .required
                view.titleVisibility = .hidden
                return view
            }
            guard let annotation = annotation as? StationAnnotation else { return nil }
            let id = "station"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? StationAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.clusteringIdentifier = nil
            view.displayPriority = .required
            view.collisionMode = .circle
            view.canShowCallout = false
            configure(view, station: annotation.station, label: false)
            return view
        }
        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) { scheduleStationLabels(mapView) }
        private func stationAppearance(_ station: RailStation) -> StationAppearance {
            if stationStyleRevision != store.renderRevision {
                stationStyleRevision = store.renderRevision
                stationStyles.removeAll(keepingCapacity: true)
            }
            if let style = stationStyles[station.id] { return style }
            let style = store.stationAppearance(station)
            stationStyles[station.id] = style
            return style
        }
        private func configure(_ view: MKAnnotationView, station: RailStation, label: Bool, appearance: StationAppearance? = nil) {
            let appearance = appearance ?? stationAppearance(station)
            #if os(macOS)
            let density = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            #else
            let density = view.window?.screen.scale ?? view.traitCollection.displayScale
            #endif
            let configuration = StationAnnotationView.SymbolConfiguration(appearance: appearance,
                title: label ? station.name : nil, uiScale: store.uiScale, density: density, lightText: lightStationLabels)
            if let view = view as? StationAnnotationView {
                guard view.symbolConfiguration != configuration else { return }
                view.symbolConfiguration = configuration
            }
            symbolUpdates += 1
            view.image = StationSymbol.image(appearance, title: configuration.title,
                                             uiScale: store.uiScale, displayScale: density, lightText: configuration.lightText)
            view.centerOffset = CGPoint(x: label ? 74 * store.uiScale : 0, y: 0)
        }
        func scheduleStationLabels(_ map: MKMapView) {
            guard labelUpdate == nil else { return }
            labelUpdate = Task { @MainActor [weak self, weak map] in
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, let map, !Task.isCancelled else { return }
                self.labelUpdate = nil
                self.updateStationLabels(map)
            }
        }
        func updateStationLabels(_ map: MKMapView) {
            labelPasses += 1
            let zoom = RailDisplayPolicy.zoom(longitudeSpan: map.region.span.longitudeDelta, width: map.bounds.width)
            let placements = store.platformNumbers(in: store.viewportBounds, zoom: store.displayZoom, screen: map.bounds) {
                map.convert(store.alignment.display($0).location, toPointTo: map)
            }
            let wanted = Set(placements.map(\.id))
            for (id, annotation) in platformAnnotations where !wanted.contains(id) {
                map.removeAnnotation(annotation)
                platformAnnotations.removeValue(forKey: id)
            }
            #if os(macOS)
            let density = map.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            #else
            let density = map.traitCollection.displayScale
            #endif
            for placement in placements {
                let coordinate = store.alignment.display(placement.coordinate)
                let style = PlatformNumberAnnotation.Style(text: placement.text, scale: store.uiScale, light: lightStationLabels, density: density)
                if let old = platformAnnotations[placement.id], old.style == style {
                    if old.coordinate.latitude != coordinate.latitude || old.coordinate.longitude != coordinate.longitude {
                        old.coordinate = coordinate.location
                    }
                } else {
                    if let old = platformAnnotations[placement.id] { map.removeAnnotation(old) }
                    let annotation = PlatformNumberAnnotation(style: style, coordinate: coordinate.location)
                    platformAnnotations[placement.id] = annotation
                    map.addAnnotation(annotation)
                }
            }
            var occupied = placements.map(\.frame)
            var symbols: [(StationAnnotation, MKAnnotationView, StationAppearance)] = []
            for case let annotation as StationAnnotation in map.annotations {
                guard let view = map.view(for: annotation) else { continue }
                symbols.append((annotation, view, stationAppearance(annotation.station)))
            }
            symbols.sort {
                if $0.2.radius == $1.2.radius { return $0.0.station.id < $1.0.station.id }
                return $0.2.radius > $1.2.radius
            }
            for (annotation, view, appearance) in symbols {
                let point = map.convert(annotation.coordinate, toPointTo: map)
                let scale = store.uiScale
                let rect = CGRect(x: point.x + 10 * scale, y: point.y - 11 * scale, width: 160 * scale, height: 22 * scale)
                let label = store.showsLabels && RailDisplayPolicy.labelVisible(appearance.kind, zoom: zoom)
                    && map.bounds.contains(point) && !occupied.contains { $0.intersects(rect) }
                if label { occupied.append(rect) }
                configure(view, station: annotation.station, label: label, appearance: appearance)
            }
        }
        #if os(macOS)
        @objc func selectTrack(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            pickTrack(gesture.location(in: map), map: map)
        }
        #else
        @objc func selectTrack(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            pickTrack(gesture.location(in: map), map: map)
        }
        #endif
        private func pickTrack(_ point: CGPoint, map: MKMapView) {
            guard !store.historyMapActive else { return }
            let display = map.convert(point, toCoordinateFrom: map)
            let location = MKMapPoint(display)
            let tolerance = map.visibleMapRect.width / max(1, map.bounds.width) * 9
            var nearest: (RailLine, Double)?
            for line in store.visibleLines {
              for part in geometry[line.id]?.2 ?? [] {
                let points = part.points()
                for index in 1..<part.pointCount {
                    let a = points[index - 1], b = points[index]
                    let dx = b.x - a.x, dy = b.y - a.y
                    let length = dx * dx + dy * dy
                    let t = length > 0 ? max(0, min(1, ((location.x - a.x) * dx + (location.y - a.y) * dy) / length)) : 0
                    let distance = hypot(location.x - a.x - t * dx, location.y - a.y - t * dy)
                    if distance < tolerance && distance < (nearest?.1 ?? .infinity) { nearest = (line, distance) }
                }
              }
            }
            if let nearest { store.selection = RailwayMapStore.item(nearest.0) }
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? StationAnnotation else { return }
            Task { @MainActor [weak self] in
                guard self?.store.selection?.id != annotation.station.id else { return }
                self?.store.select(RailwayMapStore.item(annotation.station))
            }
        }
    }
}

final class ExperienceTrainAnnotation: MKPointAnnotation {}

@MainActor
final class PlatformNumberAnnotation: MKPointAnnotation {
    struct Style: Equatable {
        let text: String
        let scale: Double
        let light: Bool
        let density: CGFloat
    }
    let style: Style
    let image: StationSymbol.Image?

    init(style: Style, coordinate: CLLocationCoordinate2D) {
        self.style = style
        let renderer = ImageRenderer(content: PlatformNumberPlacement.text(style.text, scale: style.scale, light: style.light))
        renderer.scale = style.density
        #if os(macOS)
        image = renderer.nsImage
        #else
        image = renderer.uiImage
        #endif
        super.init()
        self.coordinate = coordinate
    }
}

private final class StationAnnotationView: MKAnnotationView {
    struct SymbolConfiguration: Equatable {
        let appearance: StationAppearance
        let title: String?
        let uiScale: Double
        let density: Double
        let lightText: Bool
    }
    var symbolConfiguration: SymbolConfiguration?
}

final class StationAnnotation: NSObject, MKAnnotation {
    let station: RailStation
    let alignment: MapAlignment
    let coordinate: CLLocationCoordinate2D
    var title: String? { station.name }
    init(_ station: RailStation, alignment: MapAlignment) {
        self.station = station
        self.alignment = alignment
        coordinate = alignment.display(station.coordinate).location
    }
}

final class BasemapShade: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

private final class BasemapShadeRenderer: MKOverlayRenderer {
    var darkness: Double = 0
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.setFillColor(CGColor(gray: 0, alpha: darkness))
        context.fill(rect(for: mapRect))
    }
}
