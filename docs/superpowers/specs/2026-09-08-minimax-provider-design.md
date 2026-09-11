# MiniMax Provider（中国版）— 设计文档

| 项 | 值 |
|---|---|
| **作者** | brainstorming (Claude Fable 5) |
| **日期** | 2026-09-08 |
| **状态** | 设计稿，等待用户审核 |
| **范围** | 在 OpenUsage 中新增一个 Provider，覆盖 MiniMax 中国版的 Token Plan 用量监控 |
| **不做什么** | 不动海外版 `platform.minimax.io`、不动 ZAIProvider、不新增 widget 工厂、不引入新依赖、不实现 spend tile |

---

## 1. 背景与目标

OpenUsage 已支持 Claude、Codex、Cursor、Grok、Devin、ZAI、OpenRouter、Antigravity 等多家 AI 服务的用量监控。MiniMax 是一家中国 AI 服务商，提供语言/语音/视频/图像模型；其中国版（`platform.minimaxi.com`）目前**不在**支持列表中。

本变更新增一个 Provider，把 MiniMax 中国版的 **Token Plan 订阅配额**接入菜单栏的用量监控面板。

### 监控范围（与用户达成共识）

- **只** 监控 Token Plan 订阅配额
- **不** 监控按量计费 API Key 余额
- **不** 监控已购积分余额
- **不** 渲染 spend tile

这意味着 MiniMax 中国版用户在 OpenUsage 中看到的就是：

- 5 小时滚动窗口剩余（% 进度条）
- 周窗口剩余（% 进度条）

---

## 2. 关键事实（来自官方文档）

- **国内站点**：`https://platform.minimaxi.com/`
- **公开 API**：`GET https://www.minimaxi.com/v1/token_plan/remains`
- **认证**：`Authorization: Bearer <订阅 Key>`（Token Plan 订阅 Key，与按量计费 API Key **不可互换**）
- **配额窗口**：5 小时固定窗口 + 周窗口（Plus / Max / Ultra 三档）
- **失败行为**：响应可能含 `success: false` 字段，表示账号无有效订阅，需按 ZAIProvider 的方式映射成 provider warning，而不是空白 meter

> 真实响应字段名以首次抓取为准；本文档只声明映射契约，字段表将在 `MiniMaxUsageMapper` 实现时通过 fixture 锁定。

---

## 3. 架构与文件结构

完全沿用 ZAIProvider 的三件套模式：**AuthStore / UsageClient / Mapper + ProviderRuntime**。

### 新增文件

```
Sources/OpenUsage/Providers/MiniMax/
├── MiniMaxProvider.swift       # ProviderRuntime 主类
├── MiniMaxAuthStore.swift      # Keychain + 环境变量 MINIMAX_API_KEY 回退
├── MiniMaxUsageClient.swift    # HTTP GET /v1/token_plan/remains
└── MiniMaxUsageMapper.swift    # 响应 → MetricLine

Tests/OpenUsageTests/
├── MiniMaxProviderTests.swift        # ProviderRuntime 行为
├── MiniMaxUsageMapperTests.swift     # 映射边界、空值、错误码
└── MiniMaxAuthStoreTests.swift       # Keychain + env var 优先级
```

### 不新增的内容

- 不新增 `WidgetDescriptor` 工厂方法（`planBadge` 之类一律不引入）
- 不修改 `pricing_supplement.json`（Token Plan 不展示现金消耗）
- 不修改 `ProviderCatalog` 之外的任何共享代码
- 不引入第三方依赖

---

## 4. `MiniMaxProvider` 设计

### 静态工厂

```swift
static func makeProvider(
    id: String = "minimax",
    displayName: String = "MiniMax"
) -> Provider
```

返回：

```swift
Provider(
    id: id,
    displayName: displayName,
    icon: .providerMark("minimax"),
    links: [
        .init(label: "Status",   url: "https://status.minimaxi.com/"),
        .init(label: "Dashboard", url: "https://platform.minimaxi.com/")
    ]
)
```

> `status.minimaxi.com` 的真实可达性需在实现阶段验证；若不可达，链接替换为 `https://platform.minimaxi.com/` 即可。

### 实例属性

```swift
let provider: Provider
let authStore: MiniMaxAuthStore
let usageClient: MiniMaxUsageClient
let now: @Sendable () -> Date   // 与 ZAIProvider 一致，可注入便于测试
```

### `widgetDescriptors`

```swift
var widgetDescriptors: [WidgetDescriptor] {
    [
        .percent(id: "\(provider.id).session", provider: provider, title: "Session")
            .exportingLimit("session", unit: "percent"),
        .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
            .exportingLimit("weekly", unit: "percent")
    ]
}
```

- 两个 `.percent(...)` 进度条对应 5h 滚动窗口与周窗口
- 不调用 `WidgetDescriptor.spendTiles(provider:)`（无 spend）
- 不附加 `usageTrend` / `values` / `combined`（与 ZAIProvider 保持同样的极简结构）

### `hasLocalCredentials()` / `refresh()`

完全沿用 ZAIProvider 的实现模式：

- `hasLocalCredentials()` 调用 `authStore.loadAPIKey()`，**不**触发 Keychain 权限弹窗
- `refresh()` 流程：load key → fetch remains → map → snapshot
- `now` 默认 `Date.init`，测试时可注入固定时钟

---

## 5. 数据流

```
定时刷新 / 用户手动触发
        │
        ▼
MiniMaxProvider.refresh()
        │
        ├─ authStore.loadAPIKey()           ─── Keychain 优先 → env var 回退
        │      └─ nil  → ProviderSnapshot.error(.notLoggedIn)
        │
        ├─ usageClient.fetchRemains(apiKey:)
        │     GET https://www.minimaxi.com/v1/token_plan/remains
        │     Authorization: Bearer <订阅 Key>
        │     Accept: application/json
        │
        ├─ mapper.map(response)
        │     ├─ success=true + 配额字段齐全 → MetricLine[] (5h + weekly)
        │     ├─ success=false             → ProviderSnapshot.warning(...) + 空 meter
        │     └─ 字段缺失                  → 对应 metric unavailable, 不让单个字段错误拖垮整个 snapshot
        │
        └─ ProviderSnapshot(metrics: [5h, weekly])
```

### 错误处理矩阵

| 情况 | 处理 |
|---|---|
| 无 API Key | `ProviderSnapshot.error(.notLoggedIn)`，引导去设置粘贴订阅 Key |
| HTTP 401 / 403 | `ProviderSnapshot.error(.authenticationFailed)` |
| HTTP 200 + `success:false` | `ProviderSnapshot.warning(...)`（按 ZAI 模式） |
| HTTP 429 | 仿照 ClaudeProvider 的 5 分钟 cooldown：保留 `lastGoodUsage`，跳过本次 live 调用并附 stale 标记 |
| HTTP 5xx / 网络错误 | `ProviderSnapshot.error(.serverError)`，并按 `FailureBackoffTests` 模式做指数退避 |
| 响应字段缺失 / 类型异常 | mapper 内 `try?` 容错，对应 metric 标记 unavailable |

---

## 6. 注册位置

`Sources/OpenUsage/Providers/ProviderCatalog.swift`：

- 按 `displayName` **字母序**插入到 `Grok` 之后、`OpenRouter` 之前
- `AppContainer` 的 provider 数组同步插入
- `DefaultLayout.metricIDs` / `pinnedMetricIDs` / `expandedMetricIDs` **不**主动新增（默认空状态由用户自定义布局时落位）

---

## 7. 文档更新

按 AGENTS.md 的约定，本变更需同步更新：

- `docs/providers/`（如果存在 MiniMax 的章节占位）→ 在该目录新增 `minimax.md`，与 `zai.md` 平行
- `README.md` 的 Provider 列表

---

## 8. 测试策略

完全沿用 `ZAIProviderTests.swift` 的 fixture 驱动模式，**不**让真实网络访问介入单元测试。

| 测试文件 | 覆盖范围 |
|---|---|
| `MiniMaxAuthStoreTests.swift` | Keychain 与 `MINIMAX_API_KEY` 环境变量的优先级；fixture 注入 |
| `MiniMaxUsageMapperTests.swift` | 正常响应；`success:false`；5h / weekly 字段缺失；字段类型异常；负值与超限值 |
| `MiniMaxProviderTests.swift` | `hasLocalCredentials` 不触发 Keychain 弹窗；`refresh` 三种成功路径；错误路径；429 cooldown 复用 lastGood |
| `ProviderCatalog` 注册相关 | 新 provider 出现在 catalog；字母序位置正确 |

并新增一条端到端 fixture（`MiniMaxProviderFixtures.swift`），用于在测试中复用真实响应样例。

---

## 9. 风险与权衡

| 风险 | 缓解 |
|---|---|
| MiniMax API 字段名可能与文档描述不一致 | `MiniMaxUsageMapper` 单独成文件，字段映射集中、便于一次性修正 |
| 订阅 Key 与按量计费 Key 不可互换 | `authStore` 命名清晰（`MiniMaxAuthStore.loadAPIKey`），UI 文案需明确告知用户使用**订阅 Key** |
| 5h / weekly 重置时间字段缺失导致 UI 无法展示倒计时 | mapper 内允许字段为 null，UI 显示 "Resets soon" 而非崩溃 |
| 私有仓库 fork 本地改动与上游 main 漂移 | 此 Provider 作为独立模块，新增/删除局限于 `Sources/OpenUsage/Providers/MiniMax/` 与 `Tests/OpenUsageTests/MiniMax*`，与上游冲突面极小 |

---

## 10. 验收标准

- [ ] `codegraph explore "MiniMax"` 能完整列出 ProviderRuntime 实现、AuthStore、UsageClient、Mapper、widgetDescriptors
- [ ] `swift test` 全部通过，包含新增的三个 `MiniMax*Tests` 文件
- [ ] `swift build` 无新警告
- [ ] 不修改 `pricing_supplement.json`、不修改 `ProviderCatalog` 之外的共享代码
- [ ] 在真实订阅 Key 下，菜单栏 popover 展示两个 `.percent` 进度条（5h Session + Weekly）
- [ ] 无 Key / 失效 Key / `success:false` 三种错误状态都有清晰的 UI 反馈，无崩溃
