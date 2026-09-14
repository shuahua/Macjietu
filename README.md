# 截图Free

原生 macOS 菜单栏截图工具。当前版本提供区域截图、窗口截图、全屏截图、长截图、录屏、标注编辑、复制、保存和贴图。

## 构建与运行

日常使用建议手动安装到固定的 `/Applications/截图Free.app` 后运行，不要混用旧构建产物，避免 macOS 权限记录对应到旧应用身份。Xcode 调试入口：

```bash
open 截图Free.xcodeproj
```

在 Xcode 中选择 target `截图Free`，打开 `Signing & Capabilities`，选择你的 Team，然后点击 Run。Run 启动的是 Xcode 构建目录中的应用，不会自动安装到 `/Applications`。

如果之前运行过旧版应用，需要移除旧权限项或重置对应权限后重新授权。

## SwiftPM 调试

生成 `.app`：

```bash
./scripts/build-app.sh debug path/to/release-notes.md
```

每次成功打包自动将 patch 和 build 各递增 1（初始为 1.0.0 build 1），并生成不覆盖旧文件的 `dist/截图Free-v版本-build编号.zip`、版本说明和项目根目录 `CHANGELOG.md`。第二个参数必须是非空白的本次修改说明文件；构建、签名和 plist 校验失败不会消费版本号。版本状态保存在项目内 `version-state`，锁为 `.build/build.lock`。脚本会重建 `.build/截图Free.app` 并生成 `dist` 发布文件，不会安装到 `/Applications`，也不会主动终止运行中的应用；请勿在打包时运行 `.build` 中的同一应用。

尚未发布的修改见 `release-notes-next.md`，已发布记录见 `CHANGELOG.md`。`AppCoordinator` 已包含长截图流程和权限菜单相关改动，但不代表长截图全局 Esc 穿透已解决，该问题仍待实机确认。

安装与启动：先退出旧应用，将 `dist` 中目标版本的 ZIP 解压，再将其中的 `截图Free.app` 手动复制到 `/Applications`（或复制 `.build/截图Free.app`）。确认替换的是目标版本后启动；下面的命令只打开已安装应用，不执行安装：

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
bash -n scripts/build-app.sh scripts/test-build-version.sh
bash scripts/test-build-version.sh
```

## 当前限制

- 构建不会自动安装应用；建议始终从手动安装后的 `/Applications/截图Free.app` 运行，避免混用构建目录导致 macOS 权限识别混乱。
