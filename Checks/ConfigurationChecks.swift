import Foundation
import RailwayCore

enum ConfigurationChecks {
    static func run() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw DataError.invalid("FAIL: " + label) }
            count += 1; print("PASS " + label)
        }
        let value = try AtlasConfiguration.decode(Data("""
        {"rendering":{"stationRadiusMultiplier":1.5,"metroWidthScale":0.8},
         "assistant":{"webSearch":true},
         "layers":{"categories":["speed350","speed300"],"hiddenRoutes":["metro:seoul:2"]}}
        """.utf8))
        try check(value.rendering.stationRadiusMultiplier == 1.5 && value.rendering.railwayWidthScale == 1
                  && value.interface.uiScale == 1
                  && value.map.standardBasemapSource == "apple"
                  && value.map.satelliteBasemapSource == "apple"
                  && value.map.customStandardTileTemplate.isEmpty,
                  "partial configuration fills omitted fields with defaults")
        try check(value.interface.panelSize == .medium && !value.interface.inspectorVisible
                  && value.interface.inspectorWidth == 380 && value.interface.inspectorTab == "feature",
                  "pre-panel config migrates to floating medium panel and closed feature inspector")
        let restored = try AtlasConfiguration.decode(value.encoded())
        let migrated = try AtlasConfiguration.decode(Data("""
        {"interface":{"mapControlsOpacity":0.27,"topControlsOpacity":0.42,"cornerControlsOpacity":0.63,
                      "bottomCounterOpacity":0.84,"zoomOpacity":0,"mapControlsVisible":false}}
        """.utf8)).interface
        try check(migrated.lineFocusOpacity == 0.42 && migrated.scaleOpacity == 0.63 && migrated.fitOpacity == 0.63
                  && migrated.offlineNoticeOpacity == 0.63 && migrated.zoomOpacity == 0
                  && migrated.footerHandleOpacity == 0.84 && migrated.mobileLauncherOpacity == 0.84
                  && migrated.playbackOpacity == 0.27 && !migrated.topControlsVisible && !migrated.bottomControlsVisible,
                  "old toolbar, corner and counter opacity migrate to their controls and preserve explicit zero")
        let legacy = try AtlasConfiguration.decode(Data(#"{"interface":{"mapControlsOpacity":0.25}}"#.utf8)).interface
        try check(legacy.scaleOpacity == 0.25 && legacy.lineFocusOpacity == 0.25 && legacy.mobileLauncherOpacity == 0.25
                  && legacy.offlineLegendOpacity == 0 && legacy.attributionOpacity == 1,
                  "original single opacity migrates through both generations")
        var distinct = AtlasConfiguration()
        let controls = AtlasConfiguration.MapControl.allCases
        for (index, control) in controls.enumerated() {
            distinct.interface[keyPath: control.opacity] = Double(index) / Double(controls.count)
        }
        let roundTrip = try AtlasConfiguration.decode(distinct.encoded())
        for (index, control) in controls.enumerated() {
            try check(roundTrip.interface[keyPath: control.opacity] == Double(index) / Double(controls.count),
                      control.rawValue + " has its own persisted value")
            var invalid = distinct
            invalid.interface[keyPath: control.opacity] = 1.1
            do { try invalid.validate() }
            catch { continue }
            throw DataError.invalid("accepted an out-of-range value for " + control.rawValue)
        }
        let profiles = try AtlasConfiguration.decode(Data("""
        {"assistant":{"provider":"deepseek","compatible":{"deepseek":{"model":"saved-model","maxOutputTokens":4096}}}}
        """.utf8))
        let saved = try AtlasConfiguration.decode(profiles.encoded()).assistant
        try check(saved.provider == .deepseek && saved.selectedModel == "saved-model" && saved.outputLimit == 4096
                  && saved.compatibleProfile.endpoint == AssistantProvider.deepseek.compatibleDefault?.endpoint
                  && Set(saved.compatible.keys) == ["deepseek"], "saved compatible profile reloads with its overrides and sparse defaults")
        let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/default-config.json")
        try check(try Set(AtlasConfiguration.decode(Data(contentsOf: bundled)).assistant.compatible.keys) == ["deepseek","doubao","custom"],
                  "bundled configuration accepts all supported compatible profiles")
        var stationDetail = try AtlasConfiguration.decode(Data(#"{"layers":{"showsStationLayouts":false}}"#.utf8))
        try check(stationDetail.layers.showsStationLayouts == false && stationDetail.layers.showsPlatforms
                  && stationDetail.layers.showsStationOutlines && stationDetail.layers.showsConcourses && stationDetail.layers.showsPassengerPassages
                  && stationDetail.layers.showsPlatformNumbers && stationDetail.layers.showsStationEntrances
                  && stationDetail.layers.showsPassageSigns, "legacy station detail master and new layer defaults")
        stationDetail.layers.showsStationLayouts = true
        stationDetail.layers.showsPlatforms = false
        stationDetail.layers.showsStationOutlines = false
        stationDetail.layers.showsConcourses = false
        stationDetail.layers.showsStationEntrances = false
        let savedDetail = try AtlasConfiguration.decode(stationDetail.encoded()).layers
        try check(!savedDetail.showsPlatforms && !savedDetail.showsStationOutlines && !savedDetail.showsConcourses && savedDetail.showsPassengerPassages
                  && savedDetail.showsPlatformNumbers && !savedDetail.showsStationEntrances && savedDetail.showsPassageSigns,
                  "platform, entrance, and passage switches persist independently")
        try check(!value.layers.prioritizesUrbanTransit && !restored.layers.prioritizesUrbanTransit,
                  "old config defaults urban priority off without changing category/route preferences")
        var priority = value
        priority.layers.prioritizesUrbanTransit = true
        priority.layers.showsNationalMetroOverview = false
        let priorityRestored = try AtlasConfiguration.decode(priority.encoded())
        try check(priorityRestored.layers.prioritizesUrbanTransit && !priorityRestored.layers.showsNationalMetroOverview
                  && priorityRestored.layers.categories == value.layers.categories
                  && priorityRestored.layers.hiddenRoutes == value.layers.hiddenRoutes,
                  "urban priority persists independently from overview and existing filters")
        try check(restored.assistant.webSearch && restored.layers.categories == ["speed350", "speed300"]
                  && restored.layers.hiddenRoutes == ["metro:seoul:2"], "search and per-class/per-line switches survive JSON round trip")
        var basemaps = value
        basemaps.map.standardBasemapSource = "openStreetMap"
        basemaps.map.satelliteBasemapSource = "gaode"
        basemaps.map.customStandardTileTemplate = "https://tiles.example.test/{z}/{x}/{y}.png"
        basemaps.map.customSatelliteTileTemplate = "https://tiles.example.test/satellite/{z}/{x}/{y}.jpg"
        let basemapRestored = try AtlasConfiguration.decode(basemaps.encoded())
        try check(basemapRestored.map.standardBasemapSource == "openStreetMap"
                  && basemapRestored.map.satelliteBasemapSource == "gaode"
                  && basemapRestored.map.customStandardTileTemplate.contains("{z}")
                  && basemapRestored.map.customSatelliteTileTemplate.contains("{y}"),
                  "standard and satellite basemap sources survive JSON round trip")
        basemaps.map.standardBasemapSource = "versaTiles"
        basemaps.map.automaticAlignment = true
        try check(try AtlasConfiguration.decode(basemaps.encoded()).map.standardBasemapSource == "versaTiles",
                  "vector basemap source and automatic alignment survive JSON round trip")
        for (label, json) in [
            ("future schema", #"{"version":99}"#),
            ("unknown property", #"{"rendering":{"stationRaduis":2}}"#),
            ("invalid radius", #"{"rendering":{"stationRadiusMultiplier":-1}}"#),
            ("invalid viewport buffer", #"{"rendering":{"viewportBuffer":0.6}}"#),
            ("invalid width", #"{"rendering":{"metroWidthScale":50}}"#),
            ("invalid layer", #"{"layers":{"categories":["magical"]}}"#),
            ("invalid urban priority type", #"{"layers":{"prioritizesUrbanTransit":"true"}}"#),
            ("null urban priority", #"{"layers":{"prioritizesUrbanTransit":null}}"#),
            ("invalid panel size", #"{"interface":{"panelSize":"giant"}}"#),
            ("invalid inspector pane", #"{"interface":{"inspectorTab":"unknown"}}"#),
            ("invalid inspector width", #"{"interface":{"inspectorWidth":40}}"#),
            ("credentials in config", #"{"assistant":{"apiKey":"secret"}}"#),
            ("unknown compatible provider", #"{"assistant":{"compatible":{"deepsekk":{}}}}"#),
            ("unknown compatible field", #"{"assistant":{"compatible":{"deepseek":{"apiKey":"secret"}}}}"#),
            ("invalid compatible endpoint", #"{"assistant":{"compatible":{"deepseek":{"endpoint":"http://example.test"}}}}"#),
            ("invalid compatible token type", #"{"assistant":{"compatible":{"deepseek":{"maxOutputTokens":"3000"}}}}"#),
            ("invalid endpoint", #"{"assistant":{"endpoint":"http://example.test/v1/responses"}}"#),
            ("invalid standard basemap source", #"{"map":{"standardBasemapSource":"unknownProvider"}}"#),
            ("vector street source used as satellite", #"{"map":{"satelliteBasemapSource":"versaTiles"}}"#),
            ("credentials in custom tile authority", #"{"map":{"customStandardTileTemplate":"https://me:secret@tiles.example.test/{z}/{x}/{y}"}}"#),
            ("invalid satellite basemap source", #"{"map":{"satelliteBasemapSource":"openStreetMap"}}"#),
            ("missing custom standard template", #"{"map":{"standardBasemapSource":"custom"}}"#),
            ("invalid custom tile scheme", #"{"map":{"customStandardTileTemplate":"http://tiles.example.test/{z}/{x}/{y}.png"}}"#),
            ("missing custom tile placeholder", #"{"map":{"customStandardTileTemplate":"https://tiles.example.test/{z}/{x}.png"}}"#),
            ("credential in custom tile URL", #"{"map":{"customStandardTileTemplate":"https://tiles.example.test/{z}/{x}/{y}.png?apiKey=secret"}}"#),
            ("null section", #"{"rendering":null}"#)
        ] {
            do { _ = try AtlasConfiguration.decode(Data(json.utf8)) }
            catch { count += 1; print("PASS config rejects " + label); continue }
            throw DataError.invalid("FAIL: config accepted " + label)
        }
        print("\(count) configuration checks passed.")
    }
}
