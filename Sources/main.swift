import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Mac 本体の画面と合わせて最大3画面
    static let maxTablets = 2
    /// タブレット側で開くポート。Mac 側はスロットごとに basePort, basePort+1, …
    static let devicePort: UInt16 = 7710
    static let basePort: UInt16 = 7710

    private let adb = ADBBridge(maxDevices: AppDelegate.maxTablets, devicePort: AppDelegate.devicePort,
                                basePort: AppDelegate.basePort)
    private var statusItem: NSStatusItem!
    private var signalSources: [DispatchSourceSignal] = []

    // main スレッドでのみ触る
    private var sessions: [Int: TabletSession] = [:]  // スロット → セッション
    private var overflow = 0

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

        adb.onAdded = { [weak self] slot, info in self?.addSession(slot, info) }
        adb.onRemoved = { [weak self] slot in self?.removeSession(slot) }
        adb.onOverflow = { [weak self] count in self?.overflow = count }
        adb.start()

        // 2台目がなくても試せるように、仮のタブレットを足せる（ページは Mac のブラウザで http://localhost:7711 を開く）
        //   defaults write local.soma.tabdisplay testTablet "1920x1200@240"
        if let spec = UserDefaults.standard.string(forKey: "testTablet") {
            let n = spec.split(whereSeparator: { "x@".contains($0) }).compactMap { Int($0) }
            if n.count == 3 {
                adb.addTestDevice(TabletInfo(id: "test-\(spec)", model: "Test", width: n[0], height: n[1], density: n[2]))
            }
        }

        // 画面収録の許可が後から付いた場合や、キャプチャが止まった場合に再開する
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sessions.values.forEach { $0.tick() }
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

    // MARK: - タブレット

    private func addSession(_ slot: Int, _ info: TabletInfo) {
        sessions[slot]?.stop()
        let session = TabletSession(slot: slot, info: info, port: Self.basePort + UInt16(slot), pageURL: Self.pageURL,
                                    orientationSetting: { [weak self] in self?.orientationSetting ?? "auto" })
        sessions[slot] = session
        session.onConnectionChanged = { [weak self] connected in self?.adb.setConnected(slot, connected) }
        session.start()

        // ページを開いたままなら自動で再接続してくるので、来なかったときだけブラウザで開く
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak session] in
            guard let self, let session, self.sessions[slot] === session, !session.isClientConnected else { return }
            self.adb.openBrowser(slot: slot)
        }
    }

    private func removeSession(_ slot: Int) {
        adb.setConnected(slot, false)
        sessions[slot]?.stop()
        sessions[slot] = nil
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
        func action(_ title: String, _ selector: Selector, _ key: String = "") {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
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

        if sessions.isEmpty {
            info(tr("No tablet connected", ja: "タブレット未接続", zh: "未连接平板", es: "Ninguna tableta conectada"))
        }
        for session in sessions.keys.sorted().compactMap({ sessions[$0] }) {
            let state: String
            if screenOK && !session.capturing {
                state = tr("capture stopped", ja: "キャプチャ停止中", zh: "捕获已停止", es: "captura detenida")
            } else if session.clientConnected {
                state = tr("streaming", ja: "送信中", zh: "正在传输", es: "transmitiendo")
            } else {
                state = tr("page not connected", ja: "ページ未接続", zh: "页面未连接", es: "página no conectada")
            }
            info("\(session.info.model) — \(session.sizeDescription) — \(state)")
        }
        if overflow > 0 {
            info(tr("⚠️ Up to \(Self.maxTablets) tablets can be used", ja: "⚠️ 使えるタブレットは\(Self.maxTablets)台までです",
                    zh: "⚠️ 最多可使用 \(Self.maxTablets) 台平板", es: "⚠️ Se pueden usar hasta \(Self.maxTablets) tabletas"))
        }
        if !screenOK {
            info(tr("⚠️ Screen Recording is not allowed", ja: "⚠️ 画面収録が許可されていません",
                    zh: "⚠️ 未允许屏幕录制", es: "⚠️ La grabación de pantalla no está permitida"))
        }
        if !inputOK {
            info(tr("⚠️ Accessibility is not allowed (needed for touch)",
                    ja: "⚠️ アクセシビリティが許可されていません（タッチ操作）",
                    zh: "⚠️ 未允许辅助功能（触控操作需要）",
                    es: "⚠️ La accesibilidad no está permitida (necesaria para el tacto)"))
        }
        menu.addItem(.separator())

        action(tr("Open Page on Tablets", ja: "タブレットでページを開く", zh: "在平板上打开页面", es: "Abrir la página en las tabletas"),
               #selector(openOnTablets))
        submenu(tr("Orientation", ja: "向き", zh: "方向", es: "Orientación"), [
            (tr("Match Tablet", ja: "タブレットに合わせる", zh: "跟随平板", es: "Según la tableta"), "auto", orientationSetting == "auto"),
            (tr("Landscape", ja: "横", zh: "横向", es: "Horizontal"), "landscape", orientationSetting == "landscape"),
            (tr("Portrait", ja: "縦", zh: "纵向", es: "Vertical"), "portrait", orientationSetting == "portrait"),
        ], #selector(setOrientationSetting(_:)))
        submenu(tr("Language", ja: "言語", zh: "语言", es: "Idioma"),
                Language.allCases.map { ($0.nativeName, $0.rawValue, $0 == Language.current) },
                #selector(setLanguage(_:)))
        action(tr("Open Display Settings…", ja: "ディスプレイ設定を開く…", zh: "打开显示器设置…", es: "Abrir ajustes de pantallas…"),
               #selector(openDisplaySettings))
        if !screenOK {
            action(tr("Open Screen Recording Settings…", ja: "画面収録の設定を開く…",
                      zh: "打开屏幕录制设置…", es: "Abrir ajustes de grabación de pantalla…"),
                   #selector(openScreenCaptureSettings))
        }
        if !inputOK {
            action(tr("Open Accessibility Settings…", ja: "アクセシビリティの設定を開く…",
                      zh: "打开辅助功能设置…", es: "Abrir ajustes de accesibilidad…"),
                   #selector(openAccessibilitySettings))
        }
        action(tr("Restart", ja: "再起動", zh: "重新启动", es: "Reiniciar"), #selector(relaunch))
        menu.addItem(.separator())
        action(tr("Quit", ja: "終了", zh: "退出", es: "Salir"), #selector(quit), "q")
    }

    @objc private func openOnTablets() { adb.openBrowser() }

    @objc private func setOrientationSetting(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        orientationSetting = value
        sessions.values.forEach { $0.applyOrientationSetting() }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let lang = Language(rawValue: value) else { return }
        Language.current = lang
        sessions.values.forEach { $0.sendLanguage() }
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
