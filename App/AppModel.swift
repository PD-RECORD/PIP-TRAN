import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let server = LinkServer()
    let translator = Translator()
    let pip = PiPManager()

    @Published var config = ExtConfig()
    @Published var snapshot: UIImage?
    @Published var lastHeartbeat = Date.distantPast
    @Published var original = ""
    @Published var translated = ""
    @Published var now = Date()

    @AppStorage("engine") var engineRaw = Engine.auto.rawValue
    @AppStorage("fontSize") var fontSize = 34.0
    @AppStorage("showOriginal") var showOriginal = false
    @AppStorage("darkPiP") var darkPiP = true
    @AppStorage("pipWide") var pipWide = true
    @AppStorage("savedRegion") private var savedRegion = ""
    @AppStorage("interval") private var savedInterval = 0.8
    @AppStorage("langHint") private var savedLangHint = "auto"

    private var seq = 0
    private var started = false

    var engine: Engine { Engine(rawValue: engineRaw) ?? .auto }
    var broadcasting: Bool { now.timeIntervalSince(lastHeartbeat) < 6 }

    func start() {
        guard !started else { return }
        started = true
        if let d = savedRegion.data(using: .utf8), let r = try? JSONDecoder().decode(NormRect.self, from: d) {
            config.region = r
        }
        config.interval = savedInterval
        config.langHint = savedLangHint

        server.onMessage = { [weak self] m in self?.handle(m) }
        server.onConnected = { [weak self] in self?.pushConfig(); self?.server.send(LinkMessage(type: "resend")) }
        server.start()

        applyPiPSize()
        pip.setup()
        refreshPiP()

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    func setForeground(_ fg: Bool) {
        config.appForeground = fg
        if fg { server.start() }
        pushConfig()
    }

    func configChanged() {
        if let d = try? JSONEncoder().encode(config.region) { savedRegion = String(data: d, encoding: .utf8) ?? "" }
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

    func refreshPiP() {
        pip.show(translated: translated, original: original,
                 style: .init(fontSize: fontSize, showOriginal: showOriginal, dark: darkPiP))
    }

    private func handle(_ m: LinkMessage) {
        switch m.type {
        case "hello", "heartbeat":
            lastHeartbeat = Date()
        case "snapshot":
            lastHeartbeat = Date()
            if let d = m.image, let img = UIImage(data: d) { snapshot = img }
        case "ocr":
            lastHeartbeat = Date()
            let paras = m.paragraphs ?? []
            let lang = config.langHint == "auto" ? (m.lang ?? "en") : config.langHint
            seq += 1
            let mySeq = seq
            original = paras.joined(separator: "\n")
            if paras.isEmpty { translated = ""; refreshPiP(); return }
            Task {
                let out = await translator.translate(paras, lang: lang, engine: engine)
                guard mySeq == self.seq else { return }   // 已有更新的結果
                self.translated = out.joined(separator: "\n")
                self.refreshPiP()
            }
        default: break
        }
    }
}
