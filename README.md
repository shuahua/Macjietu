# 截图Free

原生 macOS 菜单栏截图工具。当前版本提供区域截图、窗口截图、全屏截图、长截图、录屏、标注编辑、复制、保存和贴图。

## 构建与运行

推荐使用固定的 `/Applications/截图Free.app` 运行，不要混用旧构建产物，避免 macOS 权限记录对应到旧应用身份：

```bash
open 截图Free.xcodeproj
```

在 Xcode 中选择 target `截图Free`，打开 `Signing & Capabilities`，选择你的 Team，然后点击 Run。

如果之前运行过旧版应用，需要移除旧权限项或重置对应权限后重新授权。

## SwiftPM 调试

生成 `.app`：

```bash
./scripts/build-app.sh
```

启动应用：

```bash
open /Applications/截图Free.app
```

应用是菜单栏常驻程序，不会打开普通主窗口。启动后在菜单栏寻找“截”。

## 使用

- 点击菜单栏“截”图标，选择“区域截图”。
- 默认快捷键是 `Command + Shift + S`。
- 首次截图需要授予屏幕录制权限。点击“请求屏幕录制权限”或“区域截图”后，系统会把应用加入“系统设置 > 隐私与安全性 > 屏幕录制”。授权后需要退出并重新打开应用。
- 截图后会直接进入编辑窗口，可标注、复制、保存或贴图。

## 测试

```bash
swift test
```

## 当前限制

- 当前 `.app` 安装在 `/Applications/截图Free.app`，避免每次从不同构建目录运行导致 macOS 权限识别混乱。
