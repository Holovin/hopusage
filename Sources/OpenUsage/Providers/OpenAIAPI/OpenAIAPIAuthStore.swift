import Foundation

struct OpenAIAPIAuth: Hashable, Sendable {
    var apiKey: String
}

enum OpenAIAPIAuthError: Error, LocalizedError, Equatable {
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
            return "No OpenAI Admin key."
        case .invalidKey:
            return "OpenAI rejected the Admin key. API Usage needs an Admin key (sk-admin-…) from platform.openai.com/settings/organization/admin-keys."
        case .saveFailed:
            return "Couldn't save the OpenAI Admin key."
        case .deleteFailed:
            return "Couldn't remove the saved OpenAI Admin key."
        }
    }
}

/// Fork: the OpenAI Admin key for one Codex card's API Usage row. Each Codex account has its own key,
/// saved in Customize ▸ Codex ▸ OpenAI Admin Key to a file named after the card id. There is no
/// environment fallback: one variable can't say which account it belongs to, and the regular project
/// key (`OPENAI_API_KEY`) is rejected by the organization usage endpoints anyway.
struct OpenAIAPIAuthStore: Sendable {
    static let configDirectory = "~/.config/hopusage/openai-api"

    static func configPath(cardID: String) -> String {
        "\(configDirectory)/\(cardID).json"
    }

    private let store: UserAPIKeyStore

    init(
        cardID: String,
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        store = UserAPIKeyStore(
            configPaths: [Self.configPath(cardID: cardID)],
            environmentNames: [],
            files: files,
            environment: environment,
            makeError: { OpenAIAPIAuthError($0) }
        )
    }

    func loadAPIKey() -> OpenAIAPIAuth? { store.loadKey().map(OpenAIAPIAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}
