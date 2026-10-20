import CoreGraphics
import Foundation

/// タブレットから来た操作を Mac のマウス・スクロールイベントとして注入する。
/// ジェスチャーの判定（タップ／長押し／2本指など）はタブレット側の JS で行い、
/// ここには「どこで何をするか」だけが届く。
///
/// メッセージ（座標 x, y は仮想ディスプレイ内の 0〜1）:
///   {type: "move" | "down" | "drag" | "up", x, y, b: 0=左 1=右, c: クリック回数}
///   {type: "scroll", phase, dx, dy, x?, y?}   dx, dy も仮想ディスプレイの幅・高さに対する割合
///     phase: begin | change | end | mbegin | mchange | mend（m は慣性スクロール）
final class InputInjector {
    /// 縦横の切り替えでディスプレイを作り直すと変わる
    var displayID = kCGNullDirectDisplay
    private let source = CGEventSource(stateID: .hidSystemState)
    private var remX = 0.0, remY = 0.0
    private var warnedNoAccess = false

    func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String, displayID != kCGNullDirectDisplay else { return }
        if !CGPreflightPostEventAccess() {
            if !warnedNoAccess { Log.write("no accessibility permission; input ignored") }
            warnedNoAccess = true
            return
        }
        warnedNoAccess = false

        let right = (msg["b"] as? NSNumber)?.intValue == 1
        let button: CGMouseButton = right ? .right : .left
        let clicks = Int64((msg["c"] as? NSNumber)?.intValue ?? 1)

        switch type {
        case "move":
            mouse(.mouseMoved, point(msg), .left, 0)
        case "down":
            mouse(right ? .rightMouseDown : .leftMouseDown, point(msg), button, clicks)
        case "drag":
            mouse(right ? .rightMouseDragged : .leftMouseDragged, point(msg), button, 1)
        case "up":
            mouse(right ? .rightMouseUp : .leftMouseUp, point(msg), button, clicks)
        case "scroll":
            scroll(msg)
        default:
            break
        }
    }

    private func point(_ msg: [String: Any]) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        let x = min(max((msg["x"] as? NSNumber)?.doubleValue ?? 0, 0), 0.9999)
        let y = min(max((msg["y"] as? NSNumber)?.doubleValue ?? 0, 0), 0.9999)
        return CGPoint(x: b.minX + x * b.width, y: b.minY + y * b.height)
    }

    private func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, _ clicks: Int64) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        e.post(tap: .cghidEventTap)
    }

    private func scroll(_ msg: [String: Any]) {
        let phase = msg["phase"] as? String ?? "change"
        if phase == "begin", msg["x"] != nil {
            mouse(.mouseMoved, point(msg), .left, 0)
        }
        if phase == "begin" || phase == "mbegin" {
            remX = 0
            remY = 0
        }

        // 整数ポイントしか送れないので端数は次回に持ち越す
        let b = CGDisplayBounds(displayID)
        let fx = ((msg["dx"] as? NSNumber)?.doubleValue ?? 0) * b.width + remX
        let fy = ((msg["dy"] as? NSNumber)?.doubleValue ?? 0) * b.height + remY
        let dx = fx.rounded(.towardZero), dy = fy.rounded(.towardZero)
        remX = fx - dx
        remY = fy - dy

        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // kCGScrollPhase: Began=1 Changed=2 Ended=4 / kCGMomentumScrollPhase: Begin=1 Continue=2 End=3
        let (scrollPhase, momentumPhase): (Int64, Int64) = switch phase {
        case "begin": (1, 0)
        case "end": (4, 0)
        case "mbegin": (0, 1)
        case "mchange": (0, 2)
        case "mend": (0, 3)
        default: (2, 0)
        }
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        e.post(tap: .cghidEventTap)
    }
}
