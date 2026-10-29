import Foundation

extension AccountProviderRuntime {
    /// MiniMax's Token Plan quota for the 5-hour rolling window and the weekly window.
    ///
    /// The endpoint needs the account's subscription Key (a "Token Plan" key, not the pay-as-you-go
    /// API key). A key the provider rejects is an expired sign-in, not a transient failure.
    func refreshMiniMax(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let key) = credential else { throw ProviderError.invalidResponse }
        let response = try await MiniMaxUsageClient(http: http).fetchRemains(apiKey: key)
        try ProviderError.requireSuccess(response, kind: .minimax)
        return ProviderUsage(plan: nil, lines: try MiniMaxUsageMapper.map(response.body, now: now()))
    }
}
