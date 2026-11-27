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

enum RailwayMapAction {
    case cameraChanged(final: Bool, zooming: Bool)
    case featureSelected
}

struct AppleRailwayMap: PlatformMapRepresentable {
    @ObservedObject var store: RailwayMapStore
    @Environment(\.colorScheme) private var colorScheme
    var onMapAction: ((RailwayMapAction) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, onMapAction: onMapAction)
    }

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
        let allowsZoom = !store.journeyPlayer.holdsZoom
        if map.isZoomEnabled != allowsZoom { map.isZoomEnabled = allowsZoom }
        coordinator.onMapAction = onMapAction ?? store.mapActionHandler
        if coordinator.historyActive != store.historyMapActive {
            coordinator.historyActive = store.historyMapActive
            coordinator.renderRevision = -1
        }
        let displayGroups = store.historyMapActive ? [] : store.renderGroups
        let renderingChanged = coordinator.renderRevision != store.renderRevision
        let lightLabels = store.basemapStyle != .standard || store.basemapDarkness >= 0.35
            || ((store.activeBasemapSource == .apple || store.activeBasemapSource.isVector) && colorScheme == .dark)
        let labelContrastChanged = coordinator.lightStationLabels != lightLabels
        coordinator.lightStationLabels = lightLabels
        coordinator.updateBasemap(map,
                                  source: store.activeBasemapSource,
                                  style: store.basemapStyle,
                                  template: store.activeBasemapTemplate, dark: colorScheme == .dark)
        if coordinator.shade == nil {
            let shade = Coordinator.shadePolygon("basemap-shade")
            coordinator.shade = shade
            map.addOverlay(shade, level: .aboveLabels)
        }
        if let shade = coordinator.shade, let renderer = map.renderer(for: shade),
           renderer.alpha != store.basemapDarkness {
            renderer.alpha = store.basemapDarkness
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
                    coordinator.addBackground(multi, to: map)
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
        let focus = store.historyMapActive ? nil : store.lineFocus
        let paletteChanged = coordinator.focusInk != store.renderSettings.focusInk
        coordinator.focusInk = store.renderSettings.focusInk
        let focusChanged = coordinator.focusRevision != focus?.revision || paletteChanged
        if focusChanged || renderingChanged {
            coordinator.updateFocus(focus, on: map)
            coordinator.scheduleStationLabels(map)
        }
        let numbersEnabled = [store.showsPlatformNumbers, store.showsStationEntrances, store.showsPassageSigns,
                              store.showsStationLayouts, !store.historyMapActive]
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
                let nearby = abs(map.region.center.latitude - target.center.latitude) < 3 * target.span.latitudeDelta &&
                    abs(map.region.center.longitude - target.center.longitude) < 3 * target.span.longitudeDelta
                if !nearby { map.setCenter(target.center, animated: false) }
                map.setRegion(target, animated: !firstCamera && nearby)
                coordinator.cameraUpdatePending = false
                if firstCamera { coordinator.updateViewport(map, final: true) }
                coordinator.scheduleStationLabels(map)
            }
        }
        if coordinator.selectedID != store.selection?.id || renderingChanged {
            coordinator.selectedID = store.selection?.id
            if let annotation = map.annotations.first(where: { ($0 as? StationAnnotation)?.station.id == store.selection?.id }) {
                map.selectAnnotation(annotation, animated: true)
            }
        }
        if coordinator.experienceRevision != store.experienceGeometryRevision || coordinator.experienceAlignment != store.alignment || paletteChanged {
            coordinator.experienceRevision = store.experienceGeometryRevision
            coordinator.experienceAlignment = store.alignment
            map.removeOverlays(coordinator.experienceOverlays)
            coordinator.experienceOverlays = []
            let groups = Dictionary(grouping: store.experienceLines, by: { "\($0.colour ?? store.renderSettings.focusInk.hex)|\($0.uncertain)" })
            for (key, lines) in groups.sorted(by: { $0.key < $1.key }) {
                let parts = lines.flatMap { store.alignment.displaySegments($0.coordinates) }.map { points in
                    let locations = points.map(\.location)
                    return MKPolyline(coordinates: locations, count: locations.count)
                }
                let overlay = MKMultiPolyline(parts)
                overlay.title = "experience|\(key)"
                coordinator.experienceOverlays.append(overlay)
                coordinator.addBackground(overlay, to: map)
            }
        }
        if let place = store.ridePlace {
            let annotation = coordinator.ridePlace ?? RidePlaceAnnotation()
            annotation.title = place.name
            annotation.subtitle = place.note
            let coordinate = store.alignment.display(.init(place.lat,place.lon)).location
            if coordinator.ridePlace == nil || annotation.coordinate.latitude != coordinate.latitude ||
                annotation.coordinate.longitude != coordinate.longitude { annotation.coordinate = coordinate }
            if coordinator.ridePlace == nil { coordinator.ridePlace = annotation; map.addAnnotation(annotation) }
        } else if let annotation = coordinator.ridePlace {
            map.removeAnnotation(annotation); coordinator.ridePlace = nil
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
            if paletteChanged, let marker = map.view(for: annotation) as? MKMarkerAnnotationView {
                marker.markerTintColor = PlatformColor(store.renderSettings.focusInk.tint)
            }
        } else if let train = coordinator.train {
            map.removeAnnotation(train); coordinator.train = nil
        }
        let ordered: [any MKOverlay] = coordinator.overlays(for: .outline)
            + coordinator.overlays(for: .concourse)
            + displayGroups.flatMap {
                coordinator.groups[.init(token: $0.geometryToken, alignment: store.alignment), default: []]
                    .map { $0 as any MKOverlay }
            } + coordinator.overlays(for: .platform) + coordinator.overlays(for: .passage) + coordinator.overlays(for: .entrance)
            + coordinator.experienceOverlays.map { $0 as any MKOverlay }
        let orderIDs = ordered.map(ObjectIdentifier.init)
        if coordinator.overlayOrder != orderIDs {
            // New groups arrive after retained overlays in MapKit. Restore
            // the prepared paint order so a late neutral track cannot cover
            // an already-coloured route. Reordering keeps vector geometry.
            coordinator.overlayOrder = orderIDs
            let wanted = Set(ordered.map(ObjectIdentifier.init))
            // Retiring geometry, the fixed tints and the foreground never trade places.
            var actual = map.overlays(in: .aboveLabels).filter { wanted.contains(ObjectIdentifier($0)) }
            var positions = Dictionary(uniqueKeysWithValues: actual.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
            for (target, overlay) in ordered.enumerated() {
                guard target < actual.count,
                      let current = positions[ObjectIdentifier(overlay)], current != target else { continue }
                // The legacy index-based API operates only above roads;
                // our rail layers are above labels. Exchange actual objects.
                map.exchangeOverlay(overlay, with: actual[target])
                positions[ObjectIdentifier(actual[target])] = current
                positions[ObjectIdentifier(overlay)] = target
                actual.swapAt(current, target)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        let store: RailwayMapStore
        var onMapAction: ((RailwayMapAction) -> Void)?
        var renderRevision = -1
        var cameraRevision = -1
        var cameraUpdatePending = false
        var selectedID: String?
        struct FocusPiece {
            let paths: [[Coordinate]]
            let overlays: [MKMultiPolyline]
        }
        var focusPieces: [String: FocusPiece] = [:]
        var focusAlignment: MapAlignment?
        var focusRevision: UUID?
        var focusInk: RailColor?
        var focusVeil: MKPolygon?
        static func shadePolygon(_ name: String) -> MKPolygon {
            let w = MKMapRect.world.width
            // Intermediate vertices keep each edge shorter than half a wrapped world.
            let points = [0.0,0.25,0.5,0.75,1.0].map { MKMapPoint(x: $0*w, y: 0) }
                + [1.0,0.75,0.5,0.25,0.0].map { MKMapPoint(x: $0*w, y: w) }
            let polygon = MKPolygon(points: points, count: points.count)
            polygon.title = name
            return polygon
        }
        func addBackground(_ overlay: any MKOverlay, to map: MKMapView) {
            if let focusVeil { map.insertOverlay(overlay, below: focusVeil) }
            else { map.addOverlay(overlay, level: .aboveLabels) }
        }
        func updateFocus(_ focus: MapLineFocus?, on map: MKMapView) {
            let changed = focusRevision != focus?.revision || focusAlignment != store.alignment
            if changed { stationStyles.removeAll(keepingCapacity: true) }
            focusRevision = focus?.revision
            focusAlignment = store.alignment
            var old = focusPieces
            func removeOld() {
                let overlays = old.values.flatMap(\.overlays)
                guard !overlays.isEmpty else { return }
                map.removeOverlays(overlays)
                for overlay in overlays { styles.removeValue(forKey: ObjectIdentifier(overlay)) }
            }
            guard let focus else {
                focusPieces.removeAll()
                removeOld()
                if let focusVeil { map.removeOverlay(focusVeil); self.focusVeil = nil }
                return
            }
            if focusVeil == nil {
                let veil = Self.shadePolygon("focus-shade")
                focusVeil = veil
                map.addOverlay(veil, level: .aboveLabels)
            }
            var next: [String: FocusPiece] = [:]
            var firstDetailInk: MKMultiPolyline?
            let rim = RailStroke(color: RailColor("#FFFFFF")!, width: 7)
            func sync(_ key: String, _ paths: [[Coordinate]], _ strokes: [RailStroke]) {
                guard !paths.isEmpty else { return }
                if !changed, let piece = old[key], piece.paths == paths, piece.overlays.count == strokes.count {
                    for (overlay, stroke) in zip(piece.overlays, strokes) where styles[ObjectIdentifier(overlay)] != stroke {
                        styles[ObjectIdentifier(overlay)] = stroke
                        if let renderer = map.renderer(for: overlay) as? MKOverlayPathRenderer { apply(stroke, to: renderer) }
                    }
                    next[key] = old.removeValue(forKey: key)
                    if key != "directory", firstDetailInk == nil { firstDetailInk = piece.overlays[1] }
                    return
                }
                let parts = paths.flatMap { store.alignment.displaySegments($0) }.map { path in
                    let coordinates = path.map(\.location)
                    return MKPolyline(coordinates: coordinates, count: coordinates.count)
                }
                var overlays: [MKMultiPolyline] = []
                for (i,stroke) in strokes.enumerated() {
                    let multi = MKMultiPolyline(parts)
                    multi.title = key.hasPrefix("inspection/") && i > 0 ? key : (i == 0 ? "focus-rim" : "focus-rail")
                    styles[ObjectIdentifier(multi)] = stroke
                    if i == 0, key != "directory", let firstDetailInk { map.insertOverlay(multi, below: firstDetailInk) }
                    else { map.addOverlay(multi, level: .aboveLabels) }
                    overlays.append(multi)
                }
                if key != "directory", firstDetailInk == nil { firstDetailInk = overlays[1] }
                next[key] = FocusPiece(paths: paths, overlays: overlays)
            }
            sync("directory", focus.paths, [rim,RailStroke(color: focus.pathColor ?? store.renderSettings.focusInk, width: 4.4)])
            for layer in focus.inspectionLayers {
                sync("inspection/" + layer.ink.rawValue, layer.parts, [rim, layer.ink.stroke])
            }
            for line in store.focusedLines(focus) {
                sync(line.id,[line.coordinates],[rim]+store.appearance(line).focusStrokes(zoom: store.displayZoom, settings: store.renderSettings))
            }
            focusPieces = next
            removeOld()
        }
        var historyActive = false
        var experienceRevision = -1
        var experienceAlignment: MapAlignment?
        var experienceOverlays: [MKMultiPolyline] = []
        var train: ExperienceTrainAnnotation?
        var ridePlace: RidePlaceAnnotation?
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
        var basemapOverlay: BasemapTileOverlay?
        var basemapKey = ""
        var shade: MKPolygon?
        var overlayOrder: [ObjectIdentifier] = []
        var lastViewport: MKCoordinateRegion?
        var labelRevision = -1
        var uiScale = 1.0
        var lightStationLabels = false
        var layoutDataRevision = -1
        var numbersEnabled: [Bool] = []
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
                addBackground(overlay, to: map)
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
        init(store: RailwayMapStore, onMapAction: ((RailwayMapAction) -> Void)?) {
            self.store = store
            self.onMapAction = onMapAction
        }

        func updateBasemap(_ map: MKMapView, source: BasemapSource, style: BasemapStyle, template: String?, dark: Bool) {
            let key = "\(style.rawValue)|\(source.rawValue)|\(template ?? "")|\(source.isVector && dark)"
            let mapType = source == .apple ? style.mapType : MKMapType.standard
            if map.mapType != mapType { map.mapType = mapType }
            guard key != basemapKey else { return }
            basemapKey = key

            let previous = basemapOverlay
            if source.isVector || template != nil {
                let next = BasemapTileOverlay(template: template, source:source, dark:dark)
                basemapOverlay = next
                map.addOverlay(next, level:.aboveRoads)
            } else {
                basemapOverlay = nil
            }
            if let previous { map.removeOverlay(previous) }
        }

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
            if store.journeyPlayer.mode == .train, store.journeyPlayer.follow,
               !cameraUpdatePending, mapView.rideHasPanInput { store.journeyPlayer.userPanned() }
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
                let previous = self.lastViewport
                let zooming = previous.map {
                    abs(log(max(0.000001, value.span.longitudeDelta) / max(0.000001, $0.span.longitudeDelta))) > 0.015
                        || abs(log(max(0.000001, value.span.latitudeDelta) / max(0.000001, $0.span.latitudeDelta))) > 0.015
                } ?? false
                self.lastViewport = value
                self.onMapAction?(.cameraChanged(final: final, zooming: zooming))
                self.store.viewportChanged(value, width: mapView.bounds.width, height: mapView.bounds.height)
                if final { self.scheduleStationLabels(mapView) }
            }
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon, polygon === shade || polygon === focusVeil {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.shouldRasterize = false
                renderer.fillColor = .black
                renderer.strokeColor = nil
                renderer.alpha = polygon === shade ? store.basemapDarkness : 0.50
                return renderer
            }
            if let tile = overlay as? BasemapTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let kind = layoutKinds[ObjectIdentifier(overlay)] {
                let renderer: MKOverlayPathRenderer
                if let polygon = overlay as? MKPolygon { renderer = MKPolygonRenderer(polygon: polygon) }
                else if let circle = overlay as? MKCircle { renderer = MKCircleRenderer(circle: circle) }
                else if let line = overlay as? MKMultiPolyline { renderer = MKMultiPolylineRenderer(multiPolyline: line) }
                else { return MKOverlayRenderer(overlay: overlay) }
                paintLayout(kind, renderer)
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
                view.canShowCallout = annotation.style.kind != .platform
                view.isEnabled = view.canShowCallout
                #if os(macOS)
                view.toolTip = annotation.style.title
                #endif
                view.displayPriority = .required
                view.image = annotation.image
                setFocusOpacity(view, member: store.lineFocus == nil)
                return view
            }
            if annotation is RidePlaceAnnotation {
                let id = "ride-place"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.canShowCallout = true
                view.markerTintColor = .systemTeal
                view.displayPriority = .required
                return view
            }
            if annotation is ExperienceTrainAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "experience-train") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "experience-train")
                view.annotation = annotation
                view.markerTintColor = PlatformColor(store.renderSettings.focusInk.tint)
                view.glyphText = "🚆"
                view.displayPriority = .required
                view.titleVisibility = .hidden
                setFocusOpacity(view, member: store.lineFocus == nil)
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
            setFocusOpacity(view, member: store.lineFocus?.includes(station) ?? true)
            let appearance = appearance ?? stationAppearance(station)
            let zoom = store.displayZoom
            view.isEnabled = label
                || [.major, .connection, .interchange].contains(appearance.kind)
                || zoom >= 14
                || RailDisplayPolicy.labelVisible(appearance.kind, zoom: zoom)
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
        private func setFocusOpacity(_ view: MKAnnotationView, member: Bool) {
            #if os(macOS)
            view.alphaValue = member ? 1 : 0.25
            #else
            view.alpha = member ? 1 : 0.25
            #endif
            view.zPriority = member && store.lineFocus != nil ? .max : .defaultUnselected
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
            let placements = store.layoutLabels(in: store.viewportBounds, zoom: store.displayZoom, screen: map.bounds) {
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
                var coordinate = store.alignment.display(placement.coordinate).location
                var leader = CGSize.zero
                if let start = placement.leaderStart {
                    // Center the image between the geographic exit and its displaced badge.
                    let middle = CGPoint(x: (start.x + placement.point.x) / 2, y: (start.y + placement.point.y) / 2)
                    coordinate = map.convert(middle, toCoordinateFrom: map)
                    leader = CGSize(width: placement.point.x - start.x, height: placement.point.y - start.y)
                    #if os(macOS)
                    if !map.isFlipped { leader.height = -leader.height }
                    #endif
                }
                let style = PlatformNumberAnnotation.Style(text: placement.text, kind: placement.kind, title: placement.title,
                                                          scale: store.uiScale, light: lightStationLabels, density: density, leader: leader)
                if let old = platformAnnotations[placement.id], old.style == style {
                    if old.coordinate.latitude != coordinate.latitude || old.coordinate.longitude != coordinate.longitude {
                        old.coordinate = coordinate
                    }
                } else {
                    if let old = platformAnnotations[placement.id] { map.removeAnnotation(old) }
                    let annotation = PlatformNumberAnnotation(style: style, coordinate: coordinate)
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
                if let focus = store.lineFocus {
                    let left = focus.includes($0.0.station), right = focus.includes($1.0.station)
                    if left != right { return left }
                }
                if $0.2.radius == $1.2.radius { return $0.0.station.id < $1.0.station.id }
                return $0.2.radius > $1.2.radius
            }
            for (annotation, view, appearance) in symbols {
                let point = map.convert(annotation.coordinate, toPointTo: map)
                let scale = store.uiScale
                let rect = CGRect(x: point.x + 10 * scale, y: point.y - 11 * scale, width: 160 * scale, height: 22 * scale)
                let member = store.lineFocus?.includes(annotation.station) == true
                let label = store.showsLabels && (member || RailDisplayPolicy.labelVisible(appearance.kind, zoom: zoom))
                    && map.bounds.contains(point) && !occupied.contains { $0.intersects(rect) }
                if label { occupied.append(rect) }
                configure(view, station: annotation.station, label: label, appearance: appearance)
            }
            for annotation in map.annotations where annotation is PlatformNumberAnnotation || annotation is ExperienceTrainAnnotation {
                if let view = map.view(for: annotation) { setFocusOpacity(view, member: store.lineFocus == nil) }
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
            // Annotation selection has its own delegate callback. A pick on a
            // station must not immediately select the track beneath that station.
            #if os(macOS)
            var hit = map.hitTest(point)
            #else
            var hit = map.hitTest(point, with: nil)
            #endif
            while let view = hit {
                if let annotationView = view as? MKAnnotationView {
                    // An annotation view still owns the click area even when
                    // its station label is hidden. Respect that ownership
                    // while applying the same conservative visibility rule
                    // as the nearby-annotation check below.
                    guard isSelectableAnnotation(annotationView.annotation, view: annotationView, map: map) else { return }
                    return
                }
                hit = view.superview
            }
            if annotationIsNear(point, map: map) { return }
            let display = map.convert(point, toCoordinateFrom: map)
            let location = MKMapPoint(display)
            let tolerance = map.visibleMapRect.width / max(1, map.bounds.width) * hitTolerancePixels(map)
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
            guard let nearest else { return }
            store.selection = RailwayMapStore.item(nearest.0)
            onMapAction?(.featureSelected)
        }
        private func isSelectableAnnotation(_ annotation: MKAnnotation?, view: MKAnnotationView, map: MKMapView) -> Bool {
            guard let annotation else { return false }
            if annotation is PlatformNumberAnnotation { return true }
            guard let station = annotation as? StationAnnotation else { return false }
            let zoom = RailDisplayPolicy.zoom(longitudeSpan: map.region.span.longitudeDelta, width: map.bounds.width)
            let appearance = stationAppearance(station.station)
            let titleVisible = view is StationAnnotationView
                && (view as? StationAnnotationView)?.symbolConfiguration?.title != nil
            return titleVisible
                || [.major, .connection, .interchange].contains(appearance.kind)
                || zoom >= 14
                || RailDisplayPolicy.labelVisible(appearance.kind, zoom: zoom)
        }
        private func annotationIsNear(_ point: CGPoint, map: MKMapView) -> Bool {
            let zoom = RailDisplayPolicy.zoom(longitudeSpan: map.region.span.longitudeDelta, width: map.bounds.width)
            let radius = zoom < 9 ? 4.0 : zoom < 13 ? 7.0 : 11.0
            for annotation in map.annotations {
                guard annotation is StationAnnotation
                    || annotation is PlatformNumberAnnotation
                    || annotation is ExperienceTrainAnnotation else { continue }
                guard let view = map.view(for: annotation) else { continue }
                let frame = view.convert(view.bounds, to: map).insetBy(dx: -radius, dy: -radius)
                if frame.contains(point) { return true }
            }
            return false
        }
        private func hitTolerancePixels(_ map: MKMapView) -> Double {
            let zoom = RailDisplayPolicy.zoom(longitudeSpan: map.region.span.longitudeDelta, width: map.bounds.width)
            switch zoom {
            case ..<8: return 3.5
            case ..<11: return 4.5
            case ..<14: return 6.5
            case ..<17: return 8.5
            default: return 11
            }
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? StationAnnotation else { return }
            if store.selection?.id == annotation.station.id { return }
            guard isSelectableAnnotation(annotation, view: view, map: mapView) else {
                mapView.deselectAnnotation(annotation, animated: false)
                return
            }
            Task { @MainActor [weak self] in
                guard self?.store.selection?.id != annotation.station.id else { return }
                self?.store.select(RailwayMapStore.item(annotation.station))
                self?.onMapAction?(.featureSelected)
            }
        }
    }
}

final class ExperienceTrainAnnotation: MKPointAnnotation {}

@MainActor
final class PlatformNumberAnnotation: MKPointAnnotation {
    struct Style: Equatable {
        let text: String
        let kind: StationLayoutKind
        let title: String?
        let scale: Double
        let light: Bool
        let density: CGFloat
        let leader: CGSize

        @ViewBuilder var glyph: some View {
            let badge = PlatformNumberPlacement.text(text, kind: kind, scale: scale, light: light)
            if leader == .zero {
                badge
            } else {
                let diameter = PlatformNumberPlacement.diameter(text, scale: scale)
                let width = diameter + abs(leader.width), height = diameter + abs(leader.height)
                let end = CGPoint(x: (width + leader.width) / 2, y: (height + leader.height) / 2)
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: end.x - leader.width, y: end.y - leader.height))
                        path.addLine(to: end)
                    }.stroke(kind.ink(dark: light), lineWidth: scale)
                    badge.position(end)
                }.frame(width: width, height: height)
            }
        }
    }
    let style: Style
    let image: StationSymbol.Image?

    init(style: Style, coordinate: CLLocationCoordinate2D) {
        self.style = style
        let renderer = ImageRenderer(content: style.glyph)
        renderer.scale = style.density
        #if os(macOS)
        image = renderer.nsImage
        #else
        image = renderer.uiImage
        #endif
        super.init()
        title = style.title
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
