import MapKit
import RailwayCore
import SwiftUI

/// Embedded in SidebarView's existing ScrollView; no extra scroll surface.
@MainActor
struct DiscoveryView: View {
    @Environment(\.atlasUIScale) private var uiScale
    @EnvironmentObject private var store: RailwayMapStore
    @ObservedObject private var favorites = FavoriteStore.shared
    @State private var cities: [DiscoveryCity] = []
    @State private var stations: [DiscoveryStation] = []
    @State private var favoriteCity: String?
    @State private var groupsFavorites = false
    @State private var editingFavorite: FavoriteEntry?
    @Environment(\.openWindow) private var openWindow
    @State private var showsExperiences = false

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 8 * uiScale), GridItem(.flexible(), spacing: 8 * uiScale)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            overview
            Button {
                #if os(macOS)
                openWindow(id: "railway-experiences")
                #else
                showsExperiences = true
                #endif
            } label: {
                HStack(spacing: 10 * uiScale) {
                    Image(systemName: "ticket").atlasFont(.title3)
                    VStack(alignment: .leading, spacing: 3 * uiScale) {
                        Text("铁道漫游").atlasFont(.subheadline.weight(.semibold))
                        Text("猜城市 · 护照 · 明信片 · 时光机").atlasFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").atlasFont(.caption)
                }
                .atlasPadding(12)
                .atlasPanelDecoration(Color.railwayAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12 * uiScale))
            }.buttonStyle(.plain).foregroundStyle(Color.railwayAccent)
                .accessibilityIdentifier("open-railway-experiences")
            #if os(iOS)
            RailGameShortcuts { tab in
                store.journeyWorkspace.tab = tab
                showsExperiences = true
            }.frame(height: 44)
            #endif
            favoriteSection
            citySection
            stationSection
        }
        .onAppear {
            if cities.isEmpty { cities = DiscoveryCatalog.randomCities() }
            if stations.isEmpty { stations = DiscoveryCatalog.randomStations() }
            favorites.reconcile(with: store)
        }
        .onChange(of: favorites.cityGroups.map(\.city)) { _, cities in
            if let favoriteCity, !cities.contains(favoriteCity) { self.favoriteCity = nil }
        }
        .sheet(item: $editingFavorite) { entry in
            FavoriteEditorView(entry: entry, favorites: favorites)
                .environmentObject(store)
                .environment(\.atlasUIScale, uiScale)
        }
        .sheet(isPresented: $showsExperiences) { ExperienceRootView(model: store.journeyWorkspace, map: store) }
        .accessibilityIdentifier("discovery-view")
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            HStack {
                Text(store.activeName).atlasFont(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Button { store.fitDataset() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .atlasFont(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Color.railwayAccent)
                .help(store.mapMode == .offline ? "查看整个区域" : "查看全国")
                .accessibilityLabel("查看整个区域")
            }
            HStack(spacing: 12 * uiScale) {
                countSummary(store.activeLines.count, title: "视野区段")
                countSummary(store.activeStations.count, title: "车站")
            }
        }
        .atlasPadding(12)
        .atlasPanelDecoration(Color.railwayAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12 * uiScale))
        .accessibilityIdentifier("discovery-overview")
    }

    private func countSummary(_ count: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2 * uiScale) {
            Text(count.formatted()).atlasFont(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(title).atlasFont(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(count)")
    }

    private var favoriteSection: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            HStack {
                Label("我的收藏", systemImage: "star.fill")
                    .atlasFont(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(favorites.entries.count)").atlasFont(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityAddTraits(.isHeader)
            if favorites.entries.isEmpty {
                Text("点选线路或站点，按五角星收藏。")
                    .atlasFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8 * uiScale) {
                    Picker("城市", selection: $favoriteCity) {
                        Text("全部城市").tag(Optional<String>.none)
                        ForEach(favorites.cityGroups) { group in
                            Text("\(group.title) · \(group.entries.count)").tag(Optional(group.city))
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .atlasFont(.caption).atlasControlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("筛选收藏城市")
                    .accessibilityIdentifier("favorite-city-filter")
                    Toggle(isOn: $groupsFavorites) {
                        Label("按城市分组", systemImage: "rectangle.3.group")
                    }
                    .toggleStyle(.button).labelStyle(.iconOnly)
                    .atlasFont(.caption).atlasControlSize(.small)
                    .help("按城市分组")
                    .accessibilityLabel("按城市分组")
                    .accessibilityIdentifier("favorite-city-grouping")
                }
                LazyVStack(spacing: 2 * uiScale) {
                    if groupsFavorites && favoriteCity == nil {
                        ForEach(favorites.cityGroups) { group in
                            HStack {
                                Text(group.title).atlasFont(.caption.weight(.semibold))
                                Spacer()
                                Text("\(group.entries.count)").atlasFont(.caption2)
                            }
                            .foregroundStyle(.secondary).atlasPadding(.top, 7).atlasPadding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(group.entries) { favoriteRow($0) }
                        }
                    } else {
                        ForEach(favorites.entries(inCity: favoriteCity)) { favoriteRow($0) }
                    }
                }
            }
            if let message = favorites.persistenceMessage {
                Text(message).atlasFont(.caption2).foregroundStyle(.orange)
            }
        }
        .accessibilityIdentifier("discovery-favorites")
    }

    private func favoriteRow(_ entry: FavoriteEntry) -> some View {
        HStack(spacing: 4 * uiScale) {
            if let snapshot = entry.snapshot {
                Button { favorites.locate(entry, on: store) } label: {
                    HStack(spacing: 8 * uiScale) {
                        Image(systemName: snapshot.kind.icon)
                            .atlasFont(.system(size: 13))
                            .atlasFrame(width: 22)
                            .foregroundStyle(Color.railwayAccent)
                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text(snapshot.name).atlasFont(.caption.weight(.medium)).lineLimit(1)
                            Text("\(snapshot.kind.title) · \(entry.isLoaded ? "已载入" : "已保存位置")")
                                .atlasFont(.caption2).foregroundStyle(.secondary)
                            filingLabel(entry)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "location").atlasFont(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("定位 \(snapshot.name)")
                .accessibilityLabel("定位收藏，\(snapshot.kind.title)，\(snapshot.name)")
                .accessibilityValue(filingText(entry))
                .accessibilityHint(entry.isLoaded ? "查看地图详情" : "前往保存的位置并载入地图")
                .accessibilityIdentifier("favorite-locate-\(entry.id)")
            } else {
                HStack(spacing: 8 * uiScale) {
                    Image(systemName: "clock").atlasFont(.caption)
                        .atlasFrame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2 * uiScale) {
                        Text("待载入").atlasFont(.caption.weight(.medium))
                        Text(entry.id).atlasFont(.caption2.monospaced())
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        filingLabel(entry)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                .help("旧收藏尚无位置快照；再次载入对应地图数据后恢复。\(entry.id)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("旧收藏待载入，尚无保存位置，\(entry.id)，\(filingText(entry))")
            }

            Button { editingFavorite = entry } label: {
                Image(systemName: "pencil")
                    .atlasFont(.caption)
                    .frame(minWidth: rowHeight, minHeight: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("编辑城市与标签")
            .accessibilityLabel("编辑收藏城市与标签，\(entry.snapshot?.name ?? entry.id)")
            .accessibilityIdentifier("favorite-edit-\(entry.id)")

            Button(role: .destructive) { favorites.remove(entry.id, in: store) } label: {
                Image(systemName: "xmark.circle")
                    .atlasFont(.caption)
                    .frame(minWidth: rowHeight, minHeight: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("移除收藏")
            .accessibilityLabel("移除收藏，\(entry.snapshot?.name ?? entry.id)")
            .accessibilityIdentifier("favorite-remove-\(entry.id)")
        }
        .atlasPadding(.horizontal, 4)
        .atlasPanelDecoration(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8 * uiScale))
        .contextMenu {
            Button("编辑城市与标签", systemImage: "pencil") { editingFavorite = entry }
            if entry.snapshot != nil {
                Button("定位", systemImage: "location") { favorites.locate(entry, on: store) }
            }
            Button("移除收藏", systemImage: "star.slash", role: .destructive) {
                favorites.remove(entry.id, in: store)
            }
        }
    }

    @ViewBuilder
    private func filingLabel(_ entry: FavoriteEntry) -> some View {
        let text = filingText(entry)
        if !text.isEmpty {
            Text(text).atlasFont(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail).help(text)
        }
    }

    private func filingText(_ entry: FavoriteEntry) -> String {
        ([entry.annotation.city].filter { !$0.isEmpty } + entry.annotation.labels.map { "#\($0)" })
            .joined(separator: " · ")
    }

    private var rowHeight: Double {
        #if os(macOS)
        34 * uiScale
        #else
        max(44, 40 * uiScale)
        #endif
    }

    private var citySection: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            HStack {
                Text("城市灵感").atlasFont(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("10 城").atlasFont(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("换一批", systemImage: "arrow.clockwise") {
                    cities = DiscoveryCatalog.randomCities(excluding: Set(cities.map(\.id)))
                }
                .buttonStyle(.borderless).atlasFont(.caption)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("更换 10 座城市（⇧⌘R）")
                .accessibilityLabel("刷新城市灵感，换十座城市")
                .accessibilityIdentifier("discovery-refresh-cities")
            }
            LazyVGrid(columns: columns, spacing: 6 * uiScale) {
                ForEach(cities) { city in
                    Button { navigate(to: city.region) } label: {
                        destinationLabel(city.name, country: city.country)
                    }
                    .buttonStyle(.bordered).atlasControlSize(.small)
                    .help("\(city.name) · \(city.country) · 约 50 × 50 km")
                    .accessibilityLabel("\(city.name)，\(city.country)")
                    .accessibilityHint("显示约五十公里见方的地图")
                    .accessibilityIdentifier(city.id)
                }
            }
        }
        .accessibilityIdentifier("discovery-cities")
    }

    private var stationSection: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            HStack {
                Text("车站漫游").atlasFont(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("20 处").atlasFont(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("换一批", systemImage: "arrow.clockwise") {
                    stations = DiscoveryCatalog.randomStations(excluding: Set(stations.map(\.id)))
                }
                .buttonStyle(.borderless).atlasFont(.caption)
                .keyboardShortcut("r", modifiers: [.command, .control])
                .help("更换 20 处车站与站场（⌃⌘R）")
                .accessibilityLabel("刷新车站漫游，四类各五处")
                .accessibilityIdentifier("discovery-refresh-stations")
            }
            ForEach(DiscoveryStationKind.allCases) { kind in
                Label(kind.title, systemImage: kind.icon)
                    .atlasFont(.caption).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: columns, spacing: 6 * uiScale) {
                    ForEach(stations.filter { $0.kind == kind }) { station in
                        Button { navigate(to: station.region) } label: {
                            destinationLabel(station.name, country: station.country)
                        }
                        .buttonStyle(.bordered).atlasControlSize(.small)
                        .help("\(station.name) · \(station.country) · 定位附近")
                        .accessibilityLabel("\(station.name)，\(station.country)，\(kind.title)")
                        .accessibilityHint("定位附近，载入真实地图要素")
                        .accessibilityIdentifier(station.id)
                        .contextMenu {
                            Button("定位附近", systemImage: "location") { navigate(to: station.region) }
                            Link("位置参考", destination: station.referenceURL)
                        }
                    }
                }
            }
            Text("目录用于定位，详情以地图载入为准。")
                .atlasFont(.caption2).foregroundStyle(.tertiary)
        }
        .accessibilityIdentifier("discovery-stations")
    }

    private func destinationLabel(_ name: String, country: String) -> some View {
        VStack(alignment: .leading, spacing: 4 * uiScale) {
            Text(name).atlasFont(.caption.weight(.medium))
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text(country).atlasFont(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .atlasPadding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func navigate(to region: MKCoordinateRegion) {
        store.selection = nil
        store.searchText = ""
        store.showsStations = true
        store.region = region
        store.cameraRevision += 1
        if store.mapMode == .offline {
            store.changeMode(.apple)
        } else {
            store.rebuildVisible()
            store.refreshViewport()
        }
    }
}
