import RailwayCore
import SwiftUI

struct ReferenceTicketFace: View {
    let blue: Bool
    let receipt: Bool
    let ticket: RailwayPostcardTicket
    let journey: RailJourney
    let shareCode: CGImage?

    private var tint: Color { blue ? Color(red:0.26,green:0.54,blue:0.58) : Color(red:0.64,green:0.35,blue:0.34) }
    private var ink: Color { Color(red:0.13,green:0.15,blue:0.13) }
    private func label(_ value: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ size: CGFloat,
                       _ alignment: Alignment = .leading, _ colour: Color? = nil, digits: Bool = false) -> some View {
        Text(verbatim:value)
            .font(digits ? TicketTypography.digits(size) : TicketTypography.chinese(.redReplica,size:size))
            .foregroundStyle(colour ?? ink)
            .lineLimit(1).minimumScaleFactor(0.45)
            .frame(width:width,height:size*1.4,alignment:alignment)
            .position(x:x+width/2,y:y-size/2)
    }
    private func station(_ name: String, _ latin: String, _ x: CGFloat) -> some View {
        let clean = name.hasSuffix("站") ? String(name.dropLast()) : name
        let spaced = clean.count == 2 ? clean.map(String.init).joined(separator:"　") : clean
        return ZStack(alignment:.topLeading) {
            HStack(alignment:.firstTextBaseline,spacing:3) {
                Text(verbatim:spaced).font(TicketTypography.chinese(.redReplica,size:38))
                Text("站").font(TicketTypography.chinese(.redReplica,size:19))
            }.foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.45)
                .frame(width:200,height:51).position(x:x,y:77)
            label(latin,x-97,117,194,16,.center)
        }
    }
    var body: some View {
        let rgb = blue ? (0.82,0.91,0.92) : (0.97,0.85,0.81)
        let date = (ticket.date.isEmpty ? journey.date : ticket.date).split(separator:"-")
        let dateText = date.count == 3 ? "\(date[0])年\(date[1])月\(date[2])日" : journey.date
        let time = ticket.departureTime.isEmpty ? journey.departure : ticket.departureTime
        ZStack(alignment:.topLeading) {
            LinearGradient(colors:[Color(red:rgb.0,green:rgb.1,blue:rgb.2),Color(red:0.95,green:0.94,blue:0.89),Color(red:rgb.0,green:rgb.1,blue:rgb.2)],
                           startPoint:.topLeading,endPoint:.bottomTrailing)
            if receipt {
                Canvas { context, _ in
                    var train = Path()
                    train.move(to:.init(x:166,y:235))
                    train.addQuadCurve(to:.init(x:266,y:201),control:.init(x:197,y:202))
                    train.addLine(to:.init(x:640,y:194)); train.addLine(to:.init(x:640,y:225))
                    train.addLine(to:.init(x:179,y:241))
                    train.addQuadCurve(to:.init(x:166,y:235),control:.init(x:158,y:242))
                    context.fill(train,with:.color(tint.opacity(0.13)))
                    var windows = Path()
                    for x in stride(from:276.0,to:640.0,by:19.0) {
                        windows.addRect(.init(x:x,y:205-(x-276)/65,width:12,height:6))
                    }
                    windows.move(to:.init(x:192,y:223))
                    windows.addQuadCurve(to:.init(x:253,y:205),control:.init(x:211,y:207))
                    windows.addLine(to:.init(x:247,y:214)); windows.closeSubpath()
                    context.fill(windows,with:.color(tint.opacity(0.20)))
                }.accessibilityHidden(true)
            }
            label(TicketText.displayed(ticket.ticketNumber, placeholder:"R000000"),24,36,235,24,.leading,Color(red:0.66,green:0.19,blue:0.23))
            label(ticket.checkNumber.hasPrefix("检票") ? ticket.checkNumber : "检票：\(TicketText.displayed(ticket.checkNumber, placeholder:"—"))",358,36,255,19,.trailing)
            station(journey.from,ticket.originLatin,140)
            station(journey.to,ticket.destinationLatin,494)
            label(journey.train,253,89,134,30,.center,digits:true)
            Path { p in p.move(to:.init(x:260,y:98));p.addLine(to:.init(x:380,y:98));p.addLine(to:.init(x:372,y:93)) }.stroke(ink,lineWidth:1.6)
            label("\(dateText) \(time) 开",26,155,365,23)
            label("\(ticket.coachNumber)车 \(ticket.seatNumber)\(ticket.seatNumber.hasSuffix("号") ? "" : "号")",380,155,202,22,.center)
            label("¥ \(TicketText.displayed(ticket.fare,placeholder:"—")) 元",26,192,195,24)
            if receipt && (1...3).contains(ticket.ticketMark.count) && ticket.ticketMark.allSatisfy({ "学惠儿折优".contains($0) }) {
                HStack(spacing:2) {
                    ForEach(Array(ticket.ticketMark.enumerated()), id:\.offset) { _, mark in
                        Text(String(mark)).font(TicketTypography.chinese(.redReplica,size:18))
                            .foregroundStyle(ink).frame(width:24,height:24).overlay(Circle().stroke(ink,lineWidth:1))
                    }
                }.position(x:320,y:182)
            } else {
                label(ticket.ticketMark,260,192,120,19,.center)
            }
            label(ticket.seatClass,380,192,202,23,.center)
            if receipt {
                Rectangle().stroke(Color(red:0.64,green:0.28,blue:0.30),lineWidth:1.4)
                    .frame(width:257,height:34).position(x:152.5,y:252)
                label("收藏样张 · 不可乘车或报销",32,262,241,18)
            } else {
                label("铁路图鉴 · 纪念样张",160,232,320,21,.center,tint.opacity(0.77))
                label(ticket.notice,27,267,435,18)
            }
            label("\(TicketText.maskedIdentityNumber(ticket.identityNumber, placeholder:"SAMPLE-ID"))　\(ticket.passengerName)",27,293,442,19)
            Rectangle().stroke(tint,style:.init(lineWidth:1,dash:[4,3])).frame(width:420,height:52).position(x:242,y:333)
            label(receipt ? ticket.notice : journey.from+" → "+journey.to,38,330,408,15,.center)
            label(receipt ? ticket.secondNotice : "纪念样张 · 不可乘车或报销",38,351,408,16,.center)
            if let shareCode {
                Image(decorative:shareCode,scale:1).interpolation(.none).resizable()
                    .frame(width:111,height:111).position(x:547.5,y:300.5)
            } else {
                Rectangle().stroke(tint,lineWidth:2).frame(width:77,height:77).position(x:549,y:298)
                label("铁路",514,292,70,21,.center,tint)
                label("纪念",514,321,70,21,.center,tint)
            }
            tint.opacity(0.38).frame(width:640,height:34).position(x:320,y:387)
            label(TicketText.displayed(ticket.serialNumber,placeholder:"ATLAS-SAMPLE"),27,394,315,16,.leading,digits:true)
            label(TicketText.displayed(ticket.issuer,placeholder:receipt ? journey.from+" · 收藏" : "铁路图鉴"),354,394,260,16,receipt ? .leading : .trailing)
        }
        .frame(width:640,height:404)
        .scaleEffect(440/404.0)
        .frame(width:440*85.6/54,height:440)
        .clipped()
    }
}
