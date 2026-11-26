import AppIntents

/// 捷徑 App 的「截取翻譯」動作。
/// 可設定到：設定 → 輔助使用 → 觸控 → 輕點背面，或 iPhone 的動作按鈕。
struct CaptureTranslateIntent: AppIntent {
    static var title: LocalizedStringResource = "截取翻譯"
    static var description = IntentDescription("截取目前畫面，翻譯成繁體中文顯示在子母畫面。需先開始螢幕廣播並開啟子母畫面。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared?.captureNow()
        return .result()
    }
}

struct NextRegionIntent: AppIntent {
    static var title: LocalizedStringResource = "切換翻譯範圍"
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared?.cyclePreset(1)
        return .result()
    }
}

struct PiPTranslatorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureTranslateIntent(),
                    phrases: ["用\(.applicationName)截取翻譯", "\(.applicationName) 截取翻譯"],
                    shortTitle: "截取翻譯",
                    systemImageName: "text.viewfinder")
        AppShortcut(intent: NextRegionIntent(),
                    phrases: ["用\(.applicationName)切換範圍"],
                    shortTitle: "切換翻譯範圍",
                    systemImageName: "rectangle.dashed")
    }
}
