#!/bin/zsh
# TabDisplay.app をビルドして ad-hoc 署名する。
#
# ad-hoc 署名なので、ビルドし直すと macOS からは別のアプリに見え、
# 画面収録・アクセシビリティの許可を付け直す必要がある。
# web/index.html はビルドせずに直接配信しているので、ページの修正だけなら再ビルド不要。
set -euo pipefail
cd "${0:A:h}"

APP=build/TabDisplay.app
BUNDLE_ID=local.soma.tabdisplay

pkill -x TabDisplay 2>/dev/null && sleep 1 || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -import-objc-header Sources/VirtualDisplay.h \
  -target arm64-apple-macos14.0 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/TabDisplay"

cp Info.plist "$APP/Contents/Info.plist"
cp web/index.html "$APP/Contents/Resources/index.html"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

# 古いビルドに付いていた許可は無効なので消しておく（次回起動時にもう一度聞かれる）
if [[ "${1:-}" == "--reset-permissions" ]]; then
  # 作り直した直後のアプリは LaunchServices に未登録で tccutil が見つけられないことがあるので、先に登録する
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
  tccutil reset ScreenCapture "$BUNDLE_ID" || true
  tccutil reset Accessibility "$BUNDLE_ID" || true
fi

echo "built: $PWD/$APP"
