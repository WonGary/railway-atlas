import RailwayCore
import SwiftUI

struct AssistantHistoryView: View {
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var map: RailwayMapStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category: String?
    @State private var editing: AssistantConversation?
    @State private var deleting: AssistantConversation?
    @State private var confirmDelete = false

    private var categories: [String] { Set(assistant.conversations.map(\.category)).sorted() }
    private var filtered: [AssistantConversation] {
        assistant.conversations.filter { (category == nil || $0.category == category) && $0.matches(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * map.uiScale) {
            HStack {
                Text("本地对话历史").atlasFont(.title2.bold())
                Spacer()
                Button("新建", systemImage: "plus") {
                    if assistant.newConversation() { dismiss() }
                }.disabled(assistant.busy)
                Button("完成") { dismiss() }
            }
            TextField("搜索标题、分类、问题、回答或引用", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("gpt-history-search")
            HStack {
                Picker("分类", selection: $category) {
                    Text("全部分类").tag(String?.none)
                    ForEach(categories, id: \.self) { value in
                        Text(value.isEmpty ? "未分类" : value).tag(Optional(value))
                    }
                }.pickerStyle(.menu)
                Spacer()
                Text("\(filtered.count) 个对话").atlasFont(.caption).foregroundStyle(.secondary)
            }
            if assistant.busy {
                Text("正在回答。停止或完成请求后即可切换、删除或编辑会话。")
                    .atlasFont(.caption).foregroundStyle(.secondary)
            }
            if let error = assistant.persistenceError {
                Text(error).atlasFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
                Button("重试保存") { assistant.persistCurrent() }
            }
            if !assistant.historyWarnings.isEmpty {
                DisclosureGroup("有 \(assistant.historyWarnings.count) 个会话文件未能载入") {
                    ScrollView {
                        Text(assistant.historyWarnings.joined(separator: "\n"))
                            .atlasFont(.caption).textSelection(.enabled)
                    }.frame(maxHeight: 90)
                }.atlasFont(.caption)
            }
            List {
                if filtered.isEmpty {
                    Text(search.isEmpty && category == nil ? "还没有本地对话。" : "没有匹配的对话。")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { conversation in
                    HStack(alignment: .top) {
                        Button {
                            if assistant.openConversation(id: conversation.id) { dismiss() }
                        } label: {
                            VStack(alignment: .leading, spacing: 5 * map.uiScale) {
                                HStack {
                                    if conversation.id == assistant.current.id {
                                        Image(systemName: "bubble.left.fill").foregroundStyle(.tint)
                                    }
                                    Text(conversation.title).atlasFont(.headline).lineLimit(2)
                                }
                                Text(conversation.draft.isEmpty ? (conversation.turns.last?.text ?? "空对话") : "草稿：" + conversation.draft)
                                    .atlasFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text("\(conversation.category.isEmpty ? "未分类" : conversation.category) · \(conversation.turns.count) 条消息 · \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .atlasFont(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(assistant.busy)
                        Menu {
                            Button("重命名 / 分类", systemImage: "pencil") { editing = conversation }.disabled(assistant.busy)
                            Button("复制整会话（Markdown）", systemImage: "doc.on.doc") {
                                AssistantClipboard.copy(conversation.id == assistant.current.id
                                                        ? assistant.conversationMarkdown
                                                        : AssistantConversationMarkdown.conversation(conversation))
                            }
                            Button("复制整会话（纯文本）", systemImage: "doc.plaintext") {
                                AssistantClipboard.copy(conversation.id == assistant.current.id
                                                        ? assistant.conversationPlainText
                                                        : AssistantConversationMarkdown.plainText(conversation))
                            }
                            Button("复制整会话（格式化文本）", systemImage: "doc.richtext") {
                                AssistantClipboard.copyFormatted(conversation.id == assistant.current.id
                                                                 ? assistant.conversationMarkdown
                                                                 : AssistantConversationMarkdown.conversation(conversation))
                            }
                            Button("删除", systemImage: "trash", role: .destructive) {
                                deleting = conversation; confirmDelete = true
                            }.disabled(assistant.busy)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("管理 \(conversation.title)")
                    }.padding(.vertical, 4)
                }
            }.listStyle(.plain)
            Text("自动保存在本机，包含草稿和每次提问的地图引用；API key 不写入会话。")
                .atlasFont(.caption2).foregroundStyle(.secondary)
            Text(assistant.repository.directory.path).atlasFont(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                .lineLimit(2)
        }
        .atlasPadding(20)
        .modifier(AtlasSheetLayout(scale: map.uiScale, width: 650, height: 620))
        .onChange(of: categories) { _, values in
            if let category, !values.contains(category) { self.category = nil }
        }
        .sheet(item: $editing) { AssistantConversationEditor(conversation: $0) }
        .alert("删除本地对话？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let deleting { assistant.deleteConversation(id: deleting.id) }
                deleting = nil
            }.disabled(assistant.busy)
        } message: {
            Text("将删除“\(deleting?.title ?? "")”的全部消息、引用和草稿。此操作无法撤销。")
        }
    }
}

private struct AssistantConversationEditor: View {
    let conversation: AssistantConversation
    @EnvironmentObject private var assistant: AssistantStore
    @EnvironmentObject private var map: RailwayMapStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var category = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * map.uiScale) {
            Text("对话名称与分类").atlasFont(.headline)
            TextField("对话名称", text: $title)
            TextField("分类（留空为未分类）", text: $category)
            Menu("使用已有分类") {
                Button("未分类") { category = "" }
                ForEach(Set(assistant.conversations.map(\.category)).filter { !$0.isEmpty }.sorted(), id: \.self) { value in
                    Button(value) { category = value }
                }
            }
            if let error = assistant.persistenceError {
                Text(error).atlasFont(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    if assistant.updateConversation(id: conversation.id, title: title, category: category) { dismiss() }
                }.buttonStyle(.borderedProminent)
                    .disabled(assistant.busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.textFieldStyle(.roundedBorder).atlasPadding(24)
            .modifier(AtlasSheetLayout(scale: map.uiScale, width: 430, height: 300))
            .onAppear { title = conversation.title; category = conversation.category }
    }
}
