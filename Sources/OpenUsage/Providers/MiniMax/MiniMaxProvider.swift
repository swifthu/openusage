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
                .exportingLimit("weekly", unit: "percent"),
            WidgetDescriptor(
                id: "\(provider.id).sessionReset",
                providerID: provider.id,
                metricLabel: "5h Reset",
                sample: {
                    var s = WidgetData(title: "5h Reset", icon: .providerMark("minimax"), kind: .count, used: 0, limit: nil)
                    s.displaySize = .small
                    return s
                }(),
                pinnable: true,
                isSpendTile: false,
                limitResources: [],
                historyResource: nil,
                barPeriodMs: MiniMaxUsageMapper.sessionPeriodMs
            )
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

        do {
            let lines = try MiniMaxUsageMapper.map(response.body, now: now)
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
