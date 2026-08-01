import XCTest
@testable import OpenTypeless

final class DataProcessingConsentStoreTests: XCTestCase {
    func testConsentIsScopedToNormalizedEndpoint() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let endpoint = DataProcessingEndpoint.current(
            provider: .custom,
            customHost: " HTTPS://Example.COM/ ",
            customBasePath: "/backend/v1/"
        )

        store.grantConsent(for: endpoint)

        XCTAssertTrue(
            store.hasConsent(
                for: .current(
                    provider: .custom,
                    customHost: "example.com",
                    customBasePath: "backend/v1"
                )
            )
        )
        XCTAssertFalse(
            store.hasConsent(
                for: .current(
                    provider: .custom,
                    customHost: "other.example.com",
                    customBasePath: "backend/v1"
                )
            )
        )
    }

    func testOpenAIEndpointDoesNotDependOnCustomFields() {
        let first = DataProcessingEndpoint.current(
            provider: .openAI,
            customHost: "one.example.com",
            customBasePath: "/one"
        )
        let second = DataProcessingEndpoint.current(
            provider: .openAI,
            customHost: "two.example.com",
            customBasePath: "/two"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.displayAddress, "https://api.openai.com/v1")
    }

    func testRevokeRemovesConsent() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let endpoint = DataProcessingEndpoint.current(provider: .openAI)
        store.grantConsent(for: endpoint)

        store.revokeConsent()

        XCTAssertFalse(store.hasConsent(for: endpoint))
    }

    func testConsentIsRememberedForEachEndpoint() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let openAI = DataProcessingEndpoint.current(provider: .openAI)
        let custom = DataProcessingEndpoint.current(
            provider: .custom,
            customHost: "api.example.com",
            customBasePath: "/v1"
        )

        store.grantConsent(for: openAI)
        store.grantConsent(for: custom)

        XCTAssertTrue(store.hasConsent(for: openAI))
        XCTAssertTrue(store.hasConsent(for: custom))
    }

    func testRevokeOnlyRemovesSelectedEndpoint() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let openAI = DataProcessingEndpoint.current(provider: .openAI)
        let custom = DataProcessingEndpoint.current(
            provider: .custom,
            customHost: "api.example.com",
            customBasePath: "/v1"
        )
        store.grantConsent(for: openAI)
        store.grantConsent(for: custom)

        store.revokeConsent(for: custom)

        XCTAssertTrue(store.hasConsent(for: openAI))
        XCTAssertFalse(store.hasConsent(for: custom))
    }

    func testLegacySingleFingerprintMigratesWhenNewEndpointIsGranted() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let openAI = DataProcessingEndpoint.current(provider: .openAI)
        let custom = DataProcessingEndpoint.current(
            provider: .custom,
            customHost: "api.example.com",
            customBasePath: "/v1"
        )
        defaults.set(openAI.fingerprint, forKey: "dataProcessingConsentEndpoint.v1")

        store.grantConsent(for: custom)

        XCTAssertTrue(store.hasConsent(for: openAI))
        XCTAssertTrue(store.hasConsent(for: custom))
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "dataProcessingConsentEndpoint.v1") ?? []),
            Set([openAI.fingerprint, custom.fingerprint])
        )
    }

    func testRevokedTokenDoesNotBecomeValidAfterConsentIsGrantedAgain() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let endpoint = DataProcessingEndpoint.current(provider: .openAI)
        store.grantConsent(for: endpoint)
        let oldToken = try! XCTUnwrap(store.consentToken(for: endpoint))

        store.revokeConsent(for: endpoint)
        store.grantConsent(for: endpoint)

        XCTAssertFalse(store.isConsentValid(oldToken, for: endpoint))
        let newToken = try! XCTUnwrap(store.consentToken(for: endpoint))
        XCTAssertTrue(store.isConsentValid(newToken, for: endpoint))
        XCTAssertNotEqual(oldToken, newToken)
    }

    func testRevokingConsentCancelsAnActiveAuthorizedRequest() async throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let endpoint = DataProcessingEndpoint.current(provider: .openAI)
        store.grantConsent(for: endpoint)
        let token = try XCTUnwrap(store.consentToken(for: endpoint))
        let requestStarted = expectation(description: "Authorized request started")

        let request = Task {
            try await store.performAuthorizedRequest(
                token: token,
                endpoint: endpoint
            ) {
                requestStarted.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "unexpected"
            }
        }
        await fulfillment(of: [requestStarted], timeout: 1)

        store.revokeConsent(for: endpoint)
        store.grantConsent(for: endpoint)

        do {
            _ = try await request.value
            XCTFail("Expected the old request token to be revoked")
        } catch DataProcessingConsentAuthorizationError.revoked {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRevokedTokenNeverStartsARequestOperation() async throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let endpoint = DataProcessingEndpoint.current(provider: .openAI)
        store.grantConsent(for: endpoint)
        let token = try XCTUnwrap(store.consentToken(for: endpoint))
        store.revokeConsent(for: endpoint)
        let operationStarted = expectation(description: "Operation must not start")
        operationStarted.isInverted = true

        do {
            _ = try await store.performAuthorizedRequest(
                token: token,
                endpoint: endpoint
            ) {
                operationStarted.fulfill()
                return "unexpected"
            }
            XCTFail("Expected the token to be rejected")
        } catch DataProcessingConsentAuthorizationError.revoked {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [operationStarted], timeout: 0.1)
    }

    func testCallerCancellationPropagatesToAuthorizedOperation() async throws {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let endpoint = DataProcessingEndpoint.current(provider: .openAI)
        store.grantConsent(for: endpoint)
        let token = try XCTUnwrap(store.consentToken(for: endpoint))
        let operationStarted = expectation(description: "Operation started")

        let request = Task {
            try await store.performAuthorizedRequest(
                token: token,
                endpoint: endpoint
            ) {
                operationStarted.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "unexpected"
            }
        }
        await fulfillment(of: [operationStarted], timeout: 1)
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(store.hasConsent(for: endpoint))
    }

    func testCustomEndpointValidationRejectsEmbeddedPathAndCredentials() {
        XCTAssertFalse(
            DataProcessingEndpoint.current(
                provider: .custom,
                customHost: "example.com/path",
                customBasePath: "/v1"
            ).isValid
        )
        XCTAssertFalse(
            DataProcessingEndpoint.current(
                provider: .custom,
                customHost: "user@example.com",
                customBasePath: "/v1"
            ).isValid
        )
        XCTAssertTrue(
            DataProcessingEndpoint.current(
                provider: .custom,
                customHost: "api.example.com",
                customBasePath: "/backend/v1"
            ).isValid
        )
    }

    private func makeStore() -> (DataProcessingConsentStore, UserDefaults, String) {
        let suiteName = "DataProcessingConsentStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (DataProcessingConsentStore(defaults: defaults), defaults, suiteName)
    }
}
