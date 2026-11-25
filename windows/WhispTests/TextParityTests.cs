using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using Whisp.Core.Text;

internal static class TextParityTests
{
    public static void Run(Action<string, string, string> expect, FillerCleaner dictCleaner)
    {
        var formatter = new TextFormatter();
        var cleaner = new FillerCleaner();

        (string Input, string Expected, string Rule)[] formatCases =
        [
        // Numbers twenty and up are written in digits; anything smaller stays a word.
        ("Send twenty five dollars today.", "Send $25 today.", "number and money"),
        ("Two hundred fifty units shipped.", "250 units shipped.", "hundreds"),
        ("We need one hundred and five of them.", "We need 105 of them.", "and inside a number"),
        ("It costs fifty bucks.", "It costs $50.", "slang money"),
        ("That is twenty five percent off.", "That is 25% off.", "percentage"),
        ("Wait twenty minutes.", "Wait 20 minutes.", "tens alone"),
        ("Three hundred thousand records.", "300000 records.", "thousand"),
        ("The twenty fifth of May.", "The 25th of May.", "ordinal"),
        ("I have five apples.", "I have five apples.", "must not fire: small count"),
        ("One thing at a time.", "One thing at a time.", "must not fire: one thing"),
        ("I have told you a hundred times.", "I have told you a hundred times.", "must not fire: a hundred times"),
        ("It costs five dollars.", "It costs five dollars.", "must not fire: small money stays words"),
        ("The five of us are here.", "The five of us are here.", "must not fire: five of us"),
        // A year or a price said the way people say it is not one number: half a
        // reading would write a wrong number, so all of it stays words.
        ("We met in twenty nineteen.", "We met in twenty nineteen.", "must not fire: spoken year"),
        ("I said twenty ten.", "I said twenty ten.", "must not fire: spoken year"),
        ("Twenty twelve was a good year.", "Twenty twelve was a good year.", "must not fire: spoken year"),
        ("In twenty twenty four we shipped it.", "In twenty twenty four we shipped it.",
         "must not fire: spoken year"),
        ("Flight twenty five twenty.", "Flight twenty five twenty.", "must not fire: number read in pairs"),
        ("That costs two fifty.", "That costs two fifty.", "must not fire: price read in pairs"),
        ("Three ninety nine for the shirt.", "Three ninety nine for the shirt.",
         "must not fire: price read in pairs"),
        ("I said dot dot dot and stopped.", "I said dot dot dot and stopped.", "must not fire: spoken ellipsis"),
        // Spoken clock times, only after a time word and only with a minute.
        ("Meet me at five thirty.", "Meet me at 5:30.", "clock time"),
        ("The call is at ten fifteen tomorrow.", "The call is at 10:15 tomorrow.", "clock time, teens"),
        ("Let us meet at five oh five.", "Let us meet at 5:05.", "clock time, leading zero"),
        ("Meet me at five.", "Meet me at five.", "must not fire: bare hour"),
        ("At one point we agreed.", "At one point we agreed.", "must not fire: at one point"),
        // Spoken file paths.
        ("Open src slash main dot swift.", "Open src/main.swift.", "path"),
        ("Open src slash components.", "Open src/components.", "single slash"),
        ("Go to www dot example dot com.", "Go to www.example.com.", "web address"),
        ("Dot env is the config file.", ".env is the config file.", "dot file at a sentence start"),
        ("Edit dot env first.", "Edit dot env first.", "must not fire: one spoken dot alone"),
        ("Check the package dot json file.", "Check the package dot json file.",
         "must not fire: one spoken dot alone"),
        ("We slash prices today.", "We slash prices today.", "must not fire: slash as a verb"),
        ("We slash prices slash costs today.", "We slash prices slash costs today.",
         "must not fire: two verbs, not a path"),
        ("Put a dot of paint on it.", "Put a dot of paint on it.", "must not fire: a dot of paint"),
        // Sentences: capital, closing stop, question mark, opener comma.
        ("we should ship it", "We should ship it.", "closing stop and capital"),
        ("is it working", "Is it working?", "question"),
        ("do you want coffee", "Do you want coffee?", "question"),
        ("where is the file", "Where is the file?", "question with wh-"),
        ("it's fine, right.", "It's fine, right?", "tag question"),
        ("what is done is done.", "What is done is done.", "must not fire: not a question"),
        ("do not do that.", "Do not do that.", "must not fire: not a question"),
        ("yes I think so.", "Yes, I think so.", "opener comma"),
        ("no it isn't.", "No, it isn't.", "opener comma"),
        ("okay let's go.", "Okay, let's go.", "opener comma"),
        ("no no, that's wrong.", "No no, that's wrong.", "must not fire: doubled no"),
        ("so we went home.", "So we went home.", "must not fire: no comma after so"),
        ("we ship today. then we rest.", "We ship today. Then we rest.", "second sentence"),
        ];
        HashSet<string> absorbedWords =
        [
        "dollars", "dollar", "bucks", "buck", "cents", "cent", "percent", "per", "slash",
        "dot", "underscore", "backslash", "forward", "and",
        ];
        HashSet<string> numberWords =
        [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty",
        "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion", "oh",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
        "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth",
        "seventeenth", "eighteenth", "nineteenth", "twentieth", "thirtieth", "fortieth",
        "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth", "hundredth",
        "thousandth", "millionth",
        ];
        foreach (var (input, expected, rule) in formatCases)
        {
            var actual = formatter.Format(input);
            expect(actual, expected, $"format({input}) - {rule}");
            expect(formatter.Format(expected), expected, $"format is idempotent: {expected}");

            var have = Words(actual).GroupBy(word => word).ToDictionary(group => group.Key, group => group.Count());
            foreach (var word in Words(input))
            {
                if (word.EnumerateRunes().Any(Rune.IsNumber) || absorbedWords.Contains(word) || numberWords.Contains(word))
                    continue;
                if (have.TryGetValue(word, out var count) && count > 0)
                    have[word] = count - 1;
                else
                    expect("missing", "present", $"format lost a word: {word} in {rule}: {input} -> {actual}");
            }
        }

        (string Input, string Expected)[] pipelineCases =
        [
        ("um so I I was thinking we should, like, ship it today",
         "So I was thinking we should ship it today."),
        ("the the build takes twenty five minutes and it's, uh, at five thirty",
         "The build takes 25 minutes and it's at 5:30."),
        ("open src slash main dot swift and change the timeout to twenty five percent",
         "Open src/main.swift and change the timeout to 25%."),
        ("it costs two hundred fifty dollars, right",
         "It costs $250, right?"),
        ("is it working yet or do we need, you know, to restart it",
         "Is it working yet or do we need to restart it?"),
        ];
        foreach (var (input, expected) in pipelineCases)
            expect(cleaner.CleanAndFormat(input), expected, $"pipeline(clean then format) {input}");

        (string Input, string Expected)[] packCases =
        [
        // File names, both spoken shapes
        ("put the rules in agents dot md", "put the rules in AGENTS.md"),
        ("update agents MD before you ship", "update AGENTS.md before you ship"),
        ("read claude dot md first", "read CLAUDE.md first"),
        ("put the rules in claude md", "put the rules in CLAUDE.md"),
        ("the soul dot md is the personality", "the SOUL.md is the personality"),
        ("add it to the readme", "add it to the README.md"),
        ("copy the dot env and fill it in", "copy the .env and fill it in"),
        ("bump package json and push", "bump package.json and push"),
        ("the ts config needs another alias", "the tsconfig.json needs another alias"),
        ("docker compose dot yaml has the ports", "docker-compose.yml has the ports"),
        ("put node modules in git ignore", "put node modules in .gitignore"),
        ("the make file has three targets", "the Makefile has three targets"),
        // Harnesses and AI tools
        ("claude code keeps rewriting my comments", "Claude Code keeps rewriting my comments"),
        ("ask chat gpt to check it", "ask ChatGPT to check it"),
        ("co-pilot wrote a worse version", "Copilot wrote a worse version"),
        ("open cursor and run the tests", "open Cursor and run the tests"),
        ("hermes is still running", "Hermes is still running"),
        ("push it to github", "push it to GitHub"),
        ("vs code is already open", "VS Code is already open"),
        ("the windsurf tab is lagging", "the Windsurf tab is lagging"),
        // Everyday words
        ("the pr on git hub is red", "the PR on GitHub is red"),
        ("put it in the jason file", "put it in the JSON file"),
        ("parse the jason and print it", "parse the JSON and print it"),
        ("run n p m install", "run npm install"),
        ("it only works on local host", "it only works on localhost"),
        ("use ssh to get in", "use SSH to get in"),
        ("the sub agent blew up", "the sub-agent blew up"),
        ("the mcp server is down", "the MCP server is down"),
        ("ask grok about the llm", "ask Grok about the LLM"),
        ("the gpu is pegged", "the GPU is pegged"),
        ("the api key is missing", "the API key is missing"),
        ("check the cli help", "check the CLI help"),
        ("fix the json output", "fix the JSON output"),
        ("it is a yaml thing", "it is a YAML thing"),
        ("post gres keeps dropping it", "Postgres keeps dropping it"),
        ("deploy it to vercel", "deploy it to Vercel"),
        ("the supabase keys are in the vault", "the Supabase keys are in the vault"),
        ("kube control rollout status", "kubectl rollout status"),
        ("swift ui is fine here", "SwiftUI is fine here"),
        ("it is core ml under the hood", "it is CoreML under the hood"),
        ("it works on mac os but not i os", "it works on macOS but not iOS"),
        ("typescript is fine, java script is not", "TypeScript is fine, JavaScript is not"),
        ("the cli is written in rust", "the CLI is written in Rust"),
        ("the cli is written in go", "the CLI is written in Go"),
        ("write a python script for it", "write a Python script for it"),
        ("open zed and paste it", "open Zed and paste it"),
        ("join the slack channel", "join the Slack channel"),
        ("the linear issue is stale", "the Linear issue is stale"),
        ("the notion page is empty", "the Notion page is empty"),
        ("figma has the new icons", "Figma has the new icons"),
        ("docker is not running", "Docker is not running"),
        ("ask capy to do it", "ask Capy to do it"),
        ("the codync agent is stuck", "the Codync agent is stuck"),
        ];
        foreach (var (input, expected) in packCases)
            expect(cleaner.Clean(input), expected, $"pack: \"{input}\"");

        string[] packUntouched =
        [
        "Jason called about the invoice.",
        "Jason's car is outside.",
        "I asked Jason to review the deploy.",
        "move the cursor to the end of the line.",
        "the cursor is blinking.",
        "make file copies of everything.",
        "a linear function of time.",
        "linear regression is boring.",
        "the notion of fairness matters.",
        "there is slack in the rope.",
        "the python was three meters long.",
        "rust on the car door.",
        "go to the store and get milk.",
        "swift delivery at noon.",
        "I bought yarn and a bun.",
        "the letter zed sounds like zee.",
        "we merged the commit and rebased the branch.",
        "the apiary is full of bees.",
        "she asked about Claude Monet.",
        "README.md is the entry point.",
        "the .gitignore file is fine.",
        "the AGENTS.md file has the rules.",
        "the package.json already has it.",
        // Nothing inside a path, a URL, an email, a branch name or an identifier.
        "open src/api/handler.ts and tell me what it says.",
        "check https://api.example.com/v1 before you deploy.",
        "send the invite to bob@api.com today.",
        "the branch is feat/api-cleanup on origin.",
        "rename api_key_for_user in the env file.",
        // Ordinary English that only looks like a product name.
        "we moved with swift action.",
        "the calls came in swift succession.",
        "coat it with rust protection.",
        "read Jason the letter when it lands.",
        "write Jason a note about it.",
        "I need to go code for a while.",
        "the wind surf was rough yesterday.",
        "the local host of the party left early.",
        ];
        foreach (var input in packUntouched)
            expect(cleaner.Clean(input), input, $"pack leaves alone: \"{input}\"");

        var overrideDict = new PersonalDictionary([], new Dictionary<string, string[]>
        {
            ["GitHub Enterprise"] = ["github"],
        });
        expect(new FillerCleaner(overrideDict).Clean("push it to git hub"), "push it to GitHub Enterprise",
            "dictionary beats the pack");

        expect(cleaner.Clean("I said dot dot dot and stopped."), "I said dot dot dot and stopped.",
            "clean leaves spoken ellipsis alone");
        expect(formatter.Format("see e.g., this test"), "See e.g., this test.", "abbreviation with comma is not a stop");

        CheckSpeed(expect, formatter, cleaner, dictCleaner);
    }

    private static IEnumerable<string> Words(string text) =>
        Regex.Matches(text.ToLowerInvariant(), @"[\p{L}\p{N}]+").Select(match => match.Value);

    private static void CheckSpeed(Action<string, string, string> expect, TextFormatter formatter,
        FillerCleaner cleaner, FillerCleaner dictCleaner)
    {
        string[] plainDictations =
        [
        "so I think we should ship it today and see what happens with the rest of the batch",
        "the meeting moved to three thirty and nobody told the other team about it",
        "can you send me the numbers from last week when you get a second",
        ];
        string[] codingDictations =
        [
        "so I told claude code to fix the agents dot md file and it broke the jason config again",
        "the pr on git hub is red so post gres and vercel both need another look before we ship it",
        "open cursor and run n p m install, then check the linear issue and put the notes in notion",
        ];

        const int longestLength = 8_815;
        var longestDictation = RepeatToLength("so I think we should ship it today and see what happens with the rest of the batch and then we can look at the numbers from last week and tell me what you think about the whole thing ", longestLength);
        var codingHeavy = RepeatToLength("so I told claude code to fix the agents dot md file and check the jason config on local host again ", longestLength);
        var longestMs = MedianCleanMs([longestDictation], 20);
        var codingHeavyMs = MedianCleanMs([codingHeavy], 20);
        var plainMs = MedianCleanMs(plainDictations, 200);
        var codingMs = MedianCleanMs(codingDictations, 200);
        Console.WriteLine($"cleanup with coding pack: {plainMs:F3} ms ordinary, {codingMs:F3} ms coding, {longestMs:F3} ms at {longestLength} chars (budget 5 ms)");
        Console.WriteLine($"  worst case at {longestLength} chars of nothing but coding words: {codingHeavyMs:F3} ms (printed, not asserted)");
        CheckBudget(Math.Max(Math.Max(plainMs, codingMs), longestMs), 5, "cleanup with coding pack");

        var longCleanup = string.Concat(Enumerable.Repeat("Um, so I I was, like, thinking we should, you know, ship the the thing. ", 40));
        var perCallMs = MeanMs(() => dictCleaner.Clean(longCleanup));
        Console.WriteLine($"clean() on {longCleanup.Length} chars: {perCallMs:F3} ms");
        CheckBudget(perCallMs, 20, "clean()");

        var longDictation = string.Concat(Enumerable.Repeat(
            "um so I I was thinking we should, like, ship the the build to src slash main dot swift at five thirty and it costs twenty five dollars. ", 32));
        var longWords = longDictation.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        var beforeMs = MeanMs(() => dictCleaner.Clean(longDictation));
        var afterMs = MeanMs(() => dictCleaner.CleanAndFormat(longDictation));
        var longCleaned = dictCleaner.Clean(longDictation);
        var perFormatMs = MeanMs(() => formatter.Format(longCleaned));
        Console.WriteLine($"text step on {longWords} words / {longDictation.Length} chars ({longWords / 2.5:F0} s of speech): clean {beforeMs:F3} ms -> clean+format {afterMs:F3} ms (format {perFormatMs:F3} ms)");
        CheckBudget(perFormatMs, 5, "format()");

        void CheckBudget(double milliseconds, int budget, string step) =>
            expect(milliseconds <= budget ? "within budget" : $"{milliseconds:F3} ms", "within budget",
                $"{step} {budget} ms budget");

        double MedianCleanMs(string[] texts, int iterations)
        {
            foreach (var text in texts) cleaner.Clean(text);
            var samples = new double[iterations];
            for (var i = 0; i < samples.Length; i++)
            {
                var start = Stopwatch.GetTimestamp();
                foreach (var text in texts) cleaner.Clean(text);
                samples[i] = Stopwatch.GetElapsedTime(start).TotalMilliseconds / texts.Length;
            }
            Array.Sort(samples);
            return samples[samples.Length / 2];
        }

        static string RepeatToLength(string sentence, int length) =>
            string.Concat(Enumerable.Repeat(sentence, (length + sentence.Length - 1) / sentence.Length))[..length];

        static double MeanMs(Action step)
        {
            step();
            var start = Stopwatch.GetTimestamp();
            for (var i = 0; i < 50; i++) step();
            return Stopwatch.GetElapsedTime(start).TotalMilliseconds / 50;
        }
    }
}
