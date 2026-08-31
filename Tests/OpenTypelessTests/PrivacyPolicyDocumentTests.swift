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

    func testTrackedRepositoryFilesContainNoHanCharactersOutsideReadmes() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryRoot.path, "ls-files", "-z"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        let fileListData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let exemptPaths: Set<String> = ["README.md", "README_CN.md"]
        let trackedPaths = try XCTUnwrap(String(data: fileListData, encoding: .utf8))
            .split(separator: "\0")
            .map(String.init)
        var violations: [String] = []
        var totalBytesRead: UInt64 = 0

        for path in trackedPaths where !exemptPaths.contains(path) {
            let fileURL = repositoryRoot.appendingPathComponent(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = try FileManager.default.destinationOfSymbolicLink(
                    atPath: fileURL.path
                )
                if Self.containsHanCharacters(destination) {
                    violations.append(path)
                }
                continue
            }

            XCTAssertEqual(
                attributes[.type] as? FileAttributeType,
                .typeRegular,
                "Tracked path is not a regular file: \(path)"
            )
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                continue
            }

            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? fileHandle.close() }
            let signature = try fileHandle.read(upToCount: 16) ?? Data()
            if Self.hasKnownBinarySignature(signature) {
                continue
            }

            XCTAssertLessThanOrEqual(
                fileSize,
                Self.maxTextFileBytes,
                "Tracked text file exceeds the scan limit: \(path)"
            )
            guard fileSize <= Self.maxTextFileBytes else { continue }
            totalBytesRead += fileSize
            XCTAssertLessThanOrEqual(
                totalBytesRead,
                Self.maxTotalTextBytes,
                "Tracked text files exceed the total scan limit"
            )
            guard totalBytesRead <= Self.maxTotalTextBytes else { break }

            try fileHandle.seek(toOffset: 0)
            let data = try fileHandle.readToEnd() ?? Data()
            guard let text = Self.decodeText(data) else {
                XCTFail("Tracked non-binary file uses an unsupported text encoding: \(path)")
                continue
            }
            if Self.containsHanCharacters(text) {
                violations.append(path)
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Tracked files containing Han characters: \(violations.joined(separator: ", "))"
        )
    }

    private static let maxTextFileBytes: UInt64 = 5 * 1_024 * 1_024
    private static let maxTotalTextBytes: UInt64 = 50 * 1_024 * 1_024

    private static func containsHanCharacters(_ text: String) -> Bool {
        text.range(
            of: #"[\p{sc=Han}]"#,
            options: .regularExpression
        ) != nil
    }

    private static func hasKnownBinarySignature(_ data: Data) -> Bool {
        let signatures: [[UInt8]] = [
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            [0xFF, 0xD8, 0xFF],
            [0x47, 0x49, 0x46, 0x38],
            [0x25, 0x50, 0x44, 0x46],
            [0x50, 0x4B, 0x03, 0x04],
            [0x69, 0x63, 0x6E, 0x73],
        ]
        return signatures.contains { data.starts(with: $0) }
    }

    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: data, encoding: .utf32BigEndian)
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return String(data: data, encoding: .utf32LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        guard data.count.isMultiple(of: 2), !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        let evenZeroCount = stride(from: 0, to: bytes.count, by: 2)
            .reduce(into: 0) { count, index in count += bytes[index] == 0 ? 1 : 0 }
        let oddZeroCount = stride(from: 1, to: bytes.count, by: 2)
            .reduce(into: 0) { count, index in count += bytes[index] == 0 ? 1 : 0 }
        let minimumZeroCount = bytes.count / 4
        if oddZeroCount >= minimumZeroCount, oddZeroCount > evenZeroCount {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if evenZeroCount >= minimumZeroCount, evenZeroCount > oddZeroCount {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return nil
    }
}
