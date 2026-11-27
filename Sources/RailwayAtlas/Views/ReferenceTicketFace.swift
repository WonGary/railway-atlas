import RailwayCore
import SwiftUI

struct ReferenceTicketFace: View {
    let blue: Bool
    let ticket: RailwayPostcardTicket
    let journey: RailJourney

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
            label(ticket.ticketNumber,24,36,235,24,.leading,.red)
            label("检票：\(ticket.checkNumber)",358,36,255,19,.trailing)
            station(journey.from,ticket.originLatin,140)
            station(journey.to,ticket.destinationLatin,494)
            label(journey.train,253,89,134,30,.center,digits:true)
            Path { p in p.move(to:.init(x:260,y:98));p.addLine(to:.init(x:380,y:98));p.addLine(to:.init(x:372,y:93)) }.stroke(ink,lineWidth:1.6)
            label("\(dateText) \(time) 开",26,155,365,23)
            label("\(ticket.coachNumber)车 \(ticket.seatNumber)",380,155,202,22,.center)
            label("¥ \(ticket.fare) 元",26,192,195,24)
            label(ticket.ticketMark,260,192,120,19,.center)
            label(ticket.seatClass,380,192,202,23,.center)
            label("铁路图鉴 · 纪念样张",160,232,320,21,.center,tint.opacity(0.77))
            label(ticket.notice,27,267,435,18)
            label("\(TicketText.maskedIdentityNumber(ticket.identityNumber, placeholder:"SAMPLE-ID"))　\(ticket.passengerName)",27,293,442,19)
            Rectangle().stroke(tint,style:.init(lineWidth:1,dash:[4,3])).frame(width:420,height:52).position(x:242,y:333)
            label(journey.from+" → "+journey.to,38,330,408,15,.center)
            label("纪念样张 · 不可乘车或报销",38,351,408,16,.center)
            Rectangle().stroke(tint,lineWidth:2).frame(width:77,height:77).position(x:549,y:298)
            label("铁路",514,292,70,21,.center,tint)
            label("纪念",514,321,70,21,.center,tint)
            tint.opacity(0.38).frame(width:640,height:34).position(x:320,y:387)
            label(ticket.serialNumber,27,394,325,16,.leading,digits:true)
            label("铁路图鉴",400,394,214,16,.trailing)
        }
        .frame(width:640,height:404)
        .scaleEffect(440/404.0)
        .frame(width:440*85.6/54,height:440)
        .clipped()
    }
}
