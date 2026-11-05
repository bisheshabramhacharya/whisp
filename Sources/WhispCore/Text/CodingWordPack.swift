import Foundation

/// Built-in vocabulary for coding dictation: file names, AI coding tools, and the
/// words a developer says all day. On by default, no dictionary.json setup.
///
/// Fixed spelling rules only. Each entry says what the speech model writes and what
/// gets typed. Two shapes earn an entry:
///
/// - a spoken form that is not English at all ("n p m", "git hub", "local host",
///   "agents dot md"), replaced wherever it appears;
/// - an English word that is also a product or language name ("cursor", "linear",
///   "python", "rust", "go"), replaced only next to a word that makes the product
///   sense the only reading ("open cursor", "the linear issue", "written in go"), so
///   "move the cursor to the end" and "a linear function" stay untouched.
///
/// A rule never matches across a file extension that is already spelled out
/// ("README.md" never becomes "README.md.md") and never before an apostrophe
/// ("Jason's" is a person, not JSON).
///
/// The user's own dictionary.json is applied after this pack, so one hand-written
/// rule always wins over a built-in one.
public final class CodingWordPack: @unchecked Sendable {

    public static let shared = CodingWordPack()

    private let rules: [Rule]

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
        /// Every one of these words must be in the text for the rule to be able to
        /// match, which keeps a dictation with no coding words off the regexes.
        let gate: Set<String>
    }

    private struct Entry {
        let spoken: String
        let written: String
        let leaders: [String]
        let followers: [String]

        init(_ spoken: String, _ written: String, leaders: [String] = [], followers: [String] = []) {
            self.spoken = spoken
            self.written = written
            self.leaders = leaders
            self.followers = followers
        }
    }

    private init() {
        // Bare words and product names first, file names last: the more specific rule
        // gets the last word, so "docker compose dot yaml" becomes "Docker compose dot
        // yaml" first and "docker-compose.yml" after it. Inside a group, longest first,
        // so "claude md" wins over "claude" and "chat g p t" over "gpt".
        let groups: [[Entry]] = [Self.tools, Self.vocabulary, Self.contextual, Self.fileNames]
        rules = groups
            .flatMap { group in
                group.sorted {
                    $0.spoken.count == $1.spoken.count ? $0.spoken < $1.spoken : $0.spoken.count > $1.spoken.count
                }
            }
            .flatMap(Self.rules)
    }

    /// Applies every rule whose words are present. Pure, allocation-light, and
    /// skipped almost entirely for a sentence with no coding vocabulary in it.
    public func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let present = Set(Self.words(in: text))
        var result = text
        for rule in rules where rule.gate.isSubset(of: present) {
            result = rule.regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.template)
        }
        return result
    }

    // MARK: - Tables

    /// File names, in both spoken shapes: "agents dot md" and "agents MD".
    private static let fileNames: [Entry] = [
        Entry("agents.md", "AGENTS.md"),
        Entry("agents dot md", "AGENTS.md"),
        Entry("agents md", "AGENTS.md"),
        Entry("agent md", "AGENTS.md"),
        Entry("claude.md", "CLAUDE.md"),
        Entry("claude dot md", "CLAUDE.md"),
        Entry("claude md", "CLAUDE.md"),
        Entry("soul.md", "SOUL.md"),
        Entry("soul dot md", "SOUL.md"),
        Entry("soul md", "SOUL.md"),
        Entry("readme.md", "README.md"),
        Entry("readme", "README.md"),
        Entry("read me dot md", "README.md"),
        Entry("dot env", ".env"),
        Entry("dotenv", ".env"),
        Entry("package.json", "package.json"),
        Entry("package dot json", "package.json"),
        Entry("package json", "package.json"),
        Entry("tsconfig.json", "tsconfig.json"),
        Entry("tsconfig", "tsconfig.json"),
        Entry("ts config", "tsconfig.json"),
        Entry("docker-compose.yml", "docker-compose.yml"),
        Entry("docker compose dot yaml", "docker-compose.yml"),
        Entry("docker compose dot yml", "docker-compose.yml"),
        Entry("docker compose yaml", "docker-compose.yml"),
        Entry("docker compose yml", "docker-compose.yml"),
        Entry("gitignore", ".gitignore"),
        Entry("git ignore", ".gitignore"),
        Entry("dot git ignore", ".gitignore"),
        Entry("makefile", "Makefile"),
        Entry("make file", "Makefile",
              leaders: ["the", "a", "an", "your", "our", "my", "this", "that",
                        "update", "open", "edit", "rewrite", "check"]),
    ]

    /// AI coding tools and harnesses.
    private static let tools: [Entry] = [
        Entry("github", "GitHub"),
        Entry("git hub", "GitHub"),
        Entry("chatgpt", "ChatGPT"),
        Entry("chat gpt", "ChatGPT"),
        Entry("chat g p t", "ChatGPT"),
        Entry("gpt", "GPT"),
        Entry("claude code", "Claude Code"),
        Entry("claude", "Claude"),
        Entry("codex", "Codex"),
        Entry("capy", "Capy"),
        Entry("codync", "Codync"),
        Entry("hermes", "Hermes"),
        Entry("copilot", "Copilot"),
        Entry("co-pilot", "Copilot"),
        Entry("co pilot", "Copilot"),
        Entry("windsurf", "Windsurf"),
        Entry("wind surf", "Windsurf"),
        Entry("aider", "Aider"),
        Entry("vs code", "VS Code"),
        Entry("vscode", "VS Code"),
        Entry("visual studio code", "VS Code"),
    ]

    /// Everyday developer words whose spelling is fixed, not English.
    private static let vocabulary: [Entry] = [
        Entry("n p m", "npm"),
        Entry("npm", "npm"),
        Entry("p n p m", "pnpm"),
        Entry("pnpm", "pnpm"),
        Entry("local host", "localhost"),
        Entry("localhost", "localhost"),
        Entry("pr", "PR"),
        Entry("json", "JSON"),
        Entry("yaml", "YAML"),
        Entry("sql", "SQL"),
        Entry("s q l", "SQL"),
        Entry("api", "API"),
        Entry("a p i", "API"),
        Entry("cli", "CLI"),
        Entry("c l i", "CLI"),
        Entry("ssh", "SSH"),
        Entry("s s h", "SSH"),
        Entry("mcp", "MCP"),
        Entry("m c p", "MCP"),
        Entry("llm", "LLM"),
        Entry("l l m", "LLM"),
        Entry("gpu", "GPU"),
        Entry("g p u", "GPU"),
        Entry("sub agent", "sub-agent"),
        Entry("subagent", "sub-agent"),
        Entry("docker", "Docker"),
        Entry("kubectl", "kubectl"),
        Entry("kube control", "kubectl"),
        Entry("cube control", "kubectl"),
        Entry("kube cuddle", "kubectl"),
        Entry("cube cuddle", "kubectl"),
        Entry("kubernetes", "Kubernetes"),
        Entry("postgres", "Postgres"),
        Entry("post gres", "Postgres"),
        Entry("post gress", "Postgres"),
        Entry("supabase", "Supabase"),
        Entry("super base", "Supabase"),
        Entry("supa base", "Supabase"),
        Entry("vercel", "Vercel"),
        Entry("ver cel", "Vercel"),
        Entry("typescript", "TypeScript"),
        Entry("type script", "TypeScript"),
        Entry("javascript", "JavaScript"),
        Entry("java script", "JavaScript"),
        Entry("swiftui", "SwiftUI"),
        Entry("swift ui", "SwiftUI"),
        Entry("coreml", "CoreML"),
        Entry("core ml", "CoreML"),
        Entry("xcode", "Xcode"),
        Entry("x code", "Xcode"),
        Entry("macos", "macOS"),
        Entry("mac os", "macOS"),
        Entry("mac o s", "macOS"),
        Entry("ios", "iOS"),
        Entry("i os", "iOS"),
        Entry("figma", "Figma"),
        Entry("golang", "Go"),
    ]

    /// Words that are also ordinary English. A leader is the word just before
    /// ("open cursor"), a follower the word just after ("the linear issue").
    private static let contextual: [Entry] = [
        Entry("cursor", "Cursor",
              leaders: ["in", "on", "open", "launch", "use", "using", "with", "via", "into", "inside", "through"],
              followers: ["app", "editor", "tab", "composer", "chat", "agent"]),
        Entry("grok", "Grok",
              leaders: ["in", "on", "ask", "open", "using", "via"]),
        Entry("zed", "Zed",
              leaders: ["in", "on", "open", "launch", "using", "via", "through"],
              followers: ["editor", "app"]),
        Entry("cline", "Cline",
              leaders: ["in", "open", "launch", "using", "via"],
              followers: ["app", "editor", "extension"]),
        Entry("slack", "Slack",
              leaders: ["in", "on", "via", "using", "open", "from"],
              followers: ["channel", "channels", "message", "messages", "dm", "dms",
                          "thread", "threads", "workspace", "app", "bot", "huddle"]),
        Entry("notion", "Notion",
              leaders: ["in", "into", "on", "via", "using", "open"],
              followers: ["page", "pages", "doc", "docs", "database", "databases",
                          "workspace", "app", "board", "template", "templates", "wiki"]),
        // Followers only: "in linear" is a real English phrase, "linear issue" is not.
        Entry("linear", "Linear",
              followers: ["issue", "issues", "ticket", "tickets", "board", "app",
                          "project", "projects", "cycle", "roadmap", "workspace"]),
        // "Jason" is a person's name, so JSON only ever comes from a follower that
        // makes the file/format sense the only reading.
        Entry("jason", "JSON",
              leaders: ["parse", "read", "write", "load", "validate", "dump",
                        "parse the", "read the", "write the", "load the", "validate the", "dump the"],
              followers: ["file", "files", "format", "config", "object", "objects",
                          "response", "body", "payload", "string", "array", "key", "keys",
                          "value", "values", "schema", "parse", "endpoint", "api", "data",
                          "output", "blob", "column", "columns", "parser", "serialization",
                          "valid", "invalid"]),
        Entry("python", "Python",
              leaders: ["in", "using", "with", "written in"],
              followers: ["code", "script", "scripts", "file", "files", "function", "package",
                          "project", "version", "interpreter", "module", "library", "repl",
                          "shell", "virtualenv", "3", "2"]),
        Entry("rust", "Rust",
              leaders: ["in", "using", "with", "written in"],
              followers: ["code", "compiler", "project", "cargo", "crates", "toolchain", "edition"]),
        Entry("swift", "Swift",
              leaders: ["in", "using", "with", "written in"],
              followers: ["code", "package", "project", "compiler", "concurrency", "6", "5"]),
        Entry("go", "Go",
              leaders: ["in", "using", "written in"],
              followers: ["module", "modules", "code", "program", "programs", "source",
                          "toolchain", "routine", "routines"]),
    ]

    // MARK: - Building

    /// An entry with both leaders and followers gets two rules, one per direction:
    /// "open cursor" and "the linear issue" are different shapes of the same word.
    private static func rules(_ entry: Entry) -> [Rule] {
        let term = phrasePattern(entry.spoken)
        let written = NSRegularExpression.escapedTemplate(for: entry.written)
        let gate = Set(words(in: entry.spoken))
        var out: [Rule] = []
        if !entry.leaders.isEmpty {
            let regex = pattern(
                #"(?<![\p{L}\p{N}.])("# + Self.alternation(entry.leaders) + #")\s+"# + term + tail)
            if let regex { out.append(Rule(regex: regex, template: "$1 " + written, gate: gate)) }
        }
        if !entry.followers.isEmpty {
            let regex = pattern(
                head + term + #"\s+("# + Self.alternation(entry.followers) + ")" + tail)
            if let regex { out.append(Rule(regex: regex, template: written + " $1", gate: gate)) }
        }
        if out.isEmpty, let regex = pattern(head + term + tail) {
            out.append(Rule(regex: regex, template: written, gate: gate))
        }
        return out
    }

    /// Whole word, not straight after a dot (already-typed ".gitignore"), not before
    /// an apostrophe ("Jason's", "Cursor's"), and not in front of a file extension
    /// that is already there.
    private static let head = #"(?<![\p{L}\p{N}.])"#
    private static let tail = #"(?![\p{L}\p{N}'’])(?!\s*(?:\.|dot)\s*(?:md|json|yml|yaml|env|toml|gitignore)\b)"#

    private static func pattern(_ body: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: body, options: [.caseInsensitive])
    }

    /// Longest alternative first, so "written in" is tried before "in" and
    /// "docs" before "doc".
    private static func alternation(_ words: [String]) -> String {
        words.sorted { $0.count > $1.count }.map(phrasePattern).joined(separator: "|")
    }

    /// "agents dot md" -> `agents\s+dot\s+md`, "package.json" -> `package\.json`.
    private static func phrasePattern(_ phrase: String) -> String {
        phrase.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
    }

    /// Lowercased runs of letters and digits, the same split the rest of the text
    /// pipeline uses, so a gate matches exactly the words a rule can match.
    private static func words(in phrase: String) -> [String] {
        phrase.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
