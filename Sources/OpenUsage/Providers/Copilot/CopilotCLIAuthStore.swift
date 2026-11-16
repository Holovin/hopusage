import Foundation

/// Where a Copilot card reads its GitHub token from. The standard Copilot card reads editor / GitHub CLI
/// tokens (`CopilotAuthStore`); the "Copilot (CLI/Desktop)" card reads the login of the GitHub Copilot
/// desktop app and `copilot` CLI (`CopilotCLIAuthStore`). Each source names its own sign-in errors, since
/// the fix differs.
protocol CopilotTokenLoading: Sendable {
    /// First usable token, or `nil`. Blocking (Keychain) — call off the main actor.
    func loadToken() -> CopilotToken?
    var notLoggedInError: CopilotAuthError { get }
    var tokenInvalidError: CopilotAuthError { get }
}

extension CopilotAuthStore: CopilotTokenLoading {
    var notLoggedInError: CopilotAuthError { .notLoggedIn }
    var tokenInvalidError: CopilotAuthError { .tokenInvalid }
}

/// Reads the GitHub token of the GitHub Copilot desktop app and the `copilot` CLI. Both share
/// `~/.copilot`: `config.json` names the signed-in account (`lastLoggedInUser`, else `loggedInUsers`),
/// and the token sits in the Keychain under service `copilot-cli`, account `https://github.com:<login>`.
/// Only github.com logins are used — another host's token must not be sent to api.github.com.
struct CopilotCLIAuthStore: CopilotTokenLoading {
    static let configPath = "~/.copilot/config.json"
    static let keychainService = "copilot-cli"
    static let githubHost = "https://github.com"

    var files: TextFileAccessing
    var keychain: KeychainAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor()
    ) {
        self.files = files
        self.keychain = keychain
    }

    var notLoggedInError: CopilotAuthError { .appNotLoggedIn }
    var tokenInvalidError: CopilotAuthError { .appTokenInvalid }

    func loadToken() -> CopilotToken? {
        guard files.exists(Self.configPath),
              let text = try? files.readText(Self.configPath),
              let login = Self.login(fromConfig: text)
        else {
            return nil
        }
        for account in Self.keychainAccounts(login: login) {
            guard let raw = try? keychain.readGenericPassword(service: Self.keychainService, account: account),
                  let token = ProviderParse.unwrapGoKeyring(raw)
            else {
                continue
            }
            return CopilotToken(value: token)
        }
        return nil
    }

    // MARK: - Parsing (pure)

    /// Keychain accounts to try for a login, in order. The app saves the main token under
    /// `<host>:<login>`; some installs only carry the `<host>:<login>:github` item.
    static func keychainAccounts(login: String) -> [String] {
        let base = "\(githubHost):\(login)"
        return [base, base + ":github"]
    }

    /// The signed-in github.com login from `~/.copilot/config.json`. The file is JSON with `//` comment
    /// lines on top, so those are dropped before parsing. `lastLoggedInUser` wins; otherwise the first
    /// github.com entry of `loggedInUsers`.
    static func login(fromConfig text: String) -> String? {
        let json = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        func githubLogin(_ value: Any?) -> String? {
            guard let user = value as? [String: Any],
                  (user["host"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == githubHost,
                  let login = (user["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !login.isEmpty
            else {
                return nil
            }
            return login
        }

        if let login = githubLogin(object["lastLoggedInUser"]) { return login }
        for user in object["loggedInUsers"] as? [Any] ?? [] {
            if let login = githubLogin(user) { return login }
        }
        return nil
    }
}
