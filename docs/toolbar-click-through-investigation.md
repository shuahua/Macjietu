# Liquid Glass 工具栏点击穿透调查

日期：2026-09-14。范围：共享 GlassView、截图编辑/标注参数和录屏工具栏。本文记录代码与回归结果，不代表已安装版本完成实际鼠标或视觉验收。

## 结论与修复

在本机原生玻璃后端的真实可见测试窗口中，已复现：布局正常且 AppKit `root.hitTest` 非空，但系统窗口命中查询返回下层窗口。仅修改 `hitTest` 无法解决事件尚未进入前景窗口的问题。

共享 `GlassView` 的功能面板增加黑色、alpha 为 `0.02` 的 layer backing；原生玻璃、材质、控件前景和阴影逻辑保持不变。没有给整个透明窗口或外部根视图填色，也没有降低整窗或控件 alpha。此值是本机验证有效的值，不宣称是所有系统的最小阈值；轻微底色的主观视觉影响尚未截图验收。

生产改动：`Sources/截图Free/GlassView.swift:8-10,38`。本轮未再次修改 `hitTest`，也未修改导出像素路径。项目已有未提交及未跟踪改动均保留；没有提交、打包、安装或重启用户应用。

## 运行身份及证据边界

- 调查时运行 PID 为 `33078`，NSWorkspace 返回 `/Applications/截图Free.app/`；独立读取安装包 Info.plist 得到版本 `1.0.13`、build `14`。不能将用户反馈归因于旧包。
- 本机 macOS `26.6.2`（`25G83`），SDK `26.5`；普通测试实际输出 `backend=native`。
- 测试进程只读检查 AX、全局事件投递、屏幕捕获权限均为 false；这不是用户 App 的权限状态。未申请或绕过权限。
- `CGWindowListCopyWindowInfo(.optionAll, 0)` 未列出上述用户进程窗口；不能据此断言用户编辑器是否打开。`kCGWindowAlpha` 是整窗属性，不是逐像素命中证据。
- 已查阅近期日志，但没有可归属到该用户窗口的一次真实点击分发链路。应用日志也会由生产控制器测试写入，不能用测试日志证明用户 App 收到点击；本次根因证据来自隔离窗口负对照。

## 系统窗口命中负对照

使用公开 API `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`，查询屏幕坐标处鼠标按下会命中的最前窗口。官方定义为 “Returns the number of the frontmost window that would be hit by a mouse-down at the specified screen location.”

官方参考：<https://developer.apple.com/tutorials/data/documentation/appkit/nswindow/windownumber(at:belowwindowwithwindownumber:).json>

测试仅创建自己的透明前景窗口与同级白色背景 probe，按窗口编号排列；布局、显示、提交 CATransaction 并等待 RunLoop 后查询。不投递鼠标事件、不点击用户应用。

1. 功能玻璃有 backing：工具栏内部返回前景窗口编号；外部透明留白返回 probe。
2. 在相同窗口、原生材质、坐标下移除 backing：`root.hitTest` 仍非空，系统查询却返回 probe。
3. 恢复 backing：同一点重新返回前景窗口编号。

2026-09-14 18:55 的普通构建复核：前景编号 `11624`，probe 编号 `11623`；内部 `(100,60)` 返回 `11624`，外部 `(10,150)` 返回 `11623`。包含移除/恢复断言的测试通过。负对照仅在 native 后端执行，fallback 结果不冒称覆盖原生负对照。

## 回归覆盖

新增 `Tests/截图FreeTests/WindowServerToolbarTests.swift`：

- `testVisibleWindowServerProbe`（第16行）：上述系统查询及负对照。
- `verify`（第61行）：功能区内缩后的稠密网格、全部 NSControl 中心及分段采样；透明外部留白；窗口可见性、忽略鼠标标志、整窗 alpha、非零 host、AppKit 控件命中与背景不拖窗。
- `testProductionEditorsParametersAndRecordingPanels`（第113行）：普通/长图截图编辑器、生产 action 创建的标注参数面板、录屏设置及录屏控制。截图窗口按创建前后对象标识差集及标题定位。
- 普通编译轮换 native → standard → opaque → native；强制 fallback 编译轮换 standard → standard → opaque → standard。

`AnnotationToolOptionsTests` 与 `WindowDecorationRegressionTests` 仅将功能玻璃的背景 alpha 契约改为共享常量，外部透明根层/窗口背景 alpha=0 的断言保留。原有 target/action、装饰及导出回归继续运行；target/action 调用不等于系统鼠标跟踪。

## 已执行验证

所有以下已核实命令均成功返回；本轮最终 `git diff --check` 无输出、退出成功。

| 验证 | 结果 |
| --- | --- |
| 已加载装饰回归 skill 的 `scripts/check.sh`：普通构建、相关测试、全量测试、diff 检查 | 成功；相关 20 项，0 失败，8.235 秒；全量 105 项，0 失败，274.159 秒 |
| 强制 fallback 相关回归，含 ImageExportTests（18:54 重跑） | 构建成功；25 项，0 失败，7.040 秒；diff 检查成功 |
| 恢复普通编译后 WindowServerToolbarTests（18:55） | 构建成功（3.61 秒）；2 项，0 失败，5.091 秒；输出 native；diff 检查成功 |

普通全量结果来自保存输出 `tool_g1a09f8aee68001Wuf3EFohjnh` 第390–400行；其中最后另一个测试框架的“0 tests”提示不替代 XCTest 的105项结果。上一轮 fallback 的截断结果未计入；确认没有残留测试进程后重新执行，以本次可核实输出为准。

复核命令（项目根目录）：

```sh
swift test -Xswiftc -DLIQUID_GLASS_FALLBACK --filter 'WindowServerToolbarTests|RecordingToolbarInteractionTests|GlassViewTests|LiquidGlassAdoptionTests|ToolbarInteractionShadowTests|WindowDecorationRegressionTests|AnnotationToolOptionsTests|ImageExportTests'
swift test --filter WindowServerToolbarTests
git diff --check
```

## 尚未验收的范围

已确认本机系统窗口命中层的可复现失败及修复效果，不仅是离屏 `hitTest`。但没有实际 CGEvent 鼠标投递、菜单/popover 原生鼠标跟踪或桌面截图证据，不能声称用户安装版已修复或视觉效果已验收。未打包安装意味着运行中的 build14 不包含此次源码修复。

剩余端到端验收需在用户允许的发布/运行与权限条件下，实际操作截图、参数和录屏控件、检查菜单及留白穿透，并观察真实玻璃和柔阴影；本次不越过这些限制。
