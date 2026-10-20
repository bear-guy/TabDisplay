import AppKit
import ApplicationServices
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let port: UInt16 = 7710

    private let core = DispatchQueue(label: "tabdisplay.core", qos: .userInteractive)
    private let screen = VirtualScreen()
    private lazy var streamer = ScreenStreamer(queue: core)
    private lazy var server = WebServer(port: Self.port, queue: core, pageURL: Self.pageURL)
    private lazy var adb = ADBBridge(ports: [Self.port], pageURL: "http://localhost:\(Self.port)/")
    private let input = InputInjector()

    private var statusItem: NSStatusItem!
    private var signalSources: [DispatchSourceSignal] = []

    // main スレッドでのみ触る
    private var capturing = false
    private var captureStarting = false
    private var captureRestartPending = false
    private var lastCaptureAttempt = Date.distantPast
    private var clientConnected = false
    private var reorienting = false
    private var pendingOrientation: Orientation?
    private var deviceSerials: [String] = []

    /// "auto" | "landscape" | "portrait"
    private var orientationSetting: String {
        get { UserDefaults.standard.string(forKey: "orientation") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "orientation") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("---- launch")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "TabDisplay")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }

        wireUp()
        do {
            try server.start()
        } catch {
            Log.write("server start failed: \(error)")
        }

        // 「タブレットに合わせる」のときは前回の向きで作る（縦のまま起動したときに作り直さずに済む）
        let initial = Orientation(rawValue: orientationSetting)
            ?? UserDefaults.standard.string(forKey: "lastOrientation").flatMap(Orientation.init)
            ?? .landscape
        screen.create(initial) { _ in
            guard self.screen.displayID != kCGNullDirectDisplay else {
                let alert = NSAlert()
                alert.messageText = tr("Could not create the virtual display",
                                       ja: "仮想ディスプレイを作成できませんでした",
                                       zh: "无法创建虚拟显示器",
                                       es: "No se pudo crear la pantalla virtual")
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
            self.displayCreated()
        }
        adb.start()

        // 画面収録の許可が後から付いた場合や、キャプチャが止まった場合に再開する
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.capturing, !self.captureStarting, !self.reorienting,
                  Date().timeIntervalSince(self.lastCaptureAttempt) > 10 else { return }
            self.startCapture()
        }

        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.write("---- quit")
        adb.teardown()
    }

    private func wireUp() {
        streamer.send = { [weak self] data in self?.server.sendBinary(data) }
        streamer.onStop = { [weak self] _ in self?.capturing = false }

        server.onConnect = { [weak self] in
            guard let self else { return }
            self.streamer.clientConnected()
            self.server.sendText(Self.languageMessage())
            DispatchQueue.main.async { self.clientConnected = true }
        }
        server.onDisconnect = { [weak self] in
            guard let self else { return }
            self.streamer.clientDisconnected()
            DispatchQueue.main.async { self.clientConnected = false }
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

        adb.isClientConnected = { [weak self] in
            guard let self else { return false }
            return self.core.sync { self.server.client != nil }
        }
        adb.onDevicesChanged = { [weak self] serials in
            DispatchQueue.main.async { self?.deviceSerials = serials }
        }
    }

    // MARK: - キャプチャ・向き

    private func startCapture() {
        guard CGPreflightScreenCaptureAccess() else { return }
        guard !captureStarting else {
            captureRestartPending = true
            return
        }
        captureStarting = true
        lastCaptureAttempt = Date()
        let id = screen.displayID
        let size = screen.pixelSize
        Task { @MainActor in
            do {
                try await self.streamer.start(displayID: id, width: size.width, height: size.height)
                self.capturing = true
            } catch {
                self.capturing = false
                Log.write("capture start failed: \(error.localizedDescription)")
            }
            self.captureStarting = false
            if self.captureRestartPending {
                self.captureRestartPending = false
                self.startCapture()
            }
        }
    }

    private func displayCreated() {
        let id = screen.displayID
        UserDefaults.standard.set(screen.orientation.rawValue, forKey: "lastOrientation")
        core.async { self.input.displayID = id }
        // モードの切り替えが落ち着いてからキャプチャを始める
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startCapture() }
    }

    /// 縦横を変えるときはディスプレイを作り直す（VirtualScreen 参照）。
    /// 作り直している最中に別の向きが来たら、終わってからその向きにする。
    private func reorient(_ o: Orientation) {
        guard !reorienting else {
            pendingOrientation = o
            return
        }
        guard o != screen.orientation else { return }
        reorienting = true
        Log.write("reorient: \(o.rawValue)")
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
        guard orientationSetting == "auto", o != screen.orientation else { return }
        Log.write("tablet orientation: \(o.rawValue)")
        reorient(o)
    }

    // MARK: - メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let screenOK = CGPreflightScreenCaptureAccess()
        let inputOK = AXIsProcessTrusted()

        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector, _ key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
            return item
        }

        func submenu(_ title: String, _ items: [(title: String, value: String, on: Bool)], _ selector: Selector) {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for entry in items {
                let item = NSMenuItem(title: entry.title, action: selector, keyEquivalent: "")
                item.target = self
                item.representedObject = entry.value
                item.state = entry.on ? .on : .off
                sub.addItem(item)
            }
            parent.submenu = sub
            menu.addItem(parent)
        }

        info(deviceSerials.isEmpty
             ? tr("Tablet: not connected", ja: "タブレット: 未接続", zh: "平板：未连接", es: "Tableta: no conectada")
             : tr("Tablet: connected", ja: "タブレット: 接続中", zh: "平板：已连接", es: "Tableta: conectada"))
        info(clientConnected
             ? tr("Display: streaming", ja: "表示: 送信中", zh: "显示：正在传输", es: "Pantalla: transmitiendo")
             : tr("Display: page not connected", ja: "表示: ページ未接続", zh: "显示：页面未连接", es: "Pantalla: página no conectada"))
        if !screenOK {
            info(tr("⚠️ Screen Recording is not allowed", ja: "⚠️ 画面収録が許可されていません",
                    zh: "⚠️ 未允许屏幕录制", es: "⚠️ La grabación de pantalla no está permitida"))
        } else if !capturing {
            info(tr("⚠️ Capture stopped", ja: "⚠️ キャプチャ停止中", zh: "⚠️ 捕获已停止", es: "⚠️ Captura detenida"))
        }
        if !inputOK {
            info(tr("⚠️ Accessibility is not allowed (needed for touch)",
                    ja: "⚠️ アクセシビリティが許可されていません（タッチ操作）",
                    zh: "⚠️ 未允许辅助功能（触控操作需要）",
                    es: "⚠️ La accesibilidad no está permitida (necesaria para el tacto)"))
        }
        menu.addItem(.separator())

        _ = action(tr("Open Page on Tablet", ja: "タブレットでページを開く", zh: "在平板上打开页面", es: "Abrir la página en la tableta"),
                   #selector(openOnTablet))
        submenu(tr("Orientation", ja: "向き", zh: "方向", es: "Orientación"), [
            (tr("Match Tablet", ja: "タブレットに合わせる", zh: "跟随平板", es: "Según la tableta"), "auto", orientationSetting == "auto"),
            (tr("Landscape", ja: "横", zh: "横向", es: "Horizontal"), "landscape", orientationSetting == "landscape"),
            (tr("Portrait", ja: "縦", zh: "纵向", es: "Vertical"), "portrait", orientationSetting == "portrait"),
        ], #selector(setOrientationSetting(_:)))
        submenu(tr("Language", ja: "言語", zh: "语言", es: "Idioma"),
                Language.allCases.map { ($0.nativeName, $0.rawValue, $0 == Language.current) },
                #selector(setLanguage(_:)))
        _ = action(tr("Open Display Settings…", ja: "ディスプレイ設定を開く…", zh: "打开显示器设置…", es: "Abrir ajustes de pantallas…"),
                   #selector(openDisplaySettings))
        if !screenOK {
            _ = action(tr("Open Screen Recording Settings…", ja: "画面収録の設定を開く…",
                          zh: "打开屏幕录制设置…", es: "Abrir ajustes de grabación de pantalla…"),
                       #selector(openScreenCaptureSettings))
        }
        if !inputOK {
            _ = action(tr("Open Accessibility Settings…", ja: "アクセシビリティの設定を開く…",
                          zh: "打开辅助功能设置…", es: "Abrir ajustes de accesibilidad…"),
                       #selector(openAccessibilitySettings))
        }
        _ = action(tr("Restart", ja: "再起動", zh: "重新启动", es: "Reiniciar"), #selector(relaunch))
        menu.addItem(.separator())
        _ = action(tr("Quit", ja: "終了", zh: "退出", es: "Salir"), #selector(quit), "q")
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let lang = Language(rawValue: value) else { return }
        Language.current = lang
        let message = Self.languageMessage()
        core.async { self.server.sendText(message) }
    }

    /// タブレットのページに表示言語を伝える
    private static func languageMessage() -> String {
        "{\"type\":\"lang\",\"lang\":\"\(Language.current.rawValue)\"}"
    }

    @objc private func openOnTablet() { adb.openBrowser() }

    @objc private func setOrientationSetting(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        orientationSetting = value
        switch value {
        case "landscape": reorient(.landscape)
        case "portrait": reorient(.portrait)
        default: break  // 次にタブレットから向きが届いたときに合わせる
        }
    }

    @objc private func openDisplaySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    @objc private func openScreenCaptureSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// 開発中は web/index.html を直接配信する（アプリを作り直さずにページを修正できる）
    private static func pageURL() -> URL? {
        let dev = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("web/index.html")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return Bundle.main.url(forResource: "index", withExtension: "html")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
