import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit

/// 仮想ディスプレイをキャプチャして JPEG にし、タブレットへ送る。
///
/// タブレットの CPU は非力なので、
/// - 前回送った画像と比べて、変化した範囲だけを切り出して送る
///   （ScreenCaptureKit の dirty rect は Retina や縮小時の座標系が曖昧なので使わず、画素を直接比べる）
/// - 送信中のフレームが maxInFlight 枚を超えたら新しいフレームは送らず、
///   タブレットから ack が来たら最新の状態をまとめて送る（古いフレームは捨てる）
///
/// 送るパケット: [frameW, frameH, x, y, w, h] (UInt16 LE) + JPEG
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let name: String
    private let queue: DispatchQueue
    private var stream: SCStream?
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // 以下は queue 上でのみ触る
    private var latest: CVPixelBuffer?
    private var fresh = false  // latest をまだ送っていない
    private var reference: [UInt8] = []  // タブレットに表示されている画像（BGRA、行の詰め物なし）
    private var needFull = true
    private var inFlight = 0
    private var active = false
    private var stats = (frames: 0, full: 0, bytes: 0, since: Date())

    // 再ビルドせずに調整できるよう defaults から読む（反映にはアプリの再起動が必要）
    //   defaults write local.soma.tabdisplay jpegQuality -float 0.6
    //   defaults write local.soma.tabdisplay maxFPS -int 20
    //   defaults write local.soma.tabdisplay fullFramesOnly -bool true
    private let quality: Double
    private let fps: Int32
    private let fullFramesOnly: Bool
    private let maxInFlight = 2
    var send: ((Data) -> Void)?
    /// main スレッドで呼ばれる
    var onStop: ((Error) -> Void)?

    init(name: String, queue: DispatchQueue) {
        self.name = name
        self.queue = queue
        let d = UserDefaults.standard
        quality = d.object(forKey: "jpegQuality") as? Double ?? 0.7
        fps = Int32(d.integer(forKey: "maxFPS") > 0 ? d.integer(forKey: "maxFPS") : 30)
        fullFramesOnly = d.bool(forKey: "fullFramesOnly")
        super.init()
    }

    /// width / height は送る画像の大きさ。ディスプレイが Retina なら、その画素から縮小される
    @MainActor
    func start(displayID: CGDirectDisplayID, width: Int, height: Int) async throws {
        await stop()

        // 作成直後の仮想ディスプレイは一覧に出てくるまで少し時間がかかる
        var target: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let target else {
            throw NSError(domain: "TabDisplay", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "display \(displayID) not found in SCShareableContent"])
        }

        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.captureResolution = .best
        cfg.scalesToFit = true
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 5

        // 最初のフレームより前にリセットしておく（後だと最初の全画面フレームを捨ててしまう）
        queue.sync {
            latest = nil
            fresh = false
            needFull = true
        }
        let s = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        Log.write("[\(name)] capture started: \(width)x\(height) quality=\(quality) fps=\(fps)")
    }

    @MainActor
    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    // MARK: - クライアントの状態（queue 上で呼ぶ）

    func clientConnected() {
        active = true
        inFlight = 0
        needFull = true
        pump()
    }

    func clientDisconnected() {
        active = false
    }

    func ack() {
        inFlight = max(0, inFlight - 1)
        pump()
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = atts.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer
        else { return }

        latest = pb
        fresh = true
        pump()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("[\(name)] capture stopped: \(error.localizedDescription)")
        DispatchQueue.main.async {
            // ディスプレイを作り直したときの古いストリームなら無視する
            guard stream === self.stream else { return }
            self.stream = nil
            self.onStop?(error)
        }
    }

    // MARK: - 送信

    private func pump() {
        guard active, inFlight < maxInFlight, fresh || needFull, let pb = latest, let send else { return }
        fresh = false

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let fw = CVPixelBufferGetWidth(pb), fh = CVPixelBufferGetHeight(pb)
        let full = CGRect(x: 0, y: 0, width: fw, height: fh)

        if reference.count != fw * fh * 4 {
            reference = [UInt8](repeating: 0, count: fw * fh * 4)
            needFull = true
        }
        var r = full
        if !needFull && !fullFramesOnly {
            guard let changed = changedRect(base, bpr, fw, fh) else { return }
            r = changed.width * changed.height > 0.6 * full.width * full.height ? full : changed
        }

        // CoreImage は左下原点
        let crop = CGRect(x: r.minX, y: full.height - r.maxY, width: r.width, height: r.height)
        let image = CIImage(cvPixelBuffer: pb).cropped(to: crop)
        let opts = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        guard let jpeg = ci.jpegRepresentation(of: image, colorSpace: sRGB, options: opts) else { return }

        // 送った範囲を、タブレットに表示されている画像として覚えておく
        let rowBytes = fw * 4
        reference.withUnsafeMutableBytes { ref in
            for y in Int(r.minY)..<Int(r.maxY) {
                memcpy(ref.baseAddress! + y * rowBytes + Int(r.minX) * 4, base + y * bpr + Int(r.minX) * 4, Int(r.width) * 4)
            }
        }

        var packet = Data(capacity: 12 + jpeg.count)
        for v in [fw, fh, Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)] {
            var le = UInt16(v).littleEndian
            withUnsafeBytes(of: &le) { packet.append(contentsOf: $0) }
        }
        packet.append(jpeg)

        needFull = false
        inFlight += 1
        send(packet)

        stats.frames += 1
        stats.bytes += packet.count
        if r == full { stats.full += 1 }
        let elapsed = Date().timeIntervalSince(stats.since)
        if elapsed >= 10 {
            Log.write(String(format: "[%@] sent %.1f fps (%d full), %.0f KB/s, avg %.0f KB", name,
                             Double(stats.frames) / elapsed, stats.full,
                             Double(stats.bytes) / elapsed / 1024, Double(stats.bytes) / Double(stats.frames) / 1024))
            stats = (0, 0, 0, Date())
        }
    }

    /// reference と比べて変化した範囲を返す（16px 単位）。変化がなければ nil
    private func changedRect(_ base: UnsafeRawPointer, _ bpr: Int, _ w: Int, _ h: Int) -> CGRect? {
        let rowBytes = w * 4
        let chunk = 16 * 4
        var minX = w, maxX = 0, minY = -1, maxY = -1
        reference.withUnsafeBytes { ref in
            let refBase = ref.baseAddress!
            for y in 0..<h {
                let a = base + y * bpr, b = refBase + y * rowBytes
                if memcmp(a, b, rowBytes) == 0 { continue }
                if minY < 0 { minY = y }
                maxY = y
                // 行の中で、左右から変化していない 16px のかたまりを読み飛ばす
                var x0 = 0
                while x0 < rowBytes, memcmp(a + x0, b + x0, min(chunk, rowBytes - x0)) == 0 { x0 += chunk }
                var x1 = rowBytes
                while x1 > x0 {
                    let s = (x1 - 1) / chunk * chunk
                    if memcmp(a + s, b + s, x1 - s) != 0 { break }
                    x1 = s
                }
                minX = min(minX, x0 / 4)
                maxX = max(maxX, x1 / 4)
            }
        }
        guard minY >= 0 else { return nil }
        let x0 = minX / 16 * 16, y0 = minY / 16 * 16
        let x1 = min((maxX + 15) / 16 * 16, w), y1 = min((maxY + 16) / 16 * 16, h)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
