import XCTest
@testable import ShadeCore

final class NotesConfigTests: XCTestCase {

    // MARK: - resolvedHome Tests

    func testResolvedHome_UsesConfiguredHome() {
        let config = NotesConfig(home: "~/custom-notes")

        let result = config.resolvedHome(
            environment: [:],
            fileExists: { _ in false }
        )

        // Should expand tilde
        XCTAssertTrue(result.hasSuffix("/custom-notes"))
        XCTAssertFalse(result.hasPrefix("~"))
    }

    func testResolvedHome_UsesNOTES_HOMEEnvVar() {
        let config = NotesConfig()

        let result = config.resolvedHome(
            environment: ["NOTES_HOME": "/env/notes"],
            fileExists: { _ in false }
        )

        XCTAssertEqual(result, "/env/notes")
    }

    func testResolvedHome_ChecksICloudPath() {
        let config = NotesConfig()
        let expectedICloudPath = "\(NSHomeDirectory())/iclouddrive/Documents/_notes"

        let result = config.resolvedHome(
            environment: [:],
            fileExists: { path in path == expectedICloudPath }
        )

        XCTAssertEqual(result, expectedICloudPath)
    }

    func testResolvedHome_DefaultsToHomeNotes() {
        let config = NotesConfig()
        let expected = "\(NSHomeDirectory())/notes"

        let result = config.resolvedHome(
            environment: [:],
            fileExists: { _ in false }
        )

        XCTAssertEqual(result, expected)
    }

    func testResolvedHome_ConfigTakesPrecedenceOverEnv() {
        let config = NotesConfig(home: "/configured/path")

        let result = config.resolvedHome(
            environment: ["NOTES_HOME": "/env/notes"],
            fileExists: { _ in true }
        )

        XCTAssertEqual(result, "/configured/path")
    }

    // MARK: - resolvedAssetsDir Tests

    func testResolvedAssetsDir_UsesConfiguredDir() {
        let config = NotesConfig(assetsDir: "~/custom-assets")

        let result = config.resolvedAssetsDir(
            environment: [:],
            fileExists: { _ in false }
        )

        XCTAssertTrue(result.hasSuffix("/custom-assets"))
        XCTAssertFalse(result.hasPrefix("~"))
    }

    func testResolvedAssetsDir_DefaultsToHomeAssets() {
        let config = NotesConfig(home: "/my/notes")

        let result = config.resolvedAssetsDir(
            environment: [:],
            fileExists: { _ in false }
        )

        XCTAssertEqual(result, "/my/notes/assets")
    }

    func testResolvedAssetsDir_UsesResolvedHomeWhenNoConfig() {
        let config = NotesConfig()

        let result = config.resolvedAssetsDir(
            environment: ["NOTES_HOME": "/env/notes"],
            fileExists: { _ in false }
        )

        XCTAssertEqual(result, "/env/notes/assets")
    }

    // MARK: - resolvedCapturesDir Tests

    func testResolvedCapturesDir_UsesConfiguredDir() {
        let config = NotesConfig(capturesDir: "~/custom-captures")

        let result = config.resolvedCapturesDir(
            environment: [:],
            fileExists: { _ in false }
        )

        XCTAssertTrue(result.hasSuffix("/custom-captures"))
        XCTAssertFalse(result.hasPrefix("~"))
    }

    func testResolvedCapturesDir_DefaultsToHomeCaptures() {
        let config = NotesConfig(home: "/my/notes")

        let result = config.resolvedCapturesDir(
            environment: [:],
            fileExists: { _ in false }
        )

        XCTAssertEqual(result, "/my/notes/captures")
    }

    // MARK: - Codable Tests

    func testCodable_EncodesWithSnakeCaseKeys() throws {
        let config = NotesConfig(
            home: "/notes",
            assetsDir: "/notes/assets",
            capturesDir: "/notes/captures"
        )

        let data = try JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"assets_dir\""))
        XCTAssertTrue(json.contains("\"captures_dir\""))
    }

    func testCodable_DecodesFromSnakeCaseKeys() throws {
        let json = """
        {
            "home": "/notes",
            "assets_dir": "/notes/assets",
            "captures_dir": "/notes/captures"
        }
        """

        let config = try JSONDecoder().decode(NotesConfig.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(config.home, "/notes")
        XCTAssertEqual(config.assetsDir, "/notes/assets")
        XCTAssertEqual(config.capturesDir, "/notes/captures")
    }

    func testCodable_HandlesNilValues() throws {
        let config = NotesConfig()

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(NotesConfig.self, from: data)

        XCTAssertNil(decoded.home)
        XCTAssertNil(decoded.assetsDir)
        XCTAssertNil(decoded.capturesDir)
    }

    // MARK: - Equatable Tests

    func testEquatable_EqualConfigs() {
        let config1 = NotesConfig(home: "/notes", assetsDir: "/assets")
        let config2 = NotesConfig(home: "/notes", assetsDir: "/assets")

        XCTAssertEqual(config1, config2)
    }

    func testEquatable_DifferentConfigs() {
        let config1 = NotesConfig(home: "/notes1")
        let config2 = NotesConfig(home: "/notes2")

        XCTAssertNotEqual(config1, config2)
    }
}
