import Foundation

struct ScanExportResult {
    let folderURL: URL
    let videoURL: URL
    let metadataURL: URL
}

enum ScanFileExporter {
    static func export(
        videoURL: URL,
        metadataData: Data,
        createdAt: Date,
        fileManager: FileManager = .default,
        documentsDirectory: URL? = nil
    ) throws -> ScanExportResult {
        let root = try documentsDirectory ?? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let folderURL = try uniqueFolderURL(in: root, createdAt: createdAt, fileManager: fileManager)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let exportedVideoURL = folderURL.appendingPathComponent("scan.mov")
        let metadataURL = folderURL.appendingPathComponent("scan_metadata.json")
        try fileManager.copyItem(at: videoURL, to: exportedVideoURL)
        try metadataData.write(to: metadataURL, options: .atomic)

        return ScanExportResult(folderURL: folderURL, videoURL: exportedVideoURL, metadataURL: metadataURL)
    }

    private static func uniqueFolderURL(in root: URL, createdAt: Date, fileManager: FileManager) throws -> URL {
        let baseName = "scan_\(folderTimestamp(from: createdAt))"
        var candidate = root.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(baseName)_\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func folderTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }
}

