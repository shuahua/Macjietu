# 设置与快捷键自定义实现记录

## 真实默认来源

改造前 `AppCoordinator.registerShortcut()` 仅注册四项；区域读取 `AppSettings.captureShortcut`，其余三项直接使用 `Shortcut.swift` 常量。手动长截图和录屏只存在菜单入口，没有热键。

| 功能 | 旧默认 | 物理 keyCode | 修饰键 |
| --- | --- | --- | --- |
| 区域截图 | ⇧⌘S（已有用户值优先） | 1 | command、shift |
| 窗口截图 | ⌃⇧W | 13 | control、shift |
| 全屏截图 | ⇧⌘F | 3 | command、shift |
| 长截图自动滚动 | ⌃⇧S | 1 | control、shift |
| 长截图手动滚动 | 未设置 | — | — |
| 录屏 | 未设置 | — | — |

## 配置与注册

- `AppSettings.shortcuts` 缺失时按旧格式解释。第一次修改任意快捷键，复制所有现有有效映射到字典，再修改目标项。
- 字典存在时缺少某功能键表示明确未设置；空字典表示全部清除，重启不补默认。旧 `captureShortcut` 字段保留供格式兼容，但新运行路径只读 `shortcut(for:)`。
- 通用设置在已加载配置上修改，保留快捷键、保存目录、原始倍率、开机启动与剪贴板行为。
- `ShortcutBindings` 为每个功能持有独立 Carbon 注册器。新组合先注册成功、再原子写盘、最后撤销该功能旧注册；注册失败或写盘失败保留旧配置和其他功能注册。本应用重复组合明确拒绝。
- Carbon 注册 ID 改为进程内唯一；事件签名/ID 不匹配返回 `eventNotHandledErr`，允许同目标上的其他注册器处理。事件处理器安装失败也报告不可用。
- 录入期间撤销本应用热键注册，并以 suspension 和 generation 拒绝旧回调。取消、失焦、切换分类、关闭窗口恢复注册；恢复失败保留配置并在界面标识不可用，而非声称成功。
- 菜单与设置统一显示持久化映射和真实注册状态。启动恢复四项默认或六项用户映射，不申请额外权限。

## 界面与录入

- 左侧通用/快捷键/关于导航，右侧内容，窗口为 740×480；标题正文保留系统安全区，背景可拖动。
- 使用现有 `GlassView` 原生/fallback/减少透明度后端，保留 0.02 交互 backing 与原有减少动态效果策略，不调整整个窗口 alpha。
- 六个功能名称与按键按钮均可进入录入，每行有明确清除按钮。按 Escape 取消；Delete/Backspace 不隐式清除，避免与实际组合键混淆。
- 仅在录入期间安装本应用局部 keyDown/flagsChanged monitor；按键被消费，不传播至本应用菜单快捷键。离开设置焦点停止录入；无全局键盘监听、无一般键盘记录。
- 存储物理 keyCode 与 command/option/control/shift，忽略 capsLock 等状态；显示 ⌃⌥⇧⌘、物理 ANSI 键名、方向键/功能键/数字及小键盘。不会依赖 `characters`，切换输入法不改变绑定；非 ANSI 布局的字母标签不是动态布局翻译。
- 单独修饰键不提交；普通组合要求 command/option/control 至少一个，F1–F20 可无修饰。系统保留、其他应用占用或不可注册组合显示错误并保留旧值。
- 关于正文仅为“免费截图工具，全部由AI生成，sang。”。
- `AppCoordinator.dispatchShortcut` 六分支分别进入区域、窗口、全屏、自动长图、手动长图、录屏选区；快捷键仅启动，不结束会话。有长图/录屏或相关选区/配置会话时直接拒绝新的快捷键启动。

## 验证记录（2026-09-15）

- `swift build` 通过；未打包、未提交、未重置工作区，也未关闭或替换用户运行中的应用。
- 按已有 appkit-decoration-regression 的 `scripts/check.sh` 执行构建、相关测试、全量测试及 `git diff --check`。最终原生构建相关测试 14 项通过（10.205 秒），全量 116 项通过（267.346 秒），无失败。
- `swift test -Xswiftc -DLIQUID_GLASS_FALLBACK --filter 'SettingsShortcutCustomizationTests|ShortcutManagerTests|WindowDecorationRegressionTests|WindowServerToolbarTests|GlassViewTests|LiquidGlassAdoptionTests'`：20 项通过（9.187 秒）。随后补充事件处理器安装失败门禁及重开设置测试，并重新通过原生全量。
- 新增 `SettingsShortcutCustomizationTests` 覆盖旧配置默认与用户值、全部清除持久化、重复冲突、注册失败、写盘回滚、六动作分发、暂停及过期回调屏蔽、录入取消/失焦/切页恢复、键码格式、六项显示、关于精确文本及关窗重开。
- 更新标题/背景/控件命中回归，保留现有其他断言；新增设置三分类的可见 WindowServer 稠密网格检查，原生、标准材质和不透明后端全部通过。
- WindowServer 新测试首轮普通层级窗口被测试 probe 的后台排序遮挡，导致误报；仅将测试所拥有的设置窗口临时提升到 floating 后复测通过，生产层级仍为 normal。此结果证明材质区域命中，不等价于前台普通层级人工操作验收。

## 未实机验收与边界

- 未向用户应用发送全局键盘或鼠标事件；快捷键注册错误与六动作派发使用注入替身测试，没有实际启动系统截图或录屏验收。
- 未实测各系统保留快捷键/第三方热键占用矩阵；实际结果依 Carbon 返回状态，无法保证所有外部监听式快捷键都能被操作系统判定为冲突。
- 未在 macOS 13 真机运行；已验证部署目标仍为 macOS 13，并通过当前系统下 fallback 编译/运行。原生玻璃后端在当前环境实际参与 WindowServer 检查。
- 未人工验收磨砂观感、鼠标拖动、不同键盘布局/硬件 Fn 行及完整物理键盘录入；这些不能以离屏布局测试替代。
- 旧格式若本来含有互相冲突的绑定，迁移保留而不擅自改值，注册失败会显示不可用。退出旧版本再运行新构建时才会看到改造，当前已运行应用未热替换。
