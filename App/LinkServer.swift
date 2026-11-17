import Foundation
import Network

/// 主程式端：在 127.0.0.1 監聽，等廣播擴充連進來
final class LinkServer {
    var onMessage: ((LinkMessage) -> Void)?     // 主執行緒呼叫
    var onConnected: (() -> Void)?             // 主執行緒呼叫
    private var listener: NWListener?
    private var current: LinkConnection?

    func start() {
        if let l = listener, l.state == .ready || l.state == .setup { return }
        listener?.cancel()
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Link.port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed = st {
                    Link.queue.asyncAfter(deadline: .now() + 1) { self?.restart() }
                }
            }
            l.start(queue: Link.queue)
            listener = l
        } catch {
            Link.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restart() }
        }
    }

    func restart() {
        listener?.cancel()
        listener = nil
        start()
    }

    private func accept(_ c: NWConnection) {
        current?.cancel()
        let lc = LinkConnection(c)
        lc.onMessage = { [weak self] m in DispatchQueue.main.async { self?.onMessage?(m) } }
        lc.onState = { [weak self] st in
            if case .ready = st { DispatchQueue.main.async { self?.onConnected?() } }
        }
        current = lc
        lc.start()
    }

    func send(_ m: LinkMessage) {
        Link.queue.async { [weak self] in self?.current?.send(m) }
    }
}
