import Foundation

/// USB でつながった Android 端末を見張り、つながったら
/// - adb reverse でタブレットの localhost:ポート → Mac のポートに転送
/// - USB 接続中は画面が消えないようにする（終了時に元の設定へ戻す）
/// - しばらく待ってもページから接続が来なければ Firefox でページを開く
final class ADBBridge {
    let ports: [UInt16]
    let pageURL: String
    let adbPath: String?
    var isClientConnected: () -> Bool = { false }
    var onDevicesChanged: (([String]) -> Void)?

    private let queue = DispatchQueue(label: "tabdisplay.adb")
    private var timer: DispatchSourceTimer?
    /// serial → 接続前の stay_on_while_plugged_in の値
    private var devices: [String: String] = [:]
    /// 最初に読んだ値。USB から無線に切り替えると同じ端末が別の serial で現れるが、
    /// そのとき読むと自分で変えた値を「元の値」と取り違えるので、最初の値を使い回す
    private var originalStayOn: String?

    init(ports: [UInt16], pageURL: String) {
        self.ports = ports
        self.pageURL = pageURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        adbPath = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "\(home)/Library/Android/sdk/platform-tools/adb"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        guard adbPath != nil else {
            Log.write("adb not found")
            return
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 3)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func openBrowser() {
        queue.async {
            for serial in self.devices.keys { self.launchBrowser(serial) }
        }
    }

    /// 終了時に同期で呼ぶ
    func teardown() {
        timer?.cancel()
        queue.sync {
            for (serial, stayOn) in devices {
                for p in ports { adb("-s", serial, "reverse", "--remove", "tcp:\(p)") }
                adb("-s", serial, "shell", "settings", "put", "global", "stay_on_while_plugged_in", stayOn)
            }
            devices.removeAll()
        }
    }

    private func poll() {
        let serials = adb("devices").split(separator: "\n").compactMap { line -> String? in
            let cols = line.split(separator: "\t")
            return cols.count == 2 && cols[1] == "device" ? String(cols[0]) : nil
        }
        var changed = false
        for serial in serials where devices[serial] == nil {
            setUp(serial)
            changed = true
        }
        for serial in devices.keys where !serials.contains(serial) {
            Log.write("device removed: \(serial)")
            devices[serial] = nil
            changed = true
        }
        if changed { onDevicesChanged?(Array(devices.keys)) }
    }

    private func setUp(_ serial: String) {
        Log.write("device found: \(serial)")
        for p in ports { adb("-s", serial, "reverse", "tcp:\(p)", "tcp:\(p)") }

        if originalStayOn == nil {
            let value = adb("-s", serial, "shell", "settings", "get", "global", "stay_on_while_plugged_in")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            originalStayOn = Int(value) == nil ? "0" : value
        }
        adb("-s", serial, "shell", "svc", "power", "stayon", "usb")
        devices[serial] = originalStayOn

        // ページを開いたままなら自動で再接続してくるので、来なかったときだけ開く
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.devices[serial] != nil, !self.isClientConnected() else { return }
            self.launchBrowser(serial)
        }
    }

    private func launchBrowser(_ serial: String) {
        Log.write("open \(pageURL) on \(serial)")
        adb("-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", pageURL, "org.mozilla.firefox")
    }

    @discardableResult
    private func adb(_ args: String...) -> String {
        guard let adbPath else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            Log.write("adb failed: \(error)")
            return ""
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
