import Foundation
import XCTest
@testable import SwiftMiner

final class DiskCacheBudgetTests: XCTestCase {
    func testPruneRemovesOldestFilesUntilCountAndByteLimitsAreMet() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMiner-DiskCacheBudget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldest = try makeFile(named: "oldest", bytes: 4, age: 300, in: directory)
        let middle = try makeFile(named: "middle", bytes: 4, age: 200, in: directory)
        let newest = try makeFile(named: "newest", bytes: 4, age: 100, in: directory)

        let result = DiskCacheBudget.prune(
            directory: directory,
            maximumBytes: 8,
            maximumFileCount: 2
        )

        XCTAssertEqual(result.filesBefore, 3)
        XCTAssertEqual(result.bytesBefore, 12)
        XCTAssertEqual(result.filesAfter, 2)
        XCTAssertEqual(result.bytesAfter, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
    }

    func testPruneContinuesUntilTheByteBudgetIsMet() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMiner-DiskCacheBudget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try makeFile(named: "oldest", bytes: 5, age: 300, in: directory)
        _ = try makeFile(named: "middle", bytes: 5, age: 200, in: directory)
        let newest = try makeFile(named: "newest", bytes: 5, age: 100, in: directory)

        let result = DiskCacheBudget.prune(
            directory: directory,
            maximumBytes: 6,
            maximumFileCount: 10
        )

        XCTAssertEqual(result.removedFiles, 2)
        XCTAssertEqual(result.bytesAfter, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
    }

    private func makeFile(named name: String, bytes: Int, age: TimeInterval, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
        return url
    }
}
