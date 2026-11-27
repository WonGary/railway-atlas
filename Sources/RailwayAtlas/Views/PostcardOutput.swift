import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import RailwayCore
import SwiftUI
import UniformTypeIdentifiers

struct PostcardDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.png,.pdf,.svg]
    let data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents:data)
    }
}

enum PostcardOutput: String, CaseIterable {
    case png, ticketPDF, a4PDF, wallpaper, svg

    var title: String {
        switch self {
        case .png: "PNG 明信片"
        case .ticketPDF: "票据 PDF（85.6 × 54 毫米）"
        case .a4PDF: "A4 打印 PDF"
        case .wallpaper: "手机壁纸（1080 × 1920）"
        case .svg: "SVG（内嵌票面图像）"
        }
    }

    var type: UTType {
        switch self {
        case .ticketPDF, .a4PDF: .pdf
        case .svg: .svg
        default: .png
        }
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    func encode(_ image: CGImage) throws -> Data {
        let ratio = CGFloat(image.height) / CGFloat(image.width)
        switch self {
        case .png: return try png(image)
        case .svg:
            let data = try png(image).base64EncodedString()
            return Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="\#(image.width)" height="\#(image.height)"><image width="100%" height="100%" href="data:image/png;base64,\#(data)"/></svg>"#.utf8)
        case .wallpaper:
            guard let ctx = CGContext(data:nil, width:1080, height:1920, bitsPerComponent:8, bytesPerRow:0,
                                      space:CGColorSpaceCreateDeviceRGB(), bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw CocoaError(.fileWriteUnknown) }
            ctx.setFillColor(red:0.914, green:0.898, blue:0.847, alpha:1)
            ctx.fill(CGRect(x:0,y:0,width:1080,height:1920))
            let h = 1000 * ratio
            ctx.interpolationQuality = .high
            ctx.draw(image, in:CGRect(x:40,y:(1920-h)/2,width:1000,height:h))
            guard let wall = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            return try png(wall)
        case .ticketPDF, .a4PDF:
            let point = 72.0 / 25.4
            let ticketWidth = 85.6 * point, ticketHeight = 54 * point
            let width = self == .a4PDF ? 210 * point : ticketWidth
            let height = self == .a4PDF ? 297 * point : ticketHeight
            var page = CGRect(x:0,y:0,width:width,height:height)
            let bytes = NSMutableData()
            guard let writer = CGDataConsumer(data:bytes), let ctx = CGContext(consumer:writer,mediaBox:&page,nil)
            else { throw CocoaError(.fileWriteUnknown) }
            ctx.beginPDFPage(nil)
            let w = min(ticketWidth,ticketHeight/ratio), h = w*ratio
            ctx.draw(image,in:CGRect(x:(width-w)/2,y:(height-h)/2,width:w,height:h))
            ctx.endPDFPage()
            ctx.closePDF()
            return bytes as Data
        }
    }
}

enum PostcardRouteShare {
    static func url(_ entry: RailJourney) async throws -> URL {
        let store = NationalJourneyPaths.shared
        guard let timetable = try await store.timetable(train:entry.train,date:entry.date,from:entry.from,to:entry.to,
                                                         boarding:true,departure:entry.departure.isEmpty ? nil : entry.departure),
              let path = try await store.journey(timetable,from:entry.from,to:entry.to),
              path.stations.first == entry.from, path.stations.last == entry.to
        else { throw DataError.invalid("公开车次库尚未收录这个区间。") }
        if let source = entry.timetable {
            let saved = try source.passengerSection(from:entry.from,to:entry.to)
            let publicStops = try timetable.passengerSection(from:entry.from,to:entry.to)
            guard saved.stops.map(\.station) == publicStops.stops.map(\.station),
                  saved.stops.map(\.departure) == publicStops.stops.map(\.departure),
                  saved.stops.map(\.arrival) == publicStops.stops.map(\.arrival)
            else { throw DataError.invalid("本机时刻与公开排图不同。") }
        }
        var fields = [("ride","1"),("train",entry.train),("day",entry.date),("from",entry.from),("to",entry.to)]
        if !entry.departure.isEmpty { fields.append(("depart",entry.departure)) }
        let identity = timetable.id.split(separator:":")
        if identity.count == 3 && identity[0] == "national" { fields.append(("trip",String(identity[1]))) }
        let alphabet = CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let hash = fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters:alphabet) ?? "")" }.joined(separator:"&")
        guard let url = URL(string:"https://wongary.github.io/railway-atlas/#\(hash)") else { throw CocoaError(.fileReadCorruptFile) }
        return url
    }

    static func qr(_ url: URL) -> CGImage? {
        guard let filter = CIFilter(name:"CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey:"inputMessage")
        filter.setValue("M", forKey:"inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        let quiet = code.extent.insetBy(dx:-4,dy:-4)
        let white = CIImage(color:CIColor(red:1,green:1,blue:1)).cropped(to:quiet)
        let image = code.composited(over:white).transformed(by:CGAffineTransform(scaleX:6,y:6))
        return CIContext().createCGImage(image,from:image.extent)
    }
}
