import Foundation
import Security

protocol APIKeyPersistence {
    func read() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

enum APIKeyStoreError: LocalizedError, Equatable {
    case emptyKey
    case keyRequiredForDestinationChange
    case invalidEncoding
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "The API key cannot be empty."
        case .keyRequiredForDestinationChange:
            return "Enter a new API key when changing provider or endpoint."
        case .invalidEncoding:
            return "The API key could not be encoded."
        case let .keychain(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(message)"
            }
            return "Keychain error (\(status))."
        }
    }
}

struct SystemAPIKeyPersistence: APIKeyPersistence {
    private let service: String
    private let account: String

    init(
        service: String = "com.scinttt.open-typeless.api-key",
        account: String = "transcription-api-key"
    ) {
        self.service = service
        self.account = account
    }

    func read() throws -> Data? {
        if let data = try read(using: dataProtectionQuery) {
            deleteLegacyItemIfPossible()
            return data
        }

        // Migrate an item written by older builds from the legacy macOS
        // file-based keychain to the data protection keychain.
        let legacyQuery = try legacyFileKeychainQuery()
        guard let legacyData = try read(using: legacyQuery) else {
            return nil
        }
        try saveToDataProtectionKeychain(legacyData)
        try? delete(using: legacyQuery)
        return legacyData
    }

    func save(_ data: Data) throws {
        try saveToDataProtectionKeychain(data)
        deleteLegacyItemIfPossible()
    }

    func delete() throws {
        var firstError: Error?
        do {
            try delete(using: dataProtectionQuery)
        } catch {
            firstError = error
        }
        do {
            try delete(using: legacyFileKeychainQuery())
        } catch {
            firstError = firstError ?? error
        }
        if let firstError {
            throw firstError
        }
    }

    private func read(using baseQuery: [String: Any]) throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw APIKeyStoreError.invalidEncoding
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw APIKeyStoreError.keychain(status)
        }
    }

    private func saveToDataProtectionKeychain(_ data: Data) throws {
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            dataProtectionQuery as CFDictionary,
            attributes as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(updateStatus)
        }

        var newItem = dataProtectionQuery
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw APIKeyStoreError.keychain(addStatus)
        }
    }

    private func delete(using query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(status)
        }
    }

    private func deleteLegacyItemIfPossible() {
        guard let query = try? legacyFileKeychainQuery() else { return }
        try? delete(using: query)
    }

    private var dataProtectionQuery: [String: Any] {
        var query = baseQuery
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    private func legacyFileKeychainQuery() throws -> [String: Any] {
        var keychain: SecKeychain?
        let status = SecKeychainCopyDefault(&keychain)
        guard status == errSecSuccess, let keychain else {
            throw APIKeyStoreError.keychain(status)
        }
        var query = baseQuery
        query[kSecMatchSearchList as String] = [keychain]
        return query
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class APIKeyStore: @unchecked Sendable {
    static let shared = APIKeyStore()

    private let persistence: any APIKeyPersistence
    private let defaults: UserDefaults
    private let legacyDefaultsKey: String
    private let lock = NSLock()

    init(
        persistence: any APIKeyPersistence = SystemAPIKeyPersistence(),
        defaults: UserDefaults = .standard,
        legacyDefaultsKey: String = "apiKey"
    ) {
        self.persistence = persistence
        self.defaults = defaults
        self.legacyDefaultsKey = legacyDefaultsKey
    }

    func load() throws -> String? {
        try withLock {
            try loadWithoutLock()
        }
    }

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIKeyStoreError.emptyKey
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw APIKeyStoreError.invalidEncoding
        }

        try withLock {
            try persistence.save(data)
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
    }

    func delete() throws {
        try withLock {
            var deletionError: Error?
            do {
                try persistence.delete()
            } catch {
                deletionError = error
            }
            defaults.removeObject(forKey: legacyDefaultsKey)
            if let deletionError {
                throw deletionError
            }
        }
    }

    @discardableResult
    func migrateLegacyKeyIfNeeded() throws -> Bool {
        try withLock {
            guard let legacyKey = defaults.string(forKey: legacyDefaultsKey),
                  !legacyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return false
            }

            if try loadWithoutLock() == nil {
                guard let data = legacyKey.data(using: .utf8) else {
                    throw APIKeyStoreError.invalidEncoding
                }
                try persistence.save(data)
            }

            defaults.removeObject(forKey: legacyDefaultsKey)
            return true
        }
    }

    private func loadWithoutLock() throws -> String? {
        guard let data = try persistence.read() else { return nil }
        guard let key = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.invalidEncoding
        }
        return key.isEmpty ? nil : key
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

struct StoredTranscriptionConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultModel = "gpt-4o-mini-transcribe"
    static let defaultFormattingModel = "gpt-4o-mini"
    static let defaultCustomHost = "space.ai-builders.com"
    static let defaultCustomBasePath = "/backend/v1"

    let version: Int
    var apiKey: String?
    var provider: APIProvider
    var customHost: String
    var customBasePath: String
    var model: String

    init(
        version: Int = currentVersion,
        apiKey: String?,
        provider: APIProvider,
        customHost: String,
        customBasePath: String,
        model: String
    ) {
        self.version = version
        self.apiKey = apiKey
        self.provider = provider
        self.customHost = customHost
        self.customBasePath = customBasePath
        self.model = model
    }

    var endpoint: DataProcessingEndpoint {
        .current(
            provider: provider,
            customHost: customHost,
            customBasePath: customBasePath
        )
    }
}

enum TranscriptionConfigurationStoreError: LocalizedError, Equatable {
    case invalidData
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "The saved transcription configuration is invalid."
        case .unsupportedVersion(let version):
            return "The saved transcription configuration version \(version) is not supported."
        }
    }
}

struct TranscriptionAPIKeyDeletionResult: Sendable {
    let configuration: StoredTranscriptionConfiguration
    let legacyCleanupErrorDescription: String?
}

final class TranscriptionConfigurationStore: @unchecked Sendable {
    static let shared = TranscriptionConfigurationStore()

    private let persistence: any APIKeyPersistence
    private let legacyAPIKeyStore: APIKeyStore
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(
        persistence: any APIKeyPersistence = SystemAPIKeyPersistence(
            service: "com.scinttt.open-typeless.transcription-configuration",
            account: "active-configuration"
        ),
        legacyAPIKeyStore: APIKeyStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.persistence = persistence
        self.legacyAPIKeyStore = legacyAPIKeyStore
        self.defaults = defaults
    }

    func loadOrMigrate() throws -> StoredTranscriptionConfiguration {
        try withLock {
            if let data = try persistence.read() {
                let configuration = try decode(data)
                // A valid configuration blob remains authoritative. Retry
                // best-effort cleanup left behind by an interrupted migration.
                try? legacyAPIKeyStore.delete()
                return configuration
            }

            try legacyAPIKeyStore.migrateLegacyKeyIfNeeded()
            let provider = defaults.string(forKey: "apiProvider")
                .flatMap(APIProvider.init(rawValue:)) ?? .openAI
            let configuration = StoredTranscriptionConfiguration(
                apiKey: try legacyAPIKeyStore.load(),
                provider: provider,
                customHost: defaults.string(forKey: "customHost")
                    ?? StoredTranscriptionConfiguration.defaultCustomHost,
                customBasePath: defaults.string(forKey: "customBasePath")
                    ?? StoredTranscriptionConfiguration.defaultCustomBasePath,
                model: defaults.string(forKey: "transcriptionModel")
                    ?? StoredTranscriptionConfiguration.defaultModel
            )
            try saveWithoutLock(configuration)
            try? legacyAPIKeyStore.delete()
            return configuration
        }
    }

    func save(_ configuration: StoredTranscriptionConfiguration) throws {
        try withLock {
            try saveWithoutLock(configuration)
            try? legacyAPIKeyStore.delete()
        }
    }

    @discardableResult
    func deleteAPIKey() throws -> TranscriptionAPIKeyDeletionResult {
        try withLock {
            var configuration: StoredTranscriptionConfiguration
            if let data = try persistence.read() {
                configuration = (try? decode(data)) ?? configurationFromLegacyDefaults()
            } else {
                configuration = configurationFromLegacyDefaults()
            }
            configuration.apiKey = nil
            try saveWithoutLock(configuration)
            // Do not report deletion as successful while a legacy copy remains.
            // The keyless configuration blob is committed first so a failed
            // cleanup can never make the legacy key authoritative again.
            var cleanupErrorDescription: String?
            do {
                try legacyAPIKeyStore.delete()
            } catch {
                cleanupErrorDescription = error.localizedDescription
            }
            return TranscriptionAPIKeyDeletionResult(
                configuration: configuration,
                legacyCleanupErrorDescription: cleanupErrorDescription
            )
        }
    }

    private func configurationFromLegacyDefaults() -> StoredTranscriptionConfiguration {
        let provider = defaults.string(forKey: "apiProvider")
            .flatMap(APIProvider.init(rawValue:)) ?? .openAI
        return StoredTranscriptionConfiguration(
            apiKey: nil,
            provider: provider,
            customHost: defaults.string(forKey: "customHost")
                ?? StoredTranscriptionConfiguration.defaultCustomHost,
            customBasePath: defaults.string(forKey: "customBasePath")
                ?? StoredTranscriptionConfiguration.defaultCustomBasePath,
            model: defaults.string(forKey: "transcriptionModel")
                ?? StoredTranscriptionConfiguration.defaultModel
        )
    }

    private func saveWithoutLock(_ configuration: StoredTranscriptionConfiguration) throws {
        guard configuration.version == StoredTranscriptionConfiguration.currentVersion else {
            throw TranscriptionConfigurationStoreError.unsupportedVersion(configuration.version)
        }
        var normalized = configuration
        normalized.apiKey = configuration.apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.apiKey?.isEmpty == true {
            normalized.apiKey = nil
        }
        guard !normalized.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionConfigurationStoreError.invalidData
        }
        try persistence.save(JSONEncoder().encode(normalized))
    }

    private func decode(_ data: Data) throws -> StoredTranscriptionConfiguration {
        let configuration: StoredTranscriptionConfiguration
        do {
            configuration = try JSONDecoder().decode(
                StoredTranscriptionConfiguration.self,
                from: data
            )
        } catch {
            throw TranscriptionConfigurationStoreError.invalidData
        }
        guard configuration.version == StoredTranscriptionConfiguration.currentVersion else {
            throw TranscriptionConfigurationStoreError.unsupportedVersion(configuration.version)
        }
        return configuration
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
