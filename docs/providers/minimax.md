# MiniMax (中国版)

MiniMax 是一家中国 AI 服务商，提供语言 / 语音 / 视频 / 图像模型。本 Provider 监控其国内站点
[platform.minimaxi.com](https://platform.minimaxi.com) 的 **Token Plan 订阅配额**，
卡片显示三行：

- **Session** — 5 小时滚动窗口
- **Weekly** — 周窗口
- **5h Reset** — 距离 Session 窗口重置的倒计时（文字）

## 认证

在 App 的 **Accounts** 界面添加 MiniMax 账号，粘贴你的 **Token Plan 订阅 Key**
（**不是**按量计费的 API Key）。Key 存在 App 自己的 Keychain service 里，不会写到别处。

卡片读取 `GET https://www.minimaxi.com/v1/token_plan/remains`。

> **与旧版的差别**：v0.7.x 及更早版本会从 `~/.config/openusage/minimax.json` 或环境变量
> `MINIMAX_API_KEY` 读取 Key。新的账号模型不再从其他工具的文件或环境变量里找凭据，
> 升级后需要在 Accounts 界面里重新添加一次账号。

## 错误处理

- Key 被拒绝（HTTP 401/403）→ 卡片提示登录已过期，删掉账号后重新添加
- 账号没有有效的 Token Plan 订阅 → 卡片提示没有订阅，而不是显示一个用量
- 网络错误、HTTP 错误 → 记录日志并在下次刷新时重试
