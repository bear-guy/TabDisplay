# TabDisplay — Android タブレットを Mac のサブモニターにする

USB でつないだ Android タブレットを、Mac の拡張ディスプレイとして使うメニューバーアプリ。タッチ操作にも対応している。
タブレット側はブラウザでページを開くだけで、専用アプリのインストールは要らない。

```
Mac                                              タブレット (ブラウザ)
┌──────────────────────────────┐   USB (adb reverse)   ┌───────────────────┐
│ CGVirtualDisplay 1280x800    │                       │ http://localhost:7710
│   ↓ ScreenCaptureKit         │ ── JPEG(変化領域) ──▶ │   canvas に描画    │
│   ↓ JPEG                     │                       │                   │
│ WebSocket :7710 (127.0.0.1)  │ ◀── タッチ操作 ────── │   ジェスチャー判定 │
│   ↓ CGEvent (マウス/スクロール)│                       │                   │
└──────────────────────────────┘                       └───────────────────┘
```

Mac 側のサーバーは 127.0.0.1 にしか bind しないので、同じネットワークの他の端末から画面を見られたり操作されたりすることはない。タブレットからは adb reverse で USB 経由でつなぐ。

## 必要なもの

- **Mac**: Apple Silicon、macOS 14 以降
- **adb**: `brew install android-platform-tools`
- **Android タブレット**: Android 5.0 以降（adb reverse に必要）、USB デバッグを有効にしておく
- **タブレットのブラウザ**: Firefox を推奨（ページを自動で開くのは Firefox）。他のブラウザでも `http://localhost:7710` を開けば使える可能性があるが、未確認

動作確認: Android 5.1・1280×800 のタブレット + Firefox 115、macOS 27（Apple Silicon）

## セットアップ

1. タブレットで USB デバッグを有効にする
   - 設定 → タブレット情報 →「ビルド番号」を7回タップして開発者向けオプションを出す
   - 設定 → 開発者向けオプション →「USB デバッグ」をオン
2. タブレットを USB で Mac につなぎ、タブレットに出る「USB デバッグを許可しますか？」を許可する（`adb devices` で `device` と表示されれば OK）
3. ビルドする: `./build.sh`
4. 初回起動時に、TabDisplay に次の2つを許可する（システム設定 → プライバシーとセキュリティ）
   - **画面収録とシステムオーディオ録音**: 仮想ディスプレイのキャプチャ用。許可したらアプリを再起動する
   - **アクセシビリティ**: タッチをマウス操作として Mac に送るため

## 使い方

1. タブレットを USB でつなぐ
2. `open build/TabDisplay.app`
   - メニューバーにアイコンが出て、Mac にディスプレイが1枚追加される
   - タブレットの Firefox でページが自動で開く（開かなければメニューの「Open Page on Tablet」）
3. タブレットで「Tap to start in full screen」をタップ
4. 終了はメニューバーのアイコン →「Quit」。仮想ディスプレイも消える

ディスプレイの左右の配置は「システム設定 → ディスプレイ」で変えられる（次回以降も記憶される）。

## タッチ操作

| 操作 | Mac での動作 |
|---|---|
| 1本指タップ | クリック（素早く2回でダブルクリック） |
| 1本指で動かす | ドラッグ |
| 1本指で長押し | 右クリック |
| 2本指で動かす | スクロール（離すと慣性で続く） |
| 2本指タップ | 右クリック |

全画面が解除されたら（Android の戻るボタンなど）、右下の「Full screen」ボタンで戻せる。

## 解像度と向き

仮想ディスプレイは横向き 1280×800、縦向き 800×1280 で作る。
比率の違うタブレットでは、上下または左右に黒い帯が出る。
解像度を変えるときは `Sources/VirtualScreen.swift` の `longSide` / `shortSide` を変えて再ビルドする。

タブレットを縦にすると、Mac 側のディスプレイも縦長に切り替わる（1〜2秒）。
メニューバーの「Orientation」で、横・縦に固定することもできる。

macOS は最初に登録した解像度と同じ向きの解像度しか使わせてくれないため、向きを変えるたびに仮想ディスプレイを作り直している。
そのため次の点に注意する。

- 切り替えの瞬間に Mac の画面が一瞬ちらつく
- タブレット側に置いていたウィンドウは、切り替え時に Mac 本体の画面へ移動する
- 配置（Mac の左右どちらに置くか）は縦・横それぞれで記憶される。縦にしたときの配置も一度「システム設定 → ディスプレイ」で合わせておく

## 表示言語

メニューバーの「Language」で English / 日本語 / 简体中文 / Español を選べる（既定は English）。
選んだ言語はタブレットのページ（接続中の表示や全画面ボタン）にもすぐ反映される。

文言は Mac 側が `Sources/main.swift` の `tr(...)` の呼び出し箇所、ページ側が `web/index.html` の `I18N` にある。

## スリープ対策

ページを表示している間は、タブレットがスリープしない（電源につないでいなくても）。
ブラウザが Screen Wake Lock API に対応していればそれを使う。
対応していないブラウザ（Firefox 125 以前など）では、見えない小さな無音動画を再生し続け、動画再生中にブラウザが取る画面点灯のウェイクロックを利用する。
この場合、ブラウザの自動再生ブロックのため、最初の1回はタップ（全画面ボタンや画面操作）で有効になる。
タブを閉じる・別のアプリに切り替えると解除される。

これとは別に、USB でつないでいる間は「USB 給電中は画面を消さない」設定も有効にしている（アプリ終了時に元に戻す）。

## ビルド

```sh
./build.sh                       # build/TabDisplay.app を作る
./build.sh --reset-permissions   # 古い許可を消してからビルド
```

ad-hoc 署名なので、**Swift を変更して再ビルドするたびに画面収録・アクセシビリティの許可を付け直す必要がある**（`--reset-permissions` を付けると、古い許可がシステム設定に残らない）。

`web/index.html` はアプリに埋め込まず直接配信している。ページの修正だけなら再ビルドは不要で、タブレットで再読み込みすれば反映される。

## 調整（再ビルド不要・アプリの再起動で反映）

```sh
defaults write local.soma.tabdisplay jpegQuality -float 0.6    # 画質（既定 0.7）
defaults write local.soma.tabdisplay maxFPS -int 20            # 最大フレームレート（既定 30）
defaults write local.soma.tabdisplay fullFramesOnly -bool true # 変化領域だけでなく毎回全体を送る
```

スクロール方向やジェスチャーの閾値は `web/index.html` 冒頭の定数（`SCROLL_SIGN` など）で変えられる。

## トラブルシューティング

- ログ: `~/Library/Logs/TabDisplay.log`（10秒ごとに送信 fps と転送量も出る）
- ページを `http://localhost:7710/?debug` で開くと、送ったメッセージやタッチイベントが左上に表示される
- 「Showing in another tab」: ブラウザの別のタブが接続している。そのタブを閉じるか、表示中の画面をタップしてこちらに切り替える
- タブレットが見つからない: `adb devices` で端末が `device` と表示されるか確認する（`unauthorized` ならタブレットで USB デバッグを許可する）

## ファイル

- `Sources/VirtualDisplay.h` — CoreGraphics の非公開 API `CGVirtualDisplay` の宣言
- `Sources/VirtualScreen.swift` — 仮想ディスプレイの作成（縦横を変えるときは作り直す）
- `Sources/ScreenStreamer.swift` — キャプチャ、JPEG 化、送信の流量制御
- `Sources/WebServer.swift` — HTTP と WebSocket（自前実装）
- `Sources/InputInjector.swift` — タッチをマウス・スクロールイベントとして注入
- `Sources/ADBBridge.swift` — 端末の検出、adb reverse、画面点灯の維持、ページを開く
- `Sources/Strings.swift` — 表示言語
- `Sources/main.swift` — メニューバーアプリ本体
- `web/index.html` — タブレット側のページ
