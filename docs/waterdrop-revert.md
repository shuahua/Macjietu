# 撤销水滴选中效果

日期：2026-09-15。目标为当前工作区 Package.swift 对应的截图Free。已检查项目及上级目录，无适用 AGENTS.md；参考 waterdrop-selection-feedback.md 与 settings-sidebar-menu-polish.md 增量撤销，没有整文件 reset。

## 实际范围

- 删除仅水滴新增的 `Sources/截图Free/WaterdropSelection.swift`（Surface、Selection、popup/segmented 子类与专用 cell、位置/尺寸动画）及 `Tests/截图FreeTests/WaterdropSelectionTests.swift`（10 项专用测试）。没有删除其他用户文件。
- `Sources/截图Free/GlassInteraction.swift`：去掉共享装饰挂载、刷新、全局 SidebarButtonCell 替换与水滴专用状态。普通按钮恢复原生 NSButtonCell 和可见的 hover/pressed/focus 反馈层；侧栏专用 cell 保持唯一 bounds 圆角底形、独立内部焦点描边，禁用 inset 反馈层，不调用 native bezel。保留既有 GlassMotion 窗口淡入，它不是水滴依赖。
- `Sources/截图Free/SettingsWindowController.swift`：撤销侧栏共享选中组；导出 popup 恢复 NSPopUpButton。
- `Sources/截图Free/AnnotationEditorController.swift`：恢复 NSSegmentedControl、原生字体/字重/形状 popup、形状选中边框，移除选中组与色块水滴豁免属性。保留色块原色、选中边框及现有布局。
- `Sources/截图Free/RecordingOptionsWindowController.swift`：音频/清晰度恢复原生 popup，布局和业务行为不变。
- 更新 `Tests/截图FreeTests/SettingsSidebarMenuPolishTests.swift` 的单一底形像素期待；在 `LiquidGlassAdoptionTests.swift` 确认普通按钮原生 cell、可见反馈及无额外兄弟装饰；在 `ToolbarInteractionShadowTests.swift` 确认原生 segmented/cell、形状选中边框与互斥状态。
- `release-notes-next.md` 改为 1.0.19 下次更新说明。`version-state` 保持 VERSION=1.0.18 / BUILD=19；下次包应为 1.0.19。没有修改历史 CHANGELOG 或旧水滴实施记录。

GlassView 的 0.02 防穿透、六项快捷键及菜单无“未设置”、设置竖线、录屏布局/比例、文字 resize、panel 间距及其他既有工作区改动保留。源码/测试中 Waterdrop、navigationFeedback、selectionGroup、selectionFeedback、preservesSwatchColor 引用已清零；文档中历史记录和本次取消说明保留。

## 实际验证

运行环境：macOS 26.6.2 / AppKit 2685.7。长命令 timeout=600000ms，均成功自然退出，无遗留后台测试。

- 复用 appkit-decoration-regression/scripts/check.sh：swift build → 相关测试 → 全量 swift test → git diff --check，成功退出。
- 首次 swift build 通过（3.33 秒）；默认相关测试 40 项、0 失败（13.121 秒）。
- 默认全量 swift test：122 项、0 失败（270.225 秒），完成时间 15:25:50。
- `swift test -Xswiftc -DLIQUID_GLASS_FALLBACK --filter 'ToolbarInteractionShadowTests|SettingsSidebarMenuPolishTests|WindowServerToolbarTests|ImageExportTests|RecordingLayoutAspectTests|GlassViewTests|LiquidGlassAdoptionTests|SettingsShortcutCustomizationTests|WindowDecorationRegressionTests|RecordingToolbarInteractionTests'`：40 项、0 失败（11.515 秒）。默认相关测试使用同一正则。
- fallback 后再次 swift build，恢复默认原生编译，通过（1.73 秒）；git diff --check 通过。
- 已保留并实际执行设置单一轮廓离屏像素、普通按钮 action/反馈/禁用、生产工具 mouseDown tracking、native/standard/opaque 根命中与 WindowServer 测试，以及录屏比例、快捷键和导出像素回归。

## 限制

未打包、提交、替换或关闭用户 App。测试只关闭测试进程创建的窗口。正在运行的旧 App 仍含水滴，源码撤销不会热更新该二进制。离屏像素与 WindowServer 命中不是人工桌面观感验收；强制 fallback 不等同于 macOS 13 实机验证。本轮复用已有回归 skill，不另建重复流程。
