import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit

/// 仮想ディスプレイをキャプチャして JPEG にし、タブレットへ送る。
///
/// タブレットの CPU は非力なので、
/// - 変化した領域（dirty rect）だけを切り出して送る
/// - 送信中のフレームが maxInFlight 枚を超えたら新しいフレームは送らず、
///   タブレットから ack が来たら最新の状態をまとめて送る（古いフレームは捨てる）
///
/// 送るパケット: [frameW, frameH, x, y, w, h] (UInt16 LE) + JPEG
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue: DispatchQueue
    private var stream: SCStream?
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // 以下は queue 上でのみ触る
    private var latest: CVPixelBuffer?
    private var dirty = CGRect.null
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

    init(queue: DispatchQueue) {
        self.queue = queue
        let d = UserDefaults.standard
        quality = d.object(forKey: "jpegQuality") as? Double ?? 0.7
        fps = Int32(d.integer(forKey: "maxFPS") > 0 ? d.integer(forKey: "maxFPS") : 30)
        fullFramesOnly = d.bool(forKey: "fullFramesOnly")
        super.init()
        Log.write("streamer: quality=\(quality) fps=\(fps) fullFramesOnly=\(fullFramesOnly)")
    }

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
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 5

        // 最初のフレームより前にリセットしておく（後だと最初の全画面フレームを捨ててしまう）
        queue.sync {
            latest = nil
            dirty = .null
            needFull = true
        }
        let s = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        Log.write("capture started: \(width)x\(height)")
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
        if fullFramesOnly {
            needFull = true
        } else if let rects = info[.dirtyRects] as? [NSDictionary] {
            for d in rects {
                if let r = CGRect(dictionaryRepresentation: d as CFDictionary) { dirty = dirty.union(r) }
            }
        } else {
            needFull = true
        }
        pump()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("capture stopped: \(error.localizedDescription)")
        DispatchQueue.main.async {
            // ディスプレイを作り直したときの古いストリームなら無視する
            guard stream === self.stream else { return }
            self.stream = nil
            self.onStop?(error)
        }
    }

    // MARK: - 送信

    private func pump() {
        guard active, inFlight < maxInFlight, let pb = latest, let send else { return }
        let fw = CVPixelBufferGetWidth(pb), fh = CVPixelBufferGetHeight(pb)
        let full = CGRect(x: 0, y: 0, width: fw, height: fh)

        var r = full
        if !needFull {
            guard !dirty.isNull, !dirty.isEmpty else { return }
            // 想定外の座標系で来たら、ずれた絵を出すより全体を送る
            if !full.contains(dirty) {
                Log.write("dirty rect \(dirty) outside frame \(full); sending full frame")
                dirty = full
            }
            // JPEG のブロック境界（16px）に揃えると継ぎ目が目立ちにくい
            let x0 = floor(dirty.minX / 16) * 16, y0 = floor(dirty.minY / 16) * 16
            let x1 = ceil(dirty.maxX / 16) * 16, y1 = ceil(dirty.maxY / 16) * 16
            r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(full)
            if r.isEmpty { return }
            if r.width * r.height > 0.6 * full.width * full.height { r = full }
        }

        // CoreImage は左下原点
        let crop = CGRect(x: r.minX, y: full.height - r.maxY, width: r.width, height: r.height)
        let image = CIImage(cvPixelBuffer: pb).cropped(to: crop)
        let opts = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        guard let jpeg = ci.jpegRepresentation(of: image, colorSpace: sRGB, options: opts) else { return }

        var packet = Data(capacity: 12 + jpeg.count)
        for v in [fw, fh, Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)] {
            var le = UInt16(v).littleEndian
            withUnsafeBytes(of: &le) { packet.append(contentsOf: $0) }
        }
        packet.append(jpeg)

        needFull = false
        dirty = .null
        inFlight += 1
        send(packet)

        stats.frames += 1
        stats.bytes += packet.count
        if r == full { stats.full += 1 }
        let elapsed = Date().timeIntervalSince(stats.since)
        if elapsed >= 10 {
            Log.write(String(format: "sent %.1f fps (%d full), %.0f KB/s, avg %.0f KB",
                             Double(stats.frames) / elapsed, stats.full,
                             Double(stats.bytes) / elapsed / 1024, Double(stats.bytes) / Double(stats.frames) / 1024))
            stats = (0, 0, 0, Date())
        }
    }
}
