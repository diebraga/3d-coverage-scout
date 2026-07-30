import XCTest
@testable import CoverageScout

final class ScanFileExporterTests: XCTestCase {
    func test_exportCreatesFilesAppFolderWithVideoAndMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceVideo = root.appendingPathComponent("source.mov")
        let sourceBytes = Data([1, 2, 3, 4])
        try sourceBytes.write(to: sourceVideo)
        let metadata = Data("{\"schema_version\":1}".utf8)
        let createdAt = Date(timeIntervalSince1970: 1_785_440_365)

        let result = try ScanFileExporter.export(
            videoURL: sourceVideo,
            metadataData: metadata,
            createdAt: createdAt,
            documentsDirectory: root
        )

        XCTAssertEqual(result.folderURL.lastPathComponent, "scan_2026-07-30_193925")
        XCTAssertEqual(result.videoURL.lastPathComponent, "scan.mov")
        XCTAssertEqual(result.metadataURL.lastPathComponent, "scan_metadata.json")
        XCTAssertEqual(try Data(contentsOf: result.videoURL), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: result.metadataURL), metadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceVideo.path))
    }

    func test_exportAvoidsOverwritingExistingScanFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("scan_2026-07-30_193925", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let sourceVideo = root.appendingPathComponent("source.mov")
        try Data([9]).write(to: sourceVideo)

        let result = try ScanFileExporter.export(
            videoURL: sourceVideo,
            metadataData: Data([8]),
            createdAt: Date(timeIntervalSince1970: 1_785_440_365),
            documentsDirectory: root
        )

        XCTAssertEqual(result.folderURL.lastPathComponent, "scan_2026-07-30_193925_2")
    }
}
