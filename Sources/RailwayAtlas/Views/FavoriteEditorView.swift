import SwiftUI

@MainActor
struct FavoriteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.atlasUIScale) private var uiScale
    @EnvironmentObject private var map: RailwayMapStore
    @ObservedObject var favorites: FavoriteStore
    let entry: FavoriteEntry
    @State private var city: String
    @State private var labelsText: String
    @State private var notice: String?
    @FocusState private var cityFocused: Bool

    init(entry: FavoriteEntry, favorites: FavoriteStore) {
        self.entry = entry
        self.favorites = favorites
        _city = State(initialValue: entry.annotation.city)
        _labelsText = State(initialValue: entry.annotation.labels.joined(separator: "，"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            Text("编辑收藏").atlasFont(.headline).accessibilityAddTraits(.isHeader)
            Text(entry.snapshot?.name ?? "待载入的收藏").atlasFont(.subheadline)
                .lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 14 * uiScale) {
                    VStack(alignment: .leading, spacing: 5 * uiScale) {
                        Text("城市").atlasFont(.caption.weight(.medium))
                        TextField("手工填写，留空则不归档", text: $city)
                            .textFieldStyle(.roundedBorder)
                            .focused($cityFocused)
                            .accessibilityLabel("收藏归档城市")
                            .accessibilityIdentifier("favorite-editor-city")
                        if let suggestion = entry.citySuggestion, suggestion.city != city {
                            Button { city = suggestion.city } label: {
                                Text("采用来源城市：\(suggestion.city)")
                                    .atlasFont(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.borderless)
                            .help("依据明确字段 \(suggestion.source)")
                            .accessibilityHint("来自 \(suggestion.source)，点击才填入城市")
                            .accessibilityIdentifier("favorite-editor-use-city")
                        }
                    }
                    VStack(alignment: .leading, spacing: 5 * uiScale) {
                        Text("自定义标签").atlasFont(.caption.weight(.medium))
                        TextField("例如：想去，换乘，拍照", text: $labelsText, axis: .vertical)
                            .lineLimit(2...4).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("收藏标签，用英文或中文逗号分隔")
                            .accessibilityIdentifier("favorite-editor-labels")
                        Text("\(FavoriteAnnotation.labels(from: labelsText).count) 个标签 · 英文或中文逗号分隔")
                            .atlasFont(.caption2).foregroundStyle(.secondary)
                    }
                    if entry.snapshot == nil {
                        Text("可先归档；位置与要素资料待地图载入。")
                            .atlasFont(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let notice {
                        Text(notice).atlasFont(.caption).foregroundStyle(.orange)
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    if favorites.updateAnnotation(entry.id, city: city,
                        labels: FavoriteAnnotation.labels(from: labelsText), in: map) {
                        dismiss()
                    } else {
                        notice = "此收藏已移除，未保存归档。"
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("favorite-editor-save")
            }
            .atlasFont(.body)
        }
        .atlasPadding(16)
        .modifier(AtlasSheetLayout(scale: uiScale, width: 430, height: 370))
        .onAppear { cityFocused = true }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .accessibilityIdentifier("favorite-editor")
    }
}
