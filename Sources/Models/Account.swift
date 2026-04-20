import Foundation

struct Account: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var profile: Profile?
    var lastUpdated: Date?
    var lastError: String?
    /// The keychain service name this account was imported from (e.g. "Claude Code-credentials-...").
    /// Used to re-read fresh tokens when the stored one expires.
    var keychainServiceName: String?
    /// When the current access token expires (used for proactive refresh).
    var tokenExpiresAt: Date?
    /// Custom path to a `.credentials.json` file for this account.
    /// When nil, defaults to `~/.claude/.credentials.json`.
    var credentialsFilePath: String?
    /// Custom path to the `.claude` configuration directory for this account.
    /// When nil, defaults to `~/.claude`. Affects session scanning for cost estimates.
    var claudeConfigDir: String?
    /// Per-account usage schedule.
    var usagePlan: UsagePlan = UsagePlan()

    var displayName: String {
        if let profile {
            return profile.email
        }
        return name
    }

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    // Custom Codable: fields added after initial release use decodeIfPresent
    // so that data serialized by older versions still decodes successfully.
    // Without this, a missing key causes the entire [Account] array to fail
    // decoding, silently losing all accounts.

    private enum CodingKeys: String, CodingKey {
        case id, name, fiveHour, sevenDay, profile, lastUpdated, lastError
        case keychainServiceName, tokenExpiresAt, credentialsFilePath, claudeConfigDir, usagePlan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fiveHour = try c.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)
        profile = try c.decodeIfPresent(Profile.self, forKey: .profile)
        lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        keychainServiceName = try c.decodeIfPresent(String.self, forKey: .keychainServiceName)
        tokenExpiresAt = try c.decodeIfPresent(Date.self, forKey: .tokenExpiresAt)
        credentialsFilePath = try c.decodeIfPresent(String.self, forKey: .credentialsFilePath)
        claudeConfigDir = try c.decodeIfPresent(String.self, forKey: .claudeConfigDir)
        usagePlan = try c.decodeIfPresent(UsagePlan.self, forKey: .usagePlan) ?? UsagePlan()
    }
}
