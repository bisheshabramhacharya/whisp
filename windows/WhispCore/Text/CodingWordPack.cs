using System.Text.RegularExpressions;

namespace Whisp.Core.Text;

/// Built-in coding vocabulary, applied before the personal dictionary.
internal static class CodingWordPack
{
    private sealed record Entry(string Spoken, string Written, string[]? leaders = null, string[]? followers = null);
    private sealed record Rule(Regex Pattern, string Replacement, long[] Gate);

    private static readonly Entry[] FileNames =
    [
        new("agents.md", "AGENTS.md"),
        new("agents dot md", "AGENTS.md"),
        new("agents md", "AGENTS.md"),
        new("agent md", "AGENTS.md"),
        new("claude.md", "CLAUDE.md"),
        new("claude dot md", "CLAUDE.md"),
        new("claude md", "CLAUDE.md"),
        new("soul.md", "SOUL.md"),
        new("soul dot md", "SOUL.md"),
        new("soul md", "SOUL.md"),
        new("readme.md", "README.md"),
        new("readme", "README.md"),
        new("read me dot md", "README.md"),
        new("dot env", ".env"),
        new("dotenv", ".env"),
        new("package.json", "package.json"),
        new("package dot json", "package.json"),
        new("package json", "package.json"),
        new("tsconfig.json", "tsconfig.json"),
        new("tsconfig", "tsconfig.json"),
        new("ts config", "tsconfig.json"),
        new("docker-compose.yml", "docker-compose.yml"),
        new("docker compose dot yaml", "docker-compose.yml"),
        new("docker compose dot yml", "docker-compose.yml"),
        new("docker compose yaml", "docker-compose.yml"),
        new("docker compose yml", "docker-compose.yml"),
        new("gitignore", ".gitignore"),
        new("git ignore", ".gitignore"),
        new("dot git ignore", ".gitignore"),
        new("makefile", "Makefile"),
        new("make file", "Makefile",
              leaders: ["the", "a", "an", "your", "our", "my", "this", "that",
                        "update", "open", "edit", "rewrite", "check"]),
    ];

    private static readonly Entry[] Tools =
    [
        new("github", "GitHub"),
        new("git hub", "GitHub"),
        new("chatgpt", "ChatGPT"),
        new("chat gpt", "ChatGPT"),
        new("chat g p t", "ChatGPT"),
        new("gpt", "GPT"),
        new("claude code", "Claude Code"),
        new("claude", "Claude"),
        new("codex", "Codex"),
        new("capy", "Capy"),
        new("codync", "Codync"),
        new("hermes", "Hermes"),
        new("copilot", "Copilot"),
        new("co-pilot", "Copilot"),
        new("co pilot", "Copilot"),
        new("windsurf", "Windsurf"),
        new("aider", "Aider"),
        new("vs code", "VS Code"),
        new("vscode", "VS Code"),
        new("visual studio code", "VS Code"),
    ];

    private static readonly Entry[] Vocabulary =
    [
        new("n p m", "npm"),
        new("npm", "npm"),
        new("p n p m", "pnpm"),
        new("pnpm", "pnpm"),
        new("localhost", "localhost"),
        new("pr", "PR"),
        new("json", "JSON"),
        new("yaml", "YAML"),
        new("sql", "SQL"),
        new("s q l", "SQL"),
        new("api", "API"),
        new("a p i", "API"),
        new("cli", "CLI"),
        new("c l i", "CLI"),
        new("ssh", "SSH"),
        new("s s h", "SSH"),
        new("mcp", "MCP"),
        new("m c p", "MCP"),
        new("llm", "LLM"),
        new("l l m", "LLM"),
        new("gpu", "GPU"),
        new("g p u", "GPU"),
        new("sub agent", "sub-agent"),
        new("subagent", "sub-agent"),
        new("docker", "Docker"),
        new("kubectl", "kubectl"),
        new("kube control", "kubectl"),
        new("cube control", "kubectl"),
        new("kube cuddle", "kubectl"),
        new("cube cuddle", "kubectl"),
        new("kubernetes", "Kubernetes"),
        new("postgres", "Postgres"),
        new("post gres", "Postgres"),
        new("post gress", "Postgres"),
        new("supabase", "Supabase"),
        new("super base", "Supabase"),
        new("supa base", "Supabase"),
        new("vercel", "Vercel"),
        new("ver cel", "Vercel"),
        new("typescript", "TypeScript"),
        new("type script", "TypeScript"),
        new("javascript", "JavaScript"),
        new("java script", "JavaScript"),
        new("swiftui", "SwiftUI"),
        new("swift ui", "SwiftUI"),
        new("coreml", "CoreML"),
        new("core ml", "CoreML"),
        new("xcode", "Xcode"),
        new("x code", "Xcode"),
        new("macos", "macOS"),
        new("mac os", "macOS"),
        new("mac o s", "macOS"),
        new("ios", "iOS"),
        new("i os", "iOS"),
        new("figma", "Figma"),
        new("golang", "Go"),
    ];

    private static readonly Entry[] Contextual =
    [
        new("cursor", "Cursor",
              leaders: ["in", "on", "open", "launch", "use", "using", "with", "via", "into", "inside", "through"],
              followers: ["app", "editor", "tab", "composer", "chat", "agent"]),
        new("grok", "Grok",
              leaders: ["in", "on", "ask", "open", "using", "via"]),
        new("zed", "Zed",
              leaders: ["in", "on", "open", "launch", "using", "via", "through"],
              followers: ["editor", "app"]),
        new("cline", "Cline",
              leaders: ["in", "open", "launch", "using", "via"],
              followers: ["app", "editor", "extension"]),
        new("slack", "Slack",
              leaders: ["in", "on", "via", "using", "open", "from"],
              followers: ["channel", "channels", "message", "messages", "dm", "dms",
                          "thread", "threads", "workspace", "app", "bot", "huddle"]),
        new("notion", "Notion",
              leaders: ["in", "into", "on", "via", "using", "open"],
              followers: ["page", "pages", "doc", "docs", "database", "databases",
                          "workspace", "app", "board", "template", "templates", "wiki"]),
        // Followers only: "in linear" is a real English phrase, "linear issue" is not.
        new("linear", "Linear",
              followers: ["issue", "issues", "ticket", "tickets", "board", "app",
                          "project", "projects", "cycle", "roadmap", "workspace"]),
        // "Jason" is a person's name, so JSON only ever comes from a cue that puts
        // "the" between the verb and the name: "the jason file", "parse the jason".
        new("jason", "JSON",
              leaders: ["parse the", "read the", "write the", "load the", "validate the", "dump the"],
              followers: ["file", "files", "format", "config", "object", "objects",
                          "response", "body", "payload", "string", "array", "key", "keys",
                          "value", "values", "schema", "parse", "endpoint", "api", "data",
                          "output", "blob", "column", "columns", "parser", "serialization",
                          "valid", "invalid"]),
        new("python", "Python",
              leaders: ["written in"],
              followers: ["code", "script", "scripts", "file", "files", "function", "package",
                          "project", "version", "interpreter", "module", "library", "repl",
                          "shell", "virtualenv", "3", "2"]),
        new("rust", "Rust",
              leaders: ["written in"],
              followers: ["code", "compiler", "project", "cargo", "crates", "toolchain", "edition"]),
        new("swift", "Swift",
              leaders: ["written in"],
              followers: ["code", "package", "project", "compiler", "concurrency", "6", "5"]),
        // No "code" follower: "go code for a while" is ordinary English.
        new("go", "Go",
              leaders: ["written in"],
              followers: ["module", "modules", "program", "programs", "source", "toolchain",
                          "routine", "routines"]),
        // "the local host of the party" is ordinary English, "on local host" is not.
        new("local host", "localhost",
              leaders: ["on", "at", "to", "via", "through", "reach"]),
    ];

    private const string Head = @"(?<![\p{L}\p{N}._/@:-])";
    private const string Tail =
        @"(?![\p{L}\p{N}'’_/@:-])(?!\s*(?:\.|dot)\s*(?:md|json|yml|yaml|env|toml|gitignore)\b)";
    private static readonly Regex GateWords = new("[a-z0-9]+", RegexOptions.CultureInvariant);
    private static readonly Rule[] Rules = new[] { Tools, Vocabulary, Contextual, FileNames }
        .SelectMany(group => group.OrderByDescending(entry => entry.Spoken.Length)
            .ThenBy(entry => entry.Spoken, StringComparer.Ordinal))
        .SelectMany(BuildRules)
        .ToArray();

    public static string Apply(string text)
    {
        if (text.Length == 0) return text;
        var present = new HashSet<long>();
        var hash = 5381L;
        var inWord = false;
        foreach (var ch in text)
        {
            var ascii = LowerAscii(ch);
            if (ascii is >= 'a' and <= 'z' or >= '0' and <= '9')
            {
                hash = unchecked(hash * 33 + ascii);
                inWord = true;
            }
            else if (inWord)
            {
                present.Add(hash);
                hash = 5381;
                inWord = false;
            }
        }
        if (inWord) present.Add(hash);

        foreach (var rule in Rules)
        {
            if (Array.TrueForAll(rule.Gate, present.Contains))
                text = rule.Pattern.Replace(text, rule.Replacement);
        }
        return text;
    }

    private static IEnumerable<Rule> BuildRules(Entry entry)
    {
        var term = Pattern(entry.Spoken);
        var written = entry.Written.Replace("$", "$$");
        var gate = GateWords.Matches(entry.Spoken).Select(match => Hash(match.Value)).Distinct().ToArray();
        if (entry.leaders is { Length: > 0 } leaders)
            yield return CreateRule("(" + Alternation(leaders) + @")\s+" + term, "$1 " + written, gate);
        if (entry.followers is { Length: > 0 } followers)
            yield return CreateRule(term + @"\s+(" + Alternation(followers) + ")", written + " $1", gate);
        if (entry.leaders is null && entry.followers is null)
            yield return CreateRule(term, written, gate);
    }

    private static Rule CreateRule(string body, string replacement, long[] gate) =>
        new(new Regex(Head + body + Tail, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), replacement, gate);

    private static string Alternation(string[] words) =>
        string.Join("|", words.OrderByDescending(word => word.Length).Select(Pattern));

    private static string Pattern(string phrase) =>
        string.Join(@"\s+", phrase.Split(' ').Select(Regex.Escape));

    private static long Hash(string word)
    {
        var hash = 5381L;
        foreach (var ch in word)
            hash = unchecked(hash * 33 + LowerAscii(ch));
        return hash;
    }

    private static char LowerAscii(char ch) => ch is >= 'A' and <= 'Z' ? (char)(ch + 32) : ch;
}
