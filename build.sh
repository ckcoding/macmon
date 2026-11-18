#!/bin/bash
# 编译 macmon CLI + MacMon.app
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ 编译 CLI …"
swiftc -O -swift-version 5 Sources/*.swift macmon.swift main.swift -o macmon -framework IOKit

echo "▸ 编译 App …"
APP=MacMon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 Sources/*.swift app/*.swift -o "$APP/Contents/MacOS/MacMon" \
    -framework AppKit -framework SwiftUI -framework UserNotifications -framework ServiceManagement -framework IOKit -framework SystemConfiguration
cp app/Info.plist "$APP/Contents/Info.plist"
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "✅ CLI: $(pwd)/macmon"
echo "✅ App: $(pwd)/$APP"

# ./build.sh install → 装到 /Applications 并重启（若开了守护模式，launchd 会自动拉起新版）
if [[ "${1:-}" == "install" ]]; then
    echo "▸ 安装到 /Applications …"
    pkill -x MacMon 2>/dev/null || true
    sleep 1
    rm -rf /Applications/MacMon.app
    cp -R "$APP" /Applications/
    LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSREG" -u "$(pwd)/$APP" 2>/dev/null || true      # 只保留 /Applications 这一份，通知图标才不会错乱
    "$LSREG" -f /Applications/MacMon.app 2>/dev/null || true
    if [[ -f "$HOME/Library/LaunchAgents/com.ck.macmon.app.agent.plist" ]]; then
        launchctl kickstart -k "gui/$(id -u)/com.ck.macmon.app.agent" 2>/dev/null || true
    else
        open /Applications/MacMon.app
    fi
    echo "✅ 已安装并启动 /Applications/MacMon.app"
fi
