# CHANGELOG_DEV

只记录已经实际发生的修改和验证；计划项放在 `ROADMAP.md`。

## 2026-09-28 — M5.8.3 Slider Authored Max + Action Identity

### 真机反馈

- M5.8.2 Slider 本体与实时数值显示已可用，但生成时输入 `31` 并不会自动变成 Slider 最大值。
- M5.8.2 的显示层去重把同方法的 Fixed / Number / Slider Builder actions 当成同一功能；Fixed/Number 会被隐藏。
- 用户明确：仅 Slider 必须在生成时填写参数值；其他控件不增加该要求。

### 根因

- M5.8.2 `ZNM582DisplayRecordIndexes()` 用 `title + canonicalIdentity` 作为 UI 去重键，业务语义过粗；`ZNRuntimeActionRuntime` 本身已经按 `actionID + canonicalIdentity + argumentValues` 去重精确嵌入记录。
- Runtime Slider 读取的是 `argumentControlConfigs[].max`，而 Builder 输入值只写入 `argumentValues`，两者没有在生成前绑定。
- Builder 参数输入此前仅在 EditingDidEnd 更新 store，用户输入后直接点生成可能读取旧值。

### 实际修改

- 新分支 `fix/m5.8.3-slider-max-action-identity`，基线 M5.8.2 `59eebc1d21c7a6894f27a5480bf8100bbf4f2094`。
- 删除 M5.8.2 Runtime UI 的二次 display collapse；现有单一 `ZNM58UnifiedControlRuntime` 直接渲染 `ZNRuntimeActionRuntime.records`，不新增第二套 UI/controller。
- Fixed / Number / Slider 即使目标 `canonicalIdentity` 相同，只要是不同 Builder Action 就不再被 UI 层吞掉。
- `ZNRuntimeMethodCallBuilderUI` 参数框增加 EditingChanged live-sync，输入值即时更新 `ZNRuntimeActionStore`。
- `ZNStaticBinaryPipeline` 在真正写 Runtime Action metadata 前执行 Slider authoring preflight。
- 仅 `enabled + type=slider` 的参数要求生成时填写有效数值；空值、非数字、非有限值、`<=0` 直接拒绝生成。
- Slider 生成 metadata：`min=0`、`max=<用户填写值>`、`step=1`、`default=<用户填写值>`。
- Number / Fixed / Switch / Button 不增加生成时必填要求。
- Footer 更新为 `0.5.8 · M5.8.3`；128-byte Static / 64-byte Runtime ABI 不变。

### CI

- First Run `36363946557`：Source Contract / Build M5.8.3 均 SUCCESS；dylib SHA256 `5c5a0d5d0897d694ec24e016ba2936f8fa7ccdf4036ed5d3b5b57f56ae9c3646`。首个失败发生在 Binary Verify：CI 错误地用 `strings -a` 搜中文 Objective-C NSString，属于验证脚本假阴性，不是编译错误。
- CI-only 修正 commit `8fcdb5af93e2cf8884f2e5189acad3acf744abcc`：Binary Verify 改查 ASCII marker，业务代码未改变。
- Final business-code Run `36364086245` / Job `108746902686`：Source Contract、Dobby arm64、Build、Binary Verify、Artifact Upload 全部 SUCCESS。
- Artifact ID `10947010903`，artifact digest `sha256:344f603bc385d8d86e044b37709ce14f76282c366fdaa49cf71ee2889f0b30cc`。

### 验证边界

- 已修改：YES。
- 已提交：YES。
- 已编译：YES。
- Binary Verify：YES。
- Artifact：YES。
- 已运行：NO。
- 已实机验证：M5.8.3 NO。
- 已回归验证：NO。

## 2026-09-28 — M5.8.2 Single Runtime UI + Runtime Value Persistence

- 单一 `ZNM58UnifiedControlRuntime` renderer；无第二套 Runtime UI。
- Fixed action 增加 Execute；Slider 增加实时数值；Runtime values 增加 `zonoe.m5.8.2.runtime-values.v1` 持久化。
- M5.8.2 的 `title + canonicalIdentity` display collapse 后续被 M5.8.3 认定会误合并独立 Builder Action，因此已撤销。

## Historical anchors

- M5.8.2 final HEAD `59eebc1d21c7a6894f27a5480bf8100bbf4f2094`.
- M5.8.1 baseline `bdda071fe30b8b18dec1f791ad9f65cca402e4a3`.
- M5.8 Control Cleanup Run `36232977858`.
- M5.7 Unified Control Runtime Run `36019982680`.
- M5.6.2 Runtime/Static Recovery Run `36012593002`.
- M5.5.1 Recovery Run `36002343325`.
- M5.4 Unified Method Finder Run `35964757740`.
- M5.2 Chain V2 `2456f6ba4dfb659e3480db2e677452dad8516153`.
