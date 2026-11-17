import SwiftUI

/// 在截圖上拖拉決定翻譯範圍：
/// - 拖角落：調整大小
/// - 拖框內：移動
/// - 在框外拖：重新畫一個框
struct RegionSelector: View {
    let image: UIImage?
    @Binding var region: NormRect

    private enum Mode { case none, move, draw, corner(Int) }
    @State private var mode: Mode = .none
    @State private var start = NormRect.default

    private var aspect: CGFloat {
        if let i = image, i.size.height > 0 { return i.size.width / i.size.height }
        let s = UIScreen.main.bounds.size
        return s.width / s.height
    }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let rect = CGRect(x: region.x * W, y: region.y * H, width: region.w * W, height: region.h * H)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(uiImage: image).resizable().frame(width: W, height: H)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.25))
                    Text("尚無截圖\n開始廣播後切到要翻譯的 App，再回來這裡")
                        .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        .frame(width: W, height: H)
                }
                // 框外變暗
                Path { p in
                    p.addRect(CGRect(x: 0, y: 0, width: W, height: H))
                    p.addRect(rect)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                ForEach(0..<4, id: \.self) { i in
                    let p = corner(i, rect)
                    Circle().fill(Color.yellow)
                        .frame(width: 18, height: 18)
                        .offset(x: p.x - 9, y: p.y - 9)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in drag(g, W: W, H: H, rect: rect) }
                    .onEnded { _ in mode = .none }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipped()
    }

    private func corner(_ i: Int, _ r: CGRect) -> CGPoint {
        switch i {
        case 0: return CGPoint(x: r.minX, y: r.minY)
        case 1: return CGPoint(x: r.maxX, y: r.minY)
        case 2: return CGPoint(x: r.minX, y: r.maxY)
        default: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func drag(_ g: DragGesture.Value, W: CGFloat, H: CGFloat, rect: CGRect) {
        let s = g.startLocation, c = g.location
        if case .none = mode {
            start = region
            if let i = (0..<4).first(where: { hypot(corner($0, rect).x - s.x, corner($0, rect).y - s.y) < 30 }) {
                mode = .corner(i)
            } else if rect.contains(s) {
                mode = .move
            } else {
                mode = .draw
            }
        }
        let dx = Double((c.x - s.x) / W), dy = Double((c.y - s.y) / H)
        switch mode {
        case .move:
            region = NormRect(x: start.x + dx, y: start.y + dy, w: start.w, h: start.h).clamped
        case .draw:
            let x0 = Double(min(s.x, c.x) / W), y0 = Double(min(s.y, c.y) / H)
            let x1 = Double(max(s.x, c.x) / W), y1 = Double(max(s.y, c.y) / H)
            region = NormRect(x: max(x0, 0), y: max(y0, 0), w: min(x1, 1) - max(x0, 0), h: min(y1, 1) - max(y0, 0)).clamped
        case .corner(let i):
            var l = start.x, t = start.y, r = start.x + start.w, b = start.y + start.h
            if i == 0 || i == 2 { l += dx } else { r += dx }
            if i == 0 || i == 1 { t += dy } else { b += dy }
            l = max(0, l); t = max(0, t); r = min(1, r); b = min(1, b)
            region = NormRect(x: min(l, r), y: min(t, b), w: abs(r - l), h: abs(b - t)).clamped
        case .none: break
        }
    }
}
