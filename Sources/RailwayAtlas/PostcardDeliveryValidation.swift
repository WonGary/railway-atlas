import Foundation
import RailwayCore
import SwiftUI
import Vision

@MainActor
enum PostcardDeliveryValidation {
    static let simulatorFlag = "--paper-ticket-check"

    static func runWithReceipt(in directory: URL) async {
        var report = ["status":"PASS", "bundle":Bundle.main.bundleURL.path]
        do {
            try await run(in:directory)
        } catch {
            report["status"] = "FAIL"
            report["error"] = error.localizedDescription
        }
        if let json = try? JSONEncoder().encode(report) {
            try? json.write(to:directory.appendingPathComponent("paper-ticket.json"),options:.atomic)
        }
    }

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
        var ticket = RailwayPostcardTicket.randomSample(for:journey)
        ticket.ticketNumber = "R012345"; ticket.serialNumber = "ATLAS-0123456789"
        ticket.passengerName = "样张旅客"; ticket.identityNumber = "RA99123456780027"
        ticket.checkNumber = "7、8"; ticket.ticketMark = "学惠"; ticket.fare = "68.50"
        ticket.notice = "陇南至广元"; ticket.secondNotice = "留作旅途纪念"; ticket.issuer = "陇南 · 收藏"
        guard TicketText.maskedIdentityNumber(ticket.identityNumber, placeholder:"") == "RA99****0027"
        else { throw DataError.invalid("票面证件号脱敏有误") }
        for style in [PostcardStyle.stockRed, .stockBlue, .stockReceipt] {
            let renderer = ImageRenderer(content:TicketPostcardArt(style:style, journey:journey,
                caption:"",legs:route.legs,stations:route.stations,ticket:ticket,
                shareCode:style == .stockReceipt ? image : nil).environment(\.colorScheme,.light))
            renderer.scale = 2
            guard let source = renderer.cgImage, let crop = source.cropping(to:.init(x:(source.width-w)/2,y:0,width:w,height:h))
            else { throw DataError.invalid("参考票面渲染失败") }
            if style == .stockReceipt {
                let scan = VNDetectBarcodesRequest()
                scan.symbologies = [.qr]
                try VNImageRequestHandler(cgImage:crop).perform([scan])
                guard scan.results?.first?.payloadStringValue == share.absoluteString
                else { throw DataError.invalid("票面上的区间分享码未能读回") }
            }
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
