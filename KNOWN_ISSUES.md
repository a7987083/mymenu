# KNOWN_ISSUES

只记录当前未关闭问题、验证缺口和设计边界。

## KI-M583-001 — Slider authored max 待真机验收

Severity: `HIGH`  
Status: `SOURCE/CI/BINARY FIXED / DEVICE PENDING`

M5.8.3 规定仅 Slider 在生成时必须填写参数值。生成前 Pipeline 会校验该值为 finite 且 `>0`，并写入 `min=0 / max=<authored value> / step=1 / default=<authored value>`。需真机验证输入 `31` 后最终生成菜单的 Slider 最大值严格为 `31`，并验证空值/非法值会阻止生成。

## KI-M583-002 — 同方法不同 Action 的显示身份待真机验收

Severity: `HIGH`  
Status: `SOURCE/CI/BINARY FIXED / DEVICE PENDING`

M5.8.2 的 `title + canonicalIdentity` UI 折叠会误吞 Fixed / Number / Slider 独立 Builder actions。M5.8.3 已删除该二次 UI 去重；精确记录去重继续由 `ZNRuntimeActionRuntime` 负责。需真机确认同一 IL2CPP 方法的 Fixed、Number、Slider 都能同时显示和执行。

## KI-M583-003 — Fixed / Number 生成与执行回归待验收

Severity: `HIGH`  
Status: `SOURCE/CI/BINARY FIXED / DEVICE PENDING`

用户明确只有 Slider 必须生成时填写。M5.8.3 未给 Number / Fixed / Switch / Button 增加生成时必填要求。需真机确认 Fixed 显示 `执行`、Number 显示输入框 + `执行`，且不被同方法 Slider 隐藏。

## KI-M582-003 — Runtime Slider 拖动稳定性与实时数值仍需回归

Severity: `HIGH`  
Status: `DEVICE PARTIAL / REGRESSION PENDING`

用户已确认 M5.8.2 Slider 可以拖动并显示数值。M5.8.3 保留相同 `ZNRangeControl` 热路径：ValueChanged 仅更新 UI，release 单次 Invoke。需在新版本回归无卡死/崩溃。

## KI-M582-004 — Runtime-only 客户值持久化重启验收

Severity: `HIGH`  
Status: `SOURCE/CI/BINARY FIXED / DEVICE PENDING`

持久化 key 继续使用 `zonoe.m5.8.2.runtime-values.v1`，身份为 `actionID + canonicalIdentity`，以保持 M5.8.2 → M5.8.3 兼容。需真机验证 Slider/Number/Switch 提交后重启 App 能恢复。

## KI-M58-002 — Static Slider 旧拖动热路径修复仍待真机

Severity: `HIGH`  
Status: `SOURCE/CI/BINARY FIXED / DEVICE PENDING`

Static typed controls 仍需使用 M5.8+ 重新生成目标验证 Slider drag/release 和 Number Execute。

## KI-M58-003 — Builder renderer 仍有多层包装

Severity: `HIGH`  
Status: `PHASE 2 OPEN`

Builder 仍存在历史 renderer/decorator 链。M5.8.3 没有增加新的 renderer 层。后续 consolidation 必须保持当前已验证行为并禁止继续叠新的 UI owner。

## KI-M58-004 — Method Finder 历史 installer 尚未物理清理

Severity: `HIGH`  
Status: `PHASE 2 OPEN`

M5.4 Unified renderer 已存在，但历史 backend/behavior decorator 仍需逐层审计和清理；必须在 Runtime/Builder 回归稳定后处理。

## KI-M56-004 — Value Cell LDR literal ±1MB 距离限制

Severity: `MEDIUM`  
Status: `FAIL-CLOSED BY DESIGN`

ARM64 LDR literal 使用 imm19*4。Builder 若 source fragment 到 owned `__ZNDATA` cell 超出 ±1MB，会生成失败，不回退到 executable-page runtime write。

## KI-M52-001 — Immediate Chain V2 Level 0 返回问题仍开放

Severity: `HIGH`  
Status: `PARTIAL DEVICE EVIDENCE / INVESTIGATION OPEN`

此前一次 `执行链` 在 Level 1 前停止：`previous managed return is null`。仍需区分 Root 方法真实返回 null 与 receiver/return propagation 问题。
