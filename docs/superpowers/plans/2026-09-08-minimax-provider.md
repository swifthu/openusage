# MiniMax Provider（中国版）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 OpenUsage 中新增一个独立的 Provider，覆盖 MiniMax 中国版（`platform.minimaxi.com`）的 Token Plan 订阅配额监控，菜单栏 popover 显示「5 小时滚动窗口」与「周窗口」两个百分比进度条。

**Architecture:** 仿照 ZAIProvider 的三件套结构，在 `Sources/OpenUsage/Providers/MiniMax/` 下新增 `MiniMaxAuthStore` / `MiniMaxUsageClient` / `MiniMaxUsageMapper` / `MiniMaxProvider`，通过 `ProviderCatalog.make(...)` 按字母序插入到 Grok 之后、OpenRouter 之前。零新增依赖，沿用 `UserAPIKeyStore` + `URLSessionHTTPClient` + 现有 `ProviderSnapshot` 工厂 + `MetricLine.progress` 词汇。

**Tech Stack:** Swift 6（严格并发）；XCTest；Foundation；URLSession；现有仓库工具集 `FakeFiles` / `FakeEnvironment` / `RoutingHTTPClient` / `ProviderParse`。

---

## Global Constraints

- **Swift 6 严格并发**：所有 ProviderRuntime 子类标 `@MainActor`；auth store 标 `Sendable`，所有 `let` 属性 immutable。
- **文件 ≤ ~500 LOC**：本次新增每个文件远小于此上限。
- **不发明新 API**：仅使用现有 `WidgetDescriptor` 工厂（`.percent(...)`）；不引入新 widget 类型；不修改 `pricing_supplement.json`。
- **不引入第三方依赖**。
- **Provider 顺序**：在 `ProviderCatalog.make(...)` 中按 `displayName` 字母序插入到 Grok 之后、OpenRouter 之前（"MiniMax" 字母序位置）。
- **API 端点**：`GET https://www.minimaxi.com/v1/token_plan/remains`，`Authorization: Bearer <订阅 Key>`。
- **认证**：订阅 Key 通过 `~/.config/openusage/minimax.json`（JSON `{"apiKey":"…"}` 或纯文本）保存；环境变量 `MINIMAX_API_KEY` 作为回退。
- **错误分类**：401/403 → `.authInvalid`；200 + `success:false` → `.notAvailable`；HTTP 5xx → `.http5xx`；429 → `.rateLimited`；网络错误 → `.network`；解码失败 → `.decoding`。
- **测试**：完全沿用 `ZAIProviderTests.swift` 的 fixture 驱动模式（`RoutingHTTPClient` / `FakeFiles` / `FakeEnvironment`），不让真实网络访问介入单元测试。
- **本文档不主动 commit**：每 Task 末尾的 commit 步骤是给执行者参考的；按用户 `~/.claude/CLAUDE.md` 规则，git commit 需用户明确要求才执行。
- **API 响应字段假设**：本计划假定响应形如 `{"success":true, "data":{"session":{"usage":..,"limit":..,"resetsAt":..},"weekly":{...}}}`。如实现阶段发现真实字段名不一致，把 Task 2 / Task 4 的 fixture 改成实际抓到的真实响应后再继续。

---

## Task 1: MiniMaxAuthStore + AuthStoreTests

**Files:**
- Create: `Sources/OpenUsage/Providers/MiniMax/MiniMaxAuthStore.swift`
- Create: `Tests/OpenUsageTests/MiniMaxAuthStoreTests.swift`

**Interfaces:**
- Consumes: `UserAPIKeyStore`（已有），`TextFileAccessing` / `EnvironmentReading`（已有）
- Produces:
  ```swift
  struct MiniMaxAuth: Hashable, Sendable { var apiKey: String }
  enum MiniMaxAuthError: Error, LocalizedError, Equatable { case missingKey, invalidKey, saveFailed, deleteFailed }
  struct MiniMaxAuthStore: Sendable {
      static let configPaths: [String]      // ["~/.config/openusage/minimax.json"]
      static let environmentNames: [String] // ["MINIMAX_API_KEY"]
      func loadAPIKey() -> MiniMaxAuth?
      func currentAPIKey() -> String?
      func keyStatus() -> APIKeyStatus
      func saveAPIKey(_ key: String) throws
      func deleteAPIKey() throws
  }
  ```

- [ ] **Step 1: Write failing test `MiniMaxAuthStoreTests.testEnvironmentKeyPrecedence`**

Create `Tests/OpenUsageTests/MiniMaxAuthStoreTests.swift`:

```swift
import XCTest
@testable import OpenUsage

final class MiniMaxAuthStoreTests: XCTestCase {
    func testEnvironmentKeyPrecedence() {
        let store = MiniMaxAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["MINIMAX_API_KEY": "minimax-env"])
        )
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "minimax-env")
    }

    func testSavedKeyOverridesEnvironment() throws {
        let files = FakeFiles()
        let store = MiniMaxAuthStore(
            files: files,
            environment: FakeEnvironment(["MINIMAX_API_KEY": "minimax-env"])
        )

        try store.saveAPIKey("minimax-saved")

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "minimax-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        let store = MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
    }

    func testReadsJSONConfigFile() {
        let store = MiniMaxAuthStore(
            files: FakeFiles([MiniMaxAuthStore.configPaths[0]: #"{"apiKey":"minimax-json"}"#]),
            environment: FakeEnvironment()
        )
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "minimax-json")
    }

    func testReadsPlainTextConfigFile() {
        let store = MiniMaxAuthStore(
            files: FakeFiles([MiniMaxAuthStore.configPaths[0]: "  minimax-plain\n"]),
            environment: FakeEnvironment()
        )
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "minimax-plain")
    }

    func testSaveAPIKeyRejectsEmptyKey() {
        let store = MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertThrowsError(try store.saveAPIKey("   ")) { error in
            XCTAssertEqual(error as? MiniMaxAuthError, .missingKey)
        }
    }

    func testKeyStatusReportsAllFourStates() {
        let envKey = ["MINIMAX_API_KEY": "minimax-env"]
        let file = [MiniMaxAuthStore.configPaths[0]: #"{"apiKey":"minimax-file"}"#]

        XCTAssertEqual(
            MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment()).keyStatus(),
            .notSet
        )
        XCTAssertEqual(
            MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment(envKey)).keyStatus(),
            .fromEnvironment
        )
        XCTAssertEqual(
            MiniMaxAuthStore(files: FakeFiles(file), environment: FakeEnvironment()).keyStatus(),
            .saved
        )
        XCTAssertEqual(
            MiniMaxAuthStore(files: FakeFiles(file), environment: FakeEnvironment(envKey)).keyStatus(),
            .overrideActive
        )
    }

    func testDeleteClearsConfigFileAndPreservesEnvironmentFallback() throws {
        let files = FakeFiles([MiniMaxAuthStore.configPaths[0]: #"{"apiKey":"minimax-file"}"#])
        let store = MiniMaxAuthStore(
            files: files,
            environment: FakeEnvironment(["MINIMAX_API_KEY": "minimax-env"])
        )

        try store.deleteAPIKey()

        XCTAssertNil(files.files[MiniMaxAuthStore.configPaths[0]])
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "minimax-env")
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
    }
}
```

- [ ] **Step 2: Run tests, verify failure**

Run: `swift test --filter MiniMaxAuthStoreTests 2>&1 | tail -20`
Expected: compile error — `MiniMaxAuthStore` not defined.

- [ ] **Step 3: Implement `MiniMaxAuthStore`**

Create `Sources/OpenUsage/Providers/MiniMax/MiniMaxAuthStore.swift`:

```swift
import Foundation

struct MiniMaxAuth: Hashable, Sendable {
    var apiKey: String
}

enum MiniMaxAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No MiniMax API key. Set MINIMAX_API_KEY or add it to ~/.config/openusage/minimax.json."
        case .invalidKey:
            return "MiniMax API key invalid. Check your key at platform.minimaxi.com."
        case .saveFailed:
            return "Couldn't save the MiniMax API key."
        case .deleteFailed:
            return "Couldn't remove the saved MiniMax API key."
        }
    }
}

/// Reads a MiniMax (https://platform.minimaxi.com, 中国版) subscription Key the user has already
/// placed on the machine. MiniMax has no companion CLI/app that stashes a credential, so the key
/// comes from an environment variable (`MINIMAX_API_KEY`) or a small config file under
/// `~/.config/openusage/minimax.json`. A GUI app launched from Finder/Dock doesn't inherit the
/// interactive shell environment, so `ProcessEnvironmentReader` captures the login shell's
/// environment at launch — meaning an env var exported in a shell profile is honored even in a
/// packaged build.
struct MiniMaxAuthStore: Sendable {
    static let configPaths = ["~/.config/openusage/minimax.json"]
    static let environmentNames = ["MINIMAX_API_KEY"]

    private let store: UserAPIKeyStore

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { MiniMaxAuthError($0) }
        )
    }

    func loadAPIKey() -> MiniMaxAuth? { store.loadKey().map(MiniMaxAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `swift test --filter MiniMaxAuthStoreTests 2>&1 | tail -20`
Expected: 8 tests passed.

---

## Task 2: MiniMaxUsageMapper + MapperTests

**Files:**
- Create: `Sources/OpenUsage/Providers/MiniMax/MiniMaxUsageMapper.swift`
- Create: `Tests/OpenUsageTests/MiniMaxUsageMapperTests.swift`

**Interfaces:**
- Consumes: `ProviderParse`（已有）
- Produces:
  ```swift
  enum MiniMaxUsageMapper {
      /// 5-hour session window in milliseconds (the spec calls out 5-hour rolling windows).
      static let sessionPeriodMs: Int
      /// 7-day weekly window in milliseconds.
      static let weeklyPeriodMs: Int
      static func isNoSubscription(_ body: Data) -> Bool
      static func map(_ body: Data) throws -> [MetricLine]
  }
  enum MiniMaxUsageError: Error, LocalizedError, Equatable {
      case connectionFailed, invalidResponse, requestFailed(Int), noSubscription
  }
  ```

- [ ] **Step 1: Write failing test `MiniMaxUsageMapperTests.testMapsSessionAndWeeklyPercentages`**

Create `Tests/OpenUsageTests/MiniMaxUsageMapperTests.swift`:

```swift
import XCTest
@testable import OpenUsage

private let bothLimitsJSON = #"""
{
  "success": true,
  "data": {
    "session": {
      "usage": 12,
      "limit": 100,
      "resetsAt": 1770648402
    },
    "weekly": {
      "usage": 30,
      "limit": 100,
      "resetsAt": 1771300000
    }
  }
}
"""#

private let sessionOnlyJSON = #"""
{
  "success": true,
  "data": {
    "session": { "usage": 12, "limit": 100, "resetsAt": 1770648402 }
  }
}
"""#

private let emptyDataJSON = #"{"success":true,"data":{}}"#

private func data(_ json: String) -> Data { Data(json.utf8) }

final class MiniMaxUsageMapperTests: XCTestCase {
    func testMapsSessionAndWeeklyPercentages() throws {
        let lines = try MiniMaxUsageMapper.map(data(bothLimitsJSON))

        let session = try XCTUnwrap(progress(lines, "Session"))
        XCTAssertEqual(session.used, 12, accuracy: 0.001)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.format, .percent)
        XCTAssertEqual(session.periodDurationMs, MiniMaxUsageMapper.sessionPeriodMs)

        let weekly = try XCTUnwrap(progress(lines, "Weekly"))
        XCTAssertEqual(weekly.used, 30, accuracy: 0.001)
        XCTAssertEqual(weekly.limit, 100)
        XCTAssertEqual(weekly.format, .percent)
        XCTAssertEqual(weekly.periodDurationMs, MiniMaxUsageMapper.weeklyPeriodMs)
    }

    func testMapsSessionOnlyWhenWeeklyAbsent() throws {
        let lines = try MiniMaxUsageMapper.map(data(sessionOnlyJSON))
        XCTAssertNotNil(progress(lines, "Session"))
        XCTAssertNil(progress(lines, "Weekly"))
    }

    func testEmptyDataReturnsNoUsageLine() throws {
        let lines = try MiniMaxUsageMapper.map(data(emptyDataJSON))
        XCTAssertEqual(lines.first, .noUsageData)
    }

    func testDetectsNoSubscriptionBody() {
        let body = data(#"{"code":401,"msg":"未订阅 Token Plan","success":false}"#)
        XCTAssertTrue(MiniMaxUsageMapper.isNoSubscription(body))
    }

    func testIsNoSubscriptionFalseForUsableBodies() {
        XCTAssertFalse(MiniMaxUsageMapper.isNoSubscription(data(bothLimitsJSON)))
        XCTAssertFalse(MiniMaxUsageMapper.isNoSubscription(
            data(#"{"code":500,"msg":"internal error","success":false}"#)
        ))
    }

    func testClampsAboveRangePercentage() throws {
        let body = data(#"""
        {"success":true,"data":{"session":{"usage":150,"limit":100,"resetsAt":1770648402}}}
        """#)
        let lines = try MiniMaxUsageMapper.map(body)
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Session")).used, 100, accuracy: 0.001)
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try MiniMaxUsageMapper.map(data("not json")))
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, format: ProgressFormat, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, let format, _, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, format, periodDurationMs)
    }
}
```

- [ ] **Step 2: Run tests, verify failure**

Run: `swift test --filter MiniMaxUsageMapperTests 2>&1 | tail -20`
Expected: compile error — `MiniMaxUsageMapper` not defined.

- [ ] **Step 3: Implement `MiniMaxUsageMapper`**

Create `Sources/OpenUsage/Providers/MiniMax/MiniMaxUsageMapper.swift`:

```swift
import Foundation

/// Builds metric lines from the MiniMax `/v1/token_plan/remains` payload. The endpoint returns the
/// remaining quota for the 5-hour rolling window and the weekly window; each window carries
/// `usage` (used percentage), `limit` (always 100), and `resetsAt` (epoch seconds).
///
/// Pure (no I/O), so it tests cleanly against sample payloads.
enum MiniMaxUsageMapper {
    /// 5-hour rolling session window in milliseconds (MiniMax's documented 5-hour window).
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    /// 7-day rolling weekly window in milliseconds.
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    /// True when a 2xx body is the "valid key, but no Token Plan subscription" signal: MiniMax
    /// answers `{"success":false,"code":…,"msg":"…未订阅 Token Plan"}` with no `data`. The provider
    /// turns this into a clear `.notAvailable` error rather than two blank "No data" meters.
    static func isNoSubscription(_ body: Data) -> Bool {
        guard let root = ProviderParse.jsonObject(body),
              (root["success"] as? Bool) == false else { return false }
        let msg = ((root["msg"] as? String) ?? "").lowercased()
        return msg.contains("token plan") || msg.contains("subscription")
    }

    /// Session + weekly meters from the quota payload. A missing window is allowed (the API may omit
    /// a window before the subscription period starts); an empty `data` object returns `.noUsageData`
    /// rather than throwing.
    static func map(_ body: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw MiniMaxUsageError.invalidResponse
        }
        guard let data = root["data"] as? [String: Any] else {
            throw MiniMaxUsageError.invalidResponse
        }
        guard !data.isEmpty else { return [.noUsageData] }

        var lines: [MetricLine] = []
        if let session = data["session"] as? [String: Any] {
            lines.append(try percentLine(session, label: "Session", periodMs: sessionPeriodMs))
        }
        if let weekly = data["weekly"] as? [String: Any] {
            lines.append(try percentLine(weekly, label: "Weekly", periodMs: weeklyPeriodMs))
        }

        guard !lines.isEmpty else { return [.noUsageData] }
        return lines
    }

    // MARK: - Private

    private static func percentLine(_ entry: [String: Any], label: String, periodMs: Int) throws -> MetricLine {
        guard let rawUsage = ProviderParse.number(entry["usage"]) else {
            throw MiniMaxUsageError.invalidResponse
        }
        let percentage = ProviderParse.clampPercent(rawUsage)
        let resetsAt = ProviderParse.number(entry["resetsAt"]).map { epochSecondsToDate($0) }
        return .progress(
            label: label,
            used: percentage,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }

    private static func epochSecondsToDate(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}

enum MiniMaxUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The key is valid but the account has no active Token Plan subscription.
    case noSubscription

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .noSubscription:
            return "No active MiniMax Token Plan subscription. Subscribe at platform.minimaxi.com to see usage."
        }
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `swift test --filter MiniMaxUsageMapperTests 2>&1 | tail -20`
Expected: 7 tests passed.

> **If the real API field names differ from the assumed shape (`data.session.usage` etc.)**, replace `bothLimitsJSON` / `sessionOnlyJSON` / `emptyDataJSON` with an actual capture from `curl https://www.minimaxi.com/v1/token_plan/remains -H "Authorization: Bearer $KEY"` and update `MiniMaxUsageMapper.map(_:)` to parse the real shape. Don't change the public API — only the JSON keys it reads.

---

## Task 3: MiniMaxUsageClient

**Files:**
- Create: `Sources/OpenUsage/Providers/MiniMax/MiniMaxUsageClient.swift`

**Interfaces:**
- Consumes: `HTTPClient`（已有）
- Produces:
  ```swift
  struct MiniMaxUsageClient: Sendable {
      static let remainsURL: URL
      var http: any HTTPClient
      func fetchRemains(apiKey: String) async throws -> HTTPResponse
  }
  ```

- [ ] **Step 1: Implement `MiniMaxUsageClient`**

(The client itself is fully exercised by the Task 4 provider tests via `RoutingHTTPClient`; a dedicated client test is unnecessary because the client is a thin GET wrapper.)

Create `Sources/OpenUsage/Providers/MiniMax/MiniMaxUsageClient.swift`:

```swift
import Foundation

struct MiniMaxUsageClient: Sendable {
    static let remainsURL = URL(string: "https://www.minimaxi.com/v1/token_plan/remains")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Token Plan remaining quota for the 5-hour rolling window and the weekly window.
    /// The endpoint requires a Bearer Token (the user's "订阅 Key", not the pay-as-you-go API key).
    func fetchRemains(apiKey: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.remainsURL,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}
```

- [ ] **Step 2: Compile-check**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds, no warnings introduced.

---

## Task 4: MiniMaxProvider + ProviderTests

**Files:**
- Create: `Sources/OpenUsage/Providers/MiniMax/MiniMaxProvider.swift`
- Create: `Tests/OpenUsageTests/MiniMaxProviderTests.swift`

**Interfaces:**
- Consumes: `MiniMaxAuthStore`, `MiniMaxUsageClient`, `MiniMaxUsageMapper`
- Produces:
  ```swift
  @MainActor
  final class MiniMaxProvider: ProviderRuntime, APIKeyManaging {
      static func makeProvider(id: String = "minimax", displayName: String = "MiniMax") -> Provider
      var provider: Provider
      var widgetDescriptors: [WidgetDescriptor]
      let authStore: MiniMaxAuthStore
      let usageClient: MiniMaxUsageClient
      let now: @Sendable () -> Date
      var apiKeyStatus: APIKeyStatus
      func currentAPIKey() -> String?
      func saveAPIKey(_ key: String) throws
      func deleteAPIKey() throws
      func hasLocalCredentials() async -> Bool
      func refresh() async -> ProviderSnapshot
  }
  ```

- [ ] **Step 1: Write failing test `MiniMaxProviderTests.testRefreshMapsSessionAndWeekly`**

Create `Tests/OpenUsageTests/MiniMaxProviderTests.swift`:

```swift
import XCTest
@testable import OpenUsage

private let bothLimitsJSON = #"""
{
  "success": true,
  "data": {
    "session": { "usage": 12, "limit": 100, "resetsAt": 1770648402 },
    "weekly": { "usage": 30, "limit": 100, "resetsAt": 1771300000 }
  }
}
"""#

private let noSubscriptionJSON = #"{"code":401,"msg":"未订阅 Token Plan","success":false}"#

private func jsonResponse(_ jsonString: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(jsonString.utf8))
}

@MainActor
final class MiniMaxProviderTests: XCTestCase {
    func testRefreshMapsSessionAndWeekly() async throws {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.url, MiniMaxUsageClient.remainsURL)
                XCTAssertEqual(request.headers["Authorization"], "Bearer minimax-test")
                return jsonResponse(bothLimitsJSON)
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = MiniMaxProvider(
            authStore: MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a key")
                return jsonResponse("{}")
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshClassifiesAuthFailure() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                jsonResponse("{}", status: 401)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshClassifiesServerFailure() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                jsonResponse("{}", status: 500)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
    }

    func testRefreshClassifiesRateLimit() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                jsonResponse("{}", status: 429)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .rateLimited)
    }

    func testRefreshOnTransportErrorReportsNetwork() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                throw MiniMaxUsageError.connectionFailed
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testRefreshWithoutSubscriptionReportsNotAvailable() async {
        let provider = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-test"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in
                jsonResponse(noSubscriptionJSON)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
    }

    func testHasLocalCredentialsReflectsAuthStore() async {
        let keyAuth = MiniMaxProvider(
            authStore: makeAuthStore(key: "minimax-env"),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in jsonResponse("{}") })
        )
        XCTAssertTrue(await keyAuth.hasLocalCredentials())

        let noAuth = MiniMaxProvider(
            authStore: MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in jsonResponse("{}") })
        )
        XCTAssertFalse(await noAuth.hasLocalCredentials())
    }

    func testProviderIdentityAndLinks() {
        let provider = MiniMaxProvider()
        XCTAssertEqual(provider.provider.id, "minimax")
        XCTAssertEqual(provider.provider.displayName, "MiniMax")
        XCTAssertTrue(provider.provider.links.contains { $0.label == "Dashboard" })
    }

    func testProviderAPIKeyManagingDelegatesToAuthStore() throws {
        let files = FakeFiles()
        let provider = MiniMaxProvider(
            authStore: MiniMaxAuthStore(files: files, environment: FakeEnvironment(["MINIMAX_API_KEY": "minimax-env"])),
            usageClient: MiniMaxUsageClient(http: RoutingHTTPClient { _ in jsonResponse("{}") })
        )

        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        XCTAssertEqual(provider.currentAPIKey(), "minimax-env")

        try provider.saveAPIKey("minimax-saved")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        XCTAssertEqual(provider.currentAPIKey(), "minimax-saved")

        try provider.deleteAPIKey()
        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
    }

    private func makeAuthStore(key: String) -> MiniMaxAuthStore {
        MiniMaxAuthStore(files: FakeFiles(), environment: FakeEnvironment(["MINIMAX_API_KEY": key]))
    }
}
```

- [ ] **Step 2: Run tests, verify failure**

Run: `swift test --filter MiniMaxProviderTests 2>&1 | tail -20`
Expected: compile error — `MiniMaxProvider` not defined.

- [ ] **Step 3: Implement `MiniMaxProvider`**

Create `Sources/OpenUsage/Providers/MiniMax/MiniMaxProvider.swift`:

```swift
import Foundation

@MainActor
final class MiniMaxProvider: ProviderRuntime {
    let provider = Provider(
        id: "minimax",
        displayName: "MiniMax",
        icon: .providerMark("minimax"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://platform.minimaxi.com/"),
            ProviderLink(label: "API Keys",  url: "https://platform.minimaxi.com/user-center/basic-information/interface-key")
        ]
    )

    let authStore: MiniMaxAuthStore
    let usageClient: MiniMaxUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: MiniMaxAuthStore = MiniMaxAuthStore(),
        usageClient: MiniMaxUsageClient = MiniMaxUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "\(provider.id).session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: a stored or environment-exported subscription key.
        await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxAuthError.missingKey)
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.fetchRemains(apiKey: auth.apiKey)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxUsageError.connectionFailed)
        }

        let status = response.statusCode
        if status == 401 || status == 403 {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxAuthError.invalidKey)
        }
        guard (200..<300).contains(status) else {
            return ProviderSnapshot.error(
                provider: provider,
                error: MiniMaxUsageError.requestFailed(status),
                category: ErrorCategory.http(status)
            )
        }

        if MiniMaxUsageMapper.isNoSubscription(response.body) {
            return ProviderSnapshot.error(provider: provider, error: MiniMaxUsageError.noSubscription)
        }

        do {
            let lines = try MiniMaxUsageMapper.map(response.body)
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}

extension MiniMaxProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

extension ProviderSnapshot {
    /// Overload of `error(provider:error:)` that accepts an explicit `ErrorCategory` — used by the
    /// MiniMax provider to map non-2xx HTTP statuses to their telemetry bucket before any error enum
    /// gets thrown. Falls back to the error's own category if `category` is `nil`.
    static func error(provider: Provider, error: Error, category: ErrorCategory?) -> ProviderSnapshot {
        let resolved = category ?? (error as? CategorizedError)?.errorCategory ?? .other
        return ProviderSnapshot.error(provider: provider, message: error.localizedDescription, category: resolved)
    }
}
```

> **Note**: `ProviderSnapshot.error(provider:error:)` and `ProviderSnapshot.error(provider:message:category:)` already exist in `ProviderSnapshot.swift`. The new overload in MiniMaxProvider.swift extends the type with `error(provider:error:category:)` — only include this `extension` if a build error indicates the missing overload. If the project's existing `error(provider:error:)` signature already accepts an optional category, **remove the `extension` block**.

- [ ] **Step 4: Run tests, verify pass**

Run: `swift test --filter MiniMaxProviderTests 2>&1 | tail -20`
Expected: 10 tests passed.

- [ ] **Step 5: Run full test suite**

Run: `swift test 2>&1 | tail -10`
Expected: all tests passed (including the previously existing ZAI / Claude / etc. tests).

---

## Task 5: Register MiniMaxProvider in ProviderCatalog

**Files:**
- Modify: `Sources/OpenUsage/Providers/ProviderCatalog.swift:41-52`

- [ ] **Step 1: Insert `MiniMaxProvider()` into the catalog**

Edit `Sources/OpenUsage/Providers/ProviderCatalog.swift` — in the `providers += [...]` array (lines 41–52), insert `MiniMaxProvider(),` between `GrokProvider()` and `OllamaProvider()`:

```swift
        providers += [
            CodexProvider(),
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
            MiniMaxProvider(),  // ← insert this line
            OllamaProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
```

> Alphabetical order of `displayName`: Antigravity, Codex, Cursor, Devin, Grok, **MiniMax**, Ollama, OpenCode, OpenRouter, Z.ai. (`Copilot` is intentionally placed in the established position before Grok.)

- [ ] **Step 2: Compile-check**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds.

- [ ] **Step 3: Run a smoke test that the catalog now contains MiniMax**

Append a temporary test in `Tests/OpenUsageTests/MiniMaxProviderTests.swift` (or rely on the existing provider-registration test if one exists):

```swift
func testProviderCatalogIncludesMiniMax() {
    let catalog = ProviderCatalog.make()
    let ids = catalog.map(\.provider.id)
    XCTAssertTrue(ids.contains("minimax"))
    // Verify alphabetical position: minimax must come after "grok" and before "ollama".
    guard let minimaxIndex = ids.firstIndex(of: "minimax"),
          let grokIndex = ids.firstIndex(of: "grok"),
          let ollamaIndex = ids.firstIndex(of: "ollama") else {
        return XCTFail("expected catalog to contain minimax, grok, ollama")
    }
    XCTAssertGreaterThan(minimaxIndex, grokIndex)
    XCTAssertLessThan(minimaxIndex, ollamaIndex)
}
```

Run: `swift test --filter MiniMaxProviderTests.testProviderCatalogIncludesMiniMax 2>&1 | tail -10`
Expected: PASS.

> If the project has a project-wide registration test (e.g. `testEveryProviderDeclaresTheApprovedPublicResourceKeys`), MiniMax must be expected there too. Run the full suite to surface any such test:

`swift test 2>&1 | tail -20` → all passed.

---

## Task 6: Documentation

**Files:**
- Create: `docs/providers/minimax.md`
- Modify: `README.md` (if it lists supported providers)

- [ ] **Step 1: Create `docs/providers/minimax.md`**

Mirror the structure of `docs/providers/zai.md` if it exists. Minimal content:

```markdown
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
```

- [ ] **Step 2: Update README.md if it lists providers**

If `README.md` contains a "Supported Providers" or similar list, append `- MiniMax (中国版)`. Otherwise skip this step.

- [ ] **Step 3: Commit-worthy state**

Run: `swift build 2>&1 | tail -5` and `swift test 2>&1 | tail -5`.
Expected: clean build, all tests pass.

> **Commit reminder**: per user `~/.claude/CLAUDE.md`, do NOT run `git commit` proactively. Surface the ready state to the user and ask whether to commit.

---

## Task 7: End-to-end manual smoke test (developer-side verification)

**Files:** none (verification only)

- [ ] **Step 1: Build the app**

Run: `swift build -c release 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 2: Set a real subscription key and launch the app**

```bash
export MINIMAX_API_KEY=<real-subscription-key-from-platform.minimaxi.com>
.build/release/OpenUsageApp &
```

Wait for the menu-bar icon to appear. Open the popover.

- [ ] **Step 3: Verify the two progress bars render**

Expected:
- The MiniMax card shows two meters titled **Session** and **Weekly**, with percentages populated from the live API.
- If the key is invalid or the account has no active subscription, the card shows the corresponding error badge (not a crash).

- [ ] **Step 4: Test API key editing via the UI**

In the popover, click **Customize → MiniMax → API Key**, paste a key, save. Verify the status flips to "Custom Key" / "Saved in App". Delete and verify it falls back to the env var (if set) or to `.notSet`.

- [ ] **Step 5: Surface results to the user**

Report to the user:

- Whether both meters populated correctly
- The exact API response shape observed (so future documentation updates can pin field names)
- Any error categories surfaced during the smoke test

> Stop here. Do not proceed to release / version-bump work — that requires explicit user approval per AGENTS.md.
