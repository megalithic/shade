import XCTest
@testable import ContextGatherer

final class AppTypeDetectorTests: XCTestCase {

    // MARK: - Browser Detection Tests (Exact Match)

    func testDetect_Safari_ReturnsBrowser() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.apple.Safari"), .browser)
    }

    func testDetect_Chrome_ReturnsBrowser() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.google.Chrome"), .browser)
    }

    func testDetect_ChromeCanary_ReturnsBrowser() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.google.Chrome.canary"), .browser)
    }

    func testDetect_BraveBrowser_ReturnsBrowser() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.brave.Browser"), .browser)
    }

    func testDetect_BraveNightly_ReturnsBrowser() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.brave.Browser.nightly"), .browser)
    }

    func testDetect_Arc_ReturnsBrowser() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "company.thebrowser.Browser"), .browser)
    }

    func testDetect_Firefox_ReturnsBrowser() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "org.mozilla.firefox"), .browser)
    }

    func testDetect_Edge_ReturnsBrowser() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.microsoft.edgemac"), .browser)
    }

    // MARK: - Terminal Detection Tests (Exact Match)

    func testDetect_Ghostty_ReturnsTerminal() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.mitchellh.ghostty"), .terminal)
    }

    func testDetect_Kitty_ReturnsTerminal() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "net.kovidgoyal.kitty"), .terminal)
    }

    func testDetect_iTerm2_ReturnsTerminal() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.googlecode.iterm2"), .terminal)
    }

    func testDetect_AppleTerminal_ReturnsTerminal() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.apple.Terminal"), .terminal)
    }

    func testDetect_Alacritty_ReturnsTerminal() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "io.alacritty"), .terminal)
    }

    func testDetect_Warp_ReturnsTerminal() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "dev.warp.Warp-Stable"), .terminal)
    }

    // MARK: - Editor Detection Tests (Exact Match)

    func testDetect_VSCode_ReturnsEditor() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.microsoft.VSCode"), .editor)
    }

    func testDetect_VSCodeInsiders_ReturnsEditor() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.microsoft.VSCodeInsiders"), .editor)
    }

    func testDetect_Xcode_ReturnsEditor() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.apple.dt.Xcode"), .editor)
    }

    func testDetect_Zed_ReturnsEditor() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "dev.zed.Zed"), .editor)
    }

    func testDetect_ZedPreview_ReturnsEditor() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "dev.zed.Zed-Preview"), .editor)
    }

    func testDetect_SublimeText_ReturnsEditor() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.sublimetext.4"), .editor)
    }

    func testDetect_Nova_ReturnsEditor() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.panic.Nova"), .editor)
    }

    func testDetect_Cursor_ReturnsEditor() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.todesktop.230313mzl4w4u92"), .editor)
    }

    // MARK: - Communication Detection Tests (Exact Match)

    func testDetect_Slack_ReturnsCommunication() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.tinyspeck.slackmacgap"), .communication)
    }

    func testDetect_Discord_ReturnsCommunication() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.hnc.Discord"), .communication)
    }

    func testDetect_Messages_ReturnsCommunication() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.apple.MobileSMS"), .communication)
    }

    func testDetect_AppleMail_ReturnsCommunication() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.apple.mail"), .communication)
    }

    func testDetect_Teams_ReturnsCommunication() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.microsoft.teams"), .communication)
    }

    func testDetect_Telegram_ReturnsCommunication() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "ru.keepcoder.Telegram"), .communication)
    }

    func testDetect_Signal_ReturnsCommunication() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "org.whispersystems.signal-desktop"), .communication)
    }

    // MARK: - Pattern Matching Tests (Case Insensitive)

    func testDetect_UnknownTerminalWithGhosttyPattern_ReturnsTerminal() {
        // Hypothetical future version
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.example.MyGhosttyFork"), .terminal)
    }

    func testDetect_UnknownBrowserWithChromePattern_ReturnsBrowser() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "org.example.ChromiumBased"), .browser)
    }

    func testDetect_UnknownEditorWithVSCodePattern_ReturnsEditor() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.example.VSCodeExtension"), .editor)
    }

    func testDetect_PatternMatchingIsCaseInsensitive() {
        // Pattern "kitty" should match regardless of case in bundle ID
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.example.KITTY"), .terminal)
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.example.Kitty"), .terminal)
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.example.kitty"), .terminal)
    }

    // MARK: - AXDocument URL Detection Tests

    func testDetect_UnknownAppWithHTTPSDocument_ReturnsBrowser() {
        let bundleID = "com.example.UnknownApp"
        let documentURL = "https://example.com/page"
        XCTAssertEqual(AppTypeDetector.detect(bundleID: bundleID, documentURL: documentURL), .browser)
    }

    func testDetect_UnknownAppWithHTTPDocument_ReturnsBrowser() {
        let bundleID = "com.example.UnknownApp"
        let documentURL = "http://localhost:8080/test"
        XCTAssertEqual(AppTypeDetector.detect(bundleID: bundleID, documentURL: documentURL), .browser)
    }

    func testDetect_UnknownAppWithFileDocument_ReturnsOther() {
        let bundleID = "com.example.UnknownApp"
        let documentURL = "file:///Users/test/document.pdf"
        XCTAssertEqual(AppTypeDetector.detect(bundleID: bundleID, documentURL: documentURL), .other)
    }

    func testDetect_UnknownAppWithNoDocument_ReturnsOther() {
        let bundleID = "com.example.UnknownApp"
        XCTAssertEqual(AppTypeDetector.detect(bundleID: bundleID, documentURL: nil), .other)
    }

    func testDetect_KnownTerminalWithHTTPDocument_ReturnsTerminal() {
        // Exact match takes precedence over document URL
        let bundleID = "com.mitchellh.ghostty"
        let documentURL = "https://example.com"
        XCTAssertEqual(AppTypeDetector.detect(bundleID: bundleID, documentURL: documentURL), .terminal)
    }

    // MARK: - Edge Cases

    func testDetect_NilBundleID_ReturnsOther() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: nil), .other)
    }

    func testDetect_EmptyBundleID_ReturnsOther() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: ""), .other)
    }

    func testDetect_UnknownBundleID_ReturnsOther() {
        XCTAssertEqual(AppTypeDetector.detect(bundleID: "com.example.RandomApp"), .other)
    }

    // MARK: - Helper Method Tests

    func testIsCodeContext_Terminal_ReturnsTrue() {
        XCTAssertTrue(AppTypeDetector.isCodeContext(.terminal))
    }

    func testIsCodeContext_Neovim_ReturnsTrue() {
        XCTAssertTrue(AppTypeDetector.isCodeContext(.neovim))
    }

    func testIsCodeContext_Editor_ReturnsTrue() {
        XCTAssertTrue(AppTypeDetector.isCodeContext(.editor))
    }

    func testIsCodeContext_Browser_ReturnsFalse() {
        XCTAssertFalse(AppTypeDetector.isCodeContext(.browser))
    }

    func testIsCodeContext_Communication_ReturnsFalse() {
        XCTAssertFalse(AppTypeDetector.isCodeContext(.communication))
    }

    func testIsCodeContext_Other_ReturnsFalse() {
        XCTAssertFalse(AppTypeDetector.isCodeContext(.other))
    }

    func testSupportsAccessibilitySelection_Browser_ReturnsFalse() {
        // Browsers should use JXA instead
        XCTAssertFalse(AppTypeDetector.supportsAccessibilitySelection(.browser))
    }

    func testSupportsAccessibilitySelection_Terminal_ReturnsTrue() {
        XCTAssertTrue(AppTypeDetector.supportsAccessibilitySelection(.terminal))
    }

    func testSupportsAccessibilitySelection_Editor_ReturnsTrue() {
        XCTAssertTrue(AppTypeDetector.supportsAccessibilitySelection(.editor))
    }

    func testSupportsAccessibilitySelection_Communication_ReturnsTrue() {
        XCTAssertTrue(AppTypeDetector.supportsAccessibilitySelection(.communication))
    }

    func testSupportsAccessibilitySelection_Other_ReturnsTrue() {
        XCTAssertTrue(AppTypeDetector.supportsAccessibilitySelection(.other))
    }

    // MARK: - Browser JXA Info Tests

    func testBrowserInfo_Safari_ReturnsSafariInfo() {
        let info = AppTypeDetector.browserInfo(for: "com.apple.Safari")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.jxaName, "Safari")
        XCTAssertTrue(info?.isSafari ?? false)
    }

    func testBrowserInfo_Chrome_ReturnsChromeInfo() {
        let info = AppTypeDetector.browserInfo(for: "com.google.Chrome")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.jxaName, "Google Chrome")
        XCTAssertFalse(info?.isSafari ?? true)
    }

    func testBrowserInfo_BraveNightly_ReturnsBraveInfo() {
        let info = AppTypeDetector.browserInfo(for: "com.brave.Browser.nightly")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.jxaName, "Brave Browser Nightly")
        XCTAssertFalse(info?.isSafari ?? true)
    }

    func testBrowserInfo_Arc_ReturnsArcInfo() {
        let info = AppTypeDetector.browserInfo(for: "company.thebrowser.Browser")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.jxaName, "Arc")
        XCTAssertFalse(info?.isSafari ?? true)
    }

    func testBrowserInfo_UnknownBrowser_ReturnsNil() {
        let info = AppTypeDetector.browserInfo(for: "com.example.UnknownBrowser")
        XCTAssertNil(info)
    }

    func testBrowserInfo_NonBrowser_ReturnsNil() {
        let info = AppTypeDetector.browserInfo(for: "com.mitchellh.ghostty")
        XCTAssertNil(info)
    }

    // MARK: - AppType Enum Tests

    func testAppType_AllCases_ArePresent() {
        let allCases = AppType.allCases
        XCTAssertEqual(allCases.count, 6)
        XCTAssertTrue(allCases.contains(.browser))
        XCTAssertTrue(allCases.contains(.terminal))
        XCTAssertTrue(allCases.contains(.neovim))
        XCTAssertTrue(allCases.contains(.editor))
        XCTAssertTrue(allCases.contains(.communication))
        XCTAssertTrue(allCases.contains(.other))
    }

    func testAppType_RawValue_IsCorrect() {
        XCTAssertEqual(AppType.browser.rawValue, "browser")
        XCTAssertEqual(AppType.terminal.rawValue, "terminal")
        XCTAssertEqual(AppType.neovim.rawValue, "neovim")
        XCTAssertEqual(AppType.editor.rawValue, "editor")
        XCTAssertEqual(AppType.communication.rawValue, "communication")
        XCTAssertEqual(AppType.other.rawValue, "other")
    }

    func testAppType_Codable_RoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for appType in AppType.allCases {
            let data = try encoder.encode(appType)
            let decoded = try decoder.decode(AppType.self, from: data)
            XCTAssertEqual(decoded, appType)
        }
    }
}
