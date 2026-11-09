# 录屏单行布局与自然比例预览验证

日期：2026-09-14。项目：截图Free（Package.swift，macOS 13+，AppKit）。

## 本轮实现

- `RecordingLayout.swift`：共享单行排版，各控件在根坐标下 centerY 一致；按录制区域中心定位、屏幕 visibleFrame 钳位，支持负坐标。窄屏保持全部控件和菜单，整行等比缩小；窗口取整后重新居中玻璃层，避免半点尺寸造成偏移。
- `RecordingOptionsWindowController.swift`：标题、音频标签/菜单、清晰度标签/菜单、开始/取消同一行。说明移至开始按钮 tooltip；音频/清晰度 allCases、默认值、回车和 Esc 不变。
- `RecordingControlWindowController.swift`：状态点、正在录制、时间、音频/质量、完成同一行；标签采用自然宽度。现有停止幂等、计时器与回调清理保留。
- `RecordingPreviewLayout.swift`：borderless 可 key 窗口，Esc 关闭；透明根 hitTest 不返回自身。异步 AVAsset track 加载 naturalSize、preferredTransform、formatDescriptions，以 clean aperture/像素宽高比展示尺寸再应用旋转；后续接受 AVPlayerItem.presentationSize 校正。
- `RecordingPreviewWindowController.swift`：无系统标题栏、traffic lights、标题文字和播放器全屏按钮。保留原生 floating 播放控制、AVPlayer 音轨链路。播放器始终 resizeAspect；媒体 viewport 独立按真实比例缩小，不拉伸、不 aspectFill。窄影片允许透明根比媒体更宽，不让工具栏撑宽播放器。
- 工具栏按两个按钮 sizeToFit 宽度 + 44 点构成，高 52 点，水平居中；外侧阴影留白 32 点，媒体与工具栏间距 20 点。拖动路径为玻璃工具栏空白背景的 performDrag，控件仍走自身鼠标处理。媒体复用 MediaDisplayView 的圆角和阴影，不改变输出文件。
- 尺寸未就绪时隐藏播放器、显示加载说明；加载失败仍可关闭/保存。取消 Task、撤销 KVO、didCleanup 与 show 守卫共同阻止迟到结果复活窗口。保存面板返回后再次检查清理状态；拒绝源文件自身作为导出目标，避免先删除再复制。

## 新增/调整的真实回归

`Tests/截图FreeTests/RecordingLayoutAspectTests.swift` 新增 4 个测试：

1. AppKit 真窗口单行各 NSControl centerY、整体居中、480 点窄屏、负坐标、边缘钳位及全部菜单选项保留。
2. 竖屏、超宽、方形、超大、工具栏宽于影片的独立 viewport，以及旋转几何和非法尺寸检查。
3. AVAssetWriter 生成两个本地短影片（320×180，含 90° track transform 变体）；实际异步读取 AVAsset，核验 AVPlayerView frame 比例、resizeAspect、无标题栏/全屏按钮、紧凑工具栏、透明根命中、保存取消、逐字节导出一致及源文件清理。生产编码器未修改。
4. 受控 continuation 在 Esc 关闭后返回尺寸，验证内容/播放器不恢复、show 无效、关闭只回调一次、临时文件清理。

`WindowServerToolbarTests.swift` 新增 1 个测试：生产预览窗口与测试自有下层 probe，以直接对象及窗口 ID 定位；原生/强制 fallback/减少透明度下查询 WindowServer，按钮与面板网格归属预览窗口，透明角落归属下层 probe。没有投递全局鼠标事件或申请权限。

`RecordingToolbarInteractionTests.swift` 的 4 个现有测试继续验证全部音频/清晰度组合、AppKit 原生按钮 tracking、保存取消/保存/关闭及旧控制器幂等；标题栏断言随 borderless 改为不存在。

`GlassViewTests.swift` 更新层级断言：播放器位于 MediaDisplayView 内，不在 GlassView 内；工具栏位于媒体下方。

## 实际执行结果

工具超时上限均为 600000 毫秒。加载的 appkit-decoration-regression 技能 `scripts/check.sh` 实际顺序执行 swift build、相关测试、全量测试、git diff --check，最终退出 0。

| 检查 | 最终结果 | XCTest 用时 |
| --- | --- | --- |
| swift build（常规） | 成功，无本轮编译警告 | 构建 0.83 秒 |
| 常规相关：RecordingLayoutAspectTests、RecordingToolbarInteractionTests、WindowServerToolbarTests、WindowDecorationRegressionTests、GlassViewTests | 17 项，0 失败 | 7.338 秒 |
| swift test（全量常规） | 110 项，0 失败 | 269.020 秒 |
| swift test -Xswiftc -DLIQUID_GLASS_FALLBACK --filter 上述相关组加 LiquidGlassAdoptionTests | 20 项，0 失败 | 6.649 秒 |
| git diff --check | 通过 | — |

初次测试编译发现 CGFloat.infinity 类型歧义和 XCTest autoclosure 不支持 await，均已修复。首次运行发现窗口取整引起玻璃中心偏移，以及旧玻璃测试假定播放器直接位于根下；修正生产居中和新媒体层级断言后重跑全部通过。没有跳过失败用例。

## 保留范围与限制

- 开始前核对 git status，项目及祖先路径未发现适用 AGENTS.md。已有大量工作区改动未重置；未提交、未打包、未关闭运行中的用户 App。仅构建测试进程创建/清理自己的窗口与 fixture。
- 本轮未改 AppCoordinator、ScreenRecordingService、GlassView、AnnotationEditorController 的现有逻辑，保留会话身份防护、.02 backing、原生 26/fallback、截图参数间距/居中与文字 resize。
- 已有真实 WindowServer 命中证据，不等同于人工桌面视觉验收；未人工验收跨实体显示器拖动、播放控制操作、系统下拉菜单选择、系统保存面板交互、音轨听感及阴影主观效果。
- 负坐标/窄屏使用注入 visibleFrame 的真 AppKit 窗口；竖屏实际影片为旋转 fixture，其余超宽/方形/超大为布局几何验证，不声称所有格式均实播。
- clean aperture/像素宽高比使用系统 presentation dimensions API；本轮 fixture 没有额外嵌入非默认 clean aperture 或非方形像素元数据。影片自身编码黑边不会去除。
- 未录用户屏幕、未请求权限、未改生产编码与转码策略；fixture 导出仍是原文件复制。
- 本轮复用了已有 AppKit 回归技能及检查脚本，不另建重复技能。
