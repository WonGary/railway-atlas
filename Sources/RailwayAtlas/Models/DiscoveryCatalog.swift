import MapKit
import RailwayCore

struct DiscoveryCity: Identifiable, Sendable {
    let name: String
    let country: String
    let countryCode: String
    let coordinate: Coordinate
    var id: String { "discovery.city.\(countryCode).\(name)" }

    init(_ name: String, _ country: String, _ countryCode: String, _ latitude: Double, _ longitude: Double) {
        self.name = name
        self.country = country
        self.countryCode = countryCode
        coordinate = Coordinate(latitude, longitude)
    }

    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate.location,
                           latitudinalMeters: 50_000, longitudinalMeters: 50_000)
    }
}

enum DiscoveryStationKind: String, CaseIterable, Sendable, Identifiable {
    case passenger, freight, metro, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .passenger: "客运"
        case .freight: "货运"
        case .metro: "地铁"
        case .other: "其他"
        }
    }
    var icon: String {
        switch self {
        case .passenger: "tram.fill"
        case .freight: "shippingbox"
        case .metro: "tram"
        case .other: "clock.arrow.circlepath"
        }
    }
}

/// An editorial navigation landmark, NOT an OSM feature or RailwaySelection.
/// Coordinates are rounded WGS84 vicinity centers; the reference identifies the
/// named landmark. Categories describe the directory, not live OSM attributes.
struct DiscoveryStation: Identifiable, Sendable {
    let name: String
    let country: String
    let kind: DiscoveryStationKind
    let coordinate: Coordinate
    let referenceArticle: String
    var id: String { "discovery.station.\(referenceArticle)" }

    init(_ name: String, _ country: String, _ kind: DiscoveryStationKind,
         _ latitude: Double, _ longitude: Double, _ referenceArticle: String) {
        self.name = name
        self.country = country
        self.kind = kind
        coordinate = Coordinate(latitude, longitude)
        self.referenceArticle = referenceArticle
    }

    var referenceURL: URL {
        URL(string: "https://en.wikipedia.org/wiki/")!.appendingPathComponent(referenceArticle)
    }

    var region: MKCoordinateRegion {
        let meters: Double = kind == .freight ? 8_000 : 4_000
        return MKCoordinateRegion(center: coordinate.location,
                                  latitudinalMeters: meters, longitudinalMeters: meters)
    }
}

enum DiscoveryCatalog {
    static let cityBatchSize = 10
    static let stationsPerKind = 5

    static func randomCities(excluding previous: Set<String> = []) -> [DiscoveryCity] {
        var generator = SystemRandomNumberGenerator()
        return randomCities(excluding: previous, using: &generator)
    }

    static func randomCities<R: RandomNumberGenerator>(
        excluding previous: Set<String> = [], using generator: inout R
    ) -> [DiscoveryCity] {
        sample(cities, count: cityBatchSize, excluding: previous, using: &generator)
    }

    static func randomStations(excluding previous: Set<String> = []) -> [DiscoveryStation] {
        var generator = SystemRandomNumberGenerator()
        return randomStations(excluding: previous, using: &generator)
    }

    static func randomStations<R: RandomNumberGenerator>(
        excluding previous: Set<String> = [], using generator: inout R
    ) -> [DiscoveryStation] {
        DiscoveryStationKind.allCases.flatMap { kind in
            sample(stations.filter { $0.kind == kind }, count: stationsPerKind,
                   excluding: previous, using: &generator)
        }
    }

    private static func sample<Item: Identifiable, R: RandomNumberGenerator>(
        _ items: [Item], count: Int, excluding previous: Set<String>, using generator: inout R
    ) -> [Item] where Item.ID == String {
        // Exhaust unseen entries before reusing any from the previous batch.
        let fresh = items.filter { !previous.contains($0.id) }.shuffled(using: &generator)
        let reused = items.filter { previous.contains($0.id) }.shuffled(using: &generator)
        return Array((fresh + reused).prefix(count))
    }

    // City centers only: inclusion does not claim that a city has a railway.
    // Major urban networks are supplemented by capitals, including small states
    // and island countries where an empty railway map can be the correct result.
    static let cities: [DiscoveryCity] = [
        .init("北京", "中国", "CN", 39.904, 116.407),
        .init("上海", "中国", "CN", 31.230, 121.474),
        .init("广州", "中国", "CN", 23.129, 113.264),
        .init("深圳", "中国", "CN", 22.543, 114.058),
        .init("南京", "中国", "CN", 32.060, 118.797),
        .init("杭州", "中国", "CN", 30.274, 120.155),
        .init("武汉", "中国", "CN", 30.593, 114.305),
        .init("成都", "中国", "CN", 30.572, 104.067),
        .init("重庆", "中国", "CN", 29.563, 106.551),
        .init("西安", "中国", "CN", 34.342, 108.940),
        .init("郑州", "中国", "CN", 34.747, 113.625),
        .init("长沙", "中国", "CN", 28.228, 112.939),
        .init("南昌", "中国", "CN", 28.683, 115.858),
        .init("天津", "中国", "CN", 39.084, 117.201),
        .init("青岛", "中国", "CN", 36.067, 120.383),
        .init("沈阳", "中国", "CN", 41.805, 123.432),
        .init("哈尔滨", "中国", "CN", 45.804, 126.535),
        .init("昆明", "中国", "CN", 25.039, 102.718),
        .init("乌鲁木齐", "中国", "CN", 43.825, 87.617),
        .init("拉萨", "中国", "CN", 29.653, 91.172),
        .init("香港", "中国", "CN", 22.319, 114.169),
        .init("澳门", "中国", "CN", 22.198, 113.544),
        .init("台北", "中国", "CN", 25.033, 121.565),
        .init("东京", "日本", "JP", 35.682, 139.767),
        .init("大阪", "日本", "JP", 34.694, 135.502),
        .init("京都", "日本", "JP", 35.012, 135.768),
        .init("名古屋", "日本", "JP", 35.181, 136.906),
        .init("福冈", "日本", "JP", 33.590, 130.402),
        .init("札幌", "日本", "JP", 43.062, 141.354),
        .init("首尔", "韩国", "KR", 37.566, 126.978),
        .init("釜山", "韩国", "KR", 35.180, 129.076),
        .init("平壤", "朝鲜", "KP", 39.039, 125.763),
        .init("乌兰巴托", "蒙古", "MN", 47.918, 106.917),
        .init("新加坡", "新加坡", "SG", 1.352, 103.820),
        .init("曼谷", "泰国", "TH", 13.756, 100.502),
        .init("河内", "越南", "VN", 21.028, 105.834),
        .init("胡志明市", "越南", "VN", 10.823, 106.630),
        .init("吉隆坡", "马来西亚", "MY", 3.139, 101.687),
        .init("雅加达", "印度尼西亚", "ID", -6.208, 106.846),
        .init("泗水", "印度尼西亚", "ID", -7.257, 112.752),
        .init("马尼拉", "菲律宾", "PH", 14.600, 120.984),
        .init("内比都", "缅甸", "MM", 19.764, 96.078),
        .init("仰光", "缅甸", "MM", 16.841, 96.174),
        .init("金边", "柬埔寨", "KH", 11.556, 104.928),
        .init("万象", "老挝", "LA", 17.975, 102.633),
        .init("斯里巴加湾", "文莱", "BN", 4.903, 114.940),
        .init("帝力", "东帝汶", "TL", -8.557, 125.561),
        .init("新德里", "印度", "IN", 28.614, 77.209),
        .init("孟买", "印度", "IN", 19.076, 72.878),
        .init("加尔各答", "印度", "IN", 22.573, 88.364),
        .init("金奈", "印度", "IN", 13.083, 80.271),
        .init("班加罗尔", "印度", "IN", 12.972, 77.595),
        .init("达卡", "孟加拉国", "BD", 23.810, 90.413),
        .init("伊斯兰堡", "巴基斯坦", "PK", 33.684, 73.047),
        .init("卡拉奇", "巴基斯坦", "PK", 24.861, 67.010),
        .init("科伦坡", "斯里兰卡", "LK", 6.927, 79.861),
        .init("斯里贾亚瓦德纳普拉科特", "斯里兰卡", "LK", 6.895, 79.902),
        .init("加德满都", "尼泊尔", "NP", 27.717, 85.324),
        .init("廷布", "不丹", "BT", 27.473, 89.639),
        .init("马累", "马尔代夫", "MV", 4.175, 73.509),
        .init("喀布尔", "阿富汗", "AF", 34.555, 69.207),
        .init("塔什干", "乌兹别克斯坦", "UZ", 41.299, 69.240),
        .init("阿斯塔纳", "哈萨克斯坦", "KZ", 51.169, 71.450),
        .init("阿拉木图", "哈萨克斯坦", "KZ", 43.238, 76.945),
        .init("比什凯克", "吉尔吉斯斯坦", "KG", 42.875, 74.570),
        .init("杜尚别", "塔吉克斯坦", "TJ", 38.560, 68.787),
        .init("阿什哈巴德", "土库曼斯坦", "TM", 37.960, 58.326),
        .init("德黑兰", "伊朗", "IR", 35.689, 51.389),
        .init("巴格达", "伊拉克", "IQ", 33.315, 44.366),
        .init("安卡拉", "土耳其", "TR", 39.933, 32.860),
        .init("伊斯坦布尔", "土耳其", "TR", 41.008, 28.978),
        .init("利雅得", "沙特阿拉伯", "SA", 24.714, 46.675),
        .init("阿布扎比", "阿联酋", "AE", 24.453, 54.377),
        .init("迪拜", "阿联酋", "AE", 25.205, 55.271),
        .init("多哈", "卡塔尔", "QA", 25.285, 51.531),
        .init("麦纳麦", "巴林", "BH", 26.228, 50.586),
        .init("科威特城", "科威特", "KW", 29.376, 47.977),
        .init("马斯喀特", "阿曼", "OM", 23.588, 58.383),
        .init("萨那", "也门", "YE", 15.369, 44.191),
        .init("安曼", "约旦", "JO", 31.945, 35.928),
        .init("贝鲁特", "黎巴嫩", "LB", 33.894, 35.502),
        .init("大马士革", "叙利亚", "SY", 33.514, 36.277),
        .init("特拉维夫", "以色列", "IL", 32.085, 34.782),
        .init("拉姆安拉", "巴勒斯坦", "PS", 31.903, 35.203),
        .init("第比利斯", "格鲁吉亚", "GE", 41.715, 44.827),
        .init("埃里温", "亚美尼亚", "AM", 40.187, 44.515),
        .init("巴库", "阿塞拜疆", "AZ", 40.409, 49.867),
        .init("伦敦", "英国", "GB", 51.507, -0.128),
        .init("曼彻斯特", "英国", "GB", 53.480, -2.242),
        .init("伯明翰", "英国", "GB", 52.486, -1.890),
        .init("爱丁堡", "英国", "GB", 55.953, -3.188),
        .init("格拉斯哥", "英国", "GB", 55.864, -4.252),
        .init("巴黎", "法国", "FR", 48.857, 2.352),
        .init("里昂", "法国", "FR", 45.764, 4.836),
        .init("马赛", "法国", "FR", 43.296, 5.370),
        .init("柏林", "德国", "DE", 52.520, 13.405),
        .init("汉堡", "德国", "DE", 53.551, 9.994),
        .init("慕尼黑", "德国", "DE", 48.135, 11.582),
        .init("法兰克福", "德国", "DE", 50.111, 8.682),
        .init("科隆", "德国", "DE", 50.938, 6.960),
        .init("罗马", "意大利", "IT", 41.903, 12.496),
        .init("米兰", "意大利", "IT", 45.464, 9.190),
        .init("那不勒斯", "意大利", "IT", 40.852, 14.268),
        .init("马德里", "西班牙", "ES", 40.417, -3.704),
        .init("巴塞罗那", "西班牙", "ES", 41.385, 2.173),
        .init("里斯本", "葡萄牙", "PT", 38.722, -9.139),
        .init("波尔图", "葡萄牙", "PT", 41.158, -8.629),
        .init("阿姆斯特丹", "荷兰", "NL", 52.367, 4.904),
        .init("鹿特丹", "荷兰", "NL", 51.924, 4.478),
        .init("布鲁塞尔", "比利时", "BE", 50.850, 4.352),
        .init("卢森堡", "卢森堡", "LU", 49.612, 6.132),
        .init("伯尔尼", "瑞士", "CH", 46.948, 7.447),
        .init("苏黎世", "瑞士", "CH", 47.377, 8.542),
        .init("维也纳", "奥地利", "AT", 48.208, 16.374),
        .init("布拉格", "捷克", "CZ", 50.075, 14.438),
        .init("华沙", "波兰", "PL", 52.230, 21.012),
        .init("克拉科夫", "波兰", "PL", 50.065, 19.945),
        .init("布达佩斯", "匈牙利", "HU", 47.498, 19.040),
        .init("布拉迪斯拉发", "斯洛伐克", "SK", 48.148, 17.108),
        .init("哥本哈根", "丹麦", "DK", 55.676, 12.568),
        .init("斯德哥尔摩", "瑞典", "SE", 59.329, 18.069),
        .init("奥斯陆", "挪威", "NO", 59.914, 10.752),
        .init("赫尔辛基", "芬兰", "FI", 60.169, 24.938),
        .init("雷克雅未克", "冰岛", "IS", 64.147, -21.943),
        .init("都柏林", "爱尔兰", "IE", 53.350, -6.260),
        .init("塔林", "爱沙尼亚", "EE", 59.437, 24.753),
        .init("里加", "拉脱维亚", "LV", 56.950, 24.105),
        .init("维尔纽斯", "立陶宛", "LT", 54.687, 25.279),
        .init("明斯克", "白俄罗斯", "BY", 53.900, 27.566),
        .init("基辅", "乌克兰", "UA", 50.450, 30.523),
        .init("基希讷乌", "摩尔多瓦", "MD", 47.011, 28.863),
        .init("莫斯科", "俄罗斯", "RU", 55.756, 37.617),
        .init("圣彼得堡", "俄罗斯", "RU", 59.934, 30.335),
        .init("新西伯利亚", "俄罗斯", "RU", 55.008, 82.936),
        .init("海参崴", "俄罗斯", "RU", 43.115, 131.886),
        .init("布加勒斯特", "罗马尼亚", "RO", 44.426, 26.103),
        .init("索非亚", "保加利亚", "BG", 42.698, 23.322),
        .init("贝尔格莱德", "塞尔维亚", "RS", 44.787, 20.449),
        .init("萨格勒布", "克罗地亚", "HR", 45.815, 15.982),
        .init("卢布尔雅那", "斯洛文尼亚", "SI", 46.057, 14.506),
        .init("萨拉热窝", "波黑", "BA", 43.856, 18.413),
        .init("波德戈里察", "黑山", "ME", 42.430, 19.259),
        .init("斯科普里", "北马其顿", "MK", 41.998, 21.426),
        .init("地拉那", "阿尔巴尼亚", "AL", 41.328, 19.819),
        .init("雅典", "希腊", "GR", 37.984, 23.728),
        .init("尼科西亚", "塞浦路斯", "CY", 35.185, 33.382),
        .init("瓦莱塔", "马耳他", "MT", 35.899, 14.514),
        .init("安道尔城", "安道尔", "AD", 42.507, 1.522),
        .init("摩纳哥", "摩纳哥", "MC", 43.738, 7.425),
        .init("瓦杜兹", "列支敦士登", "LI", 47.141, 9.520),
        .init("圣马力诺", "圣马力诺", "SM", 43.936, 12.447),
        .init("梵蒂冈", "梵蒂冈", "VA", 41.902, 12.453),
        .init("纽约", "美国", "US", 40.713, -74.006),
        .init("华盛顿", "美国", "US", 38.907, -77.037),
        .init("芝加哥", "美国", "US", 41.878, -87.630),
        .init("洛杉矶", "美国", "US", 34.052, -118.244),
        .init("旧金山", "美国", "US", 37.775, -122.419),
        .init("波士顿", "美国", "US", 42.360, -71.059),
        .init("西雅图", "美国", "US", 47.606, -122.332),
        .init("费城", "美国", "US", 39.953, -75.165),
        .init("渥太华", "加拿大", "CA", 45.421, -75.697),
        .init("多伦多", "加拿大", "CA", 43.653, -79.383),
        .init("蒙特利尔", "加拿大", "CA", 45.502, -73.567),
        .init("温哥华", "加拿大", "CA", 49.283, -123.121),
        .init("墨西哥城", "墨西哥", "MX", 19.433, -99.133),
        .init("瓜达拉哈拉", "墨西哥", "MX", 20.660, -103.350),
        .init("哈瓦那", "古巴", "CU", 23.113, -82.366),
        .init("拿骚", "巴哈马", "BS", 25.044, -77.350),
        .init("金斯敦", "牙买加", "JM", 17.971, -76.793),
        .init("太子港", "海地", "HT", 18.595, -72.307),
        .init("圣多明各", "多米尼加", "DO", 18.486, -69.931),
        .init("贝尔莫潘", "伯利兹", "BZ", 17.251, -88.759),
        .init("危地马拉城", "危地马拉", "GT", 14.635, -90.507),
        .init("圣萨尔瓦多", "萨尔瓦多", "SV", 13.693, -89.218),
        .init("特古西加尔巴", "洪都拉斯", "HN", 14.073, -87.192),
        .init("马那瓜", "尼加拉瓜", "NI", 12.115, -86.237),
        .init("圣何塞", "哥斯达黎加", "CR", 9.928, -84.091),
        .init("巴拿马城", "巴拿马", "PA", 8.983, -79.520),
        .init("圣约翰", "安提瓜和巴布达", "AG", 17.127, -61.846),
        .init("巴斯特尔", "圣基茨和尼维斯", "KN", 17.302, -62.717),
        .init("罗索", "多米尼克", "DM", 15.309, -61.379),
        .init("卡斯特里", "圣卢西亚", "LC", 14.010, -60.987),
        .init("金斯敦", "圣文森特和格林纳丁斯", "VC", 13.160, -61.225),
        .init("布里奇敦", "巴巴多斯", "BB", 13.097, -59.614),
        .init("圣乔治", "格林纳达", "GD", 12.056, -61.749),
        .init("西班牙港", "特立尼达和多巴哥", "TT", 10.655, -61.502),
        .init("圣保罗", "巴西", "BR", -23.551, -46.633),
        .init("里约热内卢", "巴西", "BR", -22.907, -43.173),
        .init("巴西利亚", "巴西", "BR", -15.794, -47.882),
        .init("布宜诺斯艾利斯", "阿根廷", "AR", -34.604, -58.382),
        .init("圣地亚哥", "智利", "CL", -33.449, -70.669),
        .init("利马", "秘鲁", "PE", -12.046, -77.043),
        .init("波哥大", "哥伦比亚", "CO", 4.711, -74.072),
        .init("麦德林", "哥伦比亚", "CO", 6.244, -75.581),
        .init("基多", "厄瓜多尔", "EC", -0.181, -78.468),
        .init("拉巴斯", "玻利维亚", "BO", -16.500, -68.150),
        .init("苏克雷", "玻利维亚", "BO", -19.019, -65.261),
        .init("亚松森", "巴拉圭", "PY", -25.264, -57.576),
        .init("蒙得维的亚", "乌拉圭", "UY", -34.901, -56.165),
        .init("加拉加斯", "委内瑞拉", "VE", 10.481, -66.904),
        .init("乔治敦", "圭亚那", "GY", 6.801, -58.155),
        .init("帕拉马里博", "苏里南", "SR", 5.852, -55.204),
        .init("开罗", "埃及", "EG", 30.044, 31.236),
        .init("亚历山大", "埃及", "EG", 31.200, 29.919),
        .init("阿尔及尔", "阿尔及利亚", "DZ", 36.754, 3.058),
        .init("突尼斯", "突尼斯", "TN", 36.807, 10.182),
        .init("拉巴特", "摩洛哥", "MA", 34.021, -6.842),
        .init("卡萨布兰卡", "摩洛哥", "MA", 33.573, -7.590),
        .init("的黎波里", "利比亚", "LY", 32.887, 13.191),
        .init("喀土穆", "苏丹", "SD", 15.500, 32.560),
        .init("朱巴", "南苏丹", "SS", 4.859, 31.571),
        .init("亚的斯亚贝巴", "埃塞俄比亚", "ET", 8.980, 38.757),
        .init("内罗毕", "肯尼亚", "KE", -1.292, 36.822),
        .init("坎帕拉", "乌干达", "UG", 0.347, 32.583),
        .init("多多马", "坦桑尼亚", "TZ", -6.163, 35.751),
        .init("达累斯萨拉姆", "坦桑尼亚", "TZ", -6.792, 39.208),
        .init("基加利", "卢旺达", "RW", -1.944, 30.062),
        .init("基特加", "布隆迪", "BI", -3.427, 29.930),
        .init("摩加迪沙", "索马里", "SO", 2.047, 45.318),
        .init("吉布提", "吉布提", "DJ", 11.572, 43.145),
        .init("阿斯马拉", "厄立特里亚", "ER", 15.323, 38.925),
        .init("阿布贾", "尼日利亚", "NG", 9.076, 7.399),
        .init("拉各斯", "尼日利亚", "NG", 6.524, 3.379),
        .init("阿克拉", "加纳", "GH", 5.604, -0.187),
        .init("达喀尔", "塞内加尔", "SN", 14.717, -17.468),
        .init("亚穆苏克罗", "科特迪瓦", "CI", 6.827, -5.289),
        .init("阿比让", "科特迪瓦", "CI", 5.360, -4.008),
        .init("巴马科", "马里", "ML", 12.639, -8.003),
        .init("瓦加杜古", "布基纳法索", "BF", 12.371, -1.520),
        .init("尼亚美", "尼日尔", "NE", 13.512, 2.126),
        .init("恩贾梅纳", "乍得", "TD", 12.134, 15.056),
        .init("班吉", "中非", "CF", 4.394, 18.558),
        .init("雅温得", "喀麦隆", "CM", 3.848, 11.502),
        .init("马拉博", "赤道几内亚", "GQ", 3.750, 8.738),
        .init("利伯维尔", "加蓬", "GA", 0.417, 9.468),
        .init("布拉柴维尔", "刚果共和国", "CG", -4.263, 15.242),
        .init("金沙萨", "刚果民主共和国", "CD", -4.442, 15.266),
        .init("罗安达", "安哥拉", "AO", -8.839, 13.290),
        .init("科纳克里", "几内亚", "GN", 9.642, -13.579),
        .init("比绍", "几内亚比绍", "GW", 11.881, -15.618),
        .init("弗里敦", "塞拉利昂", "SL", 8.465, -13.232),
        .init("蒙罗维亚", "利比里亚", "LR", 6.315, -10.801),
        .init("洛美", "多哥", "TG", 6.137, 1.212),
        .init("波多诺伏", "贝宁", "BJ", 6.497, 2.628),
        .init("班珠尔", "冈比亚", "GM", 13.455, -16.579),
        .init("努瓦克肖特", "毛里塔尼亚", "MR", 18.073, -15.958),
        .init("普拉亚", "佛得角", "CV", 14.934, -23.513),
        .init("圣多美", "圣多美和普林西比", "ST", 0.336, 6.727),
        .init("约翰内斯堡", "南非", "ZA", -26.204, 28.047),
        .init("开普敦", "南非", "ZA", -33.925, 18.424),
        .init("比勒陀利亚", "南非", "ZA", -25.747, 28.229),
        .init("温得和克", "纳米比亚", "NA", -22.560, 17.084),
        .init("哈博罗内", "博茨瓦纳", "BW", -24.628, 25.924),
        .init("哈拉雷", "津巴布韦", "ZW", -17.825, 31.033),
        .init("卢萨卡", "赞比亚", "ZM", -15.388, 28.323),
        .init("利隆圭", "马拉维", "MW", -13.963, 33.774),
        .init("马普托", "莫桑比克", "MZ", -25.970, 32.573),
        .init("马塞卢", "莱索托", "LS", -29.316, 27.486),
        .init("姆巴巴内", "斯威士兰", "SZ", -26.305, 31.136),
        .init("洛班巴", "斯威士兰", "SZ", -26.447, 31.206),
        .init("塔那那利佛", "马达加斯加", "MG", -18.879, 47.508),
        .init("路易港", "毛里求斯", "MU", -20.161, 57.501),
        .init("维多利亚", "塞舌尔", "SC", -4.620, 55.452),
        .init("莫罗尼", "科摩罗", "KM", -11.717, 43.248),
        .init("悉尼", "澳大利亚", "AU", -33.869, 151.209),
        .init("墨尔本", "澳大利亚", "AU", -37.814, 144.963),
        .init("布里斯班", "澳大利亚", "AU", -27.470, 153.025),
        .init("珀斯", "澳大利亚", "AU", -31.952, 115.861),
        .init("堪培拉", "澳大利亚", "AU", -35.280, 149.130),
        .init("惠灵顿", "新西兰", "NZ", -41.287, 174.776),
        .init("奥克兰", "新西兰", "NZ", -36.849, 174.763),
        .init("莫尔兹比港", "巴布亚新几内亚", "PG", -9.443, 147.180),
        .init("苏瓦", "斐济", "FJ", -18.141, 178.441),
        .init("霍尼亚拉", "所罗门群岛", "SB", -9.446, 159.972),
        .init("维拉港", "瓦努阿图", "VU", -17.734, 168.322),
        .init("阿皮亚", "萨摩亚", "WS", -13.834, -171.751),
        .init("努库阿洛法", "汤加", "TO", -21.139, -175.204),
        .init("富纳富提", "图瓦卢", "TV", -8.521, 179.196),
        .init("南塔拉瓦", "基里巴斯", "KI", 1.328, 172.979),
        .init("马朱罗", "马绍尔群岛", "MH", 7.089, 171.380),
        .init("帕利基尔", "密克罗尼西亚", "FM", 6.924, 158.161),
        .init("恩吉鲁穆德", "帕劳", "PW", 7.501, 134.624),
        // Nauru has no official capital; Yaren is an administrative center.
        .init("亚伦", "瑙鲁", "NR", -0.547, 166.921)
    ]

    // Each category has at least ten landmarks, so refreshing five can replace
    // every previous entry. References remain available in the context menu.
    static let stations: [DiscoveryStation] = [
        .init("东京站", "日本", .passenger, 35.681, 139.767, "Tokyo_Station"),
        .init("京都站", "日本", .passenger, 34.985, 135.759, "Kyoto_Station"),
        .init("北京南站", "中国", .passenger, 39.865, 116.378, "Beijing_South_railway_station"),
        .init("上海虹桥站", "中国", .passenger, 31.195, 121.320, "Shanghai_Hongqiao_railway_station"),
        .init("伦敦圣潘克拉斯", "英国", .passenger, 51.531, -0.126, "St_Pancras_railway_station"),
        .init("巴黎北站", "法国", .passenger, 48.881, 2.355, "Gare_du_Nord"),
        .init("柏林中央站", "德国", .passenger, 52.525, 13.369, "Berlin_Hauptbahnhof"),
        .init("纽约中央车站", "美国", .passenger, 40.753, -73.977, "Grand_Central_Terminal"),
        .init("孟买贾特拉帕蒂站", "印度", .passenger, 18.940, 72.835, "Chhatrapati_Shivaji_Terminus"),
        .init("悉尼中央站", "澳大利亚", .passenger, -33.884, 151.207, "Central_railway_station,_Sydney"),
        .init("米兰中央站", "意大利", .passenger, 45.486, 9.204, "Milano_Centrale_railway_station"),
        .init("马德里阿托查", "西班牙", .passenger, 40.406, -3.690, "Madrid_Atocha_railway_station"),
        .init("贝利编组站", "美国", .freight, 41.150, -100.830, "Bailey_Yard"),
        .init("马申编组站", "德国", .freight, 53.402, 10.050, "Maschen_Marshalling_Yard"),
        .init("曼海姆编组站", "德国", .freight, 49.457, 8.515, "Mannheim_Marshalling_Yard"),
        .init("塞尔策编组站", "德国", .freight, 52.389, 9.619, "Seelze_marshalling_yard"),
        .init("基夫胡克编组站", "荷兰", .freight, 51.837, 4.612, "Kijfhoek_classification_yard"),
        .init("莫森德编组站", "英国", .freight, 55.826, -3.973, "Mossend_railway_yard"),
        .init("托顿编组站", "英国", .freight, 52.908, -1.278, "Toton_Traction_Maintenance_Depot"),
        .init("蒂斯编组站", "英国", .freight, 54.579, -1.263, "Tees_Yard"),
        .init("麦克米伦编组站", "加拿大", .freight, 43.817, -79.504, "MacMillan_Yard"),
        .init("塞尔柯克编组站", "美国", .freight, 42.567, -73.837, "Selkirk_Yard"),
        .init("沙特莱地铁站", "法国", .metro, 48.859, 2.347, "Châtelet_(Paris_Métro)"),
        .init("贝克街地铁站", "英国", .metro, 51.523, -0.157, "Baker_Street_tube_station"),
        .init("威斯敏斯特地铁站", "英国", .metro, 51.501, -0.125, "Westminster_tube_station"),
        .init("国王花园地铁站", "瑞典", .metro, 59.331, 18.073, "Kungsträdgården_metro_station"),
        .init("索尔地铁站", "西班牙", .metro, 40.417, -3.703, "Sol_(Madrid_Metro)"),
        .init("美丽岛站", "中国", .metro, 22.631, 120.302, "Formosa_Boulevard_metro_station"),
        .init("金钟站", "中国", .metro, 22.279, 114.165, "Admiralty_station_(MTR)"),
        .init("人民广场站", "中国", .metro, 31.233, 121.476, "People's_Square_station"),
        .init("乌节站", "新加坡", .metro, 1.304, 103.832, "Orchard_MRT_station"),
        .init("阿尔巴特地铁站", "俄罗斯", .metro, 55.752, 37.605, "Arbatskaya_(Arbatsko-Pokrovskaya_line)"),
        .init("荣格峰站", "瑞士", .other, 46.548, 7.985, "Jungfraujoch_railway_station"),
        .init("戈尔内格拉特站", "瑞士", .other, 45.983, 7.784, "Gornergrat_railway_station"),
        .init("斯诺登山顶站", "英国", .other, 53.068, -4.077, "Snowdon_Summit_railway_station"),
        .init("波特马多格港站", "英国", .other, 52.924, -4.126, "Porthmadog_Harbour_railway_station"),
        .init("大吉岭站", "印度", .other, 27.037, 88.263, "Darjeeling_railway_station"),
        .init("古姆站", "印度", .other, 27.008, 88.255, "Ghum_railway_station"),
        .init("阿蒂加斯历史车站", "乌拉圭", .other, -34.895, -56.197, "Estación_Central_General_Artigas"),
        .init("丹尼丁站", "新西兰", .other, -45.875, 170.510, "Dunedin_railway_station"),
        .init("强罗登山铁路站", "日本", .other, 35.250, 139.048, "Gōra_Station"),
        .init("高野山站", "日本", .other, 34.391, 135.665, "Kōyasan_Station")
    ]
}
