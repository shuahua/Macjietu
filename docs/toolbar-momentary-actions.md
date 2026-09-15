# 工具栏四命令瞬时反馈修复

## 结论与范围

2026-09-15：只为清空 trash、复制 doc.on.doc、保存 square.and.arrow.down、贴图 pin 显式配置 momentaryPushIn 和局部 cell 样式。关闭按钮、绘图/文字 segmented、形状 popup、sidebar、settings、录屏及其他 GlassButton 保持原路径。没有 makeIconButton；当前工厂名为 addIconButton，入口为 addStandardToolbar。仓库内未找到 AGENTS.md。

原共享反馈把 focus 映射为 0.18 蓝色填充，hover 为 0.08，state 非 off 为 0.14，并有释放淡出动画。因此 state off 并不等于视觉未选中；不能只在 onClick 异步清理。原工厂没有显式设置 button type，使用 rounded 原生 bezel。没有证据证明用户截图中四个按钮全部实际 state.on，不能把视觉蓝底直接等同于状态错误。

局部配置显式设置 momentaryPushIn；原生 cell 保留 pushInCellMask 跟踪高亮，但 showsStateBy 为空，绘制不调用原生 bezel，避免默认/accent/focus 的填充来源。只有按住时反馈层 opacity 为 0.22，hover 和 focus 均不增加填充；focus 由 cell 绘制细描边。释放没有淡出动画，立即归零。

sendAction 调用业务之前及之后同步清理 off/highlight；mouseDown 原生跟踪返回时同样清理，覆盖拖出取消无 action；performClick 覆盖键盘和辅助功能调用。没有重写鼠标跟踪循环或自行派发 action。原生 cell 的 highlight(_:withFrame:in:) 也刷新反馈，因为仅监听 isHighlighted setter 不足以观察 AppKit 跟踪变化。

GlassView 未修改，既有 0.02 WindowServer 防穿透底层和无水滴状态保留。没有更改版本、提交、打包或关闭用户运行中的 App；测试仅清理自己创建的窗口。保留任务开始前的其他工作区改动。

## 回归证据

- 新增 testFourMomentaryActionsReleaseCancelRepeatAndKeyboard，使用实际编辑器中的四个按钮，以无副作用 ActionProbe 替换 target/action，不执行用户清空、剪贴板写入、保存面板或贴图业务。
- native、standard fallback、opaque 三种后端分别执行按下/释放、拖出释放取消、连续点击。从根视图命中后调用真实 mouseDown，队列提供 drag/up，未用直接 action 替代鼠标跟踪。
- 通过反馈 CALayer opacity 观察实际按压阶段达到 0.22。每次返回断言按钮及 cell state off、cell 未高亮、反馈 opacity/level 为零、无反馈动画、视图 alpha 为一。action 内也检查 off 和未高亮，正常点击恰好一次、取消零次。
- 空格 keyDown 和 performClick 均执行一次并恢复；文字选中和形状选中持久状态保留；关闭未启用局部样式。已有绘图、toggle、sidebar、录屏和 WindowServer 回归一起运行。
- 定向新增测试通过。全量 swift test：123 tests、0 failures，270.590 秒；包含构建、四个 ToolbarInteractionShadowTests 以及 WindowServerToolbarTests。git diff --check 通过。

## 调试过程与限制

最初测试事件生成顺序导致 up 时间戳早于 down，AppKit 忽略陈旧释放并等待；两次超时后核验并终止的仅为对应 xctest 进程。修正事件时间顺序后不再挂起。另修复错误的 first sublayer 假设，按层名称定位反馈层；按压观察改用真实 CALayer opacity，并补全 cell highlight 方法通知。

证据是本机 macOS 26.6.2 / AppKit 2685.7 的原生事件跟踪、状态及图层断言，不冒称已在用户当前运行的旧二进制上生效，也未进行用户真实鼠标人工视觉验收。旧 macOS 的原生外观仍需对应机器验收。
