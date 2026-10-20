import Foundation

/// 表示言語。メニューバーの「Language」で切り替え、タブレットのページにも伝える。
enum Language: String, CaseIterable {
    case en, ja, zh, es

    /// メニューに出す名前（その言語での呼び方）
    var nativeName: String {
        switch self {
        case .en: "English"
        case .ja: "日本語"
        case .zh: "简体中文"
        case .es: "Español"
        }
    }

    static var current: Language {
        get { UserDefaults.standard.string(forKey: "language").flatMap(Language.init) ?? .en }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }

    /// タブレットのページに表示言語を伝えるメッセージ
    static var pageMessage: String {
        "{\"type\":\"lang\",\"lang\":\"\(current.rawValue)\"}"
    }
}

/// 現在の言語の文言を返す。文言は呼び出し側に並べて書く。
func tr(_ en: String, ja: String, zh: String, es: String) -> String {
    switch Language.current {
    case .en: en
    case .ja: ja
    case .zh: zh
    case .es: es
    }
}
