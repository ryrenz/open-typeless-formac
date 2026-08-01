import XCTest
@testable import OpenTypeless

final class PrivacyPolicyDocumentTests: XCTestCase {
    func testLoadReadsUTF8Markdown() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyPolicyDocumentTests-\(UUID().uuidString)")
            .appendingPathExtension("md")
        let policy = "# Privacy Policy\n\nLocal and network data details."
        try policy.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(PrivacyPolicyDocument.load(url: url), policy)
    }

    func testLoadReturnsNilForMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).md")

        XCTAssertNil(PrivacyPolicyDocument.load(url: url))
    }
}
