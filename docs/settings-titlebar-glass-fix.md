# 设置窗口标题安全区与磨砂修复证据

验证时间：2026-09-14。环境：macOS 26.6.2（25G83）。

## 根因与修改

- 原 SettingsWindowController 使用 fullSizeContentView、隐藏系统标题，但仍将自绘标题直接放在根视图固定 y=154、height=28；未使用标题栏安全区。原回归测试只检查按钮，遗漏标题与 traffic lights 的 frame。用户报告的 840×400 图片符合此类安全区问题，但不能据此认定正在运行的二进制与工作区源码完全一致。
- 新实现将原有 200 点正文完整保留，正文顶部约束到 contentLayoutGuide 下方 8 点，按实际标题栏高度增高窗口；当前系统窗口实际为 420×240 点。标题与控件原有尺寸及相对间距不变。
- SettingsBodyView 的空白和非编辑标签不抢命中，交给 GlassView 的 performDrag 路径；复选框和弹出菜单正常命中。makeWindow 与 show 分离用于不可见窗口布局验证。
- 源码的 NSWindow 已设置 isOpaque=false/backgroundColor=clear，标题栏透明，根 layer 背景透明，behindWindow 配置正确。没有发现源码中的额外实底窗口层。原 popover 材质叠加 0.18 系统背景色遮罩有增加实底观感的因素；改为 hudWindow 和 0.06 遮罩，前景文字保持 alpha=1、系统语义文字色。此 GlassView 为共享组件，其他采用它的控制窗口也会改变材质，相关回归测试已覆盖。
- 减少透明度仍由系统通知驱动：开启时遮罩 alpha=1、效果 inactive，关闭后恢复 active/0.06；没有修改系统辅助功能设置。

## 只读系统与运行版本核验

- defaults read com.apple.universalaccess reduceTransparency 返回该键不存在，不能单独据此判断关闭。
- AppKit NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency 实际返回 false；新建 GlassView 初始状态与该值一致。
- ps 确认 PID 1686 执行 /Applications/截图Free.app/Contents/MacOS/截图Free，启动时间为 2026-09-14 16:39:43。
- 只读该应用 Contents/Info.plist：CFBundleShortVersionString=1.0.10，CFBundleVersion=11。核验结束时 PID 与启动时间不变。未替换已安装应用，运行中的进程未加载本轮修复。

## AppKit 实测（窗口基坐标，单位为点，非截图像素）

- 窗口 frame.size=(420,240)，contentLayoutRect=(0,0,420,208)。
- 标题 frame=(20,154,360,28)，顶部 y=182。
- closeButton frame=(9,217,14,14)。
- miniaturizeButton frame=(32,217,14,14)。
- zoomButton frame=(55,217,14,14)。
- 标题与三个标准按钮均无交集，垂直净距 35 点。三个内容控件均在标题下方，提示文本和标签完整落在根视图内。
- 测试通过创建前后 ObjectIdentifier 差集、窗口标题以及 makeWindow 返回实例定位目标；设置布局测试窗口不显示。
- 标题栏空白、正文空白、标题标签命中 GlassView；三个内容控件命中自身或子视图，保留 action 和 enabled 状态。
- 亮/暗外观下检查透明根层、语义文字色、前景不降 alpha；减少透明度 false→true→false 可恢复。离屏绘制遮罩中心 alpha 分别约 0.06/1，圆角外 alpha=0。

## 验证执行

执行已加载 AppKit 回归技能的 scripts/check.sh，依次运行 swift build、swift test --filter 'GlassViewTests|WindowDecorationRegressionTests|AnnotationToolOptionsTests'、swift test、git diff --check。

- 初次相关 6 项通过；初次全量发现 AnnotationToolOptionsTests 仍断言旧 popover 材质（2 个测试内 18 处失败），已将共享材质预期改为 hudWindow，未削弱命中或透明性断言。
- 最终 swift build：退出 0，0.13 秒。
- 最终相关测试：8 项、0 失败，0.713 秒。
- 最终全量测试：93 项、0 失败，269.424 秒。
- 脚本最终退出 0；随后再次 git diff --check 退出 0。
- 本轮仅编辑 SettingsWindowController.swift、GlassView.swift、三个相关测试文件及本文档；其他已有修改保留。未提交、未打包、未关闭已安装应用。

## 验证边界

没有真实桌面视觉验收，没有对运行中应用进行屏幕截图或真实鼠标拖动。命中与拖动入口测试不等同于 WindowServer 的真实拖动验收。其他已有 AppKit 测试会显示各自测试进程创建的窗口，但不会关闭用户运行中的应用。

单色截图或离屏遮罩 alpha 不能证明系统 behindWindow 材质是否正确采样桌面，也不能证明 HUD 的最终主观磨砂强度或所有背景上的可读性。已确认当前系统减少透明度不是开启状态；材质叠加是源码层面的可解释因素，不将其宣称为截图实底的唯一已证实原因。
