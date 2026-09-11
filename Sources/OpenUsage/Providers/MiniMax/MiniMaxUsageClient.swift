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
