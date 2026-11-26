import SwiftUI

/// 預設翻譯範圍（在子母畫面用 ⏪ ⏩ 切換，不用回到 App）
struct RegionPreset: Identifiable, Equatable {
    let id: Int
    let name: String
    let rect: NormRect?          // nil = 使用者自訂範圍

    static let all: [RegionPreset] = [
        .init(id: 0, name: "全螢幕", rect: .full),
        .init(id: 1, name: "上半部", rect: NormRect(x: 0, y: 0, w: 1, h: 0.5)),
        .init(id: 2, name: "下半部", rect: NormRect(x: 0, y: 0.5, w: 1, h: 0.5)),
        .init(id: 3, name: "字幕區", rect: NormRect(x: 0, y: 0.7, w: 1, h: 0.3)),
        .init(id: 4, name: "中間", rect: NormRect(x: 0, y: 0.3, w: 1, h: 0.4)),
        .init(id: 5, name: "自訂", rect: nil),
    ]
}

@MainActor
final class AppModel: ObservableObject {
    static weak var shared: AppModel?

    let server = LinkServer()
    let translator = Translator()
    let pip = PiPManager()

    @Published var config = ExtConfig()
    @Published var snapshot: UIImage?
    @Published var lastHeartbeat = Date.distantPast
    @Published var original = ""
    @Published var translated = ""
    @Published var now = Date()
    @Published var busy = false

    @AppStorage("engine") var engineRaw = Engine.auto.rawValue
    @AppStorage("fontSize") var fontSize = 34.0
    @AppStorage("showOriginal") var showOriginal = false
    @AppStorage("darkPiP") var darkPiP = true
    @AppStorage("pipWide") var pipWide = true
    @AppStorage("manualMode") var manualMode = true
    @AppStorage("presetID") var presetID = 0
    @AppStorage("savedRegion") private var savedRegion = ""
    @AppStorage("interval") private var savedInterval = 0.8
    @AppStorage("langHint") private var savedLangHint = "auto"

    /// 使用者在截圖上框的自訂範圍
    @Published var customRegion = NormRect.default

    private var seq = 0
    private var started = false

    init() {
        if let d = savedRegion.data(using: .utf8), let r = try? JSONDecoder().decode(NormRect.self, from: d) {
            customRegion = r
        }
        AppModel.shared = self
    }

    var engine: Engine { Engine(rawValue: engineRaw) ?? .auto }
    var broadcasting: Bool { now.timeIntervalSince(lastHeartbeat) < 6 }
    var preset: RegionPreset { RegionPreset.all.first { $0.id == presetID } ?? RegionPreset.all[0] }

    func start() {
        guard !started else { return }
        started = true
        config.interval = savedInterval
        config.langHint = savedLangHint
        config.manual = manualMode
        config.region = preset.rect ?? customRegion

        server.onMessage = { [weak self] m in self?.handle(m) }
        server.onConnected = { [weak self] in self?.pushConfig(); self?.server.send(LinkMessage(type: "resend")) }
        server.start()

        pip.onPlay = { [weak self] in self?.playPressed() }
        pip.onPause = { [weak self] in self?.pausePressed() }
        pip.onSkip = { [weak self] d in self?.cyclePreset(d) }
        applyPiPSize()
        pip.setup()
        pip.setPausedIcon(manualMode || config.paused)
        refreshPiP()

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    // MARK: - 子母畫面按鈕 / 捷徑

    /// ▶：手動模式＝截取一次；自動模式＝繼續
    func playPressed() {
        if manualMode {
            captureNow()
            pip.setPausedIcon(true)       // 保持 ▶ 圖示，方便下一次再按
        } else {
            config.paused = false
            pushConfig()
            pip.setPausedIcon(false)
            refreshPiP()
        }
    }

    func pausePressed() {
        if manualMode { pip.setPausedIcon(true); return }
        config.paused = true
        pushConfig()
        pip.setPausedIcon(true)
        refreshPiP()
    }

    /// 截取目前畫面並翻譯（子母畫面 ▶、捷徑、App 內按鈕都走這裡）
    func captureNow() {
        busy = true
        refreshPiP()
        server.send(LinkMessage(type: "capture"))
        // 沒回應時恢復標題
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.busy else { return }
            self.busy = false
            self.refreshPiP()
        }
    }

    func cyclePreset(_ d: Int) {
        let n = RegionPreset.all.count
        let i = RegionPreset.all.firstIndex { $0.id == presetID } ?? 0
        presetID = RegionPreset.all[((i + d) % n + n) % n].id
        applyPreset()
        if manualMode { captureNow() } else { refreshPiP() }
    }

    func applyPreset() {
        config.region = preset.rect ?? customRegion
        pushConfig()
    }

    func setManual(_ m: Bool) {
        manualMode = m
        config.manual = m
        config.paused = false
        pushConfig()
        pip.setPausedIcon(m)
        refreshPiP()
    }

    // MARK: - 設定

    func setForeground(_ fg: Bool) {
        config.appForeground = fg
        if fg { server.start() }
        pushConfig()
    }

    /// 使用者在截圖上拖拉框選 → 切到「自訂」
    func customRegionChanged() {
        if let d = try? JSONEncoder().encode(customRegion) { savedRegion = String(data: d, encoding: .utf8) ?? "" }
        presetID = 5
        applyPreset()
    }

    func configChanged() {
        savedInterval = config.interval
        savedLangHint = config.langHint
        pushConfig()
    }

    func pushConfig() {
        server.send(LinkMessage(type: "config", config: config))
    }

    func requestSnapshot() { server.send(LinkMessage(type: "requestSnapshot")) }

    func applyPiPSize() {
        pip.renderSize = pipWide ? CGSize(width: 960, height: 400) : CGSize(width: 720, height: 540)
    }

    var header: String {
        let mode: String
        if busy { mode = "辨識中…" }
        else if manualMode { mode = "▶ 截取" }
        else { mode = config.paused ? "已暫停" : "自動" }
        return "範圍：\(preset.name)　\(mode)　⏪⏩ 換範圍"
    }

    func refreshPiP() {
        let placeholder = manualMode ? "按子母畫面的 ▶ 截取目前畫面並翻譯" : ""
        pip.show(translated: translated.isEmpty ? placeholder : translated, original: original,
                 style: .init(fontSize: fontSize, showOriginal: showOriginal, dark: darkPiP, header: header))
    }

    // MARK: - 收到擴充的資料

    private func handle(_ m: LinkMessage) {
        switch m.type {
        case "hello", "heartbeat":
            lastHeartbeat = Date()
        case "snapshot":
            lastHeartbeat = Date()
            if let d = m.image, let img = UIImage(data: d) { snapshot = img }
        case "ocr":
            lastHeartbeat = Date()
            busy = false
            let paras = (m.paragraphs ?? []).filter { !isOwnOutput($0) }
            let lang = config.langHint == "auto" ? (m.lang ?? "en") : config.langHint
            seq += 1
            let mySeq = seq
            original = paras.joined(separator: "\n")
            if paras.isEmpty {
                translated = manualMode ? "（範圍內沒有找到英文或日文）" : ""
                refreshPiP()
                return
            }
            Task {
                let out = await translator.translate(paras, lang: lang, engine: engine)
                guard mySeq == self.seq else { return }   // 已有更新的結果
                self.translated = out.joined(separator: "\n")
                self.refreshPiP()
            }
        default: break
        }
    }

    /// 子母畫面本身也會被錄到；把「看起來是我們自己顯示的中文」濾掉
    private func isOwnOutput(_ p: String) -> Bool {
        if p.contains("範圍：") || p.contains("⏪") { return true }
        var kana = 0, han = 0, latin = 0
        for u in p.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF: kana += 1
            case 0x3400...0x9FFF: han += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        guard kana == 0, han > 0, han > latin * 2 else { return false }
        // 純漢字：如果大部分字都出現在目前翻譯結果裡，就是我們自己的輸出
        let mine = Set(translated)
        let chars = p.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard !chars.isEmpty else { return true }
        let hit = chars.filter { mine.contains($0) }.count
        return Double(hit) / Double(chars.count) > 0.6 || translated.isEmpty
    }
}
