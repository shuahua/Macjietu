# 水滴选中反馈：实现与验证

日期：2026-09-15。基于任务开始时已有未提交工作增量修改；未提交、未打包、未关闭用户运行中的应用。项目内及已检查的上级目录未发现 AGENTS.md。

## 实际范围

- `Sources/截图Free/WaterdropSelection.swift`：共享被动水滴视图、移动协调器、原生 segmented/popup 子类。
- `Sources/截图Free/GlassInteraction.swift`：所有现有 GlassButton 构造入口使用统一内容 cell 和水滴反馈，包括截图命令、长截图控制、录屏开始/取消/停止、预览保存/关闭、设置按钮和复选开关。
- `Sources/截图Free/SettingsWindowController.swift`：设置侧栏垂直分类共用一个水滴；导出尺寸 popup 仅更换按钮反馈。
- `Sources/截图Free/AnnotationEditorController.swift`：截图工具横向分段共用水滴，形状 popup 加入同一组；字体/字重 popup 保持原生菜单；颜色块保留原色及原有选中边框，不用水滴覆盖。
- `Sources/截图Free/RecordingOptionsWindowController.swift`：音频、清晰度 popup 按钮反馈接入。

布局和设置分隔线不重新设计。GlassView 原生 macOS 26 / macOS 13 兼容路径、功能区 backing alpha 0.02、父坐标 hitTest 均保持原实现。快捷键默认值、录入与捕获逻辑未改。系统菜单、保存面板未改造。装饰不进入画布导出树。

## 实现

每个互斥组持有一个 WaterdropSelection，其 surface 为同一个 WaterdropSurface 对象。它插在控件内容的兄弟层下方，hitTest 恒为 nil。位置来自目标 bounds 到 host 的实际坐标转换；分段绘制和定位使用同一个 segmentBounds，并把真实 cell 的段宽设置成对应宽度。

模型 frame 同步更新到目标，position/bounds 使用 0.25 秒 easeInEaseOut。重定向先读取 presentation layer，再移除旧动画；只有两个固定 animation key，没有异步 completion，也不回写 action/state。水平、垂直及大小变化由同一实现处理。layout、按钮 frame 更新及辅助功能变化会刷新；reduceMotion 清除动画、直接到目标。

macOS 26 且工具链支持时使用 NSGlassEffectView；原生路径不额外叠加人工边线/阴影。旧系统、强制 fallback 使用透明中心、细亮边及柔高光的兼容装饰，**不是光学折射实现**。reduceTransparency 使用不透明系统控制背景。文字/图标独立于装饰、不降低整体 alpha。

GlassButton 保留原 cell 跟踪与 target/action。普通 command 只在按下时激活；toggle/switch/radio 等保持真实 state。原生 cell 有时直接改状态而不走 NSButton.state setter，因此在 cell highlight、sendAction、performClick 和 mouseDown 返回处补刷新。disabled 隐藏激活；焦点指示独立绘制。侧栏不绘制原生 bezel，分段不绘制原生选中底形，popup 保留原生菜单和文字箭头。

## 测试与修复记录

新增 `Tests/截图FreeTests/WaterdropSelectionTests.swift`，10 项测试：

1. 同一对象双轴移动及尺寸变化。
2. 快速反复切换、presentation 起点、最终目标和有限动画 key。
3. layout 及偏移 bounds 转换。
4. reduceMotion、reduceTransparency、明暗外观和兼容后端。
5. command 暂态、toggle 真状态与 action 调用计数。
6. disabled、focus、色块不遮色。
7. 根视图命中和装饰被动性。
8. 分段与形状 popup 共用对象、互不误清除、取消及缩放。
9. 生产设置分类切换保持对象身份。
10. 兼容装饰离屏像素：透明四角、低 alpha 中心、非实心轮廓。

保留并运行已有生产 mouseDown tracking、设置分隔线、WindowServer 查询及负对照、逐像素导出等测试。测试窗口均由测试创建；没有录制用户屏幕或投递全局鼠标事件。

修复测试发现的真实 toggle 反馈刷新遗漏。同步更新旧测试契约：旧侧栏 cell 不再要求实色底形；持久选中测试明确使用 toggle；无 bezel 原生 popup 的内部文字使用 controlTextColor，其内部基线不应当作应用按钮整体中心。未按私有类名筛选，使用 NSControl 祖先关系排除内部子控件。

### 最终验证结果

| 验证 | 结果 |
| --- | --- |
| `swift build` | 通过；fallback 检查后已恢复默认原生构建 |
| skill `scripts/check.sh`：build → 相关测试 → 全量测试 → diff 检查 | 通过 |
| 原生相关测试 | 38 项，0 失败，14.380 秒 |
| 原生全量 `swift test` | 132 项，0 失败，278.467 秒 |
| `swift test -Xswiftc -DLIQUID_GLASS_FALLBACK --filter …` | 38 项，0 失败 |
| `git diff --check` | 通过 |

运行环境：macOS 26.6.2，AppKit 2685.7。每次构建/测试工具 timeout 600 秒。原生全量日志通过时间为 2026-09-15 15:03:02；表中原生耗时使用日志括号内的总耗时。构建、测试及 diff 检查命令均成功退出。

相关测试的完整筛选参数如下，可在项目根目录复现。全量验证使用 `swift test`，fallback 后用 `swift build` 恢复默认构建。

```sh
swift test --filter 'WaterdropSelectionTests|ToolbarInteractionShadowTests|SettingsSidebarMenuPolishTests|WindowServerToolbarTests|ImageExportTests|RecordingLayoutAspectTests|GlassViewTests|LiquidGlassAdoptionTests'
swift test -Xswiftc -DLIQUID_GLASS_FALLBACK --filter 'WaterdropSelectionTests|GlassViewTests|LiquidGlassAdoptionTests|ToolbarInteractionShadowTests|WindowServerToolbarTests|ImageExportTests|RecordingToolbarInteractionTests|SettingsSidebarMenuPolishTests'
```

本次收尾只补充验证文档并复查差异，没有修改实现或重新执行构建/测试；上表测试结果来自前述已完成的运行。

WindowServerToolbarTests 在原生路径实际执行移除 backing 的负对照：根 hitTest 仍命中，但 WindowServer 返回下层测试窗口；恢复 0.02 后返回前景窗口。fallback 编译没有原生材质，该条件负对照不执行，不算作旧系统负对照证据。

## 限制与待人工验收

- 未看到用户参考附件，按文字描述实现；未宣称与附件像素一致。
- 离屏像素测试仅证明兼容装饰轮廓，不能证明原生玻璃折射强度或桌面动画流畅观感。WindowServer 测试证明命中路由，不是桌面动态视觉验收。
- 未在 macOS 13 实机运行；fallback 是当前 SDK 的编译开关验证，不等同于旧 SDK/旧系统验收。
- 原生菜单 tracking 继续由系统管理；生产按钮/分段有原生鼠标跟踪测试，菜单选项测试不冒称真实展开菜单的人工验收。
- 本轮未修改导出实现；已有逐像素导出测试通过，动态装饰与画布隔离。真实桌面明暗背景下的对比、键盘焦点观感、连续移动主观效果仍需人工确认。

本轮复用已有 AppKit 装饰回归 skill 与检查脚本，没有创建重复的工程流程 skill。
