#if os(macOS)
import AppKit
import RailwayCore
import SwiftUI
import Vision

@MainActor
enum PostcardDeliveryValidation {
    static func run(in directory: URL) async throws {
        let journey = RailJourney(date:"2026-11-26",train:"D174",from:"陇南",to:"广元",departure:"13:22",
                                  status:.travelled,note:"仅作本机验收")
        let share = try await PostcardRouteShare.url(journey)
        guard let image = PostcardRouteShare.qr(share) else { throw DataError.invalid("区间分享码生成失败") }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage:image).perform([request])
        guard request.results?.first?.payloadStringValue == share.absoluteString,
              share.absoluteString.contains("880000D17403"), !share.absoluteString.contains("note")
        else { throw DataError.invalid("区间分享码解码或字段有误") }
        let core = NationalJourneyPaths.shared
        guard let full = try await core.timetable(train:journey.train,date:journey.date),
              let route = try await core.journey(full,from:journey.from,to:journey.to),
              route.legs.count == 1 else { throw DataError.invalid("日期和区间不匹配") }
        let w = 1395, h = 880
        for style in [PostcardStyle.stockRed, .stockBlue] {
            let renderer = ImageRenderer(content:TicketPostcardArt(style:style, journey:journey,
                caption:"",legs:route.legs,stations:route.stations).environment(\.colorScheme,.light))
            renderer.scale = 2
            guard let source = renderer.cgImage, let crop = source.cropping(to:.init(x:(source.width-w)/2,y:0,width:w,height:h))
            else { throw DataError.invalid("参考票面渲染失败") }
            for format in PostcardOutput.allCases {
                let data = try format.encode(crop)
                guard !data.isEmpty else { throw DataError.invalid("导出文件为空") }
                let ext = format.type.preferredFilenameExtension ?? format.rawValue
                try data.write(to:directory.appendingPathComponent("\(style.rawValue)-\(format.rawValue).\(ext)"))
            }
        }
        try Data(("PASS\n"+share.absoluteString+"\n").utf8).write(to:directory.appendingPathComponent("postcard-delivery.txt"))
    }
}
#endif
