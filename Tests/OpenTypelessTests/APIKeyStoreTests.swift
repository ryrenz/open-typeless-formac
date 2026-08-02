import Foundation
import Security
import XCTest
@testable import OpenTypeless

final class APIKeyStoreTests: XCTestCase {
    func testSystemPersistenceDataProtectionRoundTrip() throws {
        let persistence = SystemAPIKeyPersistence(
            service: "com.scinttt.open-typeless.tests.\(UUID().uuidString)",
            account: "round-trip"
        )
        let expected = Data("test-key".utf8)
        defer { try? persistence.delete() }

        do {
            try persistence.save(expected)
        } catch APIKeyStoreError.keychain(errSecInteractionNotAllowed) {
            throw XCTSkip(
                "The XCTest runner cannot access the Data Protection Keychain in this environment."
            )
        } catch APIKeyStoreError.keychain(errSecMissingEntitlement) {
            throw XCTSkip(
                "The XCTest runner does not have the entitlement required for the Data Protection Keychain."
            )
        }

        XCTAssertEqual(try persistence.read(), expected)
        try persistence.delete()
        XCTAssertNil(try persistence.read())
    }

    func testSaveLoadsKeyAndRemovesLegacyValue() throws {
        let persistence = InMemoryAPIKeyPersistence()
        let defaults = makeDefaults()
        defaults.set("legacy-key", forKey: "apiKey")
        let store = APIKeyStore(persistence: persistence, defaults: defaults)

        try store.save("  new-key  ")

        XCTAssertEqual(try store.load(), "new-key")
        XCTAssertNil(defaults.object(forKey: "apiKey"))
    }

    func testMigrationMovesLegacyKeyOnlyAfterSuccessfulSave() throws {
        let persistence = InMemoryAPIKeyPersistence()
        let defaults = makeDefaults()
        defaults.set("legacy-key", forKey: "apiKey")
        let store = APIKeyStore(persistence: persistence, defaults: defaults)

        XCTAssertTrue(try store.migrateLegacyKeyIfNeeded())
        XCTAssertEqual(try store.load(), "legacy-key")
        XCTAssertNil(defaults.object(forKey: "apiKey"))
    }

    func testFailedMigrationPreservesLegacyKey() {
        let persistence = InMemoryAPIKeyPersistence(saveError: TestError.failed)
        let defaults = makeDefaults()
        defaults.set("legacy-key", forKey: "apiKey")
        let store = APIKeyStore(persistence: persistence, defaults: defaults)

        XCTAssertThrowsError(try store.migrateLegacyKeyIfNeeded())
        XCTAssertEqual(defaults.string(forKey: "apiKey"), "legacy-key")
    }

    func testMigrationKeepsExistingKeychainValueAndErasesPlaintext() throws {
        let persistence = InMemoryAPIKeyPersistence(data: Data("keychain-key".utf8))
        let defaults = makeDefaults()
        defaults.set("legacy-key", forKey: "apiKey")
        let store = APIKeyStore(persistence: persistence, defaults: defaults)

        XCTAssertTrue(try store.migrateLegacyKeyIfNeeded())
        XCTAssertEqual(try store.load(), "keychain-key")
        XCTAssertNil(defaults.object(forKey: "apiKey"))
    }

    func testDeleteRemovesKeychainAndLegacyValues() throws {
        let persistence = InMemoryAPIKeyPersistence(data: Data("keychain-key".utf8))
        let defaults = makeDefaults()
        defaults.set("legacy-key", forKey: "apiKey")
        let store = APIKeyStore(persistence: persistence, defaults: defaults)

        try store.delete()

        XCTAssertNil(try store.load())
        XCTAssertNil(defaults.object(forKey: "apiKey"))
    }

    func testDeleteRemovesLegacyPlaintextWhenKeychainDeletionFails() {
        let persistence = InMemoryAPIKeyPersistence(
            data: Data("keychain-key".utf8),
            deleteError: TestError.failed
        )
        let defaults = makeDefaults()
        defaults.set("legacy-key", forKey: "apiKey")
        let store = APIKeyStore(persistence: persistence, defaults: defaults)

        XCTAssertThrowsError(try store.delete())

        XCTAssertNil(defaults.object(forKey: "apiKey"))
    }

    func testSaveRejectsEmptyKeyWithoutOverwritingExistingValue() throws {
        let persistence = InMemoryAPIKeyPersistence(data: Data("existing-key".utf8))
        let store = APIKeyStore(persistence: persistence, defaults: makeDefaults())

        XCTAssertThrowsError(try store.save(" \n ")) { error in
            XCTAssertEqual(error as? APIKeyStoreError, .emptyKey)
        }
        XCTAssertEqual(try store.load(), "existing-key")
    }

    func testConfigurationMigrationCommitsKeyAndEndpointAsOneBlob() throws {
        let configurationPersistence = InMemoryAPIKeyPersistence()
        let legacyPersistence = InMemoryAPIKeyPersistence(data: Data("legacy-key".utf8))
        let defaults = makeDefaults()
        defaults.set(APIProvider.custom.rawValue, forKey: "apiProvider")
        defaults.set("api.example.com", forKey: "customHost")
        defaults.set("/v2", forKey: "customBasePath")
        defaults.set("whisper-1", forKey: "transcriptionModel")
        let legacyStore = APIKeyStore(
            persistence: legacyPersistence,
            defaults: defaults
        )
        let store = TranscriptionConfigurationStore(
            persistence: configurationPersistence,
            legacyAPIKeyStore: legacyStore,
            defaults: defaults
        )

        let configuration = try store.loadOrMigrate()

        XCTAssertEqual(configuration.apiKey, "legacy-key")
        XCTAssertEqual(configuration.provider, .custom)
        XCTAssertEqual(configuration.endpoint.host, "api.example.com")
        XCTAssertEqual(configuration.endpoint.basePath, "/v2")
        XCTAssertEqual(configuration.model, "whisper-1")
        XCTAssertNotNil(configurationPersistence.data)
        XCTAssertNil(try legacyStore.load())
    }

    func testFailedConfigurationCommitPreservesPreviousCompleteSnapshot() throws {
        let persistence = InMemoryAPIKeyPersistence()
        let legacyStore = APIKeyStore(
            persistence: InMemoryAPIKeyPersistence(),
            defaults: makeDefaults()
        )
        let store = TranscriptionConfigurationStore(
            persistence: persistence,
            legacyAPIKeyStore: legacyStore,
            defaults: makeDefaults()
        )
        let original = StoredTranscriptionConfiguration(
            apiKey: "old-key",
            provider: .custom,
            customHost: "old.example.com",
            customBasePath: "/v1",
            model: "whisper-1"
        )
        try store.save(original)
        persistence.saveError = TestError.failed

        XCTAssertThrowsError(
            try store.save(
                StoredTranscriptionConfiguration(
                    apiKey: "new-key",
                    provider: .custom,
                    customHost: "new.example.com",
                    customBasePath: "/v2",
                    model: "gpt-4o-transcribe"
                )
            )
        )

        persistence.saveError = nil
        XCTAssertEqual(try store.loadOrMigrate(), original)
    }

    func testConfigurationDeleteKeyKeepsEndpointAndModel() throws {
        let persistence = InMemoryAPIKeyPersistence()
        let store = TranscriptionConfigurationStore(
            persistence: persistence,
            legacyAPIKeyStore: APIKeyStore(
                persistence: InMemoryAPIKeyPersistence(),
                defaults: makeDefaults()
            ),
            defaults: makeDefaults()
        )
        let original = StoredTranscriptionConfiguration(
            apiKey: "secret",
            provider: .custom,
            customHost: "api.example.com",
            customBasePath: "/v3",
            model: "gpt-4o-transcribe"
        )
        try store.save(original)

        let result = try store.deleteAPIKey()
        let updated = result.configuration

        XCTAssertNil(updated.apiKey)
        XCTAssertNil(result.legacyCleanupErrorDescription)
        XCTAssertEqual(updated.provider, original.provider)
        XCTAssertEqual(updated.customHost, original.customHost)
        XCTAssertEqual(updated.customBasePath, original.customBasePath)
        XCTAssertEqual(updated.model, original.model)
        XCTAssertEqual(try store.loadOrMigrate(), updated)
    }

    func testCorruptConfigurationFailsClosedWithoutLegacyFallback() {
        let persistence = InMemoryAPIKeyPersistence(data: Data("not-json".utf8))
        let legacyPersistence = InMemoryAPIKeyPersistence(data: Data("legacy-key".utf8))
        let defaults = makeDefaults()
        let legacyStore = APIKeyStore(
            persistence: legacyPersistence,
            defaults: defaults
        )
        let store = TranscriptionConfigurationStore(
            persistence: persistence,
            legacyAPIKeyStore: legacyStore,
            defaults: defaults
        )

        XCTAssertThrowsError(try store.loadOrMigrate()) { error in
            XCTAssertEqual(
                error as? TranscriptionConfigurationStoreError,
                .invalidData
            )
        }
        XCTAssertEqual(try? legacyStore.load(), "legacy-key")
    }

    func testCorruptConfigurationCanBeReplacedExplicitly() throws {
        let persistence = InMemoryAPIKeyPersistence(data: Data("not-json".utf8))
        let store = TranscriptionConfigurationStore(
            persistence: persistence,
            legacyAPIKeyStore: APIKeyStore(
                persistence: InMemoryAPIKeyPersistence(),
                defaults: makeDefaults()
            ),
            defaults: makeDefaults()
        )
        let replacement = StoredTranscriptionConfiguration(
            apiKey: "replacement-key",
            provider: .custom,
            customHost: "api.example.com",
            customBasePath: "/v2",
            model: "gpt-4o-transcribe"
        )

        try store.save(replacement)

        XCTAssertEqual(try store.loadOrMigrate(), replacement)
    }

    func testDeleteAPIKeyRecoversCorruptConfiguration() throws {
        let persistence = InMemoryAPIKeyPersistence(data: Data("not-json".utf8))
        let legacyPersistence = InMemoryAPIKeyPersistence(data: Data("legacy-key".utf8))
        let store = TranscriptionConfigurationStore(
            persistence: persistence,
            legacyAPIKeyStore: APIKeyStore(
                persistence: legacyPersistence,
                defaults: makeDefaults()
            ),
            defaults: makeDefaults()
        )

        let result = try store.deleteAPIKey()
        let configuration = result.configuration

        XCTAssertNil(configuration.apiKey)
        XCTAssertNil(result.legacyCleanupErrorDescription)
        XCTAssertNil(try store.loadOrMigrate().apiKey)
        XCTAssertNil(legacyPersistence.data)
    }

    func testDeleteAPIKeyReportsLegacyCleanupFailure() throws {
        let persistence = InMemoryAPIKeyPersistence()
        let legacyPersistence = InMemoryAPIKeyPersistence(
            data: Data("legacy-key".utf8),
            deleteError: TestError.failed
        )
        let store = TranscriptionConfigurationStore(
            persistence: persistence,
            legacyAPIKeyStore: APIKeyStore(
                persistence: legacyPersistence,
                defaults: makeDefaults()
            ),
            defaults: makeDefaults()
        )
        try store.save(
            StoredTranscriptionConfiguration(
                apiKey: "current-key",
                provider: .openAI,
                customHost: StoredTranscriptionConfiguration.defaultCustomHost,
                customBasePath: StoredTranscriptionConfiguration.defaultCustomBasePath,
                model: StoredTranscriptionConfiguration.defaultModel
            )
        )

        let result = try store.deleteAPIKey()

        XCTAssertNil(result.configuration.apiKey)
        XCTAssertNotNil(result.legacyCleanupErrorDescription)
        XCTAssertNil(try store.loadOrMigrate().apiKey)
        XCTAssertNotNil(legacyPersistence.data)
    }

    func testLoadingValidConfigurationRetriesLegacyCleanup() throws {
        let configuration = StoredTranscriptionConfiguration(
            apiKey: "current-key",
            provider: .openAI,
            customHost: StoredTranscriptionConfiguration.defaultCustomHost,
            customBasePath: StoredTranscriptionConfiguration.defaultCustomBasePath,
            model: StoredTranscriptionConfiguration.defaultModel
        )
        let persistence = InMemoryAPIKeyPersistence(
            data: try JSONEncoder().encode(configuration)
        )
        let legacyPersistence = InMemoryAPIKeyPersistence(data: Data("legacy-key".utf8))
        let store = TranscriptionConfigurationStore(
            persistence: persistence,
            legacyAPIKeyStore: APIKeyStore(
                persistence: legacyPersistence,
                defaults: makeDefaults()
            ),
            defaults: makeDefaults()
        )

        XCTAssertEqual(try store.loadOrMigrate(), configuration)
        XCTAssertNil(legacyPersistence.data)
    }

    func testDeleteWithoutConfigurationDoesNotMigrateLegacyKey() throws {
        let persistence = InMemoryAPIKeyPersistence()
        let legacyPersistence = InMemoryAPIKeyPersistence(saveError: TestError.failed)
        let legacyDefaults = makeDefaults()
        legacyDefaults.set("legacy-key", forKey: "apiKey")
        let store = TranscriptionConfigurationStore(
            persistence: persistence,
            legacyAPIKeyStore: APIKeyStore(
                persistence: legacyPersistence,
                defaults: legacyDefaults
            ),
            defaults: makeDefaults()
        )

        XCTAssertNoThrow(try store.deleteAPIKey())
        XCTAssertNil(legacyDefaults.object(forKey: "apiKey"))
        XCTAssertNil(try store.loadOrMigrate().apiKey)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "APIKeyStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private enum TestError: Error {
    case failed
}

private final class InMemoryAPIKeyPersistence: APIKeyPersistence {
    var data: Data?
    var saveError: Error?
    var deleteError: Error?

    init(
        data: Data? = nil,
        saveError: Error? = nil,
        deleteError: Error? = nil
    ) {
        self.data = data
        self.saveError = saveError
        self.deleteError = deleteError
    }

    func read() throws -> Data? {
        data
    }

    func save(_ data: Data) throws {
        if let saveError {
            throw saveError
        }
        self.data = data
    }

    func delete() throws {
        if let deleteError {
            throw deleteError
        }
        data = nil
    }
}
