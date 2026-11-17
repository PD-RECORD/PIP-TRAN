import ReplayKit
import Vision
import CoreImage
import Network

/// 螢幕廣播擴充：擷取畫面 → 裁切使用者選的範圍 → Vision OCR（英/日）→ 傳給主程式。
/// 注意：此擴充記憶體上限約 50MB，所以一次只處理一張畫面並節流。
class SampleHandler: RPBroadcastSampleHandler {

    private let work = DispatchQueue(label: "pipxlate.ocr", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastOCR: CFTimeInterval = 0
    private var lastSnap: CFTimeInterval = 0

    private var config = ExtConfig()
    private var lastSentText = ""
    private var lastParagraphs: [String] = []
    private var lastLang = "en"

    /// 最近幾張縮圖（時間, JPEG），用來挑「切回主程式之前」的畫面
    private var snapshots: [(CFTimeInterval, Data)] = []

    private var client: LinkConnection?
    private var connected = false
    private var heartbeat: DispatchSourceTimer?
    private lazy var ci = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Broadcast lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        connect()
        let t = DispatchSource.makeTimerSource(queue: Link.queue)
        t.schedule(deadline: .now() + 1, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.connected { self.client?.send(LinkMessage(type: "heartbeat")) }
            else if self.client == nil { self.connect() }
        }
        t.resume()
        heartbeat = t
    }

    override func broadcastFinished() {
        heartbeat?.cancel()
        client?.cancel()
    }

    // MARK: - Link

    private func connect() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Link.port)!, using: params)
        let lc = LinkConnection(c)
        lc.onMessage = { [weak self] m in self?.handle(m) }
        lc.onState = { [weak self, weak lc] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.connected = true
                lc?.send(LinkMessage(type: "hello"))
                // 重新連上時補送最新結果
                if !self.lastParagraphs.isEmpty {
                    lc?.send(LinkMessage(type: "ocr", paragraphs: self.lastParagraphs, lang: self.lastLang))
                }
            case .failed, .cancelled, .waiting:
                self.connected = false
                if self.client === lc {
                    self.client = nil
                    lc?.cancel()
                }
            default: break
            }
        }
        client = lc
        lc.start()
    }

    private func handle(_ m: LinkMessage) {
        switch m.type {
        case "config":
            if let c = m.config {
                lock.lock()
                let wasForeground = config.appForeground
                config = c
                lock.unlock()
                if c.appForeground && !wasForeground { sendBestSnapshot() }
            }
        case "requestSnapshot":
            sendBestSnapshot()
        case "resend":
            lastSentText = ""
        default: break
        }
    }

    private func sendBestSnapshot() {
        lock.lock()
        let now = CACurrentMediaTime()
        // 挑 0.8 秒以前的（避開切換 App 的動畫），沒有就給最新的
        let pick = snapshots.last(where: { now - $0.0 >= 0.8 }) ?? snapshots.last
        lock.unlock()
        if let pick {
            client?.send(LinkMessage(type: "snapshot", image: pick.1))
        }
    }

    // MARK: - Frames

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = CACurrentMediaTime()

        lock.lock()
        let cfg = config
        let needOCR = !cfg.appForeground && now - lastOCR >= max(cfg.interval, 0.3)
        let needSnap = !cfg.appForeground && now - lastSnap >= 1.0
        if busy || (!needOCR && !needSnap) { lock.unlock(); return }
        busy = true
        if needOCR { lastOCR = now }
        if needSnap { lastSnap = now }
        lock.unlock()

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lock.lock(); busy = false; lock.unlock(); return
        }
        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }

        work.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                if needSnap { self.makeSnapshot(pb, orientation, now) }
                if needOCR { self.recognize(pb, orientation, cfg) }
            }
            self.lock.lock(); self.busy = false; self.lock.unlock()
        }
    }

    private func makeSnapshot(_ pb: CVPixelBuffer, _ o: CGImagePropertyOrientation, _ t: CFTimeInterval) {
        var img = CIImage(cvPixelBuffer: pb).oriented(o)
        let scale = 540.0 / max(img.extent.width, 1)
        img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let jpg = ci.jpegRepresentation(of: img, colorSpace: cs,
                                              options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.6])
        else { return }
        lock.lock()
        snapshots.append((t, jpg))
        if snapshots.count > 4 { snapshots.removeFirst() }
        lock.unlock()
    }

    private func recognize(_ pb: CVPixelBuffer, _ o: CGImagePropertyOrientation, _ cfg: ExtConfig) {
        let r = cfg.region.clamped
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        switch cfg.langHint {
        case "en": req.recognitionLanguages = ["en-US"]
        default:   req.recognitionLanguages = ["ja-JP", "en-US"]
        }
        // Vision 座標原點在左下
        req.regionOfInterest = CGRect(x: r.x, y: 1 - r.y - r.h, width: r.w, height: r.h)

        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: o, options: [:])
        do { try handler.perform([req]) } catch { return }

        let lines: [(String, CGRect)] = (req.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first, c.confidence > 0.3 else { return nil }
            return (c.string, obs.boundingBox)
        }
        let paragraphs = Self.group(lines)
        let joined = paragraphs.joined(separator: "\n")
        guard joined != lastSentText else { return }
        lastSentText = joined
        lastParagraphs = paragraphs
        lastLang = Self.detectLang(joined)
        if connected {
            client?.send(LinkMessage(type: "ocr", paragraphs: paragraphs, lang: lastLang))
        } else {
            lastSentText = ""   // 沒送出，下次再送
        }
    }

    // MARK: - Text helpers

    /// 把 OCR 的每一行依上下距離合併成段落
    static func group(_ lines: [(String, CGRect)]) -> [String] {
        guard !lines.isEmpty else { return [] }
        let sorted = lines.sorted {
            abs($0.1.midY - $1.1.midY) < min($0.1.height, $1.1.height) * 0.5
                ? $0.1.minX < $1.1.minX
                : $0.1.midY > $1.1.midY
        }
        var paras: [[String]] = [[sorted[0].0]]
        var prev = sorted[0].1
        for (text, box) in sorted.dropFirst() {
            let gap = prev.minY - box.maxY
            let h = max(prev.height, box.height)
            if gap > h * 0.9 { paras.append([text]) } else { paras[paras.count - 1].append(text) }
            prev = box
        }
        return paras.map { joinLines($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func joinLines(_ ls: [String]) -> String {
        var out = ""
        for l in ls {
            let t = l.trimmingCharacters(in: .whitespaces)
            if out.isEmpty { out = t; continue }
            if out.hasSuffix("-") { out.removeLast(); out += t }
            else if isCJK(out.last) || isCJK(t.first) { out += t }
            else { out += " " + t }
        }
        return out
    }

    static func isCJK(_ c: Character?) -> Bool {
        guard let s = c?.unicodeScalars.first?.value else { return false }
        return (0x3000...0x30FF).contains(s) || (0x3400...0x9FFF).contains(s) || (0xFF00...0xFFEF).contains(s)
    }

    static func detectLang(_ s: String) -> String {
        var kana = 0, han = 0, latin = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF: kana += 1
            case 0x3400...0x9FFF: han += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        if kana > 0 || han > latin { return "ja" }
        return "en"
    }
}
