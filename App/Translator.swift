import SwiftUI
import Translation

/// 翻譯引擎：
/// - apple：iOS 內建 Translation（下載語言包後可離線）
/// - google：線上 Google 翻譯（免金鑰的公開端點，非官方）
/// - auto：先用 Apple，失敗（例如 App 在背景時）就改用 Google
enum Engine: String, CaseIterable, Identifiable {
    case auto, apple, google
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "自動（Apple→Google）"
        case .apple: return "Apple 離線"
        case .google: return "Google 線上"
        }
    }
}

/// 預設目標語言；啟動後會改成 iOS 實際支援的繁體中文代碼
let fallbackTarget = Locale.Language(identifier: "zh-TW")

@MainActor
final class Translator: ObservableObject {
    /// 只會回覆一次的 continuation 包裝（逾時或 session 結束都不會卡住）
    final class Reply {
        private var cont: CheckedContinuation<[String], Error>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<[String], Error>) { cont = c }
        func finish(_ r: Result<[String], Error>) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(with: r)
        }
    }

    enum Job {
        case translate([String], Reply)
    }

    private var streams: [String: AsyncStream<Job>.Continuation] = [:]
    private var cache: [String: String] = [:]
    @Published var lastEngineUsed = ""
    @Published var lastError = ""
    /// iOS 支援的繁體中文（啟動時查詢）
    @Published var target: Locale.Language?
    /// 各來源語言的離線包狀態，例如 ["en": "已下載"]
    @Published var status: [String: String] = [:]

    func resolveTarget() async {
        let langs = await LanguageAvailability().supportedLanguages
        let t = langs.first(where: { $0.languageCode == .chinese && $0.script == .hanTraditional })
            ?? langs.first(where: { $0.languageCode == .chinese && $0.region == .taiwan })
            ?? fallbackTarget
        target = t
        await refreshStatus()
    }

    func refreshStatus() async {
        let t = target ?? fallbackTarget
        let a = LanguageAvailability()
        for s in ["en", "ja"] {
            let st = await a.status(from: Locale.Language(identifier: s), to: t)
            switch st {
            case .installed: status[s] = "已下載 ✅"
            case .supported: status[s] = "未下載"
            case .unsupported: status[s] = "不支援 ❌"
            @unknown default: status[s] = "未知"
            }
        }
    }

    // 由隱藏的 TranslationHost 呼叫
    func makeStream(for source: String) -> AsyncStream<Job> {
        let (stream, cont) = AsyncStream<Job>.makeStream()
        streams[source]?.finish()
        streams[source] = cont
        return stream
    }

    func translate(_ texts: [String], lang: String, engine: Engine) async -> [String] {
        let todo = texts.filter { cache[key($0, lang)] == nil }
        if !todo.isEmpty {
            var result: [String]?
            if engine != .google {
                do {
                    result = try await apple(todo, lang: lang)
                    lastEngineUsed = "Apple"
                } catch {
                    lastError = "Apple 翻譯失敗：\(error.localizedDescription)"
                }
            }
            if result == nil && engine != .apple {
                do {
                    var out: [String] = []
                    for t in todo { out.append(try await Self.google(t)) }
                    result = out
                    lastEngineUsed = "Google"
                } catch {
                    lastError = "Google 翻譯失敗：\(error.localizedDescription)"
                }
            }
            if let result {
                lastError = ""
                for (s, r) in zip(todo, result) { cache[key(s, lang)] = r }
                if cache.count > 500 { cache.removeAll() }
            }
        }
        return texts.map { cache[key($0, lang)] ?? $0 }
    }

    private func key(_ s: String, _ l: String) -> String { l + "|" + s }

    private func apple(_ texts: [String], lang: String) async throws -> [String] {
        guard let c = streams[lang] else {
            throw NSError(domain: "Translator", code: 1, userInfo: [NSLocalizedDescriptionKey: "翻譯服務尚未就緒"])
        }
        return try await withCheckedThrowingContinuation { cont in
            let reply = Reply(cont)
            c.yield(.translate(texts, reply))
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                reply.finish(.failure(NSError(domain: "Translator", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "逾時（可能在背景或尚未下載語言）"])))
            }
        }
    }

    static func google(_ text: String) async throws -> String {
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        c.queryItems = [
            .init(name: "client", value: "gtx"),
            .init(name: "sl", value: "auto"),
            .init(name: "tl", value: "zh-TW"),
            .init(name: "dt", value: "t"),
            .init(name: "q", value: text),
        ]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segs = root.first as? [Any] else {
            throw NSError(domain: "Translator", code: 2, userInfo: [NSLocalizedDescriptionKey: "回應格式錯誤"])
        }
        return segs.compactMap { ($0 as? [Any])?.first as? String }.joined()
    }
}

/// 隱藏的 SwiftUI 視圖，持有 Apple TranslationSession（iOS 18 只能這樣取得 session）
struct TranslationHost: View {
    let source: String     // "en" / "ja"
    @ObservedObject var translator: Translator
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(config) { session in
                let stream = await translator.makeStream(for: source)
                for await job in stream {
                    switch job {
                    case .translate(let texts, let reply):
                        do {
                            let reqs = texts.enumerated().map {
                                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                            }
                            let resps = try await session.translations(from: reqs)
                            var out = texts
                            for r in resps {
                                if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText }
                            }
                            reply.finish(.success(out))
                        } catch {
                            reply.finish(.failure(error))
                        }
                    }
                }
            }
            .onChange(of: translator.target, initial: true) { _, t in
                guard let t else { return }
                config = .init(source: Locale.Language(identifier: source), target: t)
            }
    }
}

/// 依序下載語言包（一次只跳一個系統下載視窗）
struct LanguageDownloader: ViewModifier {
    @ObservedObject var translator: Translator
    @Binding var queue: [String]
    @State private var config: TranslationSession.Configuration?
    @State private var current = ""

    func body(content: Content) -> some View {
        content
            .translationTask(config) { session in
                var msg = ""
                do {
                    try await session.prepareTranslation()
                } catch {
                    msg = error.localizedDescription
                }
                let m = msg
                await MainActor.run {
                    if !m.isEmpty { translator.lastError = "下載\(current)語言包失敗：\(m)" }
                }
                await translator.refreshStatus()
                await MainActor.run { next() }
            }
            .onChange(of: queue) { old, new in
                if old.isEmpty && !new.isEmpty { next() }
            }
    }

    @MainActor private func next() {
        guard !queue.isEmpty else { config = nil; return }
        let s = queue.removeFirst()
        current = s == "en" ? "英文" : "日文"
        config = .init(source: Locale.Language(identifier: s), target: translator.target ?? fallbackTarget)
    }
}
