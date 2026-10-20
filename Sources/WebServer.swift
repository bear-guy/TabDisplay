import CryptoKit
import Foundation
import Network

/// タブレット向けのページ（HTTP）と、映像・入力の通信（WebSocket）を同じポートで扱う。
/// 127.0.0.1 にだけ bind し、タブレットからは adb reverse 経由（USB）でつなぐ。
///
/// Network.framework の WebSocket は Firefox が送る "Connection: keep-alive, Upgrade" を
/// 受け付けないため、ハンドシェイクとフレームの読み書きは自前で行う。
///
/// 同時に扱うクライアントは1台。新しい接続が来たら古い接続をコード 4000 で閉じる
/// （ページ側は 4000 で閉じられたら自動再接続しないので、タブ同士で奪い合わない）。
final class WebServer {
    let port: UInt16
    private let queue: DispatchQueue
    private let pageURL: () -> URL?
    private var listener: NWListener?
    private(set) var client: NWConnection?

    // すべて queue 上で呼ばれる
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onText: ((String) -> Void)?

    init(port: UInt16, queue: DispatchQueue, pageURL: @escaping () -> URL?) {
        self.port = port
        self.queue = queue
        self.pageURL = pageURL
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.readRequest(conn, Data())
        }
        l.stateUpdateHandler = { state in Log.write("listener: \(state)") }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.client?.cancel()
            self.client = nil
        }
    }

    func sendBinary(_ data: Data) {
        client?.send(content: Self.frame(opcode: 0x2, data), completion: .contentProcessed { _ in })
    }

    func sendText(_ text: String) {
        client?.send(content: Self.frame(opcode: 0x1, Data(text.utf8)), completion: .contentProcessed { _ in })
    }

    // MARK: - HTTP

    private func readRequest(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if error != nil || isComplete || buf.count > 64 * 1024 {
                    conn.cancel()
                } else {
                    self.readRequest(conn, buf)
                }
                return
            }

            let lines = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let i = line.firstIndex(of: ":") else { continue }
                headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }

            if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
                self.upgrade(conn, key: key, rest: [UInt8](buf[end.upperBound...]))
            } else {
                self.serve(conn, path: path)
            }
        }
    }

    private func serve(_ conn: NWConnection, path: String) {
        var status = "404 Not Found", type = "text/plain", body = Data("not found".utf8)
        if path == "/" || path.hasPrefix("/?"), let url = pageURL(), let page = try? Data(contentsOf: url) {
            status = "200 OK"
            type = "text/html; charset=utf-8"
            body = page
        }
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - WebSocket

    private func upgrade(_ conn: NWConnection, key: String, rest: [UInt8]) {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\r\n"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in })

        if let old = client {
            client = nil
            Self.close(old, code: 4000)
            onDisconnect?()
        }
        client = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed, .cancelled:
                if self.client === conn {
                    Log.write("client disconnected")
                    self.client = nil
                    self.onDisconnect?()
                }
            default:
                break
            }
        }
        Log.write("client connected")
        onConnect?()
        readFrames(conn, rest, fragment: nil)
    }

    private struct Fragment {
        var opcode: UInt8
        var payload: [UInt8]
    }

    private func readFrames(_ conn: NWConnection, _ buffer: [UInt8], fragment: Fragment?) {
        var buf = buffer
        var fragment = fragment
        while let f = Self.parseFrame(buf) {
            buf.removeFirst(f.used)
            switch f.opcode {
            case 0x0, 0x1, 0x2:  // 継続・テキスト・バイナリ
                if f.opcode == 0x0 {
                    fragment?.payload += f.payload
                } else {
                    fragment = Fragment(opcode: f.opcode, payload: f.payload)
                }
                if f.fin, let msg = fragment {
                    fragment = nil
                    if msg.opcode == 0x1, conn === client {
                        onText?(String(decoding: msg.payload, as: UTF8.self))
                    }
                }
            case 0x8:  // close
                Self.close(conn, code: 1000)
                return
            case 0x9:  // ping
                conn.send(content: Self.frame(opcode: 0xA, Data(f.payload)), completion: .contentProcessed { _ in })
            default:
                break
            }
        }
        if buf.count > 16 * 1024 * 1024 {
            conn.cancel()
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { buf += data }
            if error != nil || (isComplete && data == nil) {
                conn.cancel()
                return
            }
            self.readFrames(conn, buf, fragment: fragment)
        }
    }

    private static func parseFrame(_ b: [UInt8]) -> (fin: Bool, opcode: UInt8, payload: [UInt8], used: Int)? {
        guard b.count >= 2 else { return nil }
        let fin = b[0] & 0x80 != 0
        let opcode = b[0] & 0x0F
        let masked = b[1] & 0x80 != 0
        var len = Int(b[1] & 0x7F)
        var off = 2
        if len == 126 {
            guard b.count >= 4 else { return nil }
            len = Int(b[2]) << 8 | Int(b[3])
            off = 4
        } else if len == 127 {
            guard b.count >= 10 else { return nil }
            len = b[2..<10].reduce(0) { $0 << 8 | Int($1) }
            off = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard b.count >= off + 4 else { return nil }
            mask = Array(b[off..<off + 4])
            off += 4
        }
        guard len >= 0, b.count >= off + len else { return nil }
        var payload = Array(b[off..<off + len])
        if masked {
            for i in payload.indices { payload[i] ^= mask[i & 3] }
        }
        return (fin, opcode, payload, off + len)
    }

    private static func frame(opcode: UInt8, _ payload: Data) -> Data {
        var d = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 {
            d.append(UInt8(n))
        } else if n < 65536 {
            d.append(contentsOf: [126, UInt8(n >> 8), UInt8(n & 0xFF)])
        } else {
            d.append(127)
            for i in (0..<8).reversed() { d.append(UInt8((n >> (i * 8)) & 0xFF)) }
        }
        d.append(payload)
        return d
    }

    private static func close(_ conn: NWConnection, code: UInt16) {
        let payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        conn.send(content: frame(opcode: 0x8, payload), completion: .contentProcessed { _ in conn.cancel() })
    }
}
