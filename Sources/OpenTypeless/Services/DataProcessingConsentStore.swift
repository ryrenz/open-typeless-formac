import Foundation

struct DataProcessingEndpoint: Equatable {
    let provider: APIProvider
    let host: String
    let basePath: String

    static func current(
        provider: APIProvider = TranscriptionService.provider,
        customHost: String = TranscriptionService.customHost,
        customBasePath: String = TranscriptionService.customBasePath
    ) -> DataProcessingEndpoint {
        switch provider {
        case .openAI:
            return DataProcessingEndpoint(
                provider: .openAI,
                host: provider.providerPreset.defaultHost,
                basePath: provider.providerPreset.defaultBasePath
            )
        case .groq, .mistral:
            return DataProcessingEndpoint(
                provider: provider,
                host: provider.providerPreset.defaultHost,
                basePath: provider.providerPreset.defaultBasePath
            )
        case .custom:
            return DataProcessingEndpoint(
                provider: .custom,
                host: normalizedHost(customHost),
                basePath: normalizedBasePath(customBasePath)
            )
        }
    }

    var fingerprint: String {
        "v1|\(provider.rawValue)|\(host)|\(basePath)"
    }

    var displayAddress: String {
        "https://\(host)\(basePath)"
    }

    var isValid: Bool {
        guard provider.providerPreset.allowsCustomEndpoint else { return true }
        guard !host.isEmpty,
              !basePath.contains(where: { $0.isWhitespace }),
              !basePath.contains("?"),
              !basePath.contains("#"),
              let components = URLComponents(string: "https://\(host)"),
              components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil
        else {
            return false
        }
        return true
    }

    private static func normalizedHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        for prefix in ["https://", "http://"] where normalized.hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
        }
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func normalizedBasePath(_ basePath: String) -> String {
        let trimmed = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withoutTrailingSlash = trimmed == "/"
            ? ""
            : trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return withoutTrailingSlash.isEmpty ? "" : "/\(withoutTrailingSlash)"
    }
}

struct DataProcessingConsentToken: Equatable {
    fileprivate let fingerprint: String
    fileprivate let generation: UInt64
}

enum DataProcessingConsentAuthorizationError: Error {
    case revoked
}

private final class ConsentRequestStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

final class DataProcessingConsentStore {
    static let shared = DataProcessingConsentStore()

    private let defaults: UserDefaults
    private let consentKey: String
    private let generationKey: String
    private let lock = NSLock()
    private var activeRequests: [UUID: (fingerprint: String, cancel: () -> Void)] = [:]

    init(
        defaults: UserDefaults = .standard,
        consentKey: String = "dataProcessingConsentEndpoint.v1",
        generationKey: String = "dataProcessingConsentGenerations.v1"
    ) {
        self.defaults = defaults
        self.consentKey = consentKey
        self.generationKey = generationKey
    }

    func hasConsent(for endpoint: DataProcessingEndpoint) -> Bool {
        consentToken(for: endpoint) != nil
    }

    func consentToken(
        for endpoint: DataProcessingEndpoint
    ) -> DataProcessingConsentToken? {
        withLock {
            guard consentFingerprints.contains(endpoint.fingerprint) else {
                return nil
            }
            return DataProcessingConsentToken(
                fingerprint: endpoint.fingerprint,
                generation: consentGenerations[endpoint.fingerprint] ?? 0
            )
        }
    }

    func isConsentValid(
        _ token: DataProcessingConsentToken,
        for endpoint: DataProcessingEndpoint
    ) -> Bool {
        withLock {
            token.fingerprint == endpoint.fingerprint
                && consentFingerprints.contains(token.fingerprint)
                && (consentGenerations[token.fingerprint] ?? 0) == token.generation
        }
    }

    func grantConsent(for endpoint: DataProcessingEndpoint) {
        withLock {
            var fingerprints = consentFingerprints
            fingerprints.insert(endpoint.fingerprint)
            defaults.set(fingerprints.sorted(), forKey: consentKey)
        }
    }

    func revokeConsent(for endpoint: DataProcessingEndpoint) {
        let cancellations = withLock {
            var fingerprints = consentFingerprints
            fingerprints.remove(endpoint.fingerprint)
            saveConsentFingerprints(fingerprints)
            incrementGeneration(for: endpoint.fingerprint)
            return removeActiveRequests(for: [endpoint.fingerprint])
        }
        cancellations.forEach { $0() }
    }

    func revokeConsent() {
        let cancellations = withLock {
            let fingerprints = Set(consentFingerprints)
                .union(activeRequests.values.map(\.fingerprint))
            defaults.removeObject(forKey: consentKey)
            for fingerprint in fingerprints {
                incrementGeneration(for: fingerprint)
            }
            return removeActiveRequests(for: fingerprints)
        }
        cancellations.forEach { $0() }
    }

    func performAuthorizedRequest<T>(
        token: DataProcessingConsentToken,
        endpoint: DataProcessingEndpoint,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let startGate = ConsentRequestStartGate()
        let requestID = UUID()
        let task = Task {
            await startGate.wait()
            try Task.checkCancellation()
            return try await operation()
        }

        let isRegistered = withLock {
            guard token.fingerprint == endpoint.fingerprint,
                  consentFingerprints.contains(token.fingerprint),
                  (consentGenerations[token.fingerprint] ?? 0) == token.generation
            else {
                return false
            }
            activeRequests[requestID] = (
                fingerprint: token.fingerprint,
                cancel: { task.cancel() }
            )
            return true
        }

        guard isRegistered else {
            task.cancel()
            startGate.open()
            throw DataProcessingConsentAuthorizationError.revoked
        }
        startGate.open()
        defer {
            _ = withLock {
                activeRequests.removeValue(forKey: requestID)
            }
        }

        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if !isConsentValid(token, for: endpoint) {
                throw DataProcessingConsentAuthorizationError.revoked
            }
            if task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private var consentFingerprints: Set<String> {
        if let fingerprints = defaults.stringArray(forKey: consentKey) {
            return Set(fingerprints)
        }
        if let legacyFingerprint = defaults.string(forKey: consentKey) {
            return [legacyFingerprint]
        }
        return []
    }

    private var consentGenerations: [String: UInt64] {
        guard let stored = defaults.dictionary(forKey: generationKey) else {
            return [:]
        }
        return stored.reduce(into: [:]) { result, entry in
            if let value = entry.value as? NSNumber {
                result[entry.key] = value.uint64Value
            }
        }
    }

    private func saveConsentFingerprints(_ fingerprints: Set<String>) {
        if fingerprints.isEmpty {
            defaults.removeObject(forKey: consentKey)
        } else {
            defaults.set(fingerprints.sorted(), forKey: consentKey)
        }
    }

    private func incrementGeneration(for fingerprint: String) {
        var generations = consentGenerations
        generations[fingerprint] = (generations[fingerprint] ?? 0) &+ 1
        defaults.set(generations, forKey: generationKey)
    }

    private func removeActiveRequests(
        for fingerprints: Set<String>
    ) -> [() -> Void] {
        let matchingIDs = activeRequests.compactMap { entry in
            fingerprints.contains(entry.value.fingerprint) ? entry.key : nil
        }
        return matchingIDs.compactMap { activeRequests.removeValue(forKey: $0)?.cancel }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
