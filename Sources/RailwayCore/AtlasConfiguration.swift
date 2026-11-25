import Foundation

public enum MapPanelSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, large
    public var id: String { rawValue }
    public var title: String {
        switch self { case .small: "小"; case .medium: "中"; case .large: "大" }
    }
}

public enum MapPanelLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case floating, docked
    public var id: String { rawValue }
    public var title: String { self == .floating ? "浮窗" : "贴边分屏" }
}

public struct RailRenderSettings: Codable, Hashable, Sendable {
    public var metroWidthScale = 1.0
    public var railwayWidthScale = 1.0
    public var stationRadiusMultiplier = 1.25
    public var depotBrightness = 0.5
    public var railwayPattern = true
    public var viewportBuffer = 0.2
    public var focusColor = RailColor.focusPresets[0].hex
    public var focusInk: RailColor { RailColor(focusColor) ?? RailColor(RailColor.focusPresets[0].hex)! }
    public init() {}
}

/// User-editable settings only. Credentials remain in the platform Keychain.
public struct AtlasConfiguration: Codable, Sendable {
    public var version = 1
    public var rendering = RailRenderSettings()
    public var map = MapSettings()
    public var layers = LayerSettings()
    public var interface = InterfaceSettings()
    public var assistant = AssistantSettings()
    public init() {}

    public struct MapSettings: Codable, Sendable {
        public var mode = "apple"
        public var basemapStyle = "standard"
        public var standardBasemapSource = "apple"
        public var satelliteBasemapSource = "apple"
        public var customStandardTileTemplate = ""
        public var customSatelliteTileTemplate = ""
        public var automaticAlignment = true
        public var basemapDarkness = 0.0
        public var alignment = "mainlandGCJ"
        public var tileSource = RailwayTileRepository.defaultSource
    }
    public struct LayerSettings: Codable, Sendable {
        public var categories = RailCategory.allCases.map(\.rawValue)
        public var networks = RailNetwork.allCases.map(\.rawValue)
        public var hiddenRoutes: [String] = []
        public var forcedCategories: [String] = []
        public var forcedNetworks: [String] = []
        public var automaticDetail = true
        public var prioritizesUrbanTransit = false
        public var showsNationalMetroOverview = true
        public var showsStations = true
        public var showsStationLayouts: Bool? = true
        public var showsStationOutlines = true
        public var showsConcourses = true
        public var showsPlatforms = true
        public var showsPassengerPassages = true
        public var showsPlatformNumbers = true
        public var showsStationEntrances = true
        public var showsPassageSigns = true
        public var showsLabels = true
        public var showsMetroColors = true
        public var enrichWikiColours = true
    }
    public struct InterfaceSettings: Codable, Sendable {
        public var uiScale = 1.0
        public var panelWidth = 320.0
        public var panelVisible = true
        public var panelSize = MapPanelSize.medium
        public var panelLayout = MapPanelLayout.floating
        public var panelBackgroundOpacity = 1.0
        public var inspectorVisible = false
        public var inspectorWidth = 380.0
        public var inspectorTab = "feature"
        public var inspectorLayout = MapPanelLayout.docked
        public var inspectorBackgroundOpacity = 1.0
        public var statusVisible = true
        public var statusX = 0.0
        public var statusY = 0.0
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Omitted fields use defaults. Typos, invalid values and future schemas
    /// fail before any live settings are changed.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024 * 1024,
              let incoming = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try JSONSerialization.jsonObject(with: Self().encoded()) as? [String: Any] else {
            throw DataError.invalid("配置必须是小于 1 MB 的 JSON 对象。")
        }
        func merge(_ input: [String: Any], _ defaults: [String: Any], path: String) throws -> [String: Any] {
            var result = defaults
            for (key, value) in input {
                guard let fallback = defaults[key], !(value is NSNull) else {
                    throw DataError.invalid("配置字段无效：\(path)\(key)")
                }
                if let object = fallback as? [String: Any] {
                    guard let supplied = value as? [String: Any] else { throw DataError.invalid("配置字段应为对象：\(path)\(key)") }
                    result[key] = try merge(supplied, object, path: path + key + ".")
                } else { result[key] = value }
            }
            return result
        }
        let merged = try JSONSerialization.data(withJSONObject: merge(incoming, defaults, path: ""))
        var value = try JSONDecoder().decode(Self.self, from: merged)
        if let original = incoming["map"] as? [String: Any], original["automaticAlignment"] == nil,
           let alignment = original["alignment"] as? String, alignment != "mainlandGCJ" {
            value.map.automaticAlignment = false
        }
        try value.validate()
        return value
    }

    public static func validStreetTemplate(_ value: String) -> Bool {
        guard value.count <= 2048, ["{z}", "{x}", "{y}"].allSatisfy(value.contains),
              let url = URLComponents(string:value), url.scheme == "https",
              let host = url.host, !host.isEmpty, !host.contains("{"),
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        let secrets = ["key","token","secret","signature","password"]
        return !(url.queryItems ?? []).contains { item in
            secrets.contains { item.name.lowercased().contains($0) }
        }
    }

    public func validate() throws {
        func number(_ value: Double, _ range: ClosedRange<Double>, _ name: String) throws {
            guard value.isFinite, range.contains(value) else { throw DataError.invalid("\(name) 必须在 \(range.lowerBound)…\(range.upperBound) 之间。") }
        }
        guard version == 1 else { throw DataError.invalid("不支持配置版本 \(version)。") }
        guard rendering.focusColor.count == 7, RailColor(rendering.focusColor) != nil else {
            throw DataError.invalid("高亮色需要使用 #RRGGBB 格式。")
        }
        try number(rendering.metroWidthScale, 0.5...2, "地铁线宽倍率")
        try number(rendering.railwayWidthScale, 0.5...2, "铁路线宽倍率")
        try number(rendering.stationRadiusMultiplier, 0.5...3, "站点半径比例")
        try number(rendering.depotBrightness, 0.1...1, "车辆段亮度")
        try number(rendering.viewportBuffer, 0...0.5, "视野边缘预绘制比例")
        try number(map.basemapDarkness, 0...1, "底图暗化")
        try number(interface.uiScale, 0.75...1.6, "界面缩放")
        try number(interface.panelWidth, 250...560, "侧栏宽度")
        try number(interface.inspectorWidth, 200...560, "右侧栏宽度")
        try number(interface.panelBackgroundOpacity, 0...1, "左侧浮窗背景不透明度")
        try number(interface.inspectorBackgroundOpacity, 0...1, "右侧浮窗背景不透明度")
        try number(interface.statusX, -2000...2000, "状态卡横向位置")
        try number(interface.statusY, -2000...2000, "状态卡纵向位置")
        func tileTemplate(_ value: String, _ name: String, required: Bool) throws {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                guard !required else { throw DataError.invalid("\(name)不能为空。") }
                return
            }
            guard Self.validStreetTemplate(value) else { throw DataError.invalid("\(name)需要包含 {z}、{x}、{y} 的 HTTPS 地址，请移除账号或密钥。") }
        }
        guard ["feature", "assistant"].contains(interface.inspectorTab),
              ["apple", "cached", "offline"].contains(map.mode),
              ["standard", "satellite", "hybrid"].contains(map.basemapStyle),
              ["apple", "gaode", "openStreetMap", "openFreeMap", "versaTiles", "custom"].contains(map.standardBasemapSource),
              ["apple", "gaode", "custom"].contains(map.satelliteBasemapSource),
              MapAlignment(rawValue: map.alignment) != nil,
              layers.categories.allSatisfy({ RailCategory(rawValue: $0) != nil }),
              layers.forcedCategories.allSatisfy({ RailCategory(rawValue: $0) != nil }),
              layers.networks.allSatisfy({ RailNetwork(rawValue: $0) != nil }),
              layers.forcedNetworks.allSatisfy({ RailNetwork(rawValue: $0) != nil }) else {
            throw DataError.invalid("配置中的地图模式、坐标或图层名称无效。")
        }
        try tileTemplate(map.customStandardTileTemplate,
                         "自定义标准地图瓦片地址",
                         required: map.standardBasemapSource == "custom")
        try tileTemplate(map.customSatelliteTileTemplate,
                         "自定义卫星地图瓦片地址",
                         required: map.satelliteBasemapSource == "custom")
        _ = try RailwayTileRepository.normalizeSource(map.tileSource)
        // An unconfigured assistant is valid; validate its address without
        // requiring the user to choose a model just to change map settings.
        try assistant.validate()
    }
}
