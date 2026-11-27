import RailwayCore
import SwiftUI

@main
struct RailwayAtlasApp: App {
    @StateObject private var store = RailwayMapStore()
    @StateObject private var assistant = AssistantStore()
    @StateObject private var connectivity = Connectivity()
    @StateObject private var configuration: ConfigurationStore
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AtlasAppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    #endif
    init() {
        let map = RailwayMapStore(), assistant = AssistantStore(), configuration = ConfigurationStore()
        configuration.bind(map: map, assistant: assistant)
        _store = StateObject(wrappedValue: map)
        _assistant = StateObject(wrappedValue: assistant)
        _configuration = StateObject(wrappedValue: configuration)
    }

    private var mainContent: some View {
        ContentView()
            .environmentObject(store)
            .environmentObject(assistant)
            .environmentObject(connectivity)
            .environmentObject(configuration)
    }
    #if os(macOS)
    private var settingsContent: some View {
        AtlasInterface(scale: store.uiScale) { AtlasSettingsView() }
            .environmentObject(store)
            .environmentObject(assistant)
            .environmentObject(connectivity)
            .environmentObject(configuration)
    }

    private var assistantContent: some View {
        AtlasInterface(scale: store.uiScale) { AtlasAssistantView() }
            .environmentObject(store)
            .environmentObject(assistant)
            .environmentObject(connectivity)
            .environmentObject(configuration)
    }
    #endif
    var body: some Scene {
        #if os(macOS)
        let _ = delegate.configureMainWindow { openWindow(id: "main-map") }
        Window("铁道图鉴", id: "main-map") { mainContent }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)
        .commands {
            ExperienceCommands { store.journeyWorkspace.tab = $0 }
            CommandGroup(replacing: .newItem) {
                Button("导入地图包…") { store.showImporter = true }.keyboardShortcut("o")
                Button("导出当前地图包…") { store.prepareExport() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.dataset == nil)
            }
            CommandMenu("地图") {
                Button("显示整个区域") { store.fitDataset() }.keyboardShortcut("0")
                Button("放大") { store.zoom(0.65) }.keyboardShortcut("+")
                Button("缩小") { store.zoom(1.55) }.keyboardShortcut("-")
                Divider()
                ForEach(MapMode.allCases) { mode in Button(mode.title) { store.changeMode(mode) } }
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { openWindow(id: "railway-settings") }.keyboardShortcut(",")
            }
            CommandMenu("界面") {
                Button("放大界面") { store.uiScale = min(1.6, store.uiScale + 0.1) }.keyboardShortcut("+", modifiers: [.command, .option])
                Button("缩小界面") { store.uiScale = max(0.75, store.uiScale - 0.1) }.keyboardShortcut("-", modifiers: [.command, .option])
                Button("还原界面") { store.uiScale = 1 }.keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button("显示 / 隐藏左侧面板") { store.panelVisible.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("显示 / 隐藏右侧栏") { store.inspectorVisible.toggle() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Menu("左侧布局") {
                    Picker("布局", selection: $store.panelLayout) {
                        ForEach(MapPanelLayout.allCases) { Text($0.title).tag($0) }
                    }
                }
                Menu("右侧布局") {
                    Picker("布局", selection: $store.inspectorLayout) {
                        ForEach(MapPanelLayout.allCases) { Text($0.title).tag($0) }
                    }
                }
                Menu("左侧浮窗大小") {
                    Button("小") { store.panelSize = .small; store.panelVisible = true }
                        .keyboardShortcut("1", modifiers: [.command, .option])
                    Button("中") { store.panelSize = .medium; store.panelVisible = true }
                        .keyboardShortcut("2", modifiers: [.command, .option])
                    Button("大") { store.panelSize = .large; store.panelVisible = true }
                        .keyboardShortcut("3", modifiers: [.command, .option])
                }
                Button("显示 / 隐藏状态卡") { store.statusVisible.toggle() }
            }
        }
        Window("GPT 地图助手", id: "railway-assistant") { assistantContent }
            .defaultSize(width: 720, height: 820)
        Window("设置", id: "railway-settings") { settingsContent }
            .defaultSize(width: 680, height: 760)
        #else
        WindowGroup("铁道图鉴") { mainContent }
        #endif
        #if os(macOS)
        Window("铁道漫游", id: "railway-experiences") {
            ExperienceRootView(model:store.journeyWorkspace, map: store)
        }
        .defaultSize(width: 1080, height: 830)
        #endif
    }
}

#if os(macOS)
@MainActor
final class AtlasAppDelegate: NSObject, NSApplicationDelegate {
    private var openMainWindow: (() -> Void)?
    func configureMainWindow(_ action: @escaping () -> Void) { openMainWindow = action }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Older releases saved an anonymous WindowGroup identifier. Its failed
        // restoration must not leave the new named main-map scene unopened.
        DispatchQueue.main.async { [weak self] in
            if !NSApp.windows.contains(where: { $0.isVisible && $0.contentView != nil }) {
                self?.openMainWindow?()
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
