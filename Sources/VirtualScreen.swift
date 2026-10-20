import CoreGraphics
import Foundation

enum Orientation: String {
    case landscape, portrait
}

/// タブレットに合わせた仮想ディスプレイの仕様
struct DisplaySpec {
    let name: String
    /// macOS はディスプレイの配置を vendor / product / serial の組で記憶するので、端末ごとに固定の値にする
    let serial: UInt32
    /// タブレットの画面のピクセル数（送る画像の大きさ）
    let panel: (long: Int, short: Int)
    /// Mac 上での大きさ（ポイント）
    let logical: (long: Int, short: Int)
    let millimeters: (long: Double, short: Double)

    /// 高密度の画面は Retina（2倍）で描いて、タブレットの解像度に縮小して送る
    var hiDPI: Bool { logical.long != panel.long }

    init(info: TabletInfo) {
        name = "\(info.model) (TabDisplay)"
        serial = Self.hash(info.id) & ~1  // 最下位ビットは向き用

        let long = max(info.width, info.height), short = min(info.width, info.height)
        let density = info.density > 0 ? Double(info.density) : 160
        panel = (long, short)
        // Android の dp と同じ大きさにする（160dpi の端末ならピクセル数そのまま）
        logical = density > 160
            ? (Int((Double(long) * 160 / density).rounded()), Int((Double(short) * 160 / density).rounded()))
            : panel
        // macOS はこの大きさから既定のモードを決め、ほかのディスプレイの抜き差しのたびにそのモードへ戻す。
        // 1x のディスプレイを実寸（160dpi 前後）で申告すると「文字を大きく」した 800x500 などが既定になるので、
        // 1x のときは macOS の標準的な密度（100dpi）として申告し、そのままの解像度が既定になるようにする
        let mmPerPixel = 25.4 / (logical.long == panel.long ? 100 : density)
        millimeters = (Double(long) * mmPerPixel, Double(short) * mmPerPixel)
    }

    private static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261  // FNV-1a
        for b in s.utf8 {
            h ^= UInt32(b)
            h = h &* 16_777_619
        }
        return h
    }
}

/// CGVirtualDisplay で作る仮想モニター。解放するかプロセスが終了すると消える。
///
/// macOS は最初に登録したモードと同じ向きのモードしか使わせてくれないため、
/// 縦横を切り替えるときはディスプレイごと作り直す。
final class VirtualScreen {
    let spec: DisplaySpec
    private var display: CGVirtualDisplay?
    private(set) var orientation: Orientation = .landscape

    init(spec: DisplaySpec) {
        self.spec = spec
    }

    var displayID: CGDirectDisplayID { display?.displayID ?? kCGNullDirectDisplay }

    /// タブレットに送る画像の大きさ
    var panelSize: (width: Int, height: Int) { oriented(spec.panel) }

    /// Mac 上での大きさ（ポイント）
    var logicalSize: (width: Int, height: Int) { oriented(spec.logical) }

    private func oriented(_ size: (long: Int, short: Int)) -> (width: Int, height: Int) {
        orientation == .landscape ? (size.long, size.short) : (size.short, size.long)
    }

    func create(_ o: Orientation, completion: @escaping (Bool) -> Void) {
        display = nil  // 解放すると古いディスプレイが消える
        orientation = o

        let (w, h) = logicalSize
        let scale = spec.hiDPI ? 2 : 1
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = .main
        desc.name = spec.name
        desc.maxPixelsWide = UInt32(w * scale)
        desc.maxPixelsHigh = UInt32(h * scale)
        desc.sizeInMillimeters = o == .landscape
            ? CGSize(width: spec.millimeters.long, height: spec.millimeters.short)
            : CGSize(width: spec.millimeters.short, height: spec.millimeters.long)
        desc.vendorID = 0x3A4B
        desc.productID = 0x7D01
        desc.serialNum = spec.serial | (o == .portrait ? 1 : 0)  // 配置を向きごとに覚えさせる
        desc.terminationHandler = { _, _ in Log.write("virtual display terminated") }

        // hiDPI = 1 にすると、macOS が「w x h @ 2w x 2h」のモードを作ってくれる
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = spec.hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h), refreshRate: 60)]
        guard let d = CGVirtualDisplay(descriptor: desc), d.apply(settings) else {
            completion(false)
            return
        }
        display = d
        Log.write("virtual display created: id=\(d.displayID) \"\(spec.name)\" \(w)x\(h)\(spec.hiDPI ? "@2x" : "")")
        selectNativeMode(attempts: 15, completion: completion)
    }

    func destroy() {
        display = nil
    }

    /// macOS は作成直後に縮小したモード（800x500 など）を選ぶことがあるので、意図したモードを選び直す。
    /// 作成直後はモード一覧がまだ揃っていないことがあるため、数回リトライする。
    private func selectNativeMode(attempts: Int, completion: @escaping (Bool) -> Void) {
        guard display != nil else { completion(false); return }
        let (w, h) = logicalSize
        let pw = spec.hiDPI ? w * 2 : w
        if let cur = CGDisplayCopyDisplayMode(displayID), cur.width == w, cur.height == h, cur.pixelWidth == pw {
            completion(true)
            return
        }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode]) ?? []
        guard let mode = modes.first(where: { $0.width == w && $0.height == h && $0.pixelWidth == pw }) else {
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.selectNativeMode(attempts: attempts - 1, completion: completion)
                }
            } else {
                Log.write("display mode \(w)x\(h) (\(pw)px) not found")
                completion(false)
            }
            return
        }

        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { completion(false); return }
        CGConfigureDisplayWithDisplayMode(cfg, displayID, mode, nil)
        let ok = CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        Log.write("set display mode \(w)x\(h) (\(pw)px): \(ok)")
        completion(ok)
    }
}
