# Liquid Glass 采用研究与实施边界

研究日期：2026-09-14。状态：已实施并完成构建与回归验证；原生 macOS 26 与 fallback 边界、测试限制和设计参考已记录。

## 官方来源与实际读取结果

Apple 官方页面通过资料读取与本机 AppKit 头文件交叉核验。Behance 与 Dribbble 通过受管浏览器实际访问；站酷搜索 URL 返回 `net::ERR_ABORTED`，未将其内容当作证据。

## 真实设计参考（可见页面）

- Behance 搜索页：<https://www.behance.net/search/projects?search=liquid%20glass%20ui>。可见结果包括 “UI - Liquid Glass Button | Micro-interaction Study”、 “Liquid Glass Effect Music Player Widgets” 和 “Instagram Navbar Redesign - Liquid Glass”。借鉴：小面积功能层、胶囊按钮、分组控件、克制的 hover/pressed 状态，不把玻璃铺满媒体。
- Dribbble 搜索页：<https://dribbble.com/search/liquid%20glass>。页面可访问但部分作品内容受动态加载/登录状态影响，未把不可见细节写成事实。借鉴范围仅限可见的玻璃卡片、圆角分组和层次留白。
- 站酷尝试地址：<https://www.zcool.com.cn/search/content?word=Liquid%20Glass>，受管浏览器导航被 `net::ERR_ABORTED` 中止；访问限制如实保留。

1. Materials：<https://developer.apple.com/design/human-interface-guidelines/materials>
   - Liquid Glass 是导航和控件的独立功能层，不应应用于媒体内容层。
   - 节制使用自定义玻璃。普通材质仍适用于内容背景。
   - regular 调节背景模糊和亮度以保持可读性；clear 仅适合丰富媒体背景，不能为了透明而牺牲文字对比。
2. Adopting Liquid Glass：<https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass>
   - 新 SDK 配合新系统可让标准 AppKit 控件采用更新的外观和交互。
   - 减少遮盖系统效果的自定义背景；检查控件尺寸、分组、safe area、辅助功能与图标标签。
   - 不意味着全部自定义 NSView 自动成为玻璃。
3. NSGlassEffectView：<https://developer.apple.com/documentation/appkit/nsglasseffectview>
   - macOS 26.0+，提供 contentView、cornerRadius、tintColor、style。
   - 头文件明确：仅保证 contentView 被放在玻璃内部，不保证任意子视图的效果层级。
4. NSGlassEffectContainerView：<https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview>
   - macOS 26.0+，通过 contentView 和 spacing 合并邻近后代玻璃，并减少渲染遍数。
   - spacing 默认 0 支持批处理，避免不必要的融合变形；不是所有单一玻璃面板都必须添加容器。
5. Motion：<https://developer.apple.com/design/human-interface-guidelines/motion>
   - 反馈应简短、精准、可取消，不阻塞操作；触控板反馈比直接触摸更克制。
   - 不为频繁交互添加多余位移，优先标准组件已有反馈。
6. Accessibility：<https://developer.apple.com/design/human-interface-guidelines/accessibility>
   - 优先语义系统色，检查亮暗色与 Increase Contrast。
   - 支持键盘导航和 VoiceOver，避免覆盖系统快捷键。
   - Reduce Motion 下减少缩放和空间移动，可使用淡入淡出代替位移。

## 本机事实

- `xcodebuild -version`：Xcode 26.5，Build version 17F42。
- `swift --version`：Apple Swift 6.3.2，宿主目标 arm64-apple-macosx26.0。
- `xcrun --show-sdk-path`：`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`。
- SDK 的 `System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSGlassEffectView.h` 实际声明上述两个类，均标记 macOS 26.0 可用。
- `Package.swift:6` 仍为 `.macOS(.v13)`。宿主版本与 SDK 事实不等于已经验证在 macOS 13 上运行。
- 工作区、Sources、Tests 的 AGENTS 搜索未找到适用文件。现有 Git 修改及未跟踪文件均保留；没有提交、打包、关闭用户应用或修改系统偏好。

## 实施结果

`Sources/截图Free/GlassView.swift` 已提供 macOS 26 `NSGlassEffectView`/`NSGlassEffectContainerView` 原生 backend，以及 macOS 13+ `NSVisualEffectView` fallback 和 opaque accessibility backend。控件位于原生 surface 的 `contentView`，命中测试显式穿透效果层；hover/pressed/selected/focus/reveal 交互已保留。

现有设置页通过 contentLayoutGuide 留出标题安全区。现有测试覆盖标题命中、按钮 action、Spaces 配置、媒体圆角轻阴影，以及渲染图像与源像素一致性。上述测试本轮只审阅，未执行。

## 方案比较与推荐设计（待确认）

1. **推荐：原生功能层 + 兼容后端。** macOS 26 使用 NSGlassEffectView.regular，实际控件进入其 contentView；macOS 13–15 使用标准 NSVisualEffectView，不宣称真实 Liquid Glass。减少透明度时使用不透明语义背景。编译条件和运行时 availability 分开处理，新符号不得泄漏到旧 SDK 编译分支。
2. 仅调整旧 HUD 材质：改动少，但无法满足本机已有新 SDK 时采用原生 Liquid Glass 的目标，不推荐。
3. 重构所有窗口为标准工具栏/系统弹层：系统行为一致性强，但对布局、焦点、拖动和标注流程影响较大，不适合作为本轮保守改造。

推荐实现边界：媒体画布与播放器保持独立，显示圆角 11pt 和轻阴影保留，导出链路不接触玻璃。设置正文使用普通内容背景，功能控件适度分组；编辑工具栏、参数面板、长图控制和预览操作区、录屏选项与控制条及预览底栏采用统一功能层。

交互设计：按钮保留 NSButton 的 target/action、键盘和辅助功能语义，在原有命中区域内增加克制 hover/pressed/selected/focus 反馈；不缩放实际点击框。参数面板使用短淡入，不等待动画才允许操作；关闭立即撤销待执行动画。Reduce Motion 动态变化时取消自定义移动/缩放，Reduce Transparency 动态变化时更新背景；不改系统设置。

## 验证记录与能力边界

- 共享 GlassView：后端选择、原生 contentView 层级、兼容材质、语义色和辅助开关。
- 设置：内容层与功能层分离，保留标题 safe area 与背景拖动。
- 编辑：toolbar、参数面板、选中状态、颜色控件；滚动标注与 Esc 不改。
- 长截图：独立控制窗口、进度预览功能区，不模糊缩略图。
- 录屏：options、control、preview 底栏；AVPlayerView 保持独立。
- 新回归：原生与强制 fallback、辅助功能切换、交互状态和 action 调用、命中、标题安全区、媒体无污染与导出像素。
- 已运行 `swift build`、相关回归、全量 `swift test`、`swift build -Xswiftc -DLIQUID_GLASS_FALLBACK`、fallback 相关回归和 `git diff --check`；测试中发现的父层级与命中问题已修复。

### 限制

- 更正：Testing Library 输出的 `Target Platform: arm64e-apple-macos14.0` 是库的编译目标，不是实际宿主系统。2026-09-14 只读复核 `sw_vers` 为 macOS 26.6.2（25G83），`xcrun --show-sdk-version` 为 26.5。本机测试可覆盖原生 backend 的布局和命中，但仍不能以结构化测试代替 WindowServer 实机光学效果验收。
- 离屏 bitmap 不等价于实机桌面合成；未声称完成真实鼠标、Reduce Motion/Transparency 动态切换和多屏实机视觉验收。
- 媒体显示保留 11pt 展示圆角与轻阴影；导出仍从原始画布读取并做字节一致性验证，玻璃不进入导出链路。
