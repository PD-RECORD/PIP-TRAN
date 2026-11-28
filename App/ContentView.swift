import SwiftUI
import ReplayKit

struct ContentView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        Inner(m: m, tr: m.translator, pip: m.pip)
    }
}

private struct Inner: View {
    @ObservedObject var m: AppModel
    @ObservedObject var tr: Translator
    @ObservedObject var pip: PiPManager
    @State private var editingRegion = false
    @State private var downloadQueue: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PiPLayerView(layer: pip.displayLayer)
                        .aspectRatio(m.pipWide ? 960.0 / 400.0 : 720.0 / 540.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    Button(pip.isActive ? "關閉子母畫面" : "開啟子母畫面") { pip.toggle() }
                        .disabled(!pip.isPossible && !pip.isActive)
                } header: { Text("子母畫面預覽") } footer: {
                    Text("開啟後也可直接回主畫面，系統會自動縮成子母畫面。")
                }

                Section {
                    Text("""
                    1. 下面「螢幕廣播」開始直播
                    2. 開啟子母畫面，回到任何 App
                    3. 在子母畫面上點一下叫出按鈕：
                       ▶ 截取目前畫面並翻譯
                       ⏪ ⏩ 切換範圍（全螢幕／上半／下半／字幕區／中間／自訂）
                    """).font(.callout)
                } header: { Text("怎麼用（不用回到本 App）") }

                Section("1. 螢幕廣播（擷取畫面）") {
                    HStack {
                        BroadcastButton().frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(m.broadcasting ? "● 廣播中，已連線" : "○ 尚未連線")
                                .foregroundStyle(m.broadcasting ? .green : .secondary)
                            Text("點左邊按鈕 → 選「PiP翻譯」→ 開始直播")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Picker("模式", selection: Binding(get: { m.manualMode }, set: { m.setManual($0) })) {
                        Text("按 ▶ 才截取").tag(true)
                        Text("自動連續翻譯").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Picker("範圍", selection: Binding(get: { m.presetID }, set: { m.presetID = $0; m.applyPreset(); m.refreshPiP() })) {
                        ForEach(RegionPreset.all) { Text($0.name).tag($0.id) }
                    }
                    Button("現在截取翻譯") { m.captureNow() }
                        .disabled(!m.broadcasting)
                } header: { Text("2. 截取方式與範圍") } footer: {
                    Text("在子母畫面按 ⏪ ⏩ 也能切換範圍。「自動連續」適合看影片字幕。")
                }

                Section {
                    RegionSelector(image: m.snapshot, region: $m.customRegion)
                        .frame(maxHeight: 360)
                        .frame(maxWidth: .infinity)
                        .onChange(of: m.customRegion) { _, _ in m.customRegionChanged() }
                    Button("全螢幕編輯範圍") { editingRegion = true }
                } header: { Text("自訂範圍（選用）") } footer: {
                    Text("截圖是你切回本 App 前最後看到的畫面。拖拉黃色框後，範圍會自動切到「自訂」。")
                }

                Section("3. 翻譯") {
                    Picker("來源語言", selection: $m.config.langHint) {
                        Text("自動").tag("auto"); Text("英文").tag("en"); Text("日文").tag("ja")
                    }
                    .onChange(of: m.config.langHint) { _, _ in m.configChanged() }
                    Picker("翻譯引擎", selection: $m.engineRaw) {
                        ForEach(Engine.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Button("下載 Apple 離線語言包（英、日→繁中）") {
                        tr.lastError = ""
                        downloadQueue = ["en", "ja"]
                    }
                    .disabled(!downloadQueue.isEmpty)
                    LabeledContent("英文→繁中", value: tr.status["en"] ?? "查詢中…")
                    LabeledContent("日文→繁中", value: tr.status["ja"] ?? "查詢中…")
                    if tr.status.values.contains("未下載") {
                        Text("按了沒反應的話，可到 iPhone「設定 → App → 翻譯 → 已下載的語言」手動下載英文、日文、中文（繁體），再回來按「重新檢查」。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("重新檢查語言包狀態") { Task { await tr.refreshStatus() } }
                    VStack(alignment: .leading) {
                        Text("辨識間隔：\(m.config.interval, specifier: "%.1f") 秒")
                        Slider(value: $m.config.interval, in: 0.3...3, step: 0.1, onEditingChanged: { e in if !e { m.configChanged() } })
                    }
                    if !tr.lastEngineUsed.isEmpty { Text("上次使用：\(tr.lastEngineUsed)").font(.caption) }
                    if !tr.lastError.isEmpty { Text(tr.lastError).font(.caption).foregroundStyle(.red) }
                }

                Section("4. 子母畫面外觀") {
                    VStack(alignment: .leading) {
                        Text("字級：\(Int(m.fontSize))")
                        Slider(value: $m.fontSize, in: 16...72, step: 2)
                    }
                    Toggle("同時顯示原文", isOn: $m.showOriginal)
                    Toggle("深色背景", isOn: $m.darkPiP)
                    Toggle("寬版比例（否則 4:3）", isOn: $m.pipWide)
                }
                .onChange(of: m.fontSize) { _, _ in m.refreshPiP() }
                .onChange(of: m.showOriginal) { _, _ in m.refreshPiP() }
                .onChange(of: m.darkPiP) { _, _ in m.refreshPiP() }
                .onChange(of: m.pipWide) { _, _ in m.applyPiPSize(); m.refreshPiP() }

                Section("最近辨識結果") {
                    Text(m.original.isEmpty ? "—" : m.original).font(.caption).textSelection(.enabled)
                    Text(m.translated.isEmpty ? "—" : m.translated).textSelection(.enabled)
                }
            }
            .navigationTitle("PiP 翻譯")
            .modifier(LanguageDownloader(translator: tr, queue: $downloadQueue))
            .task { await tr.resolveTarget() }
            .background {
                // 隱藏的 Apple 翻譯 session（英、日各一）
                TranslationHost(source: "en", translator: tr)
                TranslationHost(source: "ja", translator: tr)
            }
            .fullScreenCover(isPresented: $editingRegion) {
                NavigationStack {
                    RegionSelector(image: m.snapshot, region: $m.customRegion)
                        .padding()
                        .onChange(of: m.customRegion) { _, _ in m.customRegionChanged() }
                        .toolbar { Button("完成") { editingRegion = false } }
                        .navigationTitle("拖拉選擇範圍")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}

/// 系統的「開始螢幕廣播」按鈕，預先選好本 App 的擴充
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        v.preferredExtension = Self.extensionBundleID()
        v.showsMicrophoneButton = false
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}

    /// 從 PlugIns 找出廣播擴充的 bundle ID（側載工具改過 ID 也找得到）
    static func extensionBundleID() -> String? {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for u in items where u.pathExtension == "appex" {
            if let b = Bundle(url: u),
               let ext = b.infoDictionary?["NSExtension"] as? [String: Any],
               ext["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload" {
                return b.bundleIdentifier
            }
        }
        return nil
    }
}
