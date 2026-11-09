# 独立形状工具与标注撤销

## 实现

- 基线 HEAD：57869c9。只修改标注编辑器和相关测试；未提交、未打包，未关闭用户运行中的 App。
- 删除形状下拉，矩形、圆形、直线、箭头分别使用纯图标 GlassButton，独立 target/action、中文 tooltip/accessibility label；互斥并支持重复点击取消，复用原粗细/颜色参数面板。
- 工具组实际宽度 534 pt，在原 560 pt 工具栏内居中。未扩大窗口最低宽度；普通截图和长截图都验证控件不越过工具栏、当前屏幕可见区域包含编辑窗口。
- 清空、复制、保存、贴图及关闭保留原瞬时行为。GlassView、0.02 interaction backing、WindowServer 防穿透与标题布局代码均未修改。
- AnnotationCanvasView 保存两个矢量快照栈和当前检查点；数组写时复制，不保存源图副本或导出位图。结构相同的状态不产生历史，工具选择不入历史，新内容操作清除 redo。
- 画笔、四种形状、马赛克、橡皮拖动从 mouseDown 到 mouseUp 为一次事务；文字移动及缩放手柄亦按一次拖动记录。清空和选中文字属性变更可撤销。
- 文字键入由 NSTextView 独立 UndoManager 处理；提交后进入画布历史。离开文字工具时，当前、undo、redo 中的会话文字一起转为固定矢量：撤销可恢复内容，但不会恢复旧文字的编辑权限。空白文字不入历史。
- 窗口 performKeyEquivalent 处理 Command+Z / Command+Shift+Z；NSTextView 为 firstResponder 时优先使用文字历史，markedText 状态吞掉该快捷键以避免中断输入法组合。不存在全局监听，各 editor 历史隔离。
- 画布缩放同步变换历史矢量坐标；导出仍使用原来的渲染路径。

## 验证记录（2026-09-15）

环境：macOS 26.6.2，AppKit 2685.7。

1. `swift build`：通过。
2. 最终 `swift test`：128 项，0 失败，约 274 秒；无跳过。包含 WindowServerToolbarTests 四项、文字、导出、标题与玻璃回归。
3. `swift test -Xswiftc -DLIQUID_GLASS_FALLBACK --filter 'Annotation|ToolbarInteractionShadow|Glass|WindowDecoration|ImageExport'`：34 项，0 失败。
4. 默认构建中工具栏测试实际覆盖 native / standard / opaque 后端，普通截图和长截图两种模式；fallback 编译路径覆盖 standard / opaque。
5. `git diff --check`：通过。

新增 AnnotationUndoTests 五项覆盖：六种绘制工具一次拖动一次撤销及导出 RGBA 像素精确恢复；橡皮、清空、多步 undo、新操作清除 redo、editor 隔离；文字新增、属性、移动、手柄缩放、固定会话清空恢复；原生文字 undo/redo 与 markedText 优先；缩放历史和无效工具操作。

工具栏测试从窗口根 hitTest 到真实 target/action，并通过原生 mouseDown 跟踪循环点击四个独立形状按钮。快捷键测试构造 NSEvent 并调用实际 AnnotationEditorWindow.performKeyEquivalent，而非直接调用撤销函数替代快捷键证据。

首轮全量测试发现旧测试仍依赖 NSPopUpButton，另发现图标按钮默认隐藏标题未清空；均已修正。新增文字测试关闭自动分组后进入 markedText 的测试设置曾触发 UndoManager 异常，恢复自动分组后通过。最终结果为修正后重新运行所得。

## 范围与限制

- 键盘测试覆盖真实 key-equivalent 方法，但不是硬件键盘经 WindowServer 注入的端到端输入；输入法覆盖 NSTextView markedText API，不等同于所有第三方输入法人工验收。
- WindowServer 防穿透采用项目既有生产编辑器测试；新增每个形状按钮的细粒度证据是窗口根命中与 AppKit 鼠标跟踪。未将二者混称为每个按钮都经过系统级物理点击。
- 未替换或重启用户运行的发行 App，因此运行中的旧版本不会自动获得本次改动。
- 不记录工具选择、窗口移动、画布显示缩放本身；文字编辑焦点内即使文字 undo 已空，也不会回退撤销画布。结束文字输入后可撤销画布。
- 参数变更按实际属性 action 记录；画布绘制、文字移动和缩放手柄按完整 drag 合并。历史没有固定条数上限，内存随矢量操作数量增长，但不随源位图大小按历史份数增长。
- 保留原有 560 pt 最小工具栏策略；当前屏幕几何已验证，未增加极窄虚拟显示器的自动换行布局。
