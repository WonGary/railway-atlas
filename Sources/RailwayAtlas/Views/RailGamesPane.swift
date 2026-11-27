import RailwayCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let railGameDidOpenMap = Self("railway-atlas.games.show-main-map")
}

struct RailGamesPane: View {
    let game: String
    let map: RailwayMapStore?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var exporting = false
    @State private var card: ExperienceFile?
    @State private var filename = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error { Text(error).font(.callout).padding(.horizontal) }
            switch RailGameAssets.bundled {
            case let .success(assets):
                RailGamesWebView(game: game, assets: assets, open: { timetable, route in
                    guard let map else { throw DataError.invalid("主地图尚未打开。") }
                    try map.journeyPlayer.start(timetable, route: route)
                    #if os(macOS)
                    openWindow(id: "main-map")
                    #else
                    dismiss()
                    NotificationCenter.default.post(name: .railGameDidOpenMap, object: nil)
                    #endif
                }, export: { name, data in
                    filename = name; card = ExperienceFile(data); exporting = true
                }, report: { error = $0 })
                .accessibilityIdentifier("rail-games-web")
            case let .failure(error):
                ContentUnavailableView("游戏资料未能载入", systemImage: "shippingbox",
                                       description: Text(error.localizedDescription))
            }
        }
        .fileExporter(isPresented: $exporting, document: card, contentType: .png, defaultFilename: filename) { result in
            if case let .failure(cause) = result { error = cause.localizedDescription }
        }
    }
}

#if os(iOS)
import UIKit

struct RailGameShortcuts: UIViewRepresentable {
    let open: (ExperienceTab) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(open: open) }
    final class Coordinator {
        var open: (ExperienceTab) -> Void
        init(open: @escaping (ExperienceTab) -> Void) { self.open = open }
    }
    func makeUIView(context: Context) -> UIStackView {
        let row = UIStackView()
        row.distribution = .fillEqually; row.spacing = 4
        for game in ExperienceTab.games {
            let button = UIButton(type: .system)
            var style = UIButton.Configuration.tinted()
            style.title = game.title
            style.contentInsets = .init(top: 4, leading: 2, bottom: 4, trailing: 2)
            button.configuration = style
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.accessibilityIdentifier = "rail-game-entry-" + game.rawValue
            button.addAction(UIAction { [weak coordinator = context.coordinator] _ in coordinator?.open(game) }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        return row
    }
    func updateUIView(_ row: UIStackView, context: Context) { context.coordinator.open = open }
}
#endif
