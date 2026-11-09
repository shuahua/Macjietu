# 控制 UI 玻璃样式验证

## 实现范围

- 新增 `Sources/截图Free/GlassView.swift`：NSView 外层裁剪 + NSVisualEffectView 系统 popover 材质；behindWindow 采样；14pt 圆角，双层 masksToBounds，无描边。
- 效果层上方使用动态 windowBackgroundColor 遮罩，正常不透明度 0.72；减少透明度开启时为 1，效果层 inactive。监听系统辅助功能变化，外观变化重绘动态背景色。
- 控件位于效果视图之外的前景，不参与 vibrancy，不给文字额外乘透明度；主/次文字使用 labelColor / secondaryLabelColor。
- 设置、截图编辑工具栏与全部参数面板、长截图控制窗与进度缩略图背景、录屏选项/控制/预览底栏已接入。
- 长截图进度文件原有回调、完成按钮、窗口排除和隐藏逻辑保留。AppCoordinator 本轮没有编辑；原有手动完成不警告逻辑保留。
- 未找到工作区或各级父目录 AGENTS.md。

## 原生与媒体边界

- 截图选区、录屏区域边框、贴图、截图画布没有加玻璃或遮罩。
- 长截图缩略图仍以 fraction=1 在独立前景绘制；播放器与玻璃底栏是互不重叠的兄弟视图。
- 通知实际由 AppCoordinator 的 UNUserNotificationCenter 发出，不是自定义 AppKit 窗口；保持系统通知外观。
- NSMenu、NSAlert、NSSavePanel、NSColorPanel、AVPlayerView 播放控件保持系统原生，不覆写私有视图。
- 不改变窗口 styleMask、level、Space、焦点或激活策略。标题栏仅采用系统透明标题栏设置。

## 最终验证（2026-09-14）

- `swift build`：通过。
- `swift test --filter 'GlassViewTests|AnnotationToolOptionsTests|AnnotationTextTests|PinWindowControllerTests|CaptureExclusionAndScrollTests'`：23 项，0 失败。
- `swift test`：86 项，0 失败，261.906 秒。
- 全量包含显式完成拒绝尾帧不警告、捕获/权限/存储错误仍报告的旧回归测试，均通过。
- `git diff --check`：通过。
- `pgrep -fl 'swift-test|截图FreePackageTests|xctest'`：无残留测试进程。
- 首轮相关测试发现 CALayer 默认 borderColor 非 nil，已显式清除；控制器集成测试窗口数量修正为实际六个玻璃窗口（区域边框不算玻璃）。修复后重新构建、相关测试及全量均通过。
- 没有提交、打包或发布。

## 真实视觉限制

本次执行了真实 AppKit 对象/窗口测试，验证暗亮动态系统色差、文字不额外降透明度、材质/遮罩配置、圆角裁剪、缩放覆盖、窗口行为保留与媒体层级隔离。没有执行桌面截屏人工视觉验收；系统色差断言不是最终合成画面的 WCAG 对比度认证。系统材质的实际透光、系统标题栏及通知样式依 macOS 版本、桌面背景和辅助功能而变化。减少透明度为注入配置测试，未修改用户系统偏好；真实系统开关通知与各种桌面背景下的观感尚未人工核验。
