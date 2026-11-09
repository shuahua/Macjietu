# 原生工具选中与文字外点退出

更新：2026-09-16。

## 最新增量：全工具栏原生样式与 Aa（本节取代下文旧版外观结论）

- 实施前局部核实 `showStandardEditor` / `showLongScreenshotEditor` 均调用 `addStandardToolbar`：当时实际源码为左侧四段 NSSegmentedControl、右侧四个形状及五个 GlassButton，不能按此前“八工具分段”的描述推断用户版本。
- 产品与设计：保留画笔 `.separated` 原生系统表面。右侧全部改用相同 style/controlSize 的单段 NSSegmentedControl；形状 `.selectOne`，清空/复制/保存/贴图/关闭 `.momentary`。关闭取消单独红色外观，原 closeWindow 行为不变。没有新增自绘选中背景。
- 文字图像由 NSImage 绘制明确的 `Aa`，设为 template，所有 segment label 为空；不再使用 textformat 系统符号。测试检查真实图像具有非透明像素，辅助说明为“文字 Aa”。
- 背景宽度由 560 改为 600 pt，实际控件组保持 546 pt；左右留白各 27 pt，整体居中。普通与长截图窗口均验证当前屏幕 visibleFrame 内、32 pt 阴影外边距未裁切。
- 参数间距 7 pt、GlassView 防穿透底色 0.02、shadowPadding 32 pt 未改。画布、文字外点退出、移动缩放、undo、自动复制实现未在本轮改动。

### 本轮验证

执行已有 AppKit 检查脚本（依次 swift build、专项 swift test、全量 swift test、git diff --check），退出成功：

- `swift build`：通过，最终增量构建 0.11 秒。
- 专项筛选 `ToolbarInteractionShadowTests|AnnotationToolOptionsTests|AnnotationTextTests|AnnotationUndoTests|AnnotationAutoCopyTests|WindowServerToolbarTests`：36 项、0 失败，16.133 秒。
- `swift test` 全量：140 项、0 失败，273.009 秒。
- `git diff --check`：通过。
- 首次专项有两条断言失败：测试按 tooltip 筛选时把左侧工具组也算为形状。改为按生产 `iconToolChanged:` action 定位后，上述专项和全量均通过。没有跳过失败测试。
- 原生跟踪覆盖五个瞬时操作（含关闭）的释放、拖出取消、重复、空格和 performClick 后无持续选中；真实回调覆盖复制/保存/贴图/关闭。全部十个控件、十三个图标入口均验证原生类型、样式、空 label 与图像存在。
- 普通/长截图的 native、standard、opaque 分支均验证控件命中、工具互斥、文字外点退出与重新激活；WindowServer 验证前景控件不穿透、透明边缘仍命中背景。

### 范围与限制

本轮仅更改 AnnotationEditorController.swift、ToolbarInteractionShadowTests.swift、AnnotationToolOptionsTests.swift 及本文，保留已有未提交修改。没有打包、安装、提交、修改版本或终止用户 App。

证据是生产构造路径、合成 AppKit 原生鼠标跟踪、真实 TextKit 与 WindowServer 命中，不是用户运行中 App 的人工视觉验收；没有声称已安装包热更新。当前屏幕几何通过，但未新增极窄屏或多显示器布局验收；旧系统外观仅在当前 macOS 26.6.2 上强制 fallback 验证。

## 修复结论

- 画笔、橡皮、马赛克、文字恢复为唯一的 `NSSegmentedControl`，使用原版 `.selectOne` 与 `.separated`。选中外观由 AppKit 绘制，不以 GlassButton toggle 或自绘背景模拟系统蓝色选中效果；系统强调色设置仍由系统决定。
- 文字入口仅显示 `textformat` 图标，segment label 为空，提示为“文字”，没有“格式”可见文字，也没有重复的独立文字按钮。
- 矩形、圆形、直线、箭头仍是独立图标按钮；清空、复制、保存、贴图仍保持原有瞬时操作表面，关闭按钮不改。
- 分段与形状入口汇入 `selectTool`；画布 `onToolChanged` 驱动分段选中和形状状态。无工具时分段为 `-1`，同时移除参数面板。
- 文字输入后点击文字框外的画布：先提交，再进入 `.none`，清除文字激活状态；本次点击不新建、不开始窗口拖动，后续空白点击不续建。再次点击文字工具才能新建。空输入同样退出且丢弃空对象。
- 外点退出沿用原有工具切换的文字固定化与历史转换，保持撤销/重做，不制造额外内容 revision。
- 自动复制内容通知从 `selectText` 移到工具栏初始化：未使用过文字工具的画笔/形状也接通通知，不再依赖隐藏的操作顺序。

## 根因与范围

当前未提交源码把原生分段替换成八个独立 toggle 按钮，导致原画笔系统选中外观丢失。文字外点原先只调用 `commitTextEditing`、撤销新建许可，没有将 `tool` 切回 `.none`，所以图标继续激活。另有内容变化回调只在选择文字时安装的问题。

本轮只编辑 `AnnotationEditorController.swift`、三个现有测试文件及本文。保留工作区其他未提交功能和文件；没有改发布版本、打包、安装、Git 提交或关闭已安装应用。检查仓库和祖先范围的 AGENTS，未发现适用于此项目的 AGENTS.md。

## 真实编辑器事件回归

`ToolbarInteractionShadowTests.testRealEditorOutsideTextClickExitsNativeSelectionAndRequiresRearm` 在普通与长截图编辑器分别运行 native、强制 fallback（standard）、减少透明度（opaque）：

1. 使用生产 controller 创建编辑器，按新窗口身份获取窗口及真实控件。
2. 从窗口根及每层祖先 hitTest 验证命中；分段通过 mouseDown 和投递 mouseUp 进入原生跟踪循环，而非只设置 selectedSegment 调 action。
3. 在真实画布创建 NSTextView，调用 insertText 输入，核对 firstResponder。
4. 点击文字框外，验证 `.none`、`selectedSegment == -1`、新建许可关闭、编辑器与参数窗口移除、内容不丢失且 revision 不重复。
5. 后续空白点击不续建；undo/redo 恢复内容但不激活工具；重新点击文字工具才能新建；空输入外点不删除已有文字。
6. 核对形状与分段互斥，并验证选择文字之前的画笔也触发内容通知。

其他回归继续覆盖四个瞬时操作的释放/取消/重复/键盘、全部形状、参数面板、自动复制、文字输入法、undo、导出、原生/fallback 控件命中，以及 WindowServer 前景控件不穿透、透明边缘命中背景。

## 验证结果

- `swift build`：通过，最终构建无本轮引入的警告。
- `env NSUnbufferedIO=YES swift test`：140 项、0 失败，265.987 秒。
- `env NSUnbufferedIO=YES swift test --filter 'ToolbarInteractionShadowTests|LiquidGlassAdoptionTests|WindowServerToolbarTests'`：12 项、0 失败，12.252 秒。
- `git diff --check`：通过。
- 环境：macOS 26.6.2（25G83），AppKit 2685.7。
- 首次全量命令因 120 秒工具时限终止；确认没有遗留 swift-test/xctest 进程后，以 600 秒时限完整重跑通过。没有把超时当作通过。
- 首次新增回归暴露 Optional `.none` 比较误用，导致参数面板未关闭；改为显式 `AnnotationTool.none` 后，全量与专项均通过。
- 已安装应用 `/Applications/截图Free.app/Contents/MacOS/截图Free` 在最终检查时仍以原 PID 792 运行。

## 证据边界

这是生产编辑器中的合成 AppKit 事件、真实 TextKit 输入和 WindowServer 命中验证，不是对已安装应用的人工鼠标验收。恢复了与原版相同的系统控件配置，未进行选中蓝色的截图像素比对；不声称已安装应用已热更新。fallback 是当前系统强制 standard/opaque 分支验证，不等于在旧 macOS 实机上测试。
