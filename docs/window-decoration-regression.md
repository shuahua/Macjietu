# 窗口装饰缺陷修复验证

验证日期：2026-09-14。保留工作区原有改动；未提交、未打包、未重启或关闭用户运行中的 App。项目及上级目录未找到 AGENTS.md。

## 根因与处理

- 设置：原先仅使原生标题栏透明，未采用 fullSizeContentView，也未开启背景拖动；效果视图仍参与鼠标命中。现在材质贯穿标题区，隐藏重复原生标题，开启 isMovable/isMovableByWindowBackground；设置根视图支持 performDrag，纯装饰材质和遮罩不接收命中。控件继续作为前景兄弟视图接收事件。
- 半透明：原有 behindWindow 配置已存在，窗口和根层也已清底，不应误称这两项原先缺失。主要应用内遮挡是材质之上 0.72 alpha 的 windowBackgroundColor 遮罩；降至 0.18，保留系统材质和不透明前景文字。减少透明度开启时仍用不透明遮罩及 inactive 状态；测试仅调用内部入口，不修改用户系统偏好。
- 编辑器四边/四角：矩形图片 draw 与未裁剪的圆角画布、1 点边框、画布阴影和整窗阴影叠加；长图视口还有未裁剪圆角。画布改为无边框、无阴影的矩形边界裁剪，长图关闭 clipView 底色并保持矩形视口；移除整窗复合阴影。工具栏材质继续圆角裁剪，补齐形状控件、色块和缩放手柄的装饰裁剪；遮罩 draw 也显式圆角裁剪。
- 未改 renderedImage、ImageEncoding 或图片裁切路径；原始截图的矩形四角保留，不以裁掉图片像素掩盖 UI 问题。

## 已执行证据

- swift build：成功。
- swift test --filter 'WindowDecorationRegressionTests|GlassViewTests|AnnotationToolOptionsTests'：8 项通过，0 失败。
- swift test：93 项通过，0 失败，271.615 秒（超时上限 600 秒）。包括原有批注、Retina 导出、长图性能与像素测试。
- git diff --check：通过；检查了现有工作区 diff，原有其他修改仍保留。
- 新测试 WindowDecorationRegressionTests：标题区几何、背景拖动能力、装饰命中穿透、复选框/弹出按钮命中和 action 保留；普通/长图透明根层、边界及装饰裁剪；渐变源位图导出全部字节一致；画布离屏缓存四角 alpha 为 1。
- 浅色/深色遮罩离屏合成：正常中心 alpha 约 0.18，减少透明度中心 alpha 为 1；四角 alpha 为 0。原有 GlassViewTests 保留文字 alpha、颜色、辅助功能切换与多个窗口材质安装验证。

## 验收限制

测试在 AppKit 测试进程创建窗口并验证布局/命中，未执行真人鼠标拖动或 WindowServer 桌面背景前后对照截图。离屏缓存验证的是遮罩和画布，不代表系统 behindWindow 磨砂采样视觉验收。实际壁纸下磨砂强度、拖动连续性和多显示器缩放仍未实机验收。设置拖动的代码路径已补齐，但不将配置与 hitTest 通过描述成真实拖动位移通过。
