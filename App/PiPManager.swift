import AVKit
import UIKit
import SwiftUI

/// 用 AVSampleBufferDisplayLayer 產生「影片畫面」，交給系統子母畫面顯示翻譯文字
final class PiPManager: NSObject, ObservableObject {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var possibleObs: NSKeyValueObservation?
    private var refresh: Timer?
    private var lastFrame: UIImage?

    @Published var isPossible = false
    @Published var isActive = false

    /// 子母畫面按鈕回呼（主執行緒）
    var onPlay: (() -> Void)?          // 按 ▶
    var onPause: (() -> Void)?         // 按 ⏸（自動模式）
    var onSkip: ((Int) -> Void)?       // ⏪ = -1, ⏩ = +1
    /// 目前顯示「暫停」狀態（▶ 圖示）
    var showsPaused = true

    /// 子母畫面比例（寬:高）
    var renderSize = CGSize(width: 960, height: 400)

    func setup() {
        guard controller == nil else { return }
        let s = AVAudioSession.sharedInstance()
        // mixWithOthers：不會打斷其他 App 正在播的影片/音樂
        try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? s.setActive(true)

        displayLayer.videoGravity = .resizeAspect
        let src = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                             playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: src)
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = true   // 回主畫面時自動進入子母畫面
        c.requiresLinearPlayback = false   // 顯示 ⏪ ⏩ 按鈕，拿來切換範圍
        possibleObs = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            DispatchQueue.main.async { self?.isPossible = c.isPictureInPicturePossible }
        }
        controller = c

        // 定期重送最後一張，避免畫面被系統判定停住
        refresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let img = self.lastFrame else { return }
            self.enqueue(img)
        }
    }

    /// 更新 ▶/⏸ 圖示
    func setPausedIcon(_ paused: Bool) {
        showsPaused = paused
        controller?.invalidatePlaybackState()
    }

    func toggle() {
        guard let c = controller else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else { c.startPictureInPicture() }
    }

    // MARK: - Rendering

    struct Style {
        var fontSize: CGFloat = 34
        var showOriginal = false
        var dark = true
        var header = ""     // 左上角小字：目前範圍、模式
    }

    func show(translated: String, original: String, style: Style) {
        let img = Self.render(translated: translated, original: original, size: renderSize, style: style)
        lastFrame = img
        enqueue(img)
    }

    static func render(translated: String, original: String, size: CGSize, style: Style) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            (style.dark ? UIColor(white: 0.08, alpha: 1) : UIColor.white).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let fg: UIColor = style.dark ? .white : .black
            let pad: CGFloat = 24
            var box = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2)
            if !style.header.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 20, weight: .semibold),
                    .foregroundColor: UIColor.systemYellow]
                (style.header as NSString).draw(at: CGPoint(x: pad, y: 10), withAttributes: attrs)
                box.origin.y += 22
                box.size.height -= 22
            }

            if style.showOriginal && !original.isEmpty {
                let oh = box.height * 0.3
                drawFit(original, in: CGRect(x: box.minX, y: box.minY, width: box.width, height: oh),
                        maxSize: style.fontSize * 0.7, color: fg.withAlphaComponent(0.55))
                box.origin.y += oh + 8
                box.size.height -= oh + 8
            }
            drawFit(translated.isEmpty ? "（等待文字…）" : translated, in: box,
                    maxSize: style.fontSize, color: fg)
        }
    }

    /// 自動縮小字級直到放得下
    private static func drawFit(_ text: String, in rect: CGRect, maxSize: CGFloat, color: UIColor) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 4
        var size = maxSize
        var attrs: [NSAttributedString.Key: Any] = [:]
        while true {
            attrs = [.font: UIFont.systemFont(ofSize: size, weight: .medium),
                     .foregroundColor: color, .paragraphStyle: para]
            let need = (text as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                       attributes: attrs, context: nil)
            if need.height <= rect.height || size <= 12 { break }
            size -= 2
        }
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: attrs, context: nil)
    }

    private func enqueue(_ image: UIImage) {
        guard let sb = Self.sampleBuffer(from: image) else { return }
        let r = displayLayer.sampleBufferRenderer
        if r.status == .failed { r.flush() }
        r.enqueue(sb)
    }

    static func sampleBuffer(from image: UIImage) -> CMSampleBuffer? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var pbOut: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                 formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb, let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isActive = true }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isActive = false }
    }
}

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        DispatchQueue.main.async {
            if playing { self.onPlay?() } else { self.onPause?() }
        }
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        // 有限長度才會出現 ⏪ ⏩ 按鈕
        CMTimeRange(start: .zero, duration: CMTime(seconds: 86_400, preferredTimescale: 1))
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { showsPaused }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        let dir = CMTimeGetSeconds(skipInterval) >= 0 ? 1 : -1
        DispatchQueue.main.async { self.onSkip?(dir) }
        completionHandler()
    }
}

/// 把 displayLayer 放進畫面（子母畫面要求圖層必須在視圖階層中）
struct PiPLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    final class V: UIView {
        var l: CALayer?
        override func layoutSubviews() { super.layoutSubviews(); l?.frame = bounds }
    }
    func makeUIView(context: Context) -> V {
        let v = V()
        v.backgroundColor = .black
        v.layer.addSublayer(layer)
        v.l = layer
        return v
    }
    func updateUIView(_ uiView: V, context: Context) {}
}
