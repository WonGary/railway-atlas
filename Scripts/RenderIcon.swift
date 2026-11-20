import AppKit
import SwiftUI

@main
struct RenderIcon {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let assets = root.appendingPathComponent("Design/AppIcon.appiconset")
        let iconset = root.appendingPathComponent("Design/RailwayAtlas.iconset")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        func render(_ size: Int, square: Bool = false, to urls: [URL]) throws {
            let renderer = ImageRenderer(content: RailwayAtlasMark(size: CGFloat(size), square: square))
            renderer.scale = 1
            guard let image = renderer.cgImage else { fatalError("Icon render failed") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG export failed") }
            for url in urls { try png.write(to: url) }
        }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                try render(size * scale, to: [
                    assets.appendingPathComponent("Icon-\(size)\(suffix).png"),
                    iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                ])
            }
        }
        for (name, size) in [("60@2x", 120), ("60@3x", 180), ("76@2x", 152), ("83.5@2x", 167), ("1024", 1024)] {
            try render(size, square: true, to: [assets.appendingPathComponent("Icon-\(name).png")])
        }
        try render(256, to: [root.appendingPathComponent("Design/Icon-preview.png")])
        print("Rendered high-speed train + route icon.")
    }
}
