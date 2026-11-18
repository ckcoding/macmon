重新生成图标：
  swiftc -O tools/icon/main.swift -o /tmp/mkicon && /tmp/mkicon /tmp/icon1024.png
  然后用 sips 缩放出 iconset、iconutil -c icns 生成 app/AppIcon.icns
