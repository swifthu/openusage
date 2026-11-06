# 使用节奏（Usage Rhythm）— 设计文档

| 项 | 值 |
|---|---|
| **作者** | brainstorming (Claude Fable 5) |
| **日期** | 2026-11-06 |
| **状态** | 设计稿，等待用户审核 |
| **分支** | `feat/usage-velocity-tracker` |
| **范围** | 采样 provider 上报的窗口占用率，按小时/分钟聚合成本地历史，在面板新增第三个 tab 展示单日节奏与跨日均值 |
| **不做什么** | 不扫本地日志、不算消费金额、不做定价、不读 token 绝对值、不上传任何数据、不做按 provider 的图表过滤、不接云端 |

---

## 1. 背景与目标

现在的面板能回答「我还有多少额度」，但答不了「**我什么时候在烧额度**」。

用户想知道的：

- 我一天里哪几个小时在用？（高峰时间）
- 这几天用下来是个什么节奏？哪几个小时平均下来最忙？
- 放大看，那段高峰到底是一次猛冲还是断断续续？

### 目标

1. 持续记录每个账号每个指标的**窗口占用百分比**随时间的变化。
2. 在 Dashboard 加第三个 tab **使用节奏**，展示：
   - **某一天**的 24 小时消耗曲线，可缩放到 6 小时 / 2 小时窗口，可左右拖动定位；
   - **最近 N 天**（7 / 30 / 90 天）按小时取平均的节奏曲线。
3. 数据**只存在本机**，保留 90 天。

### 与 fork 既有分歧的关系

`AGENTS.md` 第 3 条叫 "No spend, no trend, no pricing"，正文禁的是**扫日志、算消费、外部定价、`Pricing/` 引擎**四件事。本功能一条都不碰：它只记录 provider 自己 API 上报的百分比并做差分。

`AGENTS.md` 需要新增第 5 条分歧记录这个功能（第 4 条是「fork 自己的菜单栏和设置」，第 5 条之后 sync cadence 顺延为第 6 条），写明「记录的是 provider 上报的窗口占用率，不是消费额」。

---

## 2. 关键事实（已核对代码）

| 事实 | 位置 | 影响 |
|---|---|---|
| `MetricLine.progress(label, used, limit, format, resetsAt, periodDurationMs)` 的 `used` 是**已消耗量**，不是剩余 | `Sources/OpenUsage/Models/MetricLine.swift` | 可以直接做差分，不需要反转 |
| `WidgetDisplayMode`（used / remaining）只是显示开关 | `Sources/OpenUsage/Models/WidgetDisplayMode.swift` | 采样不受用户显示偏好影响 |
| `MetricPeriod.sessionMs` = 5h、`dayMs` = 24h、`weekMs` = 7d、`monthMs` = 30d | `Sources/OpenUsage/Support/MetricPeriod.swift` | 「会话级短窗口」= `periodDurationMs ≤ 24h` |
| `Provider.id` = `account.cardID`，账号级 | `Sources/OpenUsage/Providers/AccountProviderRuntime.swift:72` | 一条系列 = (账号 ID, 指标 label) |
| `ProviderSnapshot.lines: [MetricLine]` | `Sources/OpenUsage/Models/ProviderSnapshot.swift` | 采样直接从 snapshot 取，不用经过 WidgetData 解析 |
| 面板宽 **340pt** | `Sources/OpenUsage/Support/PanelMetrics.swift` | 图表布局按 340pt 设计 |
| `Theme.severityColor(.normal)` = `systemBlue` | `Sources/OpenUsage/Support/Theme.swift` | 图表主色直接用 systemBlue，不新增颜色 |
| 仓库**禁止**在源码里用黄色 | `Tests/OpenUsageTests/SeverityPaletteTests.swift` | 峰值高亮用深蓝/浅蓝区分，不用黄 |
| 刷新间隔 30s–5min 可调 | `Sources/OpenUsage/Stores/RefreshSetting.swift` | 采样密度跟着用户设置走，不额外发请求 |
| 没有 SQLite 依赖；只有 Application Support 目录可用 | `Package.swift` | 存储用文件 |
| 仓库里没有任何 CloudKit / iCloud 设施 | — | 本期不做云端 |

### 上游 0.7.x 的先例

上游 0.7.x 有过 opt-in 的 iCloud Drive 历史同步（`ICloudUsageHistoryFileStore` + `UsageHistoryDocument`，设备 ID 存在 Keychain，跨设备身份靠文档里的 `identities` 映射表），在 0.8.0-beta.1 连同 spend 一起删掉了。那套代码验证了「文件 + 设备 ID + identities 映射」这条路可行，本期借鉴它的**身份映射思路**，但不做 iCloud。

---

## 3. 模块与数据流

新增 `Sources/OpenUsage/Rhythm/`，四个单元各管一件事：

| 单元 | 职责 | 依赖 |
|---|---|---|
| `RhythmRecorder` | 长生命周期状态机：记住每条系列上一次的采样，算出这一段的消耗，交给 store | 纯计算 + store |
| `RhythmStore` | 协议 + 本地文件实现（将来云端是同一协议的另一个实现） | 文件系统 |
| `RhythmAnalytics` | 纯函数：一天的桶 → 曲线；多天的桶 → 均值曲线 + 高峰时段 | 无 |
| `RhythmView` | SwiftUI，Dashboard 的第三个 tab | Analytics + Store |

```
provider API
  └─ refresh 成功 → ProviderSnapshot
        └─ RhythmRecorder.record(snapshot, at: now)
              ├─ 只取 .progress 且 periodDurationMs ≤ 24h 的行
              ├─ 与上次采样做差 → 这一段的消耗百分点
              └─ RhythmStore.append(当日 5 分钟桶)
                    └─ Application Support/OpenUsage/rhythm/<bundle id>/2026-11-06.json

读取：RhythmStore.load(days:) → RhythmAnalytics → RhythmView
```

**挂在哪一环**：`WidgetDataStore.refresh(providerID:force:)` 成功更新 `snapshots` 之后。**失败不产生采样点** —— provider 报错的那段时间在图上是空白，不是 0。0 会让图看起来像「没在用」，而真相是「不知道」。

**采样频率**：跟着用户的刷新间隔走，**不额外发请求**。用户把间隔调到 5 分钟，一小时 12 个采样点；调到 30 秒，一小时 120 个。

---

## 4. 数据模型与存储格式

### 一天的记录 = 一个文件

`~/Library/Application Support/OpenUsage/rhythm/<bundle id>/2026-11-06.json`

> 目录里带 bundle id：这个 app 没有沙盒，Application Support 是所有构建共用的，dev 版和正式版会互相覆盖同一整天的文件。

```json
{
  "schema": "openusage.rhythm.v1",
  "day": "2026-11-06",
  "series": [{
    "key": "<accountID>/Session",
    "kind": "claude",
    "label": "Session",
    "windowMs": 18000000,
    "points":  [0.0, 0.1, ... 288 格 ...],
    "samples": [0,   1,   ... 288 格 ...]
  }]
}
```

- `points[h]`：这 5 分钟烧掉了窗口的多少个百分点
- `samples[h]`：这 5 分钟采到了几个点（**置信度**，用来把「没数据」和「零消耗」分开）
- 两个数组的长度 = 当天的 5 分钟桶数。正常是 288；**夏令时切换日按本地日历实际算出 276 或 300** —— 桶下标一律用「从当天零点起用 `Calendar` 推算」得到，不写死 288（这个坑上游在 Codex 的测试 fixture 上踩过一次）。

### 为什么是 5 分钟

缩放要能到分钟级，存储就得比显示更细。5 分钟对应最短 2 小时窗口（每柱 5 分钟），再细的收益不大 —— 刷新间隔最快也就 30 秒。

- 一天 6 条系列 × 288 桶 × 2 个数 ≈ 21KB
- 90 天约 **2MB**

以后想放到 1 分钟，改网格大小 + 一次数据迁移即可。

### 保留期

90 天。每次写入后删掉日期早于 90 天的文件；删不掉不阻塞（网络卷上文件可能仍被占用）。

### 落盘时机

内存里维护当天的桶，**每 5 分钟落盘一次**；小时切换时强制落盘；退出时落盘。丢失窗口 ≤ 5 分钟。

### 身份

本地文件里的系列键用 `Provider.id`（= `account.cardID`，本机生成的 UUID）。

**将来接云端时不能直接上传它** —— 那是设备本地的标识。上游 0.7.x 的做法是在文档里带一张 `identities` 映射表（账号 ID → 跨设备稳定身份）。`RhythmStore` 的协议设计成能带上这两个字段，免得将来推翻重来。

---

## 5. 计算规则

全部有单元测试。

### 5.1 归一

```
fraction = clamp(used / limit, 0...1)
```

`limit` 缺失或 0 的系列跳过 —— 不猜。

### 5.2 差分

记上次采样 `(t0, f0)`，本次 `(t1, f1)`：

| 情况 | delta | 说明 |
|---|---|---|
| `f1 ≥ f0` | `f1 - f0`，夹到上限 1.0 | 被夹时记一条警告日志（数据抖动，不静默） |
| `f1 < f0` | `0` | 窗口重置了。重置前最后几分钟的消耗没采到，认了 |
| `t1 - t0 > windowMs` | `0` | 中间必然重置过，整段丢弃 |

第三条挡掉了「旧窗口 20%、新窗口 30%」被误算成 10% 消耗的坑。

### 5.3 归属到桶

delta 按秒数比例拆分到这次间隔跨越的各个 5 分钟桶。Mac 睡了 3 小时醒来，delta 会被摊到那 3 小时上，而不是在醒来那一格堆出一个假高峰。

`samples` 记在**采样点所在**的桶。

### 5.4 缩放级别

柱子数量恒为 24 根，放大时窗口变短、每根柱子代表的时间变细：

| 级别 | 窗口 | 每柱 | 聚合 |
|---|---|---|---|
| L1 | 24 小时 | 1 小时 | 12 个 5 分钟桶合并 |
| L2 | 12 小时 | 30 分钟 | 6 个桶合并 |
| L3 | 6 小时 | 15 分钟 | 3 个桶合并 |
| L4 | 2 小时 | 5 分钟 | 1 个桶 |

级别表是数据驱动的，加级别不改结构。

### 5.5 跨日均值

先按窗口位置在每天取同一段（例如 12:00–18:00），再对 N 天求均值。缩放和拖动在两个模式下都适用。

---

## 6. 界面

Dashboard 第三个 tab，标题 **使用节奏**。

### 布局

```
使用节奏
┌────────────────────────────────┐
│ [ 这一天 ] [ 最近 30 天 ]      │  ← 分段控件
├────────────────────────────────┤
│  ‹     11 月 6 日（今天）     ›  │  ← 左右箭头翻日；长按弹日历
│  12:00 – 18:00 · 百分点 / 15 分钟 │
│  ░░░░▒▒▒▓▓▓▒▒░░░░░░░░░░░░░░░░  │  ← 上下文条（整天），蓝框=当前窗口
│  拖动 蓝框 查看一天中的其他时段   │
│  ▁▂▅█▇█▇▅▃▂▁▂▃▄▇█▇▅▃▂▁▂▁▁▁▁▁  │  ← 主图，24 根柱
│  0     6     12     18     24   │
│  缩放 ────────○────────── 全天  │  ← 缩放滑块
└────────────────────────────────┘
这一天的高峰在 14:00 – 17:00
```

- **分段控件**：左边「这一天」，右边「最近 N 天」。切到右边时，图表标题那行换成范围选择器（7 天 / 30 天 / 90 天）。
- **翻日**：‹ › 箭头一天一天翻。
- **长按日期标题** → 弹出日历控件，直接跳到任意一天（‹ › 翻太慢）。
- **缩放滑块**：4 个级别。L1（整天）没有上下文条 —— 整张图就是一天，没得拖。
- **拖动定位**：拖上下文条上的蓝框。**没有单独的滚动条** —— 蓝框本身就是指示器也是把手。
- **峰值**：深蓝柱 + 淡蓝背景带，下面一行文字总结。单日模式写「这一天的高峰在 X」，跨日模式写「你的高峰通常在 X」。
- **y 轴单位跟着级别走**：L1 是「百分点 / 小时」，L3 是「百分点 / 15 分钟」，L4 是「百分点 / 5 分钟」。

### 配色

用 app 现有的 systemBlue（`Theme.severityColor(.normal)`）：

- 普通柱：浅蓝（`systemBlue` 低透明度）
- 峰值柱：深蓝（`systemBlue`）
- 峰值背景带：systemBlue 9% 透明度
- 文字：`.primary` / `.secondary`
- 不引入新颜色，避开仓库禁用黄色的规则

---

## 7. 边界情况

| 情况 | 处理 |
|---|---|
| `samples == 0`（Mac 睡了 / app 没开 / provider 报错） | **留白，不画柱** —— 「不知道」 |
| `samples > 0` 且 `points == 0` | 画一根浅色零高度底线 —— 「在，但没烧」 |
| provider 报错 / 账号被删 | 之后的格子没有采样点，自然空白，不伪造 0 |
| 窗口重置 | delta 记 0，重置点附近有个小坑（真实的，不是 bug） |
| 换了套餐（limit 变了） | 当成重置（delta=0），或夹到 1.0 并记警告日志。两种都不静默 |
| 同 provider 多账号 | 每个账号一条独立系列，按（窗口长度 + 指标名）分组合并显示 |
| 不同窗口长度的指标 | **不合并** —— 5 小时 session 和 24 小时 day 加总没有意义 |
| 图表显示什么 | **所有会话级系列合并后的总和**。y 轴单位是「窗口百分点」：Claude 的 session 和 MiniMax 的 session 各烧掉窗口的 5%，合起来是 10 个百分点。只有一个 provider 时就是它自己的值。分系列的原始数据完整存在 store 里，将来要做堆叠柱不用改存储 |
| 同 provider 分系列过滤 | 本期**不做**。数据层留了能力（每个系列的桶分开存），UI 不加 |
| 中途改了刷新间隔 | 采样疏密不均，但 delta 的总量与密度无关，求和仍然正确；`samples` 标注置信度 |
| 还没有任何数据（刚装、刚开启记录） | 空状态：说明「从今天开始积累」，不画空图 |
| 选的那一天完全没有数据 | 同上，图区留白并写明那天没有记录 |
| 夏令时切换日（23 或 25 小时） | **窗口固定为从本地零点起的 24 小时**，24 根柱各代表一小时。25 小时那天的最后一小时（23:00 到次日零点）落在窗口外，不在图里，轴上 `01:00` 出现两次；23 小时那天的最后一根柱是空的，它的标签是次日的 `00:00`。这是有意的取舍：窗口每天含义相同，平均视图的各天切片才对得齐；代价是一年两天、一个时区 |

---

## 8. 隐私

- **数据只存在这台 Mac 上**，不上传。不碰 PostHog（那条线只发聚合遥测，从不带用量值）。
- **不读 Claude Code / Codex CLI 的本地日志**，只读 provider 自己的 API。
- 落盘内容只有：时间戳、provider 类型、指标名、窗口占用百分比。
- **不落盘**：账号标签、邮箱、凭据、绝对用量（token 数 / 金额）。
- **默认开启**，设置里有一项开关能一键停止记录，另有独立的「删除历史」按钮（停止记录 ≠ 删掉已有数据）。

---

## 9. 失败处理

| 情况 | 处理 |
|---|---|
| 写文件失败（磁盘满、NFS 抖动） | 记 AppLog 警告，**不崩**。下次写入重试；连续失败多次就停止记录并提示一次 |
| 文件损坏（写了一半） | 解码失败时记警告并跳过那个文件，不让整个 tab 打不开 |
| 未知 schema | 跳过并提示 |
| 保留期裁剪删不掉文件 | 不阻塞，忽略 |

采样是后台活动，不能因为写不进去就把 app 搞挂。

---

## 10. 测试策略

| 单元 | 测什么 |
|---|---|
| `RhythmAnalytics` | 聚合、峰值判定、缩放窗口计算、跨日均值 —— 纯函数，直接单元测试 |
| `RhythmRecorder` | 差分规则各一个测试：重置、超窗口丢弃、夹取、跨桶拆分、多账号、limit 为 0 |
| `FileRhythmStore` | 写读往返、保留期裁剪、损坏文件、未知 schema |
| 图表渲染 | 沿用 `MenuBarStripProgressBarTests` 的像素断言思路 —— 峰值格是深蓝、普通格是浅蓝、空白格没有像素 |
| 回归 | 现有 828 个测试不能挂 |

---

## 11. 要动的文件

**新增**

- `Sources/OpenUsage/Rhythm/RhythmRecorder.swift`
- `Sources/OpenUsage/Rhythm/RhythmStore.swift`
- `Sources/OpenUsage/Rhythm/RhythmAnalytics.swift`
- `Sources/OpenUsage/Rhythm/RhythmView.swift`
- `docs/rhythm.md`（用户文档，英文，跟 `docs/` 其余页面一致）
- `Tests/OpenUsageTests/Rhythm*.swift`

**修改**

- `Sources/OpenUsage/Stores/WidgetDataStore.swift` —— 刷新成功后调用 recorder
- `Sources/OpenUsage/Views/DashboardContentView.swift` —— 加第三个 tab
- `Sources/OpenUsage/Views/SettingsScreen.swift` —— 开关 + 删除历史按钮
- `AGENTS.md` —— 新增第 5 条分歧，sync cadence 顺延
- `docs/dashboard.md` —— 加一节指向 `docs/rhythm.md`

---

## 12. 未决与以后再说

- **云端同步**：协议留好了位置，但本期不做。真要做时，先想清楚身份映射（`identities` 表），再决定是自配 HTTP 端点、GitHub Gist 还是别的。
- **按 provider 过滤图表**：数据层支持，UI 不做。
- **1 分钟粒度**：需要时改网格大小 + 迁移。
- **跨设备**：本地文件方案天然不支持。
- **按 provider 的历史 API**：上游给 Codex / Cursor / Ollama / OpenRouter 接了日粒度历史（`UsageHistory` / `UsageDay`）。本功能不依赖它（它算不出小时级），但两者数据来源不同，未来若要合并要先对齐语义。

---

## 13. 实现分阶段建议

这份设计对单个实现计划来说偏大，建议按四步走，每步都能独立验证：

1. **存储与记录**：`RhythmStore`（本地文件）+ `RhythmRecorder`（差分规则）+ 挂到 `WidgetDataStore`。做完就能在磁盘上看到正确的文件，测试覆盖全部计算规则。
2. **分析**：`RhythmAnalytics` —— 聚合、峰值判定、缩放窗口、跨日均值。纯函数，好测。
3. **界面**：第三个 tab、图表、缩放滑块、拖动定位、长按日历、空状态。
4. **收尾**：设置里的开关和「删除历史」、`docs/rhythm.md`、`AGENTS.md` 第 5 条、回归测试全绿。

第 1 步做完时功能还看不见，但数据已经对了 —— 后面的步骤都是把已有的数据画出来。
