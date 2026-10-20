import CoreGraphics
import Foundation

enum Orientation: String {
    case landscape, portrait
}

/// CGVirtualDisplay で作る仮想モニター。プロセスが終了すると消える。
///
/// macOS は最初に登録したモードと同じ向きのモードしか使わせてくれないため、
/// 縦横を切り替えるときはディスプレイごと作り直す。
final class VirtualScreen {
    // SZJ-JS201 のパネル（10.1インチ 1280x800）に合わせる
    static let longSide = 1280
    static let shortSide = 800

    private var display: CGVirtualDisplay?
    private(set) var orientation: Orientation = .landscape

    var displayID: CGDirectDisplayID { display?.displayID ?? kCGNullDirectDisplay }

    var pixelSize: (width: Int, height: Int) { Self.size(orientation) }

    private static func size(_ o: Orientation) -> (width: Int, height: Int) {
        o == .landscape ? (longSide, shortSide) : (shortSide, longSide)
    }

    func create(_ o: Orientation, completion: @escaping (Bool) -> Void) {
        display = nil  // 解放すると古いディスプレイが消える

        let (w, h) = Self.size(o)
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = .main
        desc.name = "SZJ-JS201"
        desc.maxPixelsWide = UInt32(w)
        desc.maxPixelsHigh = UInt32(h)
        desc.sizeInMillimeters = o == .landscape ? CGSize(width: 217, height: 136) : CGSize(width: 136, height: 217)
        // 配置（左右どちらに置くか）は macOS がこの3つの組み合わせで記憶する。向きごとに覚えさせる
        desc.vendorID = 0x3A4B
        desc.productID = 0x0201
        desc.serialNum = o == .landscape ? 0x5A4A_0201 : 0x5A4A_0202
        desc.terminationHandler = { _, _ in Log.write("virtual display terminated") }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h), refreshRate: 60)]
        guard let d = CGVirtualDisplay(descriptor: desc), d.apply(settings) else {
            completion(false)
            return
        }
        display = d
        orientation = o
        Log.write("virtual display created: id=\(d.displayID) \(w)x\(h)")
        selectNativeMode(attempts: 15, completion: completion)
    }

    /// macOS は作成直後に縮小したモード（800x500 など）を選ぶことがあるので、1x のモードを選び直す。
    /// 作成直後はモード一覧がまだ揃っていないことがあるため、数回リトライする。
    private func selectNativeMode(attempts: Int, completion: @escaping (Bool) -> Void) {
        let (w, h) = pixelSize
        if let cur = CGDisplayCopyDisplayMode(displayID), cur.width == w, cur.height == h, cur.pixelWidth == w {
            completion(true)
            return
        }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode]) ?? []
        guard let mode = modes.first(where: { $0.width == w && $0.height == h && $0.pixelWidth == w }) else {
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.selectNativeMode(attempts: attempts - 1, completion: completion)
                }
            } else {
                Log.write("display mode \(w)x\(h) not found")
                completion(false)
            }
            return
        }

        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { completion(false); return }
        CGConfigureDisplayWithDisplayMode(cfg, displayID, mode, nil)
        let ok = CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        Log.write("set display mode \(w)x\(h): \(ok)")
        completion(ok)
    }
}
