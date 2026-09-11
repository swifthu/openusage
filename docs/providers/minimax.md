# MiniMax (中国版)

MiniMax 是一家中国 AI 服务商，提供语言 / 语音 / 视频 / 图像模型。本 Provider 监控其国内站点
[platform.minimaxi.com](https://platform.minimaxi.com) 的 **Token Plan 订阅配额**，
菜单栏展示两个进度条：

- **Session** — 5 小时滚动窗口剩余
- **Weekly** — 周窗口剩余

## 认证

OpenUsage 通过订阅 Key（**非**按量计费 API Key）调用
`GET https://www.minimaxi.com/v1/token_plan/remains`。

凭据查找顺序（与 `~/.config/openusage/zai.json` 一致）：

1. `~/.config/openusage/minimax.json`（JSON `{"apiKey":"…"}` 或纯文本）
2. 环境变量 `MINIMAX_API_KEY`

## 错误处理

- 无 Key / 失效 Key → 菜单栏展示 `.notLoggedIn` / `.authInvalid` 状态
- 账号无有效 Token Plan → `.notAvailable`
- 网络或服务端错误 → `.network` / `.http5xx`
- 限频（HTTP 429）→ `.rateLimited`
