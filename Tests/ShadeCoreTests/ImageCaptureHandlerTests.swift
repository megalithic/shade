import XCTest
@testable import ShadeCore

/// Mock file system for testing ImageCaptureProcessor
final class MockFileSystem: FileSystemProvider {
    var existingFiles: Set<String> = []
    var existingDirectories: Set<String> = []
    var copiedFiles: [(from: String, to: String)] = []
    var removedFiles: [String] = []
    var createdDirectories: [String] = []

    var shouldFailCopy = false
    var shouldFailCreateDirectory = false
    var shouldFailRemove = false

    func fileExists(atPath path: String) -> Bool {
        existingFiles.contains(path) || existingDirectories.contains(path)
    }

    func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool {
        if existingDirectories.contains(path) {
            isDirectory = true
            return true
        }
        if existingFiles.contains(path) {
            isDirectory = false
            return true
        }
        isDirectory = false
        return false
    }

    func createDirectory(atPath path: String) throws {
        if shouldFailCreateDirectory {
            throw NSError(domain: "MockFileSystem", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock directory creation failure"])
        }
        createdDirectories.append(path)
        existingDirectories.insert(path)
    }

    func copyItem(atPath src: String, toPath dest: String) throws {
        if shouldFailCopy {
            throw NSError(domain: "MockFileSystem", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mock copy failure"])
        }
        copiedFiles.append((from: src, to: dest))
        existingFiles.insert(dest)
    }

    func removeItem(atPath path: String) throws {
        if shouldFailRemove {
            throw NSError(domain: "MockFileSystem", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mock remove failure"])
        }
        removedFiles.append(path)
        existingFiles.remove(path)
    }
}

final class ImageCaptureHandlerTests: XCTestCase {

    var mockFileSystem: MockFileSystem!
    var fixedDate: Date!
    var processor: ImageCaptureProcessor!

    override func setUp() {
        super.setUp()
        mockFileSystem = MockFileSystem()

        // Fixed date: 2026-01-12 14:30:45 in local timezone
        // Using local timezone so DateFormatter output matches expected values
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 12
        components.hour = 14
        components.minute = 30
        components.second = 45
        fixedDate = Calendar.current.date(from: components)!

        processor = ImageCaptureProcessor(
            fileSystem: mockFileSystem,
            dateProvider: { [weak self] in self?.fixedDate ?? Date() }
        )
    }

    override func tearDown() {
        mockFileSystem = nil
        processor = nil
        super.tearDown()
    }

    // MARK: - generateTimestampFilename Tests

    func testGenerateTimestampFilename_ReturnsCorrectFormat() {
        let filename = processor.generateTimestampFilename()
        XCTAssertEqual(filename, "20260112-143045.png")
    }

    func testGenerateTimestampFilename_HasPngExtension() {
        let filename = processor.generateTimestampFilename()
        XCTAssertTrue(filename.hasSuffix(".png"))
    }

    // MARK: - processCapture Tests

    func testProcessCapture_Success() {
        let tempPath = "/Users/test/_screenshots/temp.png"
        let assetsDir = "/Users/test/notes/assets"

        // Setup: temp file exists, assets dir exists
        mockFileSystem.existingFiles.insert(tempPath)
        mockFileSystem.existingDirectories.insert(assetsDir)

        let result = processor.processCapture(tempPath: tempPath, assetsDir: assetsDir)

        switch result {
        case .success(let filename):
            XCTAssertEqual(filename, "20260112-143045.png")
            XCTAssertEqual(mockFileSystem.copiedFiles.count, 1)
            XCTAssertEqual(mockFileSystem.copiedFiles[0].from, tempPath)
            XCTAssertTrue(mockFileSystem.copiedFiles[0].to.hasSuffix("/20260112-143045.png"))
        case .failure(let error):
            XCTFail("Expected success, got error: \(error)")
        }
    }

    func testProcessCapture_CreatesAssetsDirectoryIfMissing() {
        let tempPath = "/Users/test/_screenshots/temp.png"
        let assetsDir = "/Users/test/notes/assets"

        // Setup: temp file exists, assets dir does NOT exist
        mockFileSystem.existingFiles.insert(tempPath)

        let result = processor.processCapture(tempPath: tempPath, assetsDir: assetsDir)

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(mockFileSystem.createdDirectories.contains(assetsDir))
    }

    func testProcessCapture_FailsWhenTempFileNotFound() {
        let tempPath = "/nonexistent/temp.png"
        let assetsDir = "/Users/test/notes/assets"

        let result = processor.processCapture(tempPath: tempPath, assetsDir: assetsDir)

        switch result {
        case .success:
            XCTFail("Expected failure for missing temp file")
        case .failure(let error):
            XCTAssertEqual(error, .tempFileNotFound(tempPath))
        }
    }

    func testProcessCapture_FailsWhenCopyFails() {
        let tempPath = "/Users/test/_screenshots/temp.png"
        let assetsDir = "/Users/test/notes/assets"

        mockFileSystem.existingFiles.insert(tempPath)
        mockFileSystem.existingDirectories.insert(assetsDir)
        mockFileSystem.shouldFailCopy = true

        let result = processor.processCapture(tempPath: tempPath, assetsDir: assetsDir)

        switch result {
        case .success:
            XCTFail("Expected failure when copy fails")
        case .failure(let error):
            if case .copyFailed(let src, let dest) = error {
                XCTAssertEqual(src, tempPath)
                XCTAssertTrue(dest.contains("assets"))
            } else {
                XCTFail("Expected copyFailed error, got: \(error)")
            }
        }
    }

    func testProcessCapture_FailsWhenAssetsDirIsFile() {
        let tempPath = "/Users/test/_screenshots/temp.png"
        let assetsDir = "/Users/test/notes/assets"

        // Setup: temp file exists, but assets "dir" is actually a file
        mockFileSystem.existingFiles.insert(tempPath)
        mockFileSystem.existingFiles.insert(assetsDir)  // File, not directory

        let result = processor.processCapture(tempPath: tempPath, assetsDir: assetsDir)

        switch result {
        case .success:
            XCTFail("Expected failure when assets dir is a file")
        case .failure(let error):
            XCTAssertEqual(error, .pathExistsButIsFile(assetsDir))
        }
    }

    // MARK: - isSafeToDelete Tests

    func testIsSafeToDelete_AllowsScreenshotsDir() {
        let home = NSHomeDirectory()
        let path = "\(home)/_screenshots/temp.png"
        XCTAssertTrue(processor.isSafeToDelete(path))
    }

    func testIsSafeToDelete_AllowsTmpDir() {
        XCTAssertTrue(processor.isSafeToDelete("/tmp/temp.png"))
    }

    func testIsSafeToDelete_AllowsNSTemporaryDirectory() {
        let path = NSTemporaryDirectory() + "temp.png"
        XCTAssertTrue(processor.isSafeToDelete(path))
    }

    func testIsSafeToDelete_DeniesHomeDir() {
        let home = NSHomeDirectory()
        XCTAssertFalse(processor.isSafeToDelete("\(home)/Documents/important.txt"))
    }

    func testIsSafeToDelete_DeniesNotesDir() {
        let home = NSHomeDirectory()
        XCTAssertFalse(processor.isSafeToDelete("\(home)/notes/assets/image.png"))
    }

    func testIsSafeToDelete_DeniesRandomPath() {
        XCTAssertFalse(processor.isSafeToDelete("/usr/local/bin/something"))
    }

    // MARK: - deleteTempFile Tests

    func testDeleteTempFile_SuccessForAllowedPath() {
        let home = NSHomeDirectory()
        let path = "\(home)/_screenshots/temp.png"
        mockFileSystem.existingFiles.insert(path)

        let result = processor.deleteTempFile(path)

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(mockFileSystem.removedFiles.contains(path))
    }

    func testDeleteTempFile_DeniedForDisallowedPath() {
        let home = NSHomeDirectory()
        let path = "\(home)/Documents/important.txt"

        let result = processor.deleteTempFile(path)

        switch result {
        case .success:
            XCTFail("Expected failure for disallowed path")
        case .failure(let error):
            XCTAssertEqual(error, .deletionDenied(path))
        }
        XCTAssertTrue(mockFileSystem.removedFiles.isEmpty)
    }

    func testDeleteTempFile_SucceedsEvenIfRemoveFails() {
        let path = "/tmp/temp.png"
        mockFileSystem.existingFiles.insert(path)
        mockFileSystem.shouldFailRemove = true

        // Deletion failure is non-fatal, should still return success
        let result = processor.deleteTempFile(path)
        XCTAssertTrue(result.isSuccess)
    }
}

// MARK: - Result Helpers

extension Result {
    var isSuccess: Bool {
        switch self {
        case .success: return true
        case .failure: return false
        }
    }
}
