import Foundation

// MARK: - Language Detector

/// Detects programming language from various context signals
/// Priority: nvim filetype > URL extension > domain hint > code fence > shebang
public struct LanguageDetector {

    // MARK: - Main Detection

    /// Detect programming language from available context
    /// - Parameters:
    ///   - selection: Selected text (may contain code fences or shebangs)
    ///   - url: Source URL (for file extension or domain hints)
    ///   - filetype: Known filetype from editor (e.g., nvim's vim.bo.filetype)
    ///   - filePath: File path (for extension-based detection)
    /// - Returns: Language identifier or nil if unknown
    public static func detect(
        selection: String? = nil,
        url: String? = nil,
        filetype: String? = nil,
        filePath: String? = nil
    ) -> String? {
        // 1. Editor filetype (highest confidence - treesitter knows best)
        if let ft = filetype, !ft.isEmpty {
            return normalizeLanguage(ft)
        }

        // 2. File path extension
        if let path = filePath, !path.isEmpty {
            if let ext = fileExtension(from: path),
               let lang = extensionToLanguage[ext.lowercased()] {
                return lang
            }
        }

        // 3. URL-based detection
        if let url = url, !url.isEmpty {
            // Git forge URLs: extract file extension from blob/src paths
            if let lang = detectFromGitURL(url) {
                return lang
            }

            // Domain-based hints (doc sites are language-specific)
            if let lang = detectFromDomain(url) {
                return lang
            }
        }

        // 4. Content-based detection (code fences, shebangs)
        if let text = selection, !text.isEmpty {
            // Code fence language hint
            if let lang = detectFromCodeFence(text) {
                return lang
            }

            // Shebang detection
            if let lang = detectFromShebang(text) {
                return lang
            }
        }

        // Unknown - better to return nil than guess wrong
        return nil
    }

    // MARK: - URL-based Detection

    /// Detect language from git forge URLs (GitHub, GitLab, etc.)
    private static func detectFromGitURL(_ url: String) -> String? {
        // Patterns for various git forges
        let patterns = [
            // GitHub: github.com/owner/repo/blob/branch/path/file.ext
            #"github\.com/[^/]+/[^/]+/blob/[^/]+/.+\.(\w+)$"#,
            // GitHub raw: raw.githubusercontent.com/owner/repo/branch/path/file.ext
            #"raw\.githubusercontent\.com/[^/]+/[^/]+/[^/]+/.+\.(\w+)$"#,
            // GitLab: gitlab.com/owner/repo/-/blob/branch/path/file.ext
            #"gitlab\.com/[^/]+/[^/]+/-/blob/[^/]+/.+\.(\w+)$"#,
            // Bitbucket: bitbucket.org/owner/repo/src/branch/path/file.ext
            #"bitbucket\.org/[^/]+/[^/]+/src/[^/]+/.+\.(\w+)$"#,
            // Codeberg: codeberg.org/owner/repo/src/branch/path/file.ext
            #"codeberg\.org/[^/]+/[^/]+/src/[^/]+/.+\.(\w+)$"#,
            // Sourcehut: sr.ht/~owner/repo/tree/branch/item/path/file.ext
            #"sr\.ht/~[^/]+/[^/]+/tree/[^/]+/item/.+\.(\w+)$"#,
            // Gitea/Forgejo: */owner/repo/src/branch/path/file.ext
            #"/[^/]+/[^/]+/src/[^/]+/.+\.(\w+)$"#,
        ]

        for pattern in patterns {
            if let ext = firstCaptureGroup(in: url, pattern: pattern) {
                if let lang = extensionToLanguage[ext.lowercased()] {
                    return lang
                }
            }
        }

        return nil
    }

    /// Detect language from documentation domain
    private static func detectFromDomain(_ url: String) -> String? {
        // Extract domain from URL
        guard let domain = extractDomain(from: url) else { return nil }

        // Direct domain lookup
        if let lang = domainToLanguage[domain] {
            return lang
        }

        // MDN special handling - inspect path
        if domain.contains("developer.mozilla.org") {
            if url.contains("/JavaScript/") || url.contains("/js/") {
                return "javascript"
            }
            if url.contains("/CSS/") {
                return "css"
            }
            if url.contains("/HTML/") {
                return "html"
            }
            if url.contains("/WebAssembly/") {
                return "wasm"
            }
        }

        return nil
    }

    // MARK: - Content-based Detection

    /// Detect language from markdown code fence
    private static func detectFromCodeFence(_ text: String) -> String? {
        // Match ```language at start of text (possibly with leading whitespace)
        let pattern = #"^\s*```(\w+)"#

        guard let lang = firstCaptureGroup(in: text, pattern: pattern) else {
            return nil
        }

        let normalized = lang.lowercased()

        // Handle common aliases
        if let canonical = languageAliases[normalized] {
            return canonical
        }

        return normalized
    }

    /// Detect language from shebang line
    private static func detectFromShebang(_ text: String) -> String? {
        // Must start with #! (possibly with leading whitespace on first line)
        let lines = text.components(separatedBy: .newlines)
        guard let firstLine = lines.first?.trimmingCharacters(in: .whitespaces),
              firstLine.hasPrefix("#!") else {
            return nil
        }

        // Pattern 1: #!/usr/bin/env interpreter
        let envPattern = #"^#!.*\benv\s+(\w+)"#
        if let interpreter = firstCaptureGroup(in: firstLine, pattern: envPattern) {
            if let lang = shebangToLanguage[interpreter.lowercased()] {
                return lang
            }
        }

        // Pattern 2: #!/path/to/interpreter
        let directPattern = #"^#!.*/(\w+)$"#
        if let interpreter = firstCaptureGroup(in: firstLine, pattern: directPattern) {
            if let lang = shebangToLanguage[interpreter.lowercased()] {
                return lang
            }
        }

        return nil
    }

    // MARK: - Normalization

    /// Normalize language identifier to canonical form
    private static func normalizeLanguage(_ lang: String) -> String {
        let lower = lang.lowercased()
        return languageAliases[lower] ?? lower
    }

    // MARK: - Helpers

    /// Extract file extension from path
    private static func fileExtension(from path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        return ext.isEmpty ? nil : ext
    }

    /// Extract domain from URL (without www. prefix)
    private static func extractDomain(from urlString: String) -> String? {
        // Simple regex-based extraction (avoid URL parsing overhead)
        let pattern = #"https?://(?:www\.)?([^/]+)"#
        return firstCaptureGroup(in: urlString, pattern: pattern)
    }

    /// Extract first capture group from regex match
    private static func firstCaptureGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[captureRange])
    }
}

// MARK: - Language Mappings

extension LanguageDetector {

    /// File extension to language mapping
    public static let extensionToLanguage: [String: String] = [
        // Web
        "html": "html",
        "htm": "html",
        "css": "css",
        "scss": "scss",
        "sass": "sass",
        "less": "less",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "jsx": "jsx",
        "ts": "typescript",
        "mts": "typescript",
        "cts": "typescript",
        "tsx": "tsx",
        "vue": "vue",
        "svelte": "svelte",
        "astro": "astro",

        // Systems
        "c": "c",
        "h": "c",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "hxx": "cpp",
        "rs": "rust",
        "go": "go",
        "zig": "zig",
        "nim": "nim",
        "d": "d",

        // JVM
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin",
        "scala": "scala",
        "groovy": "groovy",
        "clj": "clojure",
        "cljs": "clojurescript",
        "cljc": "clojure",

        // .NET
        "cs": "csharp",
        "fs": "fsharp",
        "vb": "vb",

        // Apple
        "swift": "swift",
        "m": "objc",
        "mm": "objcpp",

        // Scripting
        "py": "python",
        "pyw": "python",
        "pyi": "python",
        "rb": "ruby",
        "rake": "ruby",
        "gemspec": "ruby",
        "pl": "perl",
        "pm": "perl",
        "php": "php",
        "lua": "lua",
        "tcl": "tcl",
        "r": "r",
        "R": "r",

        // Shell
        "sh": "bash",
        "bash": "bash",
        "zsh": "zsh",
        "fish": "fish",
        "ps1": "powershell",
        "psm1": "powershell",

        // Functional
        "hs": "haskell",
        "lhs": "haskell",
        "ml": "ocaml",
        "mli": "ocaml",
        "ex": "elixir",
        "exs": "elixir",
        "erl": "erlang",
        "hrl": "erlang",
        "elm": "elm",
        "purs": "purescript",
        "rkt": "racket",
        "scm": "scheme",
        "lisp": "lisp",
        "cl": "commonlisp",

        // Data/Config
        "json": "json",
        "jsonc": "jsonc",
        "json5": "json5",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "xml": "xml",
        "xsl": "xsl",
        "xslt": "xslt",
        "ini": "ini",
        "cfg": "ini",
        "conf": "conf",
        "properties": "properties",

        // Documentation
        "md": "markdown",
        "markdown": "markdown",
        "mdx": "mdx",
        "rst": "rst",
        "tex": "latex",
        "latex": "latex",
        "org": "org",
        "adoc": "asciidoc",

        // Database
        "sql": "sql",
        "psql": "sql",
        "mysql": "sql",
        "pgsql": "sql",

        // DevOps
        "dockerfile": "dockerfile",
        "tf": "terraform",
        "tfvars": "terraform",
        "hcl": "hcl",
        "nix": "nix",

        // Editor/IDE
        "vim": "vim",
        "vimrc": "vim",
        "nvim": "vim",
        "el": "elisp",
        "emacs": "elisp",

        // Misc
        "dart": "dart",
        "graphql": "graphql",
        "gql": "graphql",
        "proto": "protobuf",
        "thrift": "thrift",
        "cmake": "cmake",
        "make": "makefile",
        "mk": "makefile",
        "diff": "diff",
        "patch": "diff",
        "asm": "asm",
        "s": "asm",
        "wasm": "wasm",
        "wat": "wat",
        "sol": "solidity",
        "move": "move",
        "cairo": "cairo",
        "gleam": "gleam",
        "heex": "heex",
        "eex": "eex",
        "erb": "erb",
        "ejs": "ejs",
        "hbs": "handlebars",
        "mustache": "mustache",
        "jinja": "jinja",
        "jinja2": "jinja",
        "j2": "jinja",
        "liquid": "liquid",
    ]

    /// Documentation domain to language mapping
    public static let domainToLanguage: [String: String] = [
        // Official docs
        "docs.python.org": "python",
        "doc.rust-lang.org": "rust",
        "docs.rs": "rust",
        "pkg.go.dev": "go",
        "go.dev": "go",
        "developer.apple.com": "swift",
        "kotlinlang.org": "kotlin",
        "ruby-doc.org": "ruby",
        "lua.org": "lua",
        "luarocks.org": "lua",
        "haskell.org": "haskell",
        "clojure.org": "clojure",
        "ziglang.org": "zig",
        "nim-lang.org": "nim",
        "dlang.org": "d",
        "elixir-lang.org": "elixir",
        "hexdocs.pm": "elixir",
        "erlang.org": "erlang",
        "elm-lang.org": "elm",
        "purescript.org": "purescript",
        "ocaml.org": "ocaml",
        "scala-lang.org": "scala",
        "groovy-lang.org": "groovy",
        "crystal-lang.org": "crystal",
        "julialang.org": "julia",
        "gleam.run": "gleam",

        // JS/TS ecosystem
        "npmjs.com": "javascript",
        "nodejs.org": "javascript",
        "deno.land": "typescript",
        "typescriptlang.org": "typescript",
        "bun.sh": "typescript",
        "react.dev": "javascript",
        "vuejs.org": "vue",
        "svelte.dev": "svelte",
        "angular.io": "typescript",
        "nextjs.org": "javascript",
        "nuxt.com": "vue",
        "astro.build": "astro",

        // Other ecosystems
        "php.net": "php",
        "laravel.com": "php",
        "symfony.com": "php",
        "rubyonrails.org": "ruby",
        "djangoproject.com": "python",
        "flask.palletsprojects.com": "python",
        "fastapi.tiangolo.com": "python",
        "spring.io": "java",
        "docs.microsoft.com": "csharp",
        "learn.microsoft.com": "csharp",

        // DevOps
        "terraform.io": "terraform",
        "nixos.org": "nix",
        "docs.docker.com": "dockerfile",
        "kubernetes.io": "yaml",

        // Database
        "postgresql.org": "sql",
        "mysql.com": "sql",
        "sqlite.org": "sql",
        "redis.io": "redis",
        "mongodb.com": "javascript",
    ]

    /// Common language aliases to canonical names
    public static let languageAliases: [String: String] = [
        // JavaScript variants
        "js": "javascript",
        "node": "javascript",
        "nodejs": "javascript",

        // TypeScript variants
        "ts": "typescript",

        // Python variants
        "py": "python",
        "python3": "python",

        // Ruby variants
        "rb": "ruby",

        // Shell variants
        "sh": "bash",
        "shell": "bash",

        // Rust variants
        "rs": "rust",

        // C variants
        "c++": "cpp",
        "cxx": "cpp",

        // C# variants
        "c#": "csharp",
        "cs": "csharp",

        // Objective-C variants
        "objective-c": "objc",
        "objectivec": "objc",
        "obj-c": "objc",

        // Elixir variants
        "ex": "elixir",
        "exs": "elixir",

        // Haskell variants
        "hs": "haskell",

        // F# variants
        "f#": "fsharp",

        // Visual Basic variants
        "visual basic": "vb",
        "visualbasic": "vb",
        "vbnet": "vb",
        "vb.net": "vb",
    ]

    /// Shebang interpreter to language mapping
    public static let shebangToLanguage: [String: String] = [
        // Python
        "python": "python",
        "python3": "python",
        "python2": "python",
        "pypy": "python",
        "pypy3": "python",

        // Ruby
        "ruby": "ruby",
        "jruby": "ruby",

        // JavaScript/Node
        "node": "javascript",
        "nodejs": "javascript",
        "deno": "typescript",
        "bun": "typescript",

        // Shell
        "sh": "bash",
        "bash": "bash",
        "zsh": "zsh",
        "fish": "fish",
        "dash": "bash",
        "ash": "bash",
        "ksh": "bash",
        "csh": "csh",
        "tcsh": "csh",

        // Perl
        "perl": "perl",
        "perl5": "perl",
        "perl6": "raku",
        "raku": "raku",

        // PHP
        "php": "php",

        // Lua
        "lua": "lua",
        "luajit": "lua",

        // Other
        "awk": "awk",
        "gawk": "awk",
        "sed": "sed",
        "tclsh": "tcl",
        "wish": "tcl",
        "expect": "tcl",
        "groovy": "groovy",
        "scala": "scala",
        "elixir": "elixir",
        "escript": "erlang",
        "racket": "racket",
        "guile": "scheme",
        "sbcl": "commonlisp",
        "clisp": "commonlisp",
        "osascript": "applescript",
        "swift": "swift",
        "julia": "julia",
        "Rscript": "r",
        "crystal": "crystal",
        "nim": "nim",
    ]
}
