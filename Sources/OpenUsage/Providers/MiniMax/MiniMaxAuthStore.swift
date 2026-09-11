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
