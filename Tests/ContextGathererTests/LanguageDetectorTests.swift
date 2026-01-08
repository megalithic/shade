import XCTest
@testable import ContextGatherer

final class LanguageDetectorTests: XCTestCase {

    // MARK: - Filetype Priority Tests (Highest Priority)

    func testDetect_Filetype_TakesPrecedence() {
        // Filetype should win even when other signals point elsewhere
        let result = LanguageDetector.detect(
            selection: "```python\nprint('hello')\n```",
            url: "https://github.com/foo/bar/blob/main/test.js",
            filetype: "rust",
            filePath: "/path/to/file.go"
        )
        XCTAssertEqual(result, "rust")
    }

    func testDetect_Filetype_NormalizesAliases() {
        XCTAssertEqual(LanguageDetector.detect(filetype: "js"), "javascript")
        XCTAssertEqual(LanguageDetector.detect(filetype: "ts"), "typescript")
        XCTAssertEqual(LanguageDetector.detect(filetype: "py"), "python")
        XCTAssertEqual(LanguageDetector.detect(filetype: "rb"), "ruby")
        XCTAssertEqual(LanguageDetector.detect(filetype: "rs"), "rust")
    }

    func testDetect_Filetype_EmptyIsIgnored() {
        let result = LanguageDetector.detect(
            filetype: "",
            filePath: "/path/to/file.swift"
        )
        XCTAssertEqual(result, "swift")
    }

    // MARK: - File Path Extension Tests

    func testDetect_FilePath_CommonExtensions() {
        XCTAssertEqual(LanguageDetector.detect(filePath: "/src/main.swift"), "swift")
        XCTAssertEqual(LanguageDetector.detect(filePath: "/src/app.tsx"), "tsx")
        XCTAssertEqual(LanguageDetector.detect(filePath: "/lib/utils.py"), "python")
        XCTAssertEqual(LanguageDetector.detect(filePath: "/pkg/main.go"), "go")
        XCTAssertEqual(LanguageDetector.detect(filePath: "/src/lib.rs"), "rust")
        XCTAssertEqual(LanguageDetector.detect(filePath: "/app/page.vue"), "vue")
        XCTAssertEqual(LanguageDetector.detect(filePath: "config.nix"), "nix")
    }

    func testDetect_FilePath_CaseInsensitive() {
        XCTAssertEqual(LanguageDetector.detect(filePath: "/TEST.SWIFT"), "swift")
        XCTAssertEqual(LanguageDetector.detect(filePath: "/Test.Swift"), "swift")
        XCTAssertEqual(LanguageDetector.detect(filePath: "/test.SWIFT"), "swift")
    }

    func testDetect_FilePath_NoExtension_ReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(filePath: "/usr/bin/bash"))
        XCTAssertNil(LanguageDetector.detect(filePath: "Makefile"))
    }

    func testDetect_FilePath_UnknownExtension_ReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(filePath: "/file.xyz"))
        XCTAssertNil(LanguageDetector.detect(filePath: "/file.unknown"))
    }

    // MARK: - GitHub URL Tests

    func testDetect_GitHubBlob_ExtractsExtension() {
        let url = "https://github.com/owner/repo/blob/main/src/lib.rs"
        XCTAssertEqual(LanguageDetector.detect(url: url), "rust")
    }

    func testDetect_GitHubBlob_DeepPath() {
        let url = "https://github.com/owner/repo/blob/feature/branch/deep/nested/path/file.tsx"
        XCTAssertEqual(LanguageDetector.detect(url: url), "tsx")
    }

    func testDetect_GitHubRaw_ExtractsExtension() {
        let url = "https://raw.githubusercontent.com/owner/repo/main/config.nix"
        XCTAssertEqual(LanguageDetector.detect(url: url), "nix")
    }

    func testDetect_GitLabBlob_ExtractsExtension() {
        let url = "https://gitlab.com/owner/repo/-/blob/main/lib/utils.ex"
        XCTAssertEqual(LanguageDetector.detect(url: url), "elixir")
    }

    func testDetect_BitbucketSrc_ExtractsExtension() {
        let url = "https://bitbucket.org/owner/repo/src/main/app.kt"
        XCTAssertEqual(LanguageDetector.detect(url: url), "kotlin")
    }

    func testDetect_CodebergSrc_ExtractsExtension() {
        let url = "https://codeberg.org/owner/repo/src/branch/main/file.zig"
        XCTAssertEqual(LanguageDetector.detect(url: url), "zig")
    }

    func testDetect_SourcehutTree_ExtractsExtension() {
        let url = "https://sr.ht/~owner/repo/tree/main/item/src/main.go"
        XCTAssertEqual(LanguageDetector.detect(url: url), "go")
    }

    // MARK: - Domain Hint Tests

    func testDetect_Domain_PythonDocs() {
        let url = "https://docs.python.org/3/library/asyncio.html"
        XCTAssertEqual(LanguageDetector.detect(url: url), "python")
    }

    func testDetect_Domain_RustDocs() {
        XCTAssertEqual(LanguageDetector.detect(url: "https://doc.rust-lang.org/book/"), "rust")
        XCTAssertEqual(LanguageDetector.detect(url: "https://docs.rs/tokio/latest/tokio/"), "rust")
    }

    func testDetect_Domain_GoDocs() {
        XCTAssertEqual(LanguageDetector.detect(url: "https://pkg.go.dev/fmt"), "go")
        XCTAssertEqual(LanguageDetector.detect(url: "https://go.dev/doc/"), "go")
    }

    func testDetect_Domain_ElixirDocs() {
        XCTAssertEqual(LanguageDetector.detect(url: "https://hexdocs.pm/phoenix/overview.html"), "elixir")
        XCTAssertEqual(LanguageDetector.detect(url: "https://elixir-lang.org/getting-started/"), "elixir")
    }

    func testDetect_Domain_SwiftDocs() {
        XCTAssertEqual(LanguageDetector.detect(url: "https://developer.apple.com/documentation/swift"), "swift")
    }

    func testDetect_Domain_NPM() {
        XCTAssertEqual(LanguageDetector.detect(url: "https://npmjs.com/package/lodash"), "javascript")
        XCTAssertEqual(LanguageDetector.detect(url: "https://nodejs.org/api/fs.html"), "javascript")
    }

    func testDetect_Domain_TypeScript() {
        XCTAssertEqual(LanguageDetector.detect(url: "https://typescriptlang.org/docs/"), "typescript")
        XCTAssertEqual(LanguageDetector.detect(url: "https://deno.land/manual"), "typescript")
    }

    func testDetect_Domain_MDN_JavaScript() {
        let url = "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array"
        XCTAssertEqual(LanguageDetector.detect(url: url), "javascript")
    }

    func testDetect_Domain_MDN_CSS() {
        let url = "https://developer.mozilla.org/en-US/docs/Web/CSS/display"
        XCTAssertEqual(LanguageDetector.detect(url: url), "css")
    }

    func testDetect_Domain_MDN_HTML() {
        let url = "https://developer.mozilla.org/en-US/docs/Web/HTML/Element/div"
        XCTAssertEqual(LanguageDetector.detect(url: url), "html")
    }

    func testDetect_Domain_StripsWWW() {
        XCTAssertEqual(LanguageDetector.detect(url: "https://www.lua.org/manual/5.4/"), "lua")
    }

    // MARK: - Code Fence Tests

    func testDetect_CodeFence_Basic() {
        let text = """
        ```python
        print("hello")
        ```
        """
        XCTAssertEqual(LanguageDetector.detect(selection: text), "python")
    }

    func testDetect_CodeFence_WithLeadingWhitespace() {
        let text = "   ```javascript\nconsole.log('hi');\n```"
        XCTAssertEqual(LanguageDetector.detect(selection: text), "javascript")
    }

    func testDetect_CodeFence_NormalizesAliases() {
        XCTAssertEqual(LanguageDetector.detect(selection: "```js\ncode\n```"), "javascript")
        XCTAssertEqual(LanguageDetector.detect(selection: "```ts\ncode\n```"), "typescript")
        XCTAssertEqual(LanguageDetector.detect(selection: "```py\ncode\n```"), "python")
        XCTAssertEqual(LanguageDetector.detect(selection: "```rb\ncode\n```"), "ruby")
        XCTAssertEqual(LanguageDetector.detect(selection: "```sh\ncode\n```"), "bash")
    }

    func testDetect_CodeFence_CaseInsensitive() {
        XCTAssertEqual(LanguageDetector.detect(selection: "```PYTHON\ncode\n```"), "python")
        XCTAssertEqual(LanguageDetector.detect(selection: "```Python\ncode\n```"), "python")
    }

    func testDetect_CodeFence_UnknownLanguage_ReturnsAsIs() {
        XCTAssertEqual(LanguageDetector.detect(selection: "```foobar\ncode\n```"), "foobar")
    }

    func testDetect_CodeFence_NotAtStart_IsIgnored() {
        let text = "Some text before\n```python\ncode\n```"
        XCTAssertNil(LanguageDetector.detect(selection: text))
    }

    // MARK: - Shebang Tests

    func testDetect_Shebang_DirectPath() {
        XCTAssertEqual(LanguageDetector.detect(selection: "#!/bin/bash\necho 'hi'"), "bash")
        XCTAssertEqual(LanguageDetector.detect(selection: "#!/usr/bin/python\nprint('hi')"), "python")
        XCTAssertEqual(LanguageDetector.detect(selection: "#!/usr/local/bin/ruby\nputs 'hi'"), "ruby")
    }

    func testDetect_Shebang_EnvStyle() {
        XCTAssertEqual(LanguageDetector.detect(selection: "#!/usr/bin/env python\nprint('hi')"), "python")
        XCTAssertEqual(LanguageDetector.detect(selection: "#!/usr/bin/env python3\nprint('hi')"), "python")
        XCTAssertEqual(LanguageDetector.detect(selection: "#!/usr/bin/env node\nconsole.log('hi')"), "javascript")
        XCTAssertEqual(LanguageDetector.detect(selection: "#!/usr/bin/env ruby\nputs 'hi'"), "ruby")
        XCTAssertEqual(LanguageDetector.detect(selection: "#!/usr/bin/env deno\nconsole.log('hi')"), "typescript")
    }

    func testDetect_Shebang_ShellVariants() {
        XCTAssertEqual(LanguageDetector.detect(selection: "#!/bin/sh\necho 'hi'"), "bash")
        XCTAssertEqual(LanguageDetector.detect(selection: "#!/bin/zsh\necho 'hi'"), "zsh")
        XCTAssertEqual(LanguageDetector.detect(selection: "#!/usr/bin/fish\necho 'hi'"), "fish")
    }

    func testDetect_Shebang_WithLeadingWhitespace() {
        // Whitespace before #! on the line is allowed
        XCTAssertEqual(LanguageDetector.detect(selection: "  #!/bin/bash\necho 'hi'"), "bash")
    }

    func testDetect_Shebang_NotOnFirstLine_IsIgnored() {
        let text = "Some comment\n#!/bin/bash\necho 'hi'"
        XCTAssertNil(LanguageDetector.detect(selection: text))
    }

    func testDetect_Shebang_UnknownInterpreter_ReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(selection: "#!/bin/unknowninterpreter\ncode"))
    }

    // MARK: - Priority Order Tests

    func testDetect_Priority_FiletypeBeatsFilePath() {
        let result = LanguageDetector.detect(
            filetype: "typescript",
            filePath: "/path/to/file.py"
        )
        XCTAssertEqual(result, "typescript")
    }

    func testDetect_Priority_FilePathBeatsURL() {
        let result = LanguageDetector.detect(
            url: "https://github.com/foo/bar/blob/main/test.js",
            filePath: "/path/to/file.swift"
        )
        XCTAssertEqual(result, "swift")
    }

    func testDetect_Priority_GitURLBeatsDomain() {
        // GitHub blob URL should win over domain hint
        let result = LanguageDetector.detect(
            url: "https://github.com/python/cpython/blob/main/Lib/asyncio/base_events.py"
        )
        XCTAssertEqual(result, "python")
    }

    func testDetect_Priority_DomainBeatsCodeFence() {
        let result = LanguageDetector.detect(
            selection: "```javascript\ncode\n```",
            url: "https://hexdocs.pm/phoenix/overview.html"
        )
        XCTAssertEqual(result, "elixir")
    }

    func testDetect_Priority_CodeFenceBeatsShebang() {
        let text = """
        ```python
        #!/bin/bash
        echo "this is bash but fence says python"
        ```
        """
        XCTAssertEqual(LanguageDetector.detect(selection: text), "python")
    }

    // MARK: - Edge Cases

    func testDetect_AllNil_ReturnsNil() {
        XCTAssertNil(LanguageDetector.detect())
    }

    func testDetect_AllEmpty_ReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(
            selection: "",
            url: "",
            filetype: "",
            filePath: ""
        ))
    }

    func testDetect_UnknownEverything_ReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(
            selection: "just some plain text",
            url: "https://example.com/unknown",
            filePath: "/path/to/file.xyz"
        ))
    }

    func testDetect_OnlySelection_NoPatterns_ReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(selection: "Hello, World!"))
    }

    // MARK: - Extension Mapping Coverage Tests

    func testExtensionMapping_Web() {
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.html"), "html")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.css"), "css")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.scss"), "scss")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.jsx"), "jsx")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.tsx"), "tsx")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.svelte"), "svelte")
    }

    func testExtensionMapping_Systems() {
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.c"), "c")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.h"), "c")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.cpp"), "cpp")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.rs"), "rust")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.go"), "go")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.zig"), "zig")
    }

    func testExtensionMapping_JVM() {
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.java"), "java")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.kt"), "kotlin")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.scala"), "scala")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.clj"), "clojure")
    }

    func testExtensionMapping_DotNet() {
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.cs"), "csharp")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.fs"), "fsharp")
    }

    func testExtensionMapping_Functional() {
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.hs"), "haskell")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.ml"), "ocaml")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.ex"), "elixir")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.erl"), "erlang")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.elm"), "elm")
    }

    func testExtensionMapping_Config() {
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.json"), "json")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.yaml"), "yaml")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.yml"), "yaml")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.toml"), "toml")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.xml"), "xml")
    }

    func testExtensionMapping_DevOps() {
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.tf"), "terraform")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.nix"), "nix")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.dockerfile"), "dockerfile")
    }

    func testExtensionMapping_Documentation() {
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.md"), "markdown")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.rst"), "rst")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.tex"), "latex")
        XCTAssertEqual(LanguageDetector.detect(filePath: "x.org"), "org")
    }
}
