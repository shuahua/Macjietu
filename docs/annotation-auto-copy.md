# 标注自动复制

## 实现与文件边界

- `ClipboardService.swift`：唯一全局仲裁器，可注入 pasteboard、快照/编码器。普通截图、长截图初始复制、标注自动复制和手动复制都从 AppCoordinator 的共用编辑入口接入。
- `AnnotationEditorController.swift`：会话 UUID；透传内容 revision；复用现有 history transaction，在 stroke/shape/eraser/文字移动和 resize 结束、clear、样式、undo/redo 后通知。文字稳定输入由内容去重和 180ms debounce 合并，不改变原有 one-shot/工具统一状态。
- `AnnotationRasterizer.swift`：主线程只取源 CGImage、画布尺寸、矢量值；串行后台队列合成及 PNG 编码。不携带 NSView、选框或手柄。自动快照不调用 commitTextEditing/unmarkText；markedText 期间不导出，组合结束后的有效内容再通知。
- `SettingsStore.swift`：保存成功后发送通知；仲裁器核对 store 身份，立即取消关闭选项前的自动请求。不开启选项时不自动复制，重新开启不会擅自复制旧编辑。

## 多窗口/外部剪贴板策略

系统剪贴板只有一个当前内容，不按窗口创建多个槽。

每次有效新操作在请求时取得全局 token，绑定 owner UUID、内容 revision、设置 generation 和请求时的 changeCount。新请求立即取消旧 debounce/排队编码；提交时再次核对全部字段及 changeCount。

- A 的旧结果不能覆盖 B 的更新请求，不论哪张图先编码完。
- 外部复制发生在请求之后，则该请求结果丢弃；不把编码完成误当新用户意图。
- 外部复制后，用户在 A 主动完成新标注可以取得新 token，合理成为最新意图。
- 手动复制不受自动选项约束，取消待处理自动请求并成为最新意图；若手动请求之后发生外部复制，仍尊重外部更新。
- 关 A 只取消 A 当前请求；不取消 B、不清剪贴板。完成/保存/取消/关闭均经过编辑器拆除回调。退出不清他人内容。
- 初始复制不再有“编辑器已关闭则回退复制源图”的过期路径。贴图仍使用原有 editor renderedImage。

## 替换事务与失败

只有完整 PNG 已准备好、请求验证通过，才在主线程连续执行 clearContents 和 setData；两者之间没有 await/调度/渲染。截图失败、快照失败或编码失败不清现有内容。

NSPasteboard 没有跨进程 compare-and-swap；changeCount 检查与写入之间的极窄跨进程竞争无法由客户端完全消除。setData 若发生系统写入失败，也没有可原子回滚的系统 API；不能承诺系统写入失败仍保留原数据。编码失败发生在 clear 之前，已验证不会清空。系统可能自动为 PNG 提供 TIFF 兼容类型，不等于本应用缓存多份历史截图。

## 性能与内存边界

mouseDragged 不触发大图编码；180ms debounce 后才捕获快照。每个 editor 只保留必要的最近矢量内容状态用于去重，不保存 PNG 历史。全局串行编码，旧操作取消后在开始前/编码后检查取消，结果提交前再验证。不可中断的系统绘制/PNG 编码可能运行至返回，但旧结果绝不写入；临时 buffer 由 autoreleasepool 和释放引用回收。

编辑所需源图和现有 Undo 历史必须保留，本功能不声称清理这些内存。也无法删除其他应用/剪贴板管理器已记录的历史。尚未做实机峰值内存或交互延迟测量。

## 验证

已覆盖：初始请求、完成标注、undo/redo、A/B 交错和迟到结果、外部 changeCount、空编码失败不清、关闭不清、设置保存立即取消、手动优先、200 次 fake 回调合并、2048×4096 实图 100 次请求仅捕获一次、后台编码线程、独立 NSPasteboard 的实际 PNG 替换、markedText 不提交、原生像素/Retina/1–3 倍导出以及六种绘制工具的 PNG 与既有导出一致。

新增测试只使用 fake 或 `NSPasteboard.withUniqueName()`，不操作用户 general 剪贴板。首轮测试修正了系统自动提供 TIFF 类型导致的过严断言。

验证命令：`swift build`；`swift test --filter 'Annotation|ImageExport|SettingsStore'`；`swift test`；`swift test --filter 'AnnotationToolOptions|ToolbarInteractionShadow|LiquidGlassAdoption'`；`git diff --check`。fallback 由现有测试的 forceFallback 分支覆盖，不依赖不存在的环境变量。最终结果见本节后续记录。

未实机验收：用户正在运行的 App 未重启、未关闭、未打包替换；未进行真实跨应用粘贴、输入法候选交互及超长图连续标注体验验收。自动化像素一致不等于实机视觉/响应验收。

### 最终执行结果（2026-09-15）

- `swift build` 通过，最后一次无编译警告。
- 相关/回归筛选 42 项全部通过（包含 native、standard fallback、opaque 分支）。
- 全量 `swift test`：139 项，0 失败，274.492 秒；包含长截图预算/匹配/会话取消回归。
- `git diff --check` 通过。原有未提交文字 one-shot、工具统一状态及相关测试改动保留；未提交、未打包、未引入权限。
- 新增自动复制专用测试 9 项。测试中的实际系统剪贴板均为 unique name，未读写 general。
