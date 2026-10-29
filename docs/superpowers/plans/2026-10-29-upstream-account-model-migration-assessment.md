# 迁移评估：跟上游 openusage 的 Account 架构重写

> 评估日期：2026-10-29
> 评估对象：本 fork（`swifthu/openusage`）当前 `main`（v0.7.16）→ 上游 `origin/main`（`7129ab29`）
> 性质：**评估与方案**，不含任何移植实现

---

## 0. 一句话结论

**跟。** 但这次不是"要不要跟一个实验分支"，而是**上游 `main` 已经换成了新架构**（`next/light` 已于 2026-10-28 通过 PR #1444 合并进 `main` 并删除分支）。不跟 = 冻结在 v0.7.16 架构，和上游的差距按每天数个 PR 扩大。

我们 fork 的独有改动很小（**37 文件 / +2515 / -53**），其中真正的自研代码只有两块：MiniMax provider（约 330 行）+ 菜单栏外观定制（约 180 行）。重建成本可控。

**两个必须先由 owner 拍板的问题**（结论见 §3、§4）：

1. **接受"本地日志推算的消费/趋势"功能消失吗？** 建议接受，不自建。
2. **保留白字 / 糖果红倒计时条吗？** 建议保留白字（低成本），**放弃糖果红倒计时条**（改成文字倒计时）。

---

## 1. 事实基线（全部已核实）

### 1.1 分支状态

| 项 | 值 |
|---|---|
| 本地 `origin/main`（旧） | `abf472d5`，2026-10-26，v0.7.16 |
| 本地 `origin/next/light` | `79b377cf`，2026-10-27（**已从上游删除**，本地残留） |
| 上游 `origin/main`（新，已 fetch） | `7129ab29`，2026-10-28，"Bring the new OpenUsage into main"（PR #1444） |
| `next/light` → 新 `main` 的额外差异 | 285 文件 / +4246 / -9272（只是 2 天的上游工作量） |
| 旧 `main` → `next/light` 的差异 | 653 文件 / +15463 / -70158 |

**`next/light` 是旧 `main` 的严格后继**（merge-base 就是旧 `main` 的 tip，旧 `main` 领先 0 个提交）。所以"跟 next/light"等价于"跟上游 main 的下一次发布"，不存在丢失上游提交的风险。

### 1.2 上游自己怎么说

上游 `CHANGELOG.md` 的 `## Unreleased` 段落，逐条列出删除项：

> **Removed**
> - Account discovery. OpenUsage no longer reads other tools' credentials, config files, Keychain items, databases, or logs. Sign in to each account from the new **Accounts** screen instead.
> - Spend and token tracking, model pricing, and the pricing supplement. The dashboard shows the limits and dollar values a provider reports, nothing computed.
> - iCloud sync of settings and layout.
> - The log file and the Log Level setting. The app logs through unified logging only.
> - The local HTTP API.
> - The proxy setting.
> - The Devin and Pi providers, which have no account sign-in.
> - The welcome screen, provider enable/disable switches, and the On Demand metric tier.
>
> **Kept**
> - The `openusage` command, which now prints what the app last fetched and nothing computed.

上游新 `AGENTS.md` 把这条写成了硬规则：

> Users initiate all provider sign-ins from the popover's Accounts screen. **Never discover credentials or accounts from other tools, and never read their files, Keychain items, SQLite databases, or environment variables.**
> Do not add log scanning, spend estimates, or external pricing.

### 1.3 上游正在"选择性恢复"

上游同时有 7 个 `restore/*` PR 处于 open 状态（#1450–#1456），包括：

| PR | 内容 | 对我们的意义 |
|---|---|---|
| #1454 | `restore/hide-from-screen-share` | 恢复屏幕共享隐私（我们的 v0.7.16 有，新架构删了） |
| #1453 | `restore/cli-compat` | CLI JSON 去掉空的 `errors` 键 |
| #1455 | `restore/replace-key` | API-key 账号可换 key |
| #1452 | `restore/chatgpt-credit-value` | ChatGPT Extra Usage 恢复美元估值 |

**这说明上游的工作模式是"选择性恢复"，不是"绝不恢复"。** 我们 fork 里想要的功能，优先走"给上游提 PR"这条路，比在 fork 里私建更可持续。

### 1.4 我们的 fork delta（相对旧 `main`）

```
37 files changed, 2515 insertions(+), 53 deletions(-)
```

| 类别 | 文件 | 规模 |
|---|---|---|
| MiniMax provider 源码 | `Sources/OpenUsage/Providers/MiniMax/` 4 个新文件 | ~330 行 |
| MiniMax 测试 | 3 个新测试文件 | ~620 行 |
| 菜单栏 / MetricLine 定制 | `MenuBarStripRenderer` / `MenuBarContent` / `MetricLine` / `WidgetData` / `WidgetDescriptor` / `WidgetDataStore` / `MenuBarDisplaySize` | ~180 行 |
| MiniMax 专属 | `ProviderCatalog` / `ErrorCategory` / `LocalUsageAPI` 各加几行 | ~40 行 |
| 文档 | `docs/providers/minimax.md` + `docs/superpowers/` 计划与规格 | ~1240 行 |
| 其它 | `script/build_and_run.sh` | 6 行 |

**真正的自研代码 ≈ 510 行源码 + 620 行测试。** 这是整个迁移的工作量上限。

---

## 2. 架构差异对照

| 维度 | 现状（v0.7.16） | 新上游（`7129ab29`） |
|---|---|---|
| 凭据来源 | 读本机文件 / 别人的 Keychain / 环境变量 / 其他工具的日志 | 只从 App 内 Accounts 登录，存 App 自己的 Keychain service `com.robinebers.openusage.accounts` |
| provider 抽象 | 每个 provider 一个 `ProviderRuntime` 类 | **一个** `AccountProviderRuntime` 类 + provider 目录里的 mapper/client + `AccountProviderRuntime+<Name>` 扩展 |
| provider 标识 | `Provider.id = "claude"` | `Provider.id = account.cardID = "claude@1a2b3c4d"`；`ProviderKind` 枚举是路由键 |
| 指标声明 | `provider.runtime.widgetDescriptors` | `AccountProviderRuntime+Descriptors.swift` 里一个静态 switch |
| 默认布局 | `DefaultLayout.metricIDs` / `pinnedMetricIDs` / `expandedMetricIDs` | 描述符上的 `.pinnedByDefault()`；`DefaultLayout.swift` 已删；指标默认全部显示 |
| 错误类型 | 每个 provider 自定义 error enum + `ErrorCategory` 遥测分桶 | 统一 `ProviderError`（`signInExpired` / `connectionFailed` / `invalidResponse` / `requestFailed` / `rateLimited` / `unavailable`） |
| 菜单栏 | `MenuBarStyle.text` / `.bars` 两套；`IconSource` / `ProviderIconShape` | 只有一条 template strip；`ProviderMarks.image` 直接出 NSImage；新增"数据过期时变暗 app icon" |
| `MetricLine` | `text` / `values` / `progress` / `badge` / `chart`，带 `colorHex`，`badge` 带 `resetsAt` | `values` / `progress` / `badge`，**无** `colorHex`、**无** `badge.resetsAt`、**无** `chart` / `text` |
| 消费 | `Pricing/` 引擎 + 各 provider 日志扫描 + Total Spend 卡 + Usage Trend 折线 | 全部删除 |
| 本地接口 | `LocalUsageAPI`（HTTP）+ `openusage` CLI | 只剩 `openusage` CLI（读快照，不计算） |
| 其它 | iCloud 同步、代理、日志文件、Devin/Pi、欢迎页、provider 开关、On Demand 层级、Bars 菜单栏 | 全部删除（屏幕共享隐私待 #1454 恢复） |

---

## 3. Q1：MiniMax 在新 Account 模型下怎么重写

### 3.1 定位：MiniMax 属于 API-key provider，新架构对它是一等公民

新上游里 `Ollama` / `OpenCode` / `OpenRouter` / `Z.ai` 走的正是这条路：

```swift
// Sources/OpenUsage/Services/DeviceProviderLogins.swift
case .ollama, .opencodeGo, .openrouter, .zai: APIKeyLogin(kind: kind)
```

MiniMax 的订阅 Key 就是一把 API key，直接归到这一组即可。**不需要 OAuth、不需要 device code、不需要自建登录 UI。**

### 3.2 逐文件改动清单

#### 新增

| 文件 | 内容 | 复用度 |
|---|---|---|
| `Sources/OpenUsage/Providers/MiniMax/MiniMaxUsageClient.swift` | 改成上游风格：`struct MiniMaxUsageClient { let http: any HTTPClient }` + `fetchRemains(apiKey:)`。URL 保持 `https://www.minimaxi.com/v1/token_plan/remains`，Header 保持 `Authorization: Bearer <订阅Key>` | ~60% |
| `Sources/OpenUsage/Providers/MiniMax/MiniMaxUsageMapper.swift` | 纯函数 mapper，逻辑几乎照搬 | **~90%** |
| `Sources/OpenUsage/Providers/MiniMax/AccountProviderRuntime+MiniMax.swift` | `refreshMiniMax(_ credential:)`：`case .apiKey(let key)` → 调 client → `ProviderAuthRetry.requireSuccess(response, kind: .minimax)` → 交给 mapper | 新写（~25 行） |

> **可直接复用的上游工具（已核实存在）**：`ProviderParse.jsonObject / number / clampPercent`（`Support/ProviderParse.swift`）、`Formatters.compactDuration`（`Support/Formatters.swift`）。mapper 里用到的 API 一个不缺。

#### 修改

| 文件 | 改动 |
|---|---|
| `Sources/OpenUsage/Models/Account.swift` | `ProviderKind` 加 `case minimax`；`displayName = "MiniMax"`；`links` = Dashboard + API Keys（`platform.minimaxi.com/user-center/basic-information/interface-key`）；`authMethod = .apiKey(keyPage: URL(...))` |
| `Sources/OpenUsage/Services/DeviceProviderLogins.swift` | `ProviderLoginCatalog` 的 switch 里把 `.minimax` 加进 `APIKeyLogin` 那一组。**注意**：该文件里的 `ProviderLoginCatalog` 上游可能会挪位置，这是个小 rebase 热点 |
| `Sources/OpenUsage/Providers/AccountProviderRuntime.swift` | **两处** switch：① `refresh(_ credential:)` 加 `case .minimax: try await refreshMiniMax(credential)`；② `resetClaimService(...)` 加 `case .minimax: return nil` |
| `Sources/OpenUsage/Providers/AccountProviderRuntime+Descriptors.swift` | 加 `case .minimax:` 的描述符列表（用上游新的 `key:` 工厂签名） |
| `docs/providers.md` / `README.md` | 表格加一行 + MiniMax 段落 |

描述符建议（按上游 `key:` 风格）：

```swift
case .minimax:
    [
        .percent(key: "session", provider: provider, title: "Session", metricLabel: "Session")
            .exportingLimit("session", unit: "percent")
            .pinnedByDefault(),
        .percent(key: "weekly", provider: provider, title: "Weekly", metricLabel: "Weekly")
            .exportingLimit("weekly", unit: "percent"),
        .badge(key: "sessionReset", provider: provider, title: "5h Reset", metricLabel: "5h Reset")
    ]
```

#### 删除

| 文件 | 原因 |
|---|---|
| `Sources/OpenUsage/Providers/MiniMax/MiniMaxAuthStore.swift` | `UserAPIKeyStore` / `ProcessEnvironmentReader` 在新上游**整体不存在**（读文件/读环境变量是上游明令禁止的） |
| `Sources/OpenUsage/Providers/MiniMax/MiniMaxProvider.swift` | `ProviderRuntime` 类这个形态不存在了；刷新逻辑搬进 `AccountProviderRuntime+MiniMax.swift` |
| `Sources/OpenUsage/Providers/ErrorCategory.swift` 里的 MiniMax 扩展 | 整个 `ErrorCategory` 已被上游删除，统一用 `ProviderError` |

#### mapper 需要改的两处

1. `.badge(label:text:)` 新上游**没有** `resetsAt` 参数 → 倒计时那行的 `resetsAt` 要去掉（保留 `text`）。
2. `MiniMaxUsageError` → 换成 `ProviderError`：
   - 连接失败 → `.connectionFailed`
   - body 解析失败 → `.invalidResponse`
   - HTTP 非 2xx → `.requestFailed(status)`（401/403 → `.signInExpired(.minimax)`）
   - 无 Token Plan 订阅 → `.unavailable("No active MiniMax Token Plan subscription. …")` ← 上游 `.unavailable(String)` 正好覆盖这种"provider 答了但没东西可计量"的情况

### 3.3 行为变化（必须写进 release notes）

| | 现在 | 迁移后 |
|---|---|---|
| 凭据来源 | `~/.config/openusage/minimax.json` → `MINIMAX_API_KEY` 环境变量 | **在 App 的 Accounts 界面粘贴订阅 Key** |
| 上手成本 | 设个环境变量就自动出现 | 手动添加一次账号 |
| 存储位置 | 明文配置文件 / 环境变量 | App 自己的 Keychain service |

这是**用户可见的 UX 倒退**，但它是上游架构的必然结果，且与 Ollama/OpenRouter 的交互一致。

**折中方案（不推荐）**：保留一个"从 `MINIMAX_API_KEY` 导入"的按钮。它违反上游 `AGENTS.md` 的明令（"never read … environment variables"），在 fork 里会变成一个长期分叉点，且每次上游改 `Account`/`ProviderLogin` 都要重新适配。**建议不做。**

### 3.4 工作量估计

| 部分 | 估计 |
|---|---|
| mapper | 复用 90%，改 ~15 行 |
| client | 复用 60%，改 ~10 行 |
| provider 层（runtime + 描述符 + 注册） | 新写 ~80 行 |
| 测试 | mapper 测试几乎全留；provider 测试重写成 Account 路径；auth store 测试删除 |
| 净增代码 | **约 +150 行 / -200 行** |

---

## 4. Q2：菜单栏定制在新架构下是否还成立

### 4.1 硬编码白字 —— 可移植，但要重做

新上游的 strip 是 **template 图**（`image.isTemplate = true`，画 `.black`），靠 macOS 着色以适配浅色/深色菜单栏。fork 的白字做法必须 `isTemplate = false`。

需要改的地方（都在 `Sources/OpenUsage/Support/MenuBarStripRenderer.swift`）：

| 位置 | 改动 |
|---|---|
| `textImage` | `isTemplate = true` → `false`（1 行） |
| `MenuBarTextStrip.body` | `.foregroundStyle(.black)` → 主题色 |
| `glyph(_:)` | `ProviderMarks.image(...).foregroundStyle(Color.black)` → 主题色 |
| `badgeView(_:)` | 胶囊 `Color.black` → 主题色；镂空字 `.foregroundStyle(Color.black).blendMode(.destinationOut)` → 主题色（destinationOut 按 alpha 挖洞，与颜色无关，仍可用） |
| `appIcon(for:)`（上游新增：数据过期时显示变暗 app icon） | 同样要改，否则浅色菜单栏下是黑图标 |
| fallback 圆点 | `Circle().fill(Color.black)` → 主题色 |

**代价与风险**：
- 上游每次改 strip 都要手动重新套白字 → 持续的小 rebase 摩擦。
- **白字在浅色菜单栏下对比度极低**（上游正是因此用 template）。fork 现在的注释写的是"the menu bar always renders against the system strip, where white reads on both Light and Dark Aqua"，这个前提需要 owner 用实际使用环境确认。
- **建议**：把颜色收敛成**一个集中常量**（例如 `MenuBarStripRenderer.themeColor`），而不是散落的 `.white`；并考虑做成跟随系统 appearance 反色的设置项，而不是无条件白字。

### 4.2 糖果红 critical 倒计时条 —— **不可直接移植**

这个特性依赖的钩子，上游在新架构里**全部删掉了**。要保留就得逐个加回：

| 钩子 | 上游现状 | 加回成本 |
|---|---|---|
| `MetricLine.badge` 的 `resetsAt` | 已删（`case badge(label:text:)`） | 改 `Models/MetricLine.swift` 的 enum **和 Codable**（→ 快照缓存格式变更，要 bump 缓存 key） |
| `WidgetData.progressFraction` / `progressLevel` / `ProgressLevel` 枚举 | 已删 | 加回 `Models/WidgetData.swift` |
| `WidgetData.displaySize` + `MenuBarDisplaySize` | 已删 | 加回 `Models/` |
| `MenuBarContent.Metric.progressFraction / progressLevel / displaySize` | 已删（`Metric` 现在只有 `id` / `label` / `value`） | 改 `Models/MenuBarContent.swift` |
| `WidgetDescriptor.barPeriodMs` | 已删 | 改 `Models/WidgetDescriptor.swift` |
| `WidgetDataStore.resolve(.badge)` 的进度计算 | 已删 | 改 `Stores/WidgetDataStore.swift` |
| `MenuBarStripRenderer` 的 `macaronBar` 绘制 | 已删 | 改 `Support/MenuBarStripRenderer.swift` |

而且新上游的 strip **只画文字**（`MenuBarContent.Metric` 连 `fraction` 概念都没有），要画条等于把上游删掉的整套结构还原。

**三个方案**：

| 方案 | 做法 | 上游钩子依赖 | 评价 |
|---|---|---|---|
| **A（推荐）** | 倒计时降级为**文字 badge**：`.badge(key: "sessionReset", ...)`，文本用 `Formatters.compactDuration` 在 mapper 里算好 | **零** | 菜单栏钉住它显示 "2h13m"，面板里也显示。失去糖果红的视觉冲击，但**倒计时本来就是刷新级（5 分钟）的**，不是秒级 —— 现在的条也一样，两者信息量相同 |
| B | 倒计时挂到 `.progress` 行的 `resetsAt`（上游支持） | 零 | 面板里能看到 "Resets in 2h"，但菜单栏对 progress 行只显示百分比，倒计时进不了菜单栏 |
| C | 完整恢复条方案（上面 7 处全加回） | 7 个上游文件 | 长期分叉点：每次上游改 `MetricLine`/`WidgetData`/`WidgetDescriptor`/`MenuBarContent` 都要处理一次冲突，且改动了快照缓存的 JSON 格式 |

**建议先做 A**。C 的成本（7 个上游文件 + 缓存格式变更 + 长期冲突）不值当，除非 owner 认为那个"最后一小时变红"的视觉是刚需。

### 4.3 顺带会丢的菜单栏相关能力

| 能力 | 上游状态 | 备注 |
|---|---|---|
| 屏幕共享隐私（`MenuBarPrivacyStore` / `MenuBarPrivacyLabel` / `privacyImage`） | 已删 | 上游 PR **#1454** 正在恢复 → **等它合入再迁移最省事** |
| Bars 风格菜单栏（`MenuBarStyle.bars`） | 已删 | 整个 `MenuBarStyle` 类型不存在了。要恢复 = 自己加回一个上游明确不要的风格 |
| 菜单栏渲染缓存键含 appearance | 已删 | 上游现在全 template，appearance 不影响像素，缓存键不需要它 —— 这条 fork 改动**可以安全丢弃** |

---

## 5. Q3：消费（spend）功能的取舍

### 5.1 精确的损失清单

**会消失（本地日志 × 模型定价推算出来的）：**

| 类别 | 内容 |
|---|---|
| 定价引擎 | `Sources/OpenUsage/Pricing/` 整目录 7 个文件（1025 行）：`ModelPricing` / `ModelPricingStore` / `ModelRates` / `PricingCatalog` / `PricingCatalogCodecs` / `PricingFallbackOptions` / `PricingSupplement` |
| 定价数据 | `Resources/pricing_supplement.json`（501 行）、LiteLLM / models.dev 快照 |
| 定价脚本 | `script/update_pricing_snapshots.sh` |
| 日志扫描器 | Claude 677 行、Codex 325+184、Grok 194、Antigravity DB 374、OpenCode 231+278、Pi 188、`IncrementalJSONLScanner` 498、`JSONLScanCacheStore` 458、JSONL 流式/尾部解析等 |
| 聚合与 UI | `SpendTileMapper` 391、`UsageHistoryAggregator` 216、`TotalSpendAggregator` 192、`TotalSpendCard` 427、`UsageSparkline`、`UsageTrendDetail`、`UsageTrendPopoverPresenter` 158、`DailyUsageSeries`、`MetricLine.chart` 分支 |
| 连带删除 | iCloud 同步（360）、本地 HTTP API（`LocalUsageAPI` 186 + `LocalLimitsAPI` 168）、代理设置、日志文件与 Log Level、Devin/Pi provider、欢迎页、provider 启用开关、On Demand 指标层级 |

`Sources/` 侧合计 **删除 160 个文件 / 24506 行**。

**仍然保留（provider 自己报的美元值，不需要 pricing 引擎）：**

Cursor On-demand 花费、Ollama purchased credits、OpenRouter balance、Claude extra usage 花费、Codex credits 的美元估值、Z.ai / Copilot 的额度。新上游把这些表达为 `.progress(.dollars)` / `.values` / `.dollarBalance`。

**所以损失的精确表述是**：
> "用本地日志 × 模型定价推算出来的**历史消费与趋势**"消失；
> "**provider API 直接报出来的美元额度 / 余额**"保留。

### 5.2 建议：**不自建**

理由：

1. **成本不是 1025 行，是 24506 行的子系统**（扫描器 + 缓存协调 + 定价目录 + 聚合 + 2 个 UI 组件），还要加上每次上游改 `MetricLine` / `WidgetData` / `WidgetDescriptor` 时的冲突 —— 而上游现在正在大改这三个类型。
2. **站在上游架构的对立面**。上游 `AGENTS.md` 写死了 "Do not add log scanning, spend estimates, or external pricing"，`docs/providers.md` 写 "OpenUsage computes no spend from logs and applies no model pricing"。自建 = 我们的每个 PR 都要处理一堆结构性冲突。
3. **定价数据本身有持续维护成本**：`pricing_supplement.json` 要定期同步 Cursor 官方定价页（我们 fork 已经有 `pricing-update` skill 在做这件事），上游删掉脚本后这套流程就只剩我们在维护。
4. **上游正在用 `restore/*` PR 逐步恢复被删功能**。如果 owner 认为"总消费"是刚需，最优路径是**给上游提 PR**（把它做成"provider 直接报一个消费数字"的形式，而不是日志扫描），而不是在 fork 里私建。哪怕上游不接，至少 fork 少维护 24.5k 行。

### 5.3 如果 owner 坚持要留

最小可行方案：**只保留 §5.1"仍然保留"那一列**（provider 报什么显示什么）。**不要尝试重建日志扫描**。若一定要重建，明确列为"长期分叉成本"，前提是：

- 有独立维护者（不能只靠上游同步的间隙）；
- 接受每次上游 release 手工 rebase 24.5k 行量级的子系统；
- 接受 `MetricLine` / `WidgetData` 的 Codable 格式与上游永久分叉（快照缓存 key 无法统一）。

---

## 6. Q4：AGENTS.md 与文档怎么同步

### 6.1 现状

我们本地的 `AGENTS.md`（79 行）与旧上游 `abf472d5` 的版本**逐字节相同** —— 我们从没改过它。迁移后它描述的四段会全部失效：

| 段落 | 失效原因 | 新上游对应写法 |
|---|---|---|
| Architecture（"an auth store reads credentials already on the user's machine"） | 认证模型整个反了 | `AccountStore` 持久化账号元数据，`CredentialVault` 存 App 自己的 Keychain；**不得**读其他工具的凭据/文件/Keychain/数据库/环境变量 |
| Providers（"one folder per provider with an auth store, a usage client, and a mapper"） | provider 目录里不再有 auth store | provider 目录里只有 **usage client + mapper**；认证统一走 `Account` / `AccountProviderRuntime` / `ProviderLogin` / `CredentialVault`；刷新逻辑写成 `AccountProviderRuntime+<Name>.swift` 扩展；指标声明写在 `AccountProviderRuntime+Descriptors.swift` 的 switch 里 |
| Model pricing（"all spend imputation prices through the shared engine"） | 引擎不存在了 | **整段删除** |
| Metric placement defaults（4 项：enabled / Always Visible vs On Demand / pinned / order） | 只剩 2 项 | ① **默认显示**（不再有 enabled 开关，所有指标默认显示）；② **pinned to menu bar**（描述符上的 `.pinnedByDefault()`）；顺序仍是 `widgetDescriptors` 声明顺序。"Always Visible vs On Demand" 和 `DefaultLayout.expandedMetricIDs` 已不存在 |
| Default order（"Claude, Codex, Cursor first, then alphabetical"） | 排序规则改了 | 用户的保存顺序；provider 的第一个账号排下面，新账号排在该 provider 账号的末尾，**永不**按目录顺序或名字排序 |
| Error Handling | 需要更严 | 增加 "Never log credentials or response bodies" |

### 6.2 同步方式建议

**不要自己重写。** 直接取上游新版本再补 fork 专属内容：

```bash
git checkout origin/main -- AGENTS.md
```

然后在上游 127 行的基础上追加 3~4 段 fork 专属内容（预计 +20 行）：

1. **本 fork 维护 MiniMax provider**（上游没有该 provider）—— 说明它走 API-key 路线，以及它的 fork 专属例外。
2. **本 fork 的菜单栏外观策略**（如果 owner 决定保留白字）—— 说明这是刻意的 fork 分叉，不接受上游"用 template 适配浅色/深色"的默认。
3. **本 fork 明确不做的事**（如果 owner 决定放弃消费推算）—— 写清"本 fork 不重建 spend 引擎"，避免后续 agent 又去加。
4. **同步节奏** —— 例如"每 2~4 周与上游同步一次；同步前先读 `docs/` 里的 fork 专属说明"。

### 6.3 文档同步清单

| 文档 | 动作 |
|---|---|
| `AGENTS.md` | 取上游新版 + 追加 fork 段（§6.2） |
| `docs/adding-a-provider.md` | **直接取上游新版**（已重写成 Account 模型，含完整 6 步） |
| `docs/providers.md` | 取上游新版 + 加 MiniMax 章节 + 表格行 |
| `README.md` | 取上游新版 + provider 列表加 MiniMax |
| `docs/providers/minimax.md` | **重写认证章节**（"粘贴 Key"取代"读配置文件/env"）+ 删掉 `.notLoggedIn`/`.authInvalid` 那套分类描述（`ErrorCategory` 没了） |
| `docs/pricing.md` | **删除**（引擎没了） |
| `docs/icloud-sync.md` | **删除** |
| `docs/local-http-api.md` | **删除**（本地 HTTP API 删了；只剩 CLI → 改 `docs/cli.md`） |
| `docs/proxy.md` | **删除** |
| `docs/provider-enablement.md` | **删除**（provider 启用开关删了） |
| `docs/menu-bar.md` | 取上游新版；若保留白字/倒计时条，补一段 fork 说明 |
| `docs/architecture.md`、`docs/dashboard.md`、`docs/settings.md`、`docs/privacy.md` | 取上游新版，逐条对照我们的实际改动 |
| `docs/superpowers/plans/`、`docs/superpowers/specs/` | **保留**（我们的设计记录，不受上游影响） |

---

## 7. Q5：结论与分步方案

### 7.1 结论：跟

**理由**：

1. **上游 main 已经是新架构**（PR #1444，2026-10-28）。不跟不是"保持稳定"，是"冻结在两天前的架构" —— 上游每天数个 PR，`next/light` 相对旧 main 已经是 109 个提交。
2. **我们的 fork delta 极小**（37 文件 / +2515 / -53，其中约一半是文档），重建成本可控；且上游的 `restore/*` 通道让我们能以"上游 PR"形式拿回想要的功能。
3. **MiniMax 天然适配新模型**（API-key provider，一等公民），mapper 可复用 90%。
4. **旧架构下我们要独自维护的东西更多**：我们的 `MetricLine.badge.resetsAt` / `ErrorCategory` / `LocalUsageAPI` 这些 fork 扩展，正好都撞在上游大改的类型上，越晚同步冲突越大。

**代价要接受**：本地日志推算的消费/趋势功能消失；现有用户升级后必须重新登录所有账号（上游新 `main` 里**没有任何凭据迁移代码**，已核实）；iCloud 同步 / 本地 HTTP API / 代理 / Devin / Pi / 欢迎页 / On Demand 层级消失。

### 7.2 分步方案

> 原则：**先把主线合干净，再逐块重放 fork 定制**。不要在一次 merge 里同时解决上游冲突和重写定制。

#### 第 0 步 · 准备（0.5 天）

| 动作 | 文件 |
|---|---|
| 给当前 `main` 打备份 tag（`pre-account-migration/v0.7.16-fork`）或留备份分支 | — |
| 把 fork delta 导出成 patch 存档：`git diff origin/main main > /tmp/fork-delta.patch`（`origin/main` 需指向旧的 `abf472d5`） | — |
| 建工作分支 `feature/account-model-migration` | — |
| 产出本评估文档 + 一份"功能取舍确认单"（owner 签字） | `docs/superpowers/plans/2026-10-29-…-assessment.md` |

**风险**：无。

#### 第 1 步 · 合上游架构（1–2 天）

| 动作 | 文件 |
|---|---|
| `git merge origin/main`（`7129ab29`） | — |
| **冲突解决原则：先全部丢弃 fork 定制**，回到纯上游版本，让编译与测试先通过 | 见下方逐文件 |
| 跑 `swift build` + `script/test_quiet.sh`（上游新增的脚本，我们没有，要一并带过来） | `script/test_quiet.sh` |

需要人工处理的冲突点（按"先丢 fork 定制"原则）：

| 文件 | 处理 |
|---|---|
| `Sources/OpenUsage/Providers/ErrorCategory.swift` | 删（上游整文件删除） |
| `Sources/OpenUsage/Services/LocalUsageAPI.swift` | 删（上游整文件删除） |
| `Sources/OpenUsage/Providers/ProviderCatalog.swift` | 删（上游重写） |
| `Sources/OpenUsage/Models/MetricLine.swift` | 删 fork 的 `badge.resetsAt` 改动（除非选方案 C） |
| `Sources/OpenUsage/Stores/WidgetDataStore.swift` | 删 fork 的 badge 进度计算 |
| `Sources/OpenUsage/Support/MenuBarStripRenderer.swift` | 回到上游版（第 3 步再改） |
| `Sources/OpenUsage/Models/MenuBarContent.swift`、`MenuBarDisplaySize.swift`（新增）、`WidgetData.swift`、`WidgetDescriptor.swift` | 回到上游版 |
| `Sources/OpenUsage/Providers/MiniMax/*`（4 个） | 删（第 2 步重写） |
| `script/release.sh` | **大概率冲突**：上游删了 iCloud（entitlements / provisioning profile / `iCloud.com.robinebers.openusage` 容器），我们的 release.sh 里有 iCloud 逻辑 → 取上游版 |
| `script/build_and_run.sh` | 冲突（上游新增 `test_quiet.sh`，改动了 bundle id 相关的注释） |
| `script/update_pricing_snapshots.sh`、`find_icloud_provisioning_profile.sh`、`render_icloud_entitlements.sh`、`OpenUsage.dev.entitlements.plist`、`OpenUsage.release.entitlements.plist` | 上游已删 → 删 |
| `Tests/OpenUsageTests/*`（14 个被改过的测试文件） | 回到上游版本（那些改动只是 badge pattern 4→5 元组的适配，上游已重写） |
| `Tests/OpenUsageTests/MenuBarStripMemoTests.swift` | 上游已删除（改由 `MenuBarStripGateTests.swift` 覆盖）→ 删 |

**验收**：`swift build` 通过；`script/test_quiet.sh` 全绿；App 能启动、Accounts 界面正常。

**风险**：medium。上游 `main` 变动频繁，`7129ab29` 可能又前进；建议在这一步开始后 24 小时内完成，并每步开始前 `git fetch origin` 确认基线。

#### 第 2 步 · 重建 MiniMax（1 天）

按 §3.2 的清单逐文件做：

```
新增  Sources/OpenUsage/Providers/MiniMax/MiniMaxUsageClient.swift
新增  Sources/OpenUsage/Providers/MiniMax/MiniMaxUsageMapper.swift
新增  Sources/OpenUsage/Providers/MiniMax/AccountProviderRuntime+MiniMax.swift
改    Sources/OpenUsage/Models/Account.swift                                  (+ ProviderKind.minimax)
改    Sources/OpenUsage/Services/DeviceProviderLogins.swift                    (+ ProviderLoginCatalog)
改    Sources/OpenUsage/Providers/AccountProviderRuntime.swift                 (+ 2 处 switch)
改    Sources/OpenUsage/Providers/AccountProviderRuntime+Descriptors.swift     (+ case .minimax)
带过  Sources/OpenUsage/Resources/ProviderIcons/minimax.svg                    (已有，直接带)
改    Tests/OpenUsageTests/MiniMaxUsageMapperTests.swift                       (复用)
改    Tests/OpenUsageTests/MiniMaxProviderTests.swift                          (重写为 Account 路径)
删    Tests/OpenUsageTests/MiniMaxAuthStoreTests.swift                         (无 auth store 了)
```

**验收**：
- Accounts 界面能添加 MiniMax 账号（粘贴订阅 Key），卡片显示 Session / Weekly 百分比 + 5h 倒计时。
- `openusage minimax` 输出 `session` / `weekly` limit（`exportingLimit` 已配）。
- mapper 单测 + 一条"无 Token Plan 订阅 → `.unavailable`"的错误路径测试。
- 401/403 → 卡片显示"sign-in expired"并提示重新添加账号。

**风险**：low-medium。主要是 `ProviderKind` 加 case 会让上游几处 `switch account.kind` 变 non-exhaustive（Swift 的 `switch` over enum 在新 case 下会编译报错，这是好事 —— 编译器会指出所有需要加 case 的地方）。

#### 第 3 步 · 菜单栏外观（0.5–1 天）

| 动作 | 文件 |
|---|---|
| `isTemplate = false` + 把散落的 `.black` 收敛成集中的主题常量 | `Sources/OpenUsage/Support/MenuBarStripRenderer.swift` |
| 同步处理上游新增的 `appIcon(for:)`（数据过期时的变暗图标） | 同上 |
| 倒计时改文字 badge（方案 A） | `Sources/OpenUsage/Providers/MiniMax/MiniMaxUsageMapper.swift` |
| 跟改上游的 strip 测试 | `Tests/OpenUsageTests/MenuBarStripTrimTests.swift`（`MenuBarStripMemoTests.swift` 已被上游删除，勿再带回） |

**验收**：浅色 + 深色菜单栏各截一张图确认可读性；`MenuBarStrip*` 测试通过。

**风险**：medium。白字在浅色菜单栏下的可读性需要 owner 用实际环境确认；建议同时把"跟随系统 appearance 反色"做成一个设置项作为兜底。

#### 第 4 步 · 文档与 AGENTS.md 同步（0.5 天）

按 §6.2 / §6.3 执行。

**验收**：`AGENTS.md` 与上游新版一致 + fork 专属段；`docs/` 无残留描述已删除功能的页面。

#### 第 5 步 · 发布

- **版本号必须由 owner 拍板**（仓库规则：绝不自行决定）。这是一次大版本级变更（架构 + 数据模型 + 用户必须重新登录），建议按 `0.8.0` 考虑，但由 owner 定。
- 用 `release-swift` skill 生成 changelog。必须写清的 breaking change：
  - 所有 provider 改为在 App 内登录，**现有用户需要重新添加账号**。
  - 本地日志推算的消费 / 趋势功能已移除。
  - iCloud 同步 / 本地 HTTP API / 代理 / Devin / Pi / 欢迎页已移除。
- 如果选方案 A，还要写："MiniMax 倒计时改为文字显示"。

### 7.3 风险清单

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| 上游 main 继续快速改动（每天数个 PR，7 个 restore PR 待合） | 高 | 中 | 每 2~4 周同步一次；fork delta 控制在 ~10 个文件；每次同步前先 fetch 确认基线 |
| 白字在浅色菜单栏不可见 | 中 | 中 | 做成跟随 appearance 反色的设置项，而不是无条件硬编码白字 |
| `ProviderKind` 加 case 后上游多处 switch 遗漏 | 低 | 低 | Swift 的 exhaustive switch 会在编译期报错，不会漏 |
| MiniMax 的 `/v1/token_plan/remains` 接口变更或下线 | 低 | 高 | 已有 401/403 → `.signInExpired` 路径；加 fixture 测试锁住响应结构 |
| 上游再次重构 `AccountProviderRuntime` | 中 | 中 | MiniMax 逻辑放在 provider 目录的扩展文件里（上游推荐做法），冲突面局限在 1 个文件 |
| 现有用户升级后无法自动迁移凭据 | **确定会发生** | 中 | release notes 明确告知；上游也没有迁移代码，不是我们的问题 |
| fork 与上游共用 bundle id `com.robinebers.openusage` 与 Keychain service `com.robinebers.openusage.accounts` | 中 | 中 | **确认发布版的 Keychain service 是否要加 fork 前缀**，避免和上游正式版互相覆盖账号列表 |
| `script/release.sh` 的 iCloud 逻辑与上游冲突 | 确定 | 中 | 第 1 步直接取上游版 |

### 7.4 一个待确认项（阻塞第 5 步）

我们 fork 的 `script/release.sh` 用的生产 bundle id 是 **`com.robinebers.openusage`**，与上游正式版**完全相同**，iCloud 容器也一样。新架构的账号列表存在 Keychain service `com.robinebers.openusage.accounts`、布局存在同一 app group 的 UserDefaults。

**如果 fork 和上游正式版装在同一台 Mac 上，会共用这些存储。** 这在旧架构下就成立（上游 v0.7.16 的 Claude/Codex 凭据也在同名 Keychain service 下），但新架构下账号列表是唯一的真相来源，共用会导致两个 App 互相覆盖账号。

**建议**：在第 0 步确认 fork 的发布身份 —— 要么换成独立 bundle id + 独立 Keychain service（需要改 `script/release.sh` 和 `AccountCredentialVault.service`，成本约 30 分钟，但会让两个 app 完全隔离），要么明确接受共用并在文档里写明。**这一项会影响第 1 步的合并结果（`AccountCredentialVault.swift` 会不会冲突），越早定越好。**

---

## 附录 A：核实方式

本文所有结论均基于对以下 ref 的只读检查 + GitHub API 查询：

- `origin/main`（旧）= `abf472d5`（2026-10-26，v0.7.16）
- `origin/next/light` = `79b377cf`（2026-10-27）
- `origin/main`（新）= `7129ab29`（2026-10-28，PR #1444 合并后）
- GitHub API：`repos/robinebers/openusage` 的 branches / commits / pulls（确认 PR #1444 已合并、`next/light` 已删除、7 个 `restore/*` PR 处于 open）

未做的事：未编译、未运行测试、未做任何移植实现。
