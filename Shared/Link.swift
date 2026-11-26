import Foundation
import Network

/// 主程式與「螢幕廣播擴充」之間透過本機 127.0.0.1 TCP 溝通。
/// 不使用 App Group，免得側載工具（Sideloadly 等）處理 entitlement 出問題。
enum Link {
    static let port: UInt16 = 47_321
    static let queue = DispatchQueue(label: "pipxlate.link")
}

/// 正規化矩形（0~1，左上角為原點，以「螢幕直立後」的畫面為準）
struct NormRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static let `default` = NormRect(x: 0.05, y: 0.35, w: 0.9, h: 0.3)
    static let full = NormRect(x: 0, y: 0, w: 1, h: 1)

    var clamped: NormRect {
        var r = self
        r.w = min(max(r.w, 0.02), 1)
        r.h = min(max(r.h, 0.02), 1)
        r.x = min(max(r.x, 0), 1 - r.w)
        r.y = min(max(r.y, 0), 1 - r.h)
        return r
    }
}

struct ExtConfig: Codable, Equatable {
    var region: NormRect = .default
    var interval: Double = 0.8        // OCR 最短間隔（秒）
    var langHint: String = "auto"     // auto / en / ja
    var appForeground: Bool = true    // 主程式在前景時暫停 OCR
    var manual: Bool = true           // true：只在按 ▶ / 捷徑時截取；false：持續自動翻譯
    var paused: Bool = false          // 自動模式下暫停
}

struct LinkMessage: Codable {
    var type: String                  // hello / heartbeat / ocr / snapshot / config / requestSnapshot / capture
    var paragraphs: [String]? = nil
    var lang: String? = nil
    var image: Data? = nil            // JPEG（JSON 內會自動 base64）
    var config: ExtConfig? = nil
}

/// 以換行分隔 JSON 的雙向連線包裝
final class LinkConnection {
    let conn: NWConnection
    var onMessage: ((LinkMessage) -> Void)?
    var onState: ((NWConnection.State) -> Void)?
    private var buffer = Data()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(_ conn: NWConnection) { self.conn = conn }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in self?.onState?(st) }
        conn.start(queue: Link.queue)
        receive()
    }

    func cancel() { conn.cancel() }

    func send(_ msg: LinkMessage) {
        guard var data = try? encoder.encode(msg) else { return }
        data.append(0x0A)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                while let nl = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                    self.buffer.removeSubrange(self.buffer.startIndex...nl)
                    if let m = try? self.decoder.decode(LinkMessage.self, from: line) {
                        self.onMessage?(m)
                    }
                }
                if self.buffer.count > 8 << 20 { self.buffer.removeAll() }
            }
            if done || err != nil {
                self.conn.cancel()
                return
            }
            self.receive()
        }
    }
}
