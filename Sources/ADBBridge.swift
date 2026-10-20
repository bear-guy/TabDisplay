import Foundation

/// adb で見えている Android 端末
struct TabletInfo {
    /// ro.serialno。USB と無線では adb の serial が変わるので、同じ端末かどうかはこれで見分ける
    let id: String
    let model: String
    /// 画面のピクセル数（端末の本来の向き）
    let width: Int
    let height: Int
    let density: Int
}

/// Android 端末を見張り、つながった端末ごとに「スロット」を割り当てる（最大 maxDevices 台）。
///
/// どの端末もページは http://localhost:7710 で開き、adb reverse で
/// スロット 0 の端末は Mac の 7710、スロット 1 の端末は 7711 … につなぐ。
/// こうすると、Mac 側は受けたポートでどの端末からの接続かが分かる。
///
/// 端末がつながったら、ほかに
/// - USB 接続中は画面が消えないようにする（終了時に元の設定へ戻す）
/// - 見えなくなってもしばらく待ってから外す（ケーブルの接触などで一瞬消えることがある）
final class ADBBridge {
    let maxDevices: Int
    let devicePort: UInt16
    let basePort: UInt16
    let removalGrace: TimeInterval = 10
    // すべて main スレッドで呼ばれる
    var onAdded: ((Int, TabletInfo) -> Void)?
    var onRemoved: ((Int) -> Void)?
    /// 台数の上限を超えてつながっている端末の数
    var onOverflow: ((Int) -> Void)?

    let adbPath: String?
    private let queue = DispatchQueue(label: "tabdisplay.adb")
    private var timer: DispatchSourceTimer?

    private struct Device {
        var info: TabletInfo
        var slot: Int
        var serial: String?  // adb の serial。テスト用の端末は nil
        var present: Bool
        var lastSeen: Date
        var lastReverse = Date.distantPast
    }

    // 以下は queue 上でのみ触る
    private var devices: [String: Device] = [:]  // id → 端末
    private var ids: [String: String] = [:]  // adb の serial → id
    /// id → 接続前の stay_on_while_plugged_in の値。
    /// USB から無線に切り替えると同じ端末が別の serial で現れるが、そのとき読むと自分で変えた値を
    /// 「元の値」と取り違えるので、端末ごとに最初の値を使い回す
    private var originalStayOn: [String: String] = [:]
    private var overflow = 0
    private var connected: Set<Int> = []  // ページがつながっているスロット

    init(maxDevices: Int, devicePort: UInt16, basePort: UInt16) {
        self.maxDevices = maxDevices
        self.devicePort = devicePort
        self.basePort = basePort
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

    /// 2台目がなくても試せるよう、adb を通さない仮の端末を足す（defaults の testTablet で使う）
    func addTestDevice(_ info: TabletInfo) {
        queue.async {
            guard let slot = self.freeSlot() else { return }
            self.devices[info.id] = Device(info: info, slot: slot, serial: nil, present: true, lastSeen: .distantFuture)
            DispatchQueue.main.async { self.onAdded?(slot, info) }
        }
    }

    /// ページがつながっているかを知らせる。つながっていない端末は adb reverse を定期的に張り直す
    /// （adb サーバーが再起動すると、端末は見えたままでも転送だけ消えていることがある）
    func setConnected(_ slot: Int, _ value: Bool) {
        queue.async {
            if value { self.connected.insert(slot) } else { self.connected.remove(slot) }
        }
    }

    /// slot が nil ならすべての端末で開く
    func openBrowser(slot: Int? = nil) {
        queue.async {
            for d in self.devices.values where slot == nil || d.slot == slot {
                if let serial = d.serial { self.launchBrowser(serial) }
            }
        }
    }

    /// 終了時に同期で呼ぶ
    func teardown() {
        timer?.cancel()
        queue.sync {
            for d in devices.values {
                guard let serial = d.serial else { continue }
                adb("-s", serial, "reverse", "--remove", "tcp:\(devicePort)")
                if let stayOn = originalStayOn[d.info.id] {
                    adb("-s", serial, "shell", "settings", "put", "global", "stay_on_while_plugged_in", stayOn)
                }
            }
            devices.removeAll()
        }
    }

    private func freeSlot() -> Int? {
        (0..<maxDevices).first { s in !devices.values.contains { $0.slot == s } }
    }

    private func poll() {
        let serials = adb("devices").split(separator: "\n").compactMap { line -> String? in
            let cols = line.split(separator: "\t")
            return cols.count == 2 && cols[1] == "device" ? String(cols[0]) : nil
        }
        let now = Date()
        var seen = Set<String>()
        var over = 0

        for serial in serials {
            let id: String
            if let cached = ids[serial] {
                id = cached
            } else {
                let value = prop(serial, "ro.serialno")
                id = value.isEmpty ? serial : value
                ids[serial] = id
            }
            guard !seen.contains(id) else { continue }  // USB と無線の両方で見えている
            seen.insert(id)

            if var d = devices[id] {
                // 一瞬消えて戻ってきた（再起動した等）か、USB ↔ 無線で serial が変わったら転送を張り直す
                let serialGone = d.serial.map { !serials.contains($0) } ?? false
                if !d.present || serialGone {
                    d.serial = serial
                    prepare(serial, id: id, slot: d.slot)
                    d.lastReverse = now
                } else if !connected.contains(d.slot), now.timeIntervalSince(d.lastReverse) > 6 {
                    reverse(serial, slot: d.slot)
                    d.lastReverse = now
                }
                d.present = true
                d.lastSeen = now
                devices[id] = d
            } else if let slot = freeSlot() {
                setUp(serial, id: id, slot: slot)
            } else {
                over += 1
            }
        }

        for (id, d) in devices where d.serial != nil && !seen.contains(id) {
            if d.present {
                Log.write("device lost: \(d.info.model) (\(id))")
                devices[id]?.present = false
            }
            if now.timeIntervalSince(d.lastSeen) > removalGrace {
                Log.write("device removed: \(d.info.model) (\(id)) slot \(d.slot)")
                devices[id] = nil
                DispatchQueue.main.async { self.onRemoved?(d.slot) }
            }
        }

        if over != overflow {
            overflow = over
            if over > 0 { Log.write("\(over) device(s) over the limit of \(maxDevices)") }
            DispatchQueue.main.async { self.onOverflow?(over) }
        }
    }

    private func setUp(_ serial: String, id: String, slot: Int) {
        let model = prop(serial, "ro.product.model")
        let size = parse(adb("-s", serial, "shell", "wm", "size"), #"(\d+)x(\d+)"#)
        let density = parse(adb("-s", serial, "shell", "wm", "density"), #"(\d+)"#)
        guard size.count == 2 else {
            Log.write("could not read screen size of \(serial)")
            return
        }
        let info = TabletInfo(id: id, model: model.isEmpty ? "Android" : model,
                              width: size[0], height: size[1], density: density.first ?? 160)
        Log.write("device found: \(info.model) (\(id)) \(info.width)x\(info.height) \(info.density)dpi -> slot \(slot)")

        devices[id] = Device(info: info, slot: slot, serial: serial, present: true, lastSeen: Date(), lastReverse: Date())
        prepare(serial, id: id, slot: slot)
        DispatchQueue.main.async { self.onAdded?(slot, info) }
    }

    /// adb reverse と画面点灯の設定。端末の再起動で消えるので、戻ってきたときにもやり直す
    private func prepare(_ serial: String, id: String, slot: Int) {
        reverse(serial, slot: slot)
        if originalStayOn[id] == nil {
            let value = adb("-s", serial, "shell", "settings", "get", "global", "stay_on_while_plugged_in")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            originalStayOn[id] = Int(value) == nil ? "0" : value
        }
        adb("-s", serial, "shell", "svc", "power", "stayon", "usb")
    }

    /// すでに張ってあっても上書きされるだけで、つながっている通信は切れない
    private func reverse(_ serial: String, slot: Int) {
        adb("-s", serial, "reverse", "tcp:\(devicePort)", "tcp:\(basePort + UInt16(slot))")
    }

    /// Firefox が入っていれば Firefox で、なければ端末の普段のブラウザで開く
    private func launchBrowser(_ serial: String) {
        let url = "http://localhost:\(devicePort)/"
        let firefox = "org.mozilla.firefox"
        let hasFirefox = adb("-s", serial, "shell", "pm", "path", firefox).hasPrefix("package:")
        Log.write("open \(url) on \(serial)" + (hasFirefox ? "" : " (default browser)"))
        if hasFirefox {
            adb("-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url, firefox)
        } else {
            adb("-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url)
        }
    }

    private func prop(_ serial: String, _ name: String) -> String {
        adb("-s", serial, "shell", "getprop", name).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `wm size` などの出力から数字を取り出す。上書き設定（Override）があればそちらを使う
    private func parse(_ output: String, _ pattern: String) -> [Int] {
        let lines = output.split(separator: "\n").map(String.init)
        guard let line = lines.first(where: { $0.hasPrefix("Override") }) ?? lines.first(where: { $0.hasPrefix("Physical") }),
              let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return [] }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: line).flatMap { Int(line[$0]) } }
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
