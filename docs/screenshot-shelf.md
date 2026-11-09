# 顶部截图架

## 使用

- 设置 → 通用 → 启用顶部截图架（持续生效）。保存后立即同步，重启仍保持；关闭清空会话缓存、窗口、计时器与监听。菜单隐藏仅临时隐藏，不修改设置。
- 鼠标顶部中央停留或默认 ⌃⌥T 显示/隐藏；有刘海使用目标屏 safeAreaInsets 和 auxiliaryTopLeft/RightArea 中间缺口，左右各扩展 40pt；无刘海宽 min(300pt, 屏宽×0.8)，夹到屏幕边界。菜单栏可见采用菜单栏高度，自动隐藏采用顶部 4pt。支持负坐标屏；快捷键不受热区限制。设置 → 快捷键可以修改或清除。
- 点击进入编辑并收起截图架；已有编辑器直接置前，已关闭则使用最新合成底图重开并更新同一卡片，不新增条目。重开保留标注外观，但原矢量标注不再可单独调整。点击不复制剪贴板；拖入支持图片或文件的聊天软件接收区即可交付原始 PNG。成功接收后移除架卡；未接受且确实拖离架区则创建桌面贴图，创建成功才移除。
- Escape 取消或松回架区保留原条目。普通纯文本框不能接收图片，不保证自动粘贴；不会申请辅助权限发送 Cmd-V，也不会因拖动清空剪贴板。

## 装饰与交互

亚麻色哑光纤维绳使用闭合变宽轮廓，中段 2.2pt、端点 0.6pt，纤维斜纹裁剪到轮廓内，不是等宽描边。顶部中央停留 120ms 展开，有图时离开不自动收起。出现时绳索和卡片从屏幕上缘落下，绳弧短暂受力下垂，卡片绕各自夹点轻摆并逐渐收稳；收起时整架向上离开，卡片滞后回摆，绳弧卸力回弹。hover 180ms 平滑放大至 1.03 并柔和回正。backing layer 保持 AppKit 标准中心，完整矩阵补偿将放大支点移到实际夹挂点。图片最大 136×104 等比显示，卡片随比例变化；小屏整体缩小，窗口固定 8pt 透明边距。

展开采用约 820ms 的欠阻尼回稳，收起约 580ms；60Hz 采样弹簧响应、绳弧松紧和各卡片的阻尼摆角。位移按卡片高度计算，不用淡入淡出伪装物体运动。窗口固定在源屏可用区域，局部 ShelfViewport 的 masksToBounds 裁剪内部绳卡运动；禁用系统位置约束不再意味着把窗口移入相邻屏。没有全屏截鼠标窗口；透明留白沿原路径穿透。按下冻结 presentation transform 并暂停整架位移，原生拖图复用同一仿射几何。减少动态直接到位；清空/暂停/停用立即清理。

实际架外 mouseDown 收起（local/global 原样放行，不申请 AX 权限），完整架区和运动中的卡片/绳窗口视为内部；mouseUp 不关闭，拖动中忽略外点。关闭后只需离开中央热区即可解除重开抑制，不要求离开整条顶部。剩余卡片及绳窗口复用，移除重排直接对齐曲线避免脱绳；最后一张取走立即清空。隐藏、暂停、停用清理监听。

外框为本地程序绘制棉麻细织纹、虚线缝线及 3pt 柔边，向图外扩展 5pt。独立装饰视图不接收命中，照片为最上方独立兄弟层，不裁角、不改 PNG；不透明织物在两种透明辅助模式下均可读，动态辅助通知仍即时更新。透明留白穿透。原 GlassView 保留辅助状态但隐藏，不叠加玻璃高光。未修改主八工具。

## 数据及拖放

- 最近六个编辑器会话，PNG 总量最多 96MiB，缩略图最长边 320 像素。后台快照沿用 300ms 去抖与 revision 校验。
- NSDraggingSource 的 endedAt/operation 是接收成功的依据，不推测目标应用名称。拖动期间不重建窗口或自动收起，结束时使用独立 session token 拒绝重复及迟到回调；隐藏、清空和停用使令牌失效。
- 移除、清空、停用为现有会话记录 tombstone，编辑器后续 add/update 不复活已取走图片。
- 同一 NSFilePromiseProvider 同时提供原始 PNG 和 file URL。临时文件位于系统临时目录 ScreenshotShelfExports，不在拖动结束时删除，以免目标延迟读取；由系统临时目录生命周期管理，可能暂占磁盘空间。promise 委托保留至 provider 释放。
- 截图暂停时隐藏架窗口；架与贴图保留现有截图排除。展示不抢焦点，不监控系统截图目录或剪贴板、不上传。

## 验证边界

### 1.0.33 / build34 本轮

- 根因：仅设置 backing layer.anchorPoint/position 与 AppKit 自动布局管理冲突；旧回归直接读配置值，未证明屏幕中的支点。现保留中心 anchorPoint，使用带平移补偿的完整 transform；hover 的完整矩阵插值也维持同一支点，拖图仿射只应用一次支点补偿。
- 越屏根因是独立 NSPanel 允许整体移出屏幕；现每个窗口与源屏可用区域取交集并加局部裁剪容器，内部运动，窗口不跨屏。capture IDs 保留到收起结束；暂停/停用立即清空。上下左右、负 origin 和尺度覆盖为确定性几何测试，并非真实混合 DPI 硬件验收。
- 绳粗细根因：原等宽粗描边以及较弱的分段宽度对比；现连续闭合轮廓 0.6→2.2→0.6pt，无金属高光/投影扩大端部。实际 NSView 离屏像素 alpha 覆盖测试断言中段大于左右近端的 1.8 倍，不只是公式检查。
- 新增非零 NSWindow origin、非零 card origin 与四个中途完整矩阵采样：实际 layer.convert→window.convertPoint(toScreen:) 验证夹点不动、下缘确实移动。生产窗口展开/收起多时刻采样、PNG/四角/透明命中/辅助选项/原生首拖仍通过。限制：中途矩阵采样不是 WindowServer presentation layer 的逐帧抓取；没有真人桌面像素支点与双屏动态截图，不能声称这些硬件验收已完成。
- 点击使用 mouseUp 有效按下且未越拖动阈值才编辑一次；AppCoordinator 复用 AnnotationEditorController，同 ID 更新，关闭后以最新 PNG 重开；失败不移除，tombstone 防复活。现存编辑器可继续调整标注，关闭重开仅保留合成外观。
- 规定脚本退出 0：swift build 0.13 秒，相关 48 项零失败 2.094 秒，全量 175 项零失败 282.402 秒，git diff --check 通过。日志 `.build/shelf-build34-check.log`。所有既有未提交保留；本轮不安装、不关闭 App、不提交、不发布。
- 中央刘海热区、持久设置/快捷键、剩余保活/外点收起、accepted/none/失败/Esc回架、PNG与文件 promise、首点拖动等回归继续覆盖。打包与校验记录见 `docs/shelf-build34-verification.md`。

### 1.0.32 中央热区、织物与绳卡同步

- 规定 check.sh 已完成：构建 1.19 秒；相关 43 项零失败，1.958 秒；全量 170 项零失败，279.302 秒；脚本退出 0，包含全量 git diff --check。日志 `.build/shelf-fabric-check.log`。
- 新增负坐标多屏、刘海/无刘海/窄屏/边缘和中央抑制测试；生产窗口 anchorPoint/position 与实际夹点校验；展开及收起多个 t 采样核对真实窗口绳曲线挂点，禁止提前 opacity 淡出；柔性上端零偏移、减少动态、按下冻结和暂停清理。已有首点原生拖动、PNG 字节、离屏照片四角/透明留白、快捷键和辅助模式测试全部保留。
- 生产采样暴露 NSPanel 默认 constrainFrameRect 会按窗口高度分别限制位置，已覆写为允许整体移出屏幕；不是只测试独立公式。像素对齐误差允许 1.1pt。外点测试兼容动画中的实际卡片区域。
- 自动离屏像素测试通过，但未额外交付织物预览图；没有真人视觉验收。织物运动为有限仿射剪切/轻压缩与阻尼摆动近似，非真实物理布料。混合 DPI、硬件拖放及 WindowServer 动态观感仍需实机确认。

### 1.0.31 摆动、hover 与展开保活

- 根因：旧 mouseEntered 清除所有动画且没有 scale；旧状态机离开 500ms 就关闭，外部拖放结束后的离开会继续触发关闭。旧拖动仅以未变换 photoRect 计算偏移，不能直接承接新增 hover。
- 改动：保留柔和摆动并新增固定挂点放大；首次 down 冻结 presentation transform，按同一仿射变换绘制原生拖图并计算包围矩形/抓取偏移，保持阈值移动。PNG/file promise 数据路径不变。减少动态禁摆动和 scale，改为静态边框高亮；减少透明度继续原有回退。
- 验证：规定 check.sh 构建通过，专项 40 项零失败（1.865 秒），全量 167 项零失败（278.556 秒），最终检查命令正常完成，git diff --check 通过。日志 `.build/shelf-motion-check-verified.log`。新增 hover 往返窗口身份、支点、独立有限动画、辅助模式、外点/松手/拖动保活、最后收起与监听清理；生产 window.sendEvent 首拖用例在 1.03 hover 下创建真实 NSDraggingSession 并核验末点尺寸/偏移。
- 前两轮专项发现旧测试用主屏顶部固定坐标代表架内不再可靠，改成 item UUID 定位的实际窗口中心后完整重跑通过；没有跳过失败断言。既有透明根层、命中、装饰裁剪、离屏四角与导出字节测试继续通过。
- 实机边界：没有真人鼠标/WindowServer 动画观感验收，未实测跨 App 接收与混合 DPI；合成事件和原生 session 测试不等于硬件验收。尤其摆动冻结的瞬时抓起、回落动画与桌面材质仍需实机观察。没有新增权限，没有改输出像素或安装/关闭现有 App。

### 1.0.30 首次按下拖动（2026-10-23）

- 已证实的代码缺口：生产 ShelfCard 从 NSView 继承的 acceptsFirstMouse 返回 false，而 acceptsFirstResponder=true、needsPanelToBecomeKey=true；ShelfPanel 的 canBecomeKey 对卡片返回 true。修复前针对 show 创建的真实窗口及 item UUID 定位的测试，首点接收/无需 key 三个断言失败（1 项，0.310 秒，`.build/shelf-first-mouse-before.log`）。这证明首点接收契约缺失，不等于已录得用户机器 WindowServer 吞事件的硬件轨迹。
- 最小修复：卡片明确 acceptsFirstMouse=true、needsPanelToBecomeKey=false，panel.becomesKeyOnlyIfNeeded=true；保留 canBecomeKey/acceptsFirstResponder 的辅助焦点能力，但 mouseDown 不再强制 makeFirstResponder，也不调用 activate/makeKey。首次按下保存位置并结束入场动画；mouseUp 只消费一次有效按下，孤立/重复松手不复制。
- 附带确认并修正：旧抓取点取自超过 4pt 阈值的 dragged 位置，会丢掉阈值移动。现在偏移来自初始 down，原生拖图初始 frame 根据当前事件位置平移，照片尺寸与末点 pin 抓取点一致；阈值仍严格大于 4pt，未提前启动拖动。
- 排查边界：root hitTest 在照片/圆角框/夹子直接返回卡片，GlassView 和独立 photoView 不成为该路径的命中对象；淡出仅作用于照片子层，不新增拦截层。hover 停动画、source fading、原生 beginDraggingSession 和 accepted/none/取消完成分支保留；无全局激活兜底。透明留白的轮询穿透及真实进入动画期间的 WindowServer 命中时序仍需硬件验证。
- 新增 3 项生产控件回归：首点接收及非激活策略；从非 key 生产窗口通过 window.sendEvent 首次 down→4pt dragged→8pt dragged 创建真实 NSDraggingSession，继续移动不重启、无 copy，验证 key/active 不变、初始抓取点及尺寸；普通 click/3pt 移动只复制一次、孤立 mouseUp 不复制。不是直接调用 completion 伪造拖动成功。完成回调用于检查末点几何和清理，随后向本测试进程队列投递 Escape/up 排空原生 tracking，不发送全局硬件事件。
- 首轮规定检查在 600 秒超时；先核实仅本轮 xctest PID 49773 残留并采样，栈证明测试未排空的延迟 NSCoreDrag tracking 进入后续工具栏测试（`.build/shelf-first-mouse-timeout.sample.txt`），仅终止该测试进程。修复测试清理后，首点拖动+后续工具栏 2 项通过（2.596 秒），未改用户 App 或工具栏代码。
- 最终执行规定 check.sh，正则 `ScreenshotShelfTests|WindowDecorationRegressionTests|SettingsShortcutCustomizationTests|ImageExportTests`：构建通过；相关 38 项零失败（1.952 秒）；全量 165 项零失败（273.216 秒），2026-10-23 18:03:44 完成；脚本退出 0，含全量 git diff --check。日志 `.build/shelf-first-mouse-check-final.log`。覆盖命中、透明根层、装饰裁剪、离屏四角与原图导出字节、设置/快捷键/截图排除及拖动结果状态。
- 未完成真实 WindowServer 硬件验收：其他 App 持有键盘时悬停展开后的首拖、菜单栏不变、跨 App 接收、Escape、桌面 pin 连续性、混合 DPI 和动画观感仍需真人复测。合成 sendEvent/原生 session 创建不是跨应用硬件验收；没有申请额外权限。
- 打包：读取实际 version-state 为 1.0.29/30，执行 `bash scripts/build-app.sh release release-notes-next.md` 退出 0，release 构建 7.55 秒，产物 `dist/截图Free-v1.0.30-build31.zip`；`unzip -t` 无错误，PlistBuddy 输出 1.0.30/31，`codesign --verify --deep --strict --verbose=2` 通过，git diff --check 通过。日志 `.build/shelf-first-mouse-release.log`。未安装、关闭现有 App、提交或发布。

### 1.0.29 拖动连续性

根因：原生拖图虽然使用照片矩形，但源照片没有让位；结束时贴图走默认居中与重新定尺寸路径；移除后 show 销毁所有窗口并重播入场。

修复：原生 session 使用同一 thumbnail 和 photoRect，记录事件在照片上的抓取偏移，以 AppKit 全局屏幕坐标计算末点矩形，专门传给贴图显示入口；原 PNG 不缩放重编码，其他贴图入口仍默认居中。源照片短淡出，夹子与外框留架；跟随期间不编码 PNG、不模拟全局鼠标。Escape/架内回落启用系统取消动画，架外 none 关闭回弹以接续贴图，accepted 不添加假飞入。稳定 ID 复用剩余卡片窗口，只做位置迁移，不重播摆动。

隐藏/清空/停用/暂停使 session token 失效，移除活动源先清理拖动；清理源照片动画和 Escape 监听，不使用延迟 completion 复活窗口。减少动态跳过淡出/重排/回弹，减少透明度沿用原回退。

最终检查：专项 34 项零失败（1.169 秒），全量 162 项零失败（275.346 秒），规定脚本退出 0，包含 swift build 与全量 git diff --check。新增生产入口回归覆盖负屏坐标抓取点到 pin、原像素保留、防重复拖动、卡片身份复用、暂停迟到、动画清理与减少动态。系统窗口边界允许 1pt 像素对齐误差。日志：`.build/shelf-continuity-check.log`。

限制：原生 session 的实际抓起、回弹时序、跨 App 接收、Escape 事件路由与混合 DPI 仍未真人桌面验证；自动测试不等于这些路径的视觉验收。

自动测试覆盖设置即时同步及重新加载、快捷键迁移/冲突/清除/菜单、accepted/none 外部/内部/Escape/贴图失败/清空/关闭/迟到回调及 tombstone、实际 NSPasteboard 的 PNG/URL/promise 类型和文件字节、原图四角、框几何、透明命中与辅助选项。

2026-10-23 最终规定检查脚本完成：相关 38 项零失败（1.554 秒），全量 160 项零失败（284.446 秒），构建与 git diff --check 通过。原有未提交修改保留。测试期间发现并修复 NSFilePromiseProvider 子类初始化崩溃及新增第七快捷键导致旧菜单测试越界；最终完整重跑通过。

拖动完成分支通过生产入口确定性测试，未以真人鼠标完成 WindowServer NSDraggingSession 跨应用交付；不能把这些测试当作跨应用兼容性验收。真实桌面玻璃观感、多屏混合 DPI、macOS 13、聊天软件接收和系统拖动期间 Escape 事件路由仍需实机验收。全局 Escape 受系统已有监听权限约束；没有额外请求权限。离屏像素检查不代表桌面材质观感已通过。
