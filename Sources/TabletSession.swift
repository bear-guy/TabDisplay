import AppKit
import CoreGraphics

/// タブレット1台ぶんの仮想ディスプレイ・キャプチャ・通信・入力をまとめたもの。
/// 公開しているメソッドとプロパティは main スレッドから使う。
final class TabletSession {
    let slot: Int
    let info: TabletInfo
    let port: UInt16

    private let core: DispatchQueue
    private let screen: VirtualScreen
    private let streamer: ScreenStreamer
    private let server: WebServer
    private let input = InputInjector()
    private let orientationSetting: () -> String
    /// ページがつながった・切れたとき（main スレッド）
    var onConnectionChanged: ((Bool) -> Void)?

    private(set) var capturing = false
    private(set) var clientConnected = false
    private var captureStarting = false
    private var captureRestartPending = false
    private var lastCaptureAttempt = Date.distantPast
    private var reorienting = false
    private var pendingOrientation: Orientation?
    private var stopped = false

    init(slot: Int, info: TabletInfo, port: UInt16, pageURL: @escaping () -> URL?,
         orientationSetting: @escaping () -> String) {
        self.slot = slot
        self.info = info
        self.port = port
        self.orientationSetting = orientationSetting
        core = DispatchQueue(label: "tabdisplay.session\(slot)", qos: .userInteractive)
        screen = VirtualScreen(spec: DisplaySpec(info: info))
        streamer = ScreenStreamer(name: info.model, queue: core)
        server = WebServer(port: port, queue: core, pageURL: pageURL)
    }

    /// メニューに出す大きさ（Mac 上のポイント）
    var sizeDescription: String {
        let s = screen.logicalSize
        return "\(s.width)×\(s.height)"
    }

    /// 別スレッドからも呼べる
    var isClientConnected: Bool {
        core.sync { server.client != nil }
    }

    private var lastOrientationKey: String { "lastOrientation.\(info.id)" }

    func start() {
        wireUp()
        do {
            try server.start()
        } catch {
            Log.write("[\(info.model)] server start failed on port \(port): \(error)")
        }
        // 「タブレットに合わせる」のときは前回の向きで作る（縦のまま起動したときに作り直さずに済む）
        let initial = Orientation(rawValue: orientationSetting())
            ?? UserDefaults.standard.string(forKey: lastOrientationKey).flatMap(Orientation.init)
            ?? .landscape
        screen.create(initial) { [weak self] _ in self?.displayCreated() }
    }

    func stop() {
        stopped = true
        server.stop()
        Task { @MainActor in
            await self.streamer.stop()
            self.screen.destroy()
        }
    }

    /// キャプチャが止まっていたら再開する（画面収録の許可が後から付いた場合など）。定期的に呼ぶ
    func tick() {
        guard !stopped, !capturing, !captureStarting, !reorienting,
              screen.displayID != kCGNullDirectDisplay,
              Date().timeIntervalSince(lastCaptureAttempt) > 10 else { return }
        startCapture()
    }

    func applyOrientationSetting() {
        if let o = Orientation(rawValue: orientationSetting()) { reorient(o) }
        // 「タブレットに合わせる」なら、次にタブレットから向きが届いたときに合わせる
    }

    func sendLanguage() {
        let message = Language.pageMessage
        core.async { self.server.sendText(message) }
    }

    private func wireUp() {
        streamer.send = { [weak self] data in self?.server.sendBinary(data) }
        streamer.onStop = { [weak self] _ in self?.capturing = false }

        // 以下は core 上で呼ばれる
        server.onConnect = { [weak self] in
            guard let self else { return }
            self.streamer.clientConnected()
            self.server.sendText(Language.pageMessage)
            DispatchQueue.main.async {
                self.clientConnected = true
                self.onConnectionChanged?(true)
            }
        }
        server.onDisconnect = { [weak self] in
            guard let self else { return }
            self.streamer.clientDisconnected()
            DispatchQueue.main.async {
                self.clientConnected = false
                self.onConnectionChanged?(false)
            }
        }
        server.onText = { [weak self] text in
            guard let self else { return }
            if text == "a" {
                self.streamer.ack()
                return
            }
            guard let data = text.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            if msg["type"] as? String == "hello" {
                let landscape = msg["landscape"] as? Bool ?? true
                DispatchQueue.main.async { self.clientOrientation(landscape ? .landscape : .portrait) }
            } else {
                self.input.handle(msg)
            }
        }
    }

    private func displayCreated() {
        guard !stopped else { return }
        let id = screen.displayID
        core.async { self.input.displayID = id }
        UserDefaults.standard.set(screen.orientation.rawValue, forKey: lastOrientationKey)
        // モードの切り替えが落ち着いてからキャプチャを始める（その間に tick() が先に始めないようにしておく）
        lastCaptureAttempt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startCapture() }
    }

    private func startCapture() {
        guard !stopped, CGPreflightScreenCaptureAccess() else { return }
        guard !captureStarting else {
            captureRestartPending = true
            return
        }
        captureStarting = true
        lastCaptureAttempt = Date()
        let id = screen.displayID
        let size = screen.panelSize
        Task { @MainActor in
            do {
                try await self.streamer.start(displayID: id, width: size.width, height: size.height)
                self.capturing = true
            } catch {
                self.capturing = false
                Log.write("[\(self.info.model)] capture start failed: \(error.localizedDescription)")
            }
            self.captureStarting = false
            if self.captureRestartPending {
                self.captureRestartPending = false
                self.startCapture()
            }
        }
    }

    /// 縦横を変えるときはディスプレイを作り直す（VirtualScreen 参照）。
    /// 作り直している最中に別の向きが来たら、終わってからその向きにする。
    private func reorient(_ o: Orientation) {
        guard !stopped else { return }
        guard !reorienting else {
            pendingOrientation = o
            return
        }
        guard o != screen.orientation else { return }
        reorienting = true
        Log.write("[\(info.model)] reorient: \(o.rawValue)")
        Task { @MainActor in
            await self.streamer.stop()
            self.capturing = false
            self.screen.create(o) { _ in
                self.reorienting = false
                if self.screen.displayID != kCGNullDirectDisplay { self.displayCreated() }
                if let next = self.pendingOrientation {
                    self.pendingOrientation = nil
                    self.reorient(next)
                }
            }
        }
    }

    private func clientOrientation(_ o: Orientation) {
        guard orientationSetting() == "auto", o != screen.orientation else { return }
        Log.write("[\(info.model)] tablet orientation: \(o.rawValue)")
        reorient(o)
    }
}
