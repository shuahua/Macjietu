# 1.0.33 build34 验证记录

## 自动验证

规定 check.sh 项目参数为当前仓库，相关正则 `ScreenshotShelfTests|WindowDecorationRegressionTests|SettingsShortcutCustomizationTests|ImageExportTests`。退出 0；构建 0.13 秒；相关 48 项零失败 2.094 秒；全量 175 项零失败 282.402 秒；包含 diff 空白检查。完整日志 `.build/shelf-build34-check.log`。

闭合绳轮廓由 NSView 实际离屏渲染，检查中段与两端像素 alpha 覆盖差异。生产卡片及非零原点窗口用完整变换中途采样验证全局支点与下缘运动。几何矩阵插值不是 WindowServer presentation layer 逐帧采样；尚无真人双屏、混合 DPI、真实透明区域穿透、跨应用拖放和动态观感验收，不宣称已通过。

## 打包

打包前实际 version-state：1.0.32 / 33。目标自动递增为 1.0.33 / 34。不安装、不关闭现有应用、不提交或发布。打包命令及签名、ZIP 与 plist 校验结果记录在 `.build/shelf-build34-release.log` 与 `.build/shelf-build34-package-verify.log`。
