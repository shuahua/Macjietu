# 文字单次输入、长按移动与工具选中状态实施证据

## 实施范围

- 八个绘图工具均为独立的 GlassButton 纯图标 toggle，共用底形和状态回调；删除 segmented 入口，不使用 shape popup。文字图标为 `textformat`，tooltip / accessibility label 为“文字”。保持工具组宽度 534、面板外框与间距以及原有瞬时快捷按钮行为。
- 点击文字按钮提交当前对象并重新准备一次新建；新建消耗 `textCreationArmed`。输入对象外的画布点击只提交，随后的空白点击不会续建。字号、颜色等参数变化不结束输入。未安装全局鼠标监视器，不拦截系统候选窗口点击。
- CanvasTextView 接入原生 `didChangeText`、`setMarkedText`、`unmarkText`，画布接入 NSLayoutManager 布局完成回调；组合输入同步内容和布局，不重写 marked 属性或选区。解除组合后应用当前样式。布局采用真实 usedRect 和 extraLineFragmentRect，并有重入保护。
- 已完成文字在文字/空闲模式按住 0.25 秒后可移动，命中同时覆盖 editableTexts 和旧会话 shapes，不迁移固定文字、不为移动重新打开内容编辑器。短按不移动也不新建。保留长按选中后的真实字号手柄。
- timer 运行于 common run-loop mode；松手、切工具、撤销恢复、清空、缩放、dispose 和离开窗口时取消。每次长按拖动/手柄调整分别只产生一个历史事务；既有 history/future、会话固定化和显示缩放历史变换继续保留。
- 本轮没有更改 GlassView 的 0.02 交互 backing，没有提交、打包、发布或关闭用户运行中的 App。测试只清理测试进程创建的窗口。

## 已执行验证

环境：macOS 26.6.2（25G83），AppKit 2685.7。

1. `swift test`，工具超时上限 600000 ms：2026-09-15 19:35:52 至 19:40:26，130 项，0 失败，测试耗时 273.869 秒，构建成功。
2. 全量通过后补充固定文字手柄字号与 undo 断言，再执行 `swift test --filter 'Annotation|ToolbarInteractionShadow|WindowServerToolbar'`：26 项，0 失败，14.660 秒，构建成功。此次未改变生产代码。
3. `git diff --check`：通过。

### 覆盖的实际路径

- AnnotationTextTests 使用真实 NSTextView.insertText 替换输入，而非设置 string 后手动通知；覆盖长短/多行、末尾 newline、deleteBackward 删空、原生 UndoManager undo/redo、markedText 增长缩短、unmark、字号颜色保留、显示缩放。
- 鼠标事件测试覆盖单次输入外点提交、后续点击不新建、再次激活文字、短按拖动不移动、切工具/销毁取消延迟回调。
- 真实主线程 Timer 等待后验证当前会话和固定文字移动、空闲模式移动、移动 undo/redo、固定文字手柄修改真实字号及 undo。未用直接调用激活函数替代计时器。
- AnnotationUndoTests 保留所有绘图工具一次 drag 一次撤销、清空/橡皮历史、键盘 Cmd+Z/Shift+Cmd+Z 分流、组合态优先、导出像素恢复和缩放历史测试。
- AnnotationToolOptionsTests / ToolbarInteractionShadowTests 覆盖八个统一按钮、唯一选中、tooltip、根视图命中、原生 mouse tracking、参数交互、瞬时按钮和布局居中；包含 native、standard fallback、opaque 三种模式及普通/长截图窗口。
- WindowServerToolbarTests 实际运行通过：生产编辑器与参数面板在上述后端下进行窗口命中探测；透明间隙仍命中后方窗口，功能面板不穿透。

## 证据边界

- 原生 TextKit API、AppKit 鼠标跟踪和 WindowServer 探测均为自动化执行证据，不等同于人工端到端验收。
- 本轮没有人工操作系统拼音候选面板、跨屏候选窗口或第三方输入法。没有全局候选点击拦截，markedText/选区保留已有自动化断言，但不能据此宣称全部输入法候选交互已实机验证。
- 未安装或替换用户现有 App，现有运行实例不会自动获得源码修改。
- 原工作区已存在多个未提交修改和未跟踪文档；本轮在其上增量修改，仅涉及 AnnotationEditorController、相关四个测试文件及本文，不将 git 总 diff 误认为本轮独占变更。
