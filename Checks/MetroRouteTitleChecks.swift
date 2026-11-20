import Foundation
import RailwayCore

enum MetroRouteTitleChecks {
    static func run() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw DataError.invalid("MetroRouteTitle: " + message) }
        }
        func route(_ id: Int, _ name: String, _ tags: [String: String]) throws -> RailRoute {
            try JSONDecoder().decode(RailRoute.self, from: JSONSerialization.data(withJSONObject: [
                "id": "relation/\(id)", "name": name, "tags": tags
            ]))
        }
        let shenzhen = try route(1, "深圳地铁4号线", [
            "ref": "4", "network": "深圳地铁", "operator": "香港鐵路有限公司",
            "atlas:paletteIdentity": "metro:shenzhen:sz4"
        ])
        let hongkong = try route(2, "港鐵荃灣綫", [
            "ref": "TWL", "network": "港鐵", "atlas:paletteIdentity": "metro:hongkong:twl"
        ])
        let border = MetroRouteTitle.labels([shenzhen, hongkong])
        try check(border[shenzhen.visibilityKey] == "深圳4" && border[hongkong.visibilityKey] == "香港TWL",
                  "mixed Shenzhen/Hong Kong labels distinguish networks, regardless of operator")
        try check(MetroRouteTitle.labels([shenzhen])[shenzhen.visibilityKey] == "4",
                  "a single network does not acquire a redundant city prefix")
        var withoutIdentity = shenzhen
        withoutIdentity.tags.removeValue(forKey: "atlas:paletteIdentity")
        try check(MetroRouteTitle.labels([withoutIdentity, hongkong])[withoutIdentity.visibilityKey] == "深圳4",
                  "explicit Shenzhen network wins over its Hong Kong operator")

        let cityGroups: [[(city: String, line: String, ref: String, expected: String)]] = [
            [("beijing", "bj1", "1", "北京1"), ("tianjin", "tj2", "2", "天津2")],
            [("guangzhou", "gz1", "1", "广州1"), ("foshan", "fs2", "2", "佛山2"),
             ("dongguan", "r2", "2", "东莞2"), ("shenzhen", "sz4", "4", "深圳4"),
             ("hongkong", "twl", "TWL", "香港TWL")],
            [("shanghai", "sh1", "1", "上海1"), ("suzhou", "sz2", "2", "苏州2"),
             ("nanjing", "nj3", "3", "南京3"), ("hangzhou", "hz4", "4", "杭州4")],
            [("tokyo", "g", "G", "东京G"), ("paris", "m1", "1", "巴黎1"),
             ("algiers", "m1", "1", "Algiers 1")]
        ]
        for (groupIndex, group) in cityGroups.enumerated() {
            let routes = try group.enumerated().map { index, sample in
                try route(100 + groupIndex * 20 + index, "Line \(sample.ref)", [
                    "ref": sample.ref, "atlas:paletteIdentity": "metro:\(sample.city):\(sample.line)"
                ])
            }
            let labels = MetroRouteTitle.labels(routes)
            for (sample, item) in zip(group, routes) {
                try check(labels[item.visibilityKey] == sample.expected,
                          "multi-city labels use catalogue city names: \(sample.expected)")
            }
            try check(Set(labels.keys) == Set(routes.map(\.visibilityKey)),
                      "multi-city labels preserve every original visibility key")
        }
        let beijing = try route(30, "北京地铁1号线", [
            "ref": "1", "atlas:paletteIdentity": "metro:beijing:bj1"
        ])
        let beijing2 = try route(31, "北京地铁2号线", [
            "ref": "2", "atlas:paletteIdentity": "metro:beijing:bj2"
        ])
        let singleCity = MetroRouteTitle.labels([beijing, beijing2])
        try check(singleCity[beijing.visibilityKey] == "1" && singleCity[beijing2.visibilityKey] == "2",
                  "multiple lines in one city keep short numbers")
        let tianjin = try route(32, "2号线", [
            "ref": "2", "atlas:paletteCity": "tianjin", "operator": "北京地铁"
        ])
        try check(MetroRouteTitle.labels([beijing, tianjin])[tianjin.visibilityKey] == "天津2",
                  "an explicit catalogue city works without a line identity, regardless of operator")
        let namedBeijing = try route(37, "北京地铁1号线", [:])
        let namedTianjin = try route(38, "天津地铁2号线", [:])
        let namedCities = MetroRouteTitle.labels([namedBeijing, namedTianjin])
        try check(namedCities[namedBeijing.visibilityKey] == "北京1"
                  && namedCities[namedTianjin.visibilityKey] == "天津2",
                  "explicit leading city-and-line names work without palette metadata")
        let unknowns = [
            try route(33, "Line 7 to Tianjin", ["ref": "7", "operator": "北京地铁"]),
            try route(34, "Line 8", [
                "ref": "8", "atlas:paletteIdentity": "metro:unlisted:8", "network": "天津地铁"
            ]),
            try route(35, "Line 9", [
                "ref": "9", "atlas:paletteCity": "unlisted", "network": "北京地铁"
            ]),
            try route(36, "Beijing → Tianjin", ["ref": "10"])
        ]
        let withUnknowns = MetroRouteTitle.labels([beijing] + unknowns)
        try check(withUnknowns[beijing.visibilityKey] == "1",
                  "unconfirmed cities do not trigger multi-city prefixes")
        let mixedUnknowns = MetroRouteTitle.labels([beijing, tianjin] + unknowns)
        for item in unknowns {
            try check(withUnknowns[item.visibilityKey] == item.tags["ref"]
                      && mixedUnknowns[item.visibilityKey] == item.tags["ref"],
                      "unknown catalogue cities, operators and termini never supply a guessed prefix")
        }

        let seoul = try route(3, "서울 지하철 1호선 (소요산 → 인천)", [
            "ref": "1", "network": "수도권 전철", "operator": "인천교통공사",
            "atlas:paletteIdentity": "metro:seoul:s1"
        ])
        let incheon = try route(4, "인천 도시철도 1호선", [
            "ref": "1", "network": "수도권 전철", "atlas:paletteIdentity": "metro:seoul:i1"
        ])
        let korea = MetroRouteTitle.labels([seoul, incheon])
        try check(korea[seoul.visibilityKey] == "首尔1" && korea[incheon.visibilityKey] == "仁川1",
                  "Seoul line 1 reaching Incheon retains its own prefix")
        var unclassifiedSeoul = seoul
        unclassifiedSeoul.tags.removeValue(forKey: "atlas:paletteIdentity")
        try check(MetroRouteTitle.labels([unclassifiedSeoul, incheon])[unclassifiedSeoul.visibilityKey] == "首尔1",
                  "an endpoint or operator containing Incheon is not an Incheon line identity")
        let koreanName = try route(5, "인천1호선".decomposedStringWithCanonicalMapping, ["network": "수도권 전철"])
        try check(MetroRouteTitle.labels([seoul, koreanName])[koreanName.visibilityKey] == "仁川1",
                  "an explicit Korean Incheon line name works without a palette identity or ref")
        for (line, ref, expected) in [("i2", "2", "仁川2"), ("im", "M", "仁川M"), ("a", "A", "首尔A")] {
            let item = try route(6, "Line \(ref) to Incheon", [
                "ref": ref, "atlas:paletteIdentity": "metro:seoul:\(line)", "operator": "인천교통공사"
            ])
            try check(MetroRouteTitle.labels([seoul, incheon, item])[item.visibilityKey] == expected,
                      "only dedicated Incheon line identities change the Seoul display city: \(line)")
        }

        for (name, tags, expected) in [
            ("上海地铁2号线", [String: String](), "2"),
            ("東京メトロ銀座線", [:], "銀座線"),
            ("港鐵屯馬綫（金鐘 → 烏溪沙）", ["network": "港鐵"], "屯馬綫"),
            ("北京地铁昌平线", ["network": "北京地铁"], "昌平线"),
            ("South Island Line (West)", [:], "South Island Line (West)"),
            ("Line 2: Airport Branch", [:], "Line 2: Airport Branch"),
            ("支线", ["ref": "1;2号线"], "1;2号线"),
            ("线路全称", ["short_name": "机场快线"], "机场快线")
        ] {
            try check(MetroRouteTitle.short(try route(10, name, tags)) == expected,
                      "short title preserves the meaningful name/branch: \(name)")
        }
        let duplicateHover = try route(20, "上海地铁1号线", ["network": "上海地铁", "operator": "上海地铁"])
        try check(MetroRouteTitle.full(duplicateHover) == "上海地铁1号线",
                  "hover does not repeat network/operator already in the full name")
        let hover = try route(21, "Line 1", ["network": "MTR", "operator": "MTR Corporation"])
        try check(MetroRouteTitle.full(hover) == "Line 1 · MTR Corporation",
                  "hover keeps distinct operator information without repeating its network name")
        let boundary = try route(22, "Metropolitan Line", ["network": "Metro"])
        try check(MetroRouteTitle.full(boundary) == "Metropolitan Line · Metro",
                  "hover deduplication respects Latin word boundaries")
        var prefixed = incheon
        prefixed.tags["ref"] = "仁川 1"
        try check(MetroRouteTitle.labels([seoul, prefixed])[prefixed.visibilityKey] == "仁川 1",
                  "an explicit city prefix is not repeated")
        var compactPrefixed = beijing
        compactPrefixed.tags["ref"] = "北京1"
        try check(MetroRouteTitle.labels([compactPrefixed, tianjin])[compactPrefixed.visibilityKey] == "北京1",
                  "a compact Chinese city prefix is not repeated")
        let inputs = [shenzhen, hongkong, seoul, incheon]
        let labels = MetroRouteTitle.labels(inputs)
        try check(Set(labels.keys) == Set(inputs.map(\.visibilityKey)),
                  "short labels retain all distinct visibility identities")
        print("PASS metro route titles: multi-city labels, single-city numbers, unknown cities, Seoul/Incheon and hover.")
    }
}
