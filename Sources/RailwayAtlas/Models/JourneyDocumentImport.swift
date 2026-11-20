import CoreGraphics
import Foundation
import PDFKit
import RailwayCore
import Vision

enum JourneyDocumentImport {
    struct Result: Sendable {
        var journeys: [RailJourney] = []
        var notes: [String] = []
    }
    static func read(_ urls: [URL]) async -> Result {
        await Task.detached(priority: .userInitiated) {
            var result = Result()
            for url in urls.prefix(30) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 20_000_000 else { throw DataError.invalid("文件超过 20 MB") }
                    let data = try Data(contentsOf: url)
                    switch url.pathExtension.lowercased() {
                    case "json":
                        result.journeys += try RailJourneyArchive.decode(data).journeys
                    case "csv":
                        guard let text = String(data: data, encoding: .utf8) else { throw DataError.invalid("请使用 UTF-8 CSV") }
                        result.journeys += try JourneyImport.csv(text)
                    case "pdf":
                        guard let doc = PDFDocument(data: data), !doc.isLocked, doc.pageCount <= 30 else {
                            throw DataError.invalid("PDF 加密、损坏或超过 30 页")
                        }
                        for i in 0..<doc.pageCount {
                            let text = doc.page(at: i)?.string ?? ""
                            let extracted = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            let content: String
                            if extracted.count > 20 { content = extracted }
                            else { content = try recognizePDF(data, page: i + 1) }
                            result.journeys += JourneyImport.text(content, source: "PDF 票据 · 第 \(i + 1) 页")
                        }
                    case "txt", "text":
                        guard let text = String(data: data, encoding: .utf8) else { throw DataError.invalid("请使用 UTF-8 文字") }
                        result.journeys += JourneyImport.text(text)
                    default:
                        let request = VNRecognizeTextRequest()
                        configure(request)
                        try VNImageRequestHandler(data: data, options: [:]).perform([request])
                        let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
                        result.journeys += JourneyImport.text(text, source: "票据图片识别")
                    }
                } catch { result.notes.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            if urls.count > 30 { result.notes.append("每批最多 30 个文件，剩余文件请另行导入") }
            if result.journeys.isEmpty { result.notes.append("没有提取到记录。可粘贴文字，或手动补记。") }
            return result
        }.value
    }

    private static func configure(_ request: VNRecognizeTextRequest) {
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = false
    }
    private static func recognizePDF(_ data: Data, page number: Int) throws -> String {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: number) else { throw DataError.invalid("无法读取 PDF 页面") }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { throw DataError.invalid("PDF 页面尺寸无效") }
        let scale = min(3, 2400 / max(box.width, box.height))
        let width = max(1, Int(box.width * scale)), height = max(1, Int(box.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DataError.invalid("无法识别 PDF 页面")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(page.getDrawingTransform(.mediaBox,
                                                      rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                      rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw DataError.invalid("PDF 页面渲染失败") }
        let request = VNRecognizeTextRequest()
        configure(request)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }
}
