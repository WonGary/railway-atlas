import Foundation
import CoreGraphics
import ImageIO
import Vision

enum TicketCheck: Error { case input, raster, decode(String) }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let receipt = try String(contentsOf: folder.appendingPathComponent("postcard-delivery.txt"), encoding: .utf8)
let lines = receipt.split(separator: "\n")
guard lines.count == 2, lines[0] == "PASS" else { throw TicketCheck.input }
let expected = String(lines[1])

func scan(_ image: CGImage, filename: String) throws {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    try VNImageRequestHandler(cgImage: image).perform([request])
    guard request.results?.contains(where: { $0.payloadStringValue == expected }) == true
    else { throw TicketCheck.decode(filename) }
    print("PASS \(filename)  \(expected)")
}

for file in CommandLine.arguments.dropFirst(2) {
    let url = folder.appendingPathComponent(file)
    if url.pathExtension.lowercased() == "pdf" {
        guard let pdf = CGPDFDocument(url as CFURL), pdf.numberOfPages == 1, let page = pdf.page(at: 1)
        else { throw TicketCheck.input }
        let box = page.getBoxRect(.mediaBox)
        guard abs(box.width * 25.4 / 72 - 85.6) < 0.1, abs(box.height * 25.4 / 72 - 54) < 0.1,
              let canvas = CGContext(data: nil, width: Int(ceil(box.width * 6)), height: Int(ceil(box.height * 6)),
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw TicketCheck.raster }
        canvas.scaleBy(x: 6, y: 6)
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(box)
        canvas.drawPDFPage(page)
        guard let image = canvas.makeImage() else { throw TicketCheck.raster }
        try scan(image, filename: file)
    } else {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw TicketCheck.input }
        try scan(image, filename: file)
    }
}
