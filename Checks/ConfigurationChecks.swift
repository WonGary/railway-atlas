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
                  && value.interface.uiScale == 1, "partial configuration fills omitted fields with defaults")
        try check(value.interface.panelSize == .medium && !value.interface.inspectorVisible
                  && value.interface.inspectorWidth == 380 && value.interface.inspectorTab == "feature",
                  "pre-panel config migrates to floating medium panel and closed feature inspector")
        let restored = try AtlasConfiguration.decode(value.encoded())
        var stationDetail = try AtlasConfiguration.decode(Data(#"{"layers":{"showsStationLayouts":false}}"#.utf8))
        try check(stationDetail.layers.showsStationLayouts == false && stationDetail.layers.showsPlatforms
                  && stationDetail.layers.showsStationOutlines && stationDetail.layers.showsConcourses && stationDetail.layers.showsPassengerPassages
                  && stationDetail.layers.showsPlatformNumbers, "legacy station detail master and new layer defaults")
        stationDetail.layers.showsStationLayouts = true
        stationDetail.layers.showsPlatforms = false
        stationDetail.layers.showsStationOutlines = false
        stationDetail.layers.showsConcourses = false
        let savedDetail = try AtlasConfiguration.decode(stationDetail.encoded()).layers
        try check(!savedDetail.showsPlatforms && !savedDetail.showsStationOutlines && !savedDetail.showsConcourses && savedDetail.showsPassengerPassages
                  && savedDetail.showsPlatformNumbers, "platform numbers persist independently from platform shapes")
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
            ("invalid endpoint", #"{"assistant":{"endpoint":"http://example.test/v1/responses"}}"#),
            ("null section", #"{"rendering":null}"#)
        ] {
            do { _ = try AtlasConfiguration.decode(Data(json.utf8)) }
            catch { count += 1; print("PASS config rejects " + label); continue }
            throw DataError.invalid("FAIL: config accepted " + label)
        }
        print("\(count) configuration checks passed.")
    }
}
