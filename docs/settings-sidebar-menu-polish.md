# 设置侧栏与菜单修复事实记录

日期：2026-09-15。目标由工作区 Package.swift、AppCoordinator、SettingsWindowController 确认。项目内未发现 AGENTS.md；检查了上级目录。开始时存在大量已修改及未跟踪文件，本轮只增量修改下列相关文件，没有 reset、提交、打包或重启用户 App。

## 根因与落地

1. 菜单调用 ShortcutBindings.display(for:)，把设置页的“未设置”和注册状态后缀直接拼入标题，并且 keyEquivalent 为空。现从 SettingsStore 读取实际绑定，普通键、功能键、方向及控制键交给 keyEquivalent/keyEquivalentModifierMask；无绑定只有动作名且 modifierMask 为空。无法准确表达的小键盘/未知物理键使用已有 displayString 文本降级，不伪造按键。设置页 display 和未设置提示未改变。
2. 之前只在 menuWillOpen 重建，已创建菜单不会随设置写入立即刷新。新增成功写盘并切换注册后的 onChange，同步更新状态菜单；失败不通知、不覆盖旧配置。打开菜单仍重新读取，无硬编码默认残留。
3. 分类按钮使用 rounded native bezel，同时 GlassButton 叠加 bounds.insetBy(2,2)、radius=7 的反馈层。两套不同底形导致底层露出。仅侧栏改为 SidebarButtonCell 单一 bounds 圆角底形，不绘制 native bezel、不显示反馈层；选中、未选中、hover、pressed 共用 frame，focus 只在同底形内描边。其他 GlassButton 不变。
4. 替换 cell 的首轮回归发现 target/action/tag 会随 cell 丢失，已显式保存恢复并加入 performClick 分类切换断言。首轮也修正了 AppKit 不存在的 opaqueSeparatorColor API，最终采用 separatorColor 的不透明变体。
5. 设置正文增加独立被动分隔视图：frame=(164,20,1,366)，位于侧栏右缘152和正文左缘176之间；上下留白，不进入标题区。支持动态深浅色、系统减少透明度通知，hitTest 返回 nil。

## 修改范围

- Sources/截图Free/AppCoordinator.swift：菜单实际快捷键列、写后同步刷新、测试注册工厂注入。
- Sources/截图Free/Shortcut.swift：菜单键字符转换；displayString 保持原语义。
- Sources/截图Free/ShortcutBindings.swift：成功更新通知。
- Sources/截图Free/SettingsWindowController.swift：侧栏专用底形接入、正文标识、被动分隔线。
- Sources/截图Free/GlassInteraction.swift：侧栏单一绘制及状态处理；保留 cell 的动作属性。
- Tests/截图FreeTests/SettingsSidebarMenuPolishTests.swift：新增六项测试。

GlassView.swift 未改，interactionBackingOpacity=0.02、材质、标题安全区和窗口拖动配置保留；没有恢复已取消的胶囊布局。

## 验证结果

所有长命令 timeout=600000ms，均自然退出，无运行中的后台测试。

- 最终 swift build：通过，1.85秒。
- 相关 swift test：25项、0失败，10.597秒。
- 全量 swift test：122项、0失败，275.723秒。
- swift test -Xswiftc -DLIQUID_GLASS_FALLBACK --filter 相关测试正则：25项、0失败，9.538秒。之后恢复默认编译并执行上述最终 build/相关/全量测试。
- git diff --check：通过。
- 默认验证使用已有 appkit-decoration-regression/scripts/check.sh 顺序执行 build、相关、全量和 diff 检查。相关正则：SettingsSidebarMenuPolishTests|SettingsShortcutCustomizationTests|PermissionMenuTests|WindowDecorationRegressionTests|WindowServerToolbarTests|LiquidGlassAdoptionTests|GlassViewTests。

## 证据层级

- 菜单六动作逐一验证初始绑定/未绑定、清除、首次绑定、改绑、再次清除；同一个生产菜单对象在不重新打开时立即更新，selector/target 不变，设置与退出快捷键保留；注册边界使用 fake，不占用用户热键。
- 侧栏 performClick 验证三分类动作，原生/standard/opaque 往返验证 frame、左右内容不重叠、按钮中心及左右边缘命中、分隔空白交给根视图；focus 与 label/icon rect 在切换后不漂移。
- 离屏执行生产 SidebarButtonCell.draw，在 aqua/darkAqua、透明/opaque、选中/未选中、hover/pressed 往返中检查透明四角、整条水平及垂直中线 alpha 一致（包含旧 inset 边缘），回到初始状态 PNG 字节相同。另验证分隔线深浅色下透明/不透明像素。不是仅检查布尔状态。
- 已有 WindowServerToolbarTests 在本轮运行：创建并验证测试拥有的设置窗口对象及标题，三分类分别经过 native→standard→opaque→native，稠密网格和控件点查询到正确 windowNumber。默认构建确实返回 native，fallback 编译返回 standard/opaque。

## 未实机验收限制

离屏像素证明绘制轮廓及无残留，不等于真实桌面材质美观度验收。WindowServer 证明可见测试窗口的系统命中，不等于真实鼠标端到端点击、键盘导航或人工拖动验收。没有截取用户桌面、未对最终设置页进行人工视觉评价；label/icon 验证是几何而非文字像素审美。没有启动新用户 App，因此正在运行的旧二进制不会因源码修复自动变化。菜单非美式键盘布局的系统字符匹配仍需实机核验，设置继续按物理键位显示。
