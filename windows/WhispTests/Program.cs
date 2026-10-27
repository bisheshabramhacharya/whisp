// Plain executable test runner for WhispCore on Windows. The cleanup, dictionary,
// segmenter and hotkey tables are the same cases as Sources/whisp-tests/main.swift,
// so both platforms are held to identical behavior. Exits non-zero on any failure.

using System.IO.Compression;
using Whisp.Core;
using Whisp.Core.ASR;
using Whisp.Core.Input;
using Whisp.Core.Text;

var failures = 0;
var passes = 0;

void Expect(string actual, string expected, string label = "", [System.Runtime.CompilerServices.CallerLineNumber] int line = 0)
{
    if (actual == expected)
    {
        passes++;
    }
    else
    {
        failures++;
        Console.WriteLine($"FAIL line {line} {label}\n  expected: {expected}\n  actual:   {actual}");
    }
}

string Lower(bool b) => b ? "true" : "false";

string NewTempPath(string name) => Path.Combine(Path.GetTempPath(), $"whisp-{name}-{Guid.NewGuid():N}");

// FillerCleaner

var cleaner = new FillerCleaner();
(string, string)[] cases =
{
    // Hesitations
    ("Um, I think we should go.", "I think we should go."),
    ("Uh, so what's the plan?", "So what's the plan?"),
    ("I was, uh, going to call you.", "I was going to call you."),
    ("So, um, we should ship it.", "So, we should ship it."),
    ("I think, um.", "I think."),
    ("Um. I think it works.", "I think it works."),
    ("The um meeting is at 3 PM.", "The meeting is at 3 PM."),
    ("Hmm, let me check.", "Let me check."),
    ("Um.", ""),
    ("", ""),
    // Parenthetical fillers only when set off by commas
    ("It was, like, huge.", "It was huge."),
    ("Like, I don't know.", "I don't know."),
    ("I like pizza.", "I like pizza."),
    ("It looks like rain.", "It looks like rain."),
    ("It was great, you know.", "It was great."),
    ("You know, I think so.", "I think so."),
    ("Do you know where it is?", "Do you know where it is?"),
    ("It's, I mean, fine.", "It's fine."),
    ("I mean what I say.", "I mean what I say."),
    ("I like, you know, dogs.", "I like dogs."),
    // Stutters
    ("I I think so.", "I think so."),
    ("I, I think so.", "I think so."),
    ("The the report is done.", "The report is done."),
    ("We we we should go.", "We should go."),
    ("I know that that is true.", "I know that that is true."),
    ("She had had enough.", "She had had enough."),
    ("No no, that's wrong.", "No no, that's wrong."),
    ("It was very very good.", "It was very very good."),
    ("Go. Go.", "Go. Go."),
    // Restarted phrases
    ("Go to the go to desktop folder.", "Go to desktop folder."),
    ("I want to I want to go home.", "I want to go home."),
    ("Make sure you, make sure you open it.", "Make sure you open it."),
    ("Is it, is it working?", "Is it working?"),
    ("It is what it is.", "It is what it is."),
    ("How long did it take? How long did it take?", "How long did it take? How long did it take?"),
    ("No no no no.", "No no no no."),
    ("I can can make make it.", "I can make it."),
    ("Just do that Do that, but fast.", "Just do that, but fast."),
    // Never rewrites
    ("She went to the ER.", "She went to the ER."),
    ("It's 5 mm wide.", "It's 5 mm wide."),
    ("Send $4.2 million to Sarah by March 3rd.", "Send $4.2 million to Sarah by March 3rd."),
    ("Uh-huh, that works.", "Uh-huh, that works."),
    ("Honestly, it's basically done.", "Honestly, it's basically done."),
    ("Let's meet at 10:30 — okay?", "Let's meet at 10:30 — okay?"),
    // Real Parakeet output
    ("Um, so I think we should, well, send $4.2 million to Sarah by March 3rd. And then, you know, update the vintage listing.",
     "So I think we should, well, send $4.2 million to Sarah by March 3rd. And then update the vintage listing."),
    // Clock times
    ("Send me the report by 5.30? Thanks.", "Send me the report by 5:30? Thanks."),
    ("Moved to Thursday at 2.45 p.m.", "Moved to Thursday at 2:45 p.m."),
    ("Call her 3.45 PM.", "Call her 3:45 PM."),
    ("We shipped version 2.4 on Tuesday.", "We shipped version 2.4 on Tuesday."),
    ("Upgrade to 2.45 today.", "Upgrade to 2.45 today."),
    ("It went from 1.25.3 to 1.26.", "It went from 1.25.3 to 1.26."),
    ("That costs $5.30 total.", "That costs $5.30 total."),
    ("Peak hit 1.2 gigabytes.", "Peak hit 1.2 gigabytes."),
    // Adversarial table — real sentences the cleaner must not damage.
    ("Hear, hear!", "Hear, hear!"),
    ("Order the mahi mahi.", "Order the mahi mahi."),
    ("We're going to Bora Bora in June.", "We're going to Bora Bora in June."),
    ("Walla Walla onions are sweet.", "Walla Walla onions are sweet."),
    ("A yo yo rolled by.", "A yo yo rolled by."),
    ("The odds are fifty fifty.", "The odds are fifty fifty."),
    ("Keep the details hush hush.", "Keep the details hush hush."),
    ("I do do my best work at night.", "I do do my best work at night."),
    ("Test test, is this thing on?", "Test test, is this thing on?"),
    ("Stop, stop! That tickles.", "Stop, stop! That tickles."),
    ("He served time in Sing Sing.", "He served time in Sing Sing."),
    ("We flew to Pago Pago.", "We flew to Pago Pago."),
    ("She adopted a chow chow.", "She adopted a chow chow."),
    ("In twenty twenty we moved.", "In twenty twenty we moved."),
    ("It was nineteen nineteen.", "It was nineteen nineteen."),
    ("She sang na na na na.", "She sang na na na na."),
    ("The cow goes moo moo.", "The cow goes moo moo."),
    ("The duck said quack quack.", "The duck said quack quack."),
    ("Honk honk went the horn.", "Honk honk went the horn."),
    ("She wore a mu mu dress.", "She wore a mu mu dress."),
    ("I love a good bon bon.", "I love a good bon bon."),
    ("Ding ding, round two.", "Ding ding, round two."),
    ("Goo goo ga ga, said the baby.", "Goo goo ga ga, said the baby."),
    ("Woo woo, here we go.", "Woo woo, here we go."),
    ("The crowd went rah rah rah.", "The crowd went rah rah rah."),
    ("Yadda yadda yadda, whatever.", "Yadda yadda yadda, whatever."),
    ("Hee hee, that's funny.", "Hee hee, that's funny."),
    ("He laughed haw haw haw.", "He laughed haw haw haw."),
    ("Nudge nudge, wink wink.", "Nudge nudge, wink wink."),
    ("Tut tut, that's naughty.", "Tut tut, that's naughty."),
    ("Tsk tsk, not again.", "Tsk tsk, not again."),
    ("Ring ring, someone's calling.", "Ring ring, someone's calling."),
    ("Woof woof, said the dog.", "Woof woof, said the dog."),
    ("The cat goes meow meow.", "The cat goes meow meow."),
    ("Dum dum, went the beat.", "Dum dum, went the beat."),
    ("Let's go let's go!", "Let's go let's go!"),
    ("Wake up wake up!", "Wake up wake up!"),
    ("On off on off.", "On off on off."),
    ("Press 1 2 1 2.", "Press 1 2 1 2."),
    ("He ran and ran and ran.", "He ran and ran and ran."),
    ("Up down up down up.", "Up down up down up."),
    ("Thank you thank you.", "Thank you thank you."),
    ("I think. um, he agrees.", "I think. He agrees."),
    ("We won. uh, the crowd cheered.", "We won. The crowd cheered."),
    ("It's fine. you know, we should go.", "It's fine. We should go."),
    ("you know, we should go.", "We should go."),
    ("I agree. i mean, it works.", "I agree. It works."),
    ("The rate is at 3.14 percent.", "The rate is at 3.14 percent."),
    ("It grew by 2.45 percent.", "It grew by 2.45 percent."),
    ("We measured at 4.30 inches.", "We measured at 4.30 inches."),
    ("Down by 5.30 kilos.", "Down by 5.30 kilos."),
    ("Rates vary from 2.30 to 4.10 percent.", "Rates vary from 2.30 to 4.10 percent."),
    ("The score rose by 1.50 points.", "The score rose by 1.50 points."),
    ("It's priced at 9.99 dollars.", "It's priced at 9.99 dollars."),
    ("It costs at least 5.30 dollars.", "It costs at least 5.30 dollars."),
    ("Meet me at 5.30.", "Meet me at 5:30."),
    ("See you around 6.15.", "See you around 6:15."),
    ("The meeting ends by 8.45.", "The meeting ends by 8:45."),
    ("Meet from 9.00 to 5.30.", "Meet from 9:00 to 5:30."),
    ("The shop is open between 8.30 and 6.00.", "The shop is open between 8:30 and 6:00."),
    ("It runs at 5.30 or 6.00.", "It runs at 5:30 or 6:00."),
    ("Open from 8.30-5.30.", "Open from 8:30-5:30."),
    ("We can, we can't.", "We can, we can't."),
    ("I did, I didn't.", "I did, I didn't."),
    ("Like father, like son.", "Like father, like son."),
    ("I like pizza and you know it.", "I like pizza and you know it."),
    ("You know what, I agree.", "You know what, I agree."),
    ("I mean business.", "I mean business."),
    ("So, the plan is simple.", "So, the plan is simple."),
    ("What he is, is a mystery.", "What he is, is a mystery."),
    ("The reason is is that he left.", "The reason is is that he left."),
    ("Do it don't do it.", "Do it don't do it."),
    ("I had had enough by then.", "I had had enough by then."),
    ("Send it to the ER.", "Send it to the ER."),
};
foreach (var (input, output) in cases)
{
    Expect(cleaner.Clean(input), output, $"clean(\"{input}\")");
}

// PersonalDictionary

var dict = new PersonalDictionary(
    new[] { "Vinted", "Poshmark", "Whisp", "lowercase" },
    new Dictionary<string, string[]> { ["ChatGPT"] = new[] { "chat gpt", "chat g p t" }, ["Bishesha"] = new[] { "bee shesha" } });
var dictCleaner = new FillerCleaner(dict);
Expect(dictCleaner.Clean("I listed it on vinted and poshmark."), "I listed it on Vinted and Poshmark.");
Expect(dictCleaner.Clean("Ask chat  g p t, um, about it."), "Ask ChatGPT about it.");
Expect(dictCleaner.Clean("Chat GPT is useful."), "ChatGPT is useful.");
Expect(dictCleaner.Clean("Hi, I'm bee shesha."), "Hi, I'm Bishesha.");
Expect(dictCleaner.Clean("Invented things."), "Invented things.", "no partial-word match");
Expect(dictCleaner.Clean("whisper and whisp"), "whisper and Whisp");
Expect(new PersonalDictionary(Array.Empty<string>(), new Dictionary<string, string[]> { ["$5 & up"] = new[] { "five up" } })
    .Apply("costs five up"), "costs $5 & up", "replacement text is literal");

// File-backed dictionary: live reload on edit, malformed edit keeps last good version.
{
    var tmp = NewTempPath("dict") + ".json";
    var fileDict = new PersonalDictionary(tmp);
    Expect(fileDict.Apply("vinted"), "vinted", "missing file is empty");
    File.WriteAllText(tmp, """{"terms": ["Vinted"], "replacements": [{"from": "posh mark", "to": "Poshmark"}]}""");
    Expect(fileDict.Apply("vinted and posh mark"), "Vinted and Poshmark", "loads file");
    File.WriteAllText(tmp, """{"terms": ["Depop"]}""");
    File.SetLastWriteTimeUtc(tmp, DateTime.UtcNow.AddSeconds(5));
    Expect(fileDict.Apply("vinted on depop"), "vinted on Depop", "reloads on change");
    File.WriteAllText(tmp, """{"terms": [""");
    File.SetLastWriteTimeUtc(tmp, DateTime.UtcNow.AddSeconds(10));
    Expect(fileDict.Apply("depop"), "Depop", "malformed edit keeps last good");
    File.Delete(tmp);
    Expect(fileDict.Apply("depop"), "Depop", "transiently missing file keeps last good");
    File.WriteAllText(tmp, """{"terms": ["Grailed"], "replacements": [{"from": "depop", "to": "Depop App"}]}""");
    Expect(fileDict.Apply("grailed"), "Grailed", "recovers after the file returns");
    File.Delete(tmp);
}

// PersonalDictionary.AddReplacement / AddTerm / Remove*
{
    var url = NewTempPath("add") + ".json";
    PersonalDictionary.AddReplacement("Pychy", "pi CLI", url);
    File.WriteAllText(url, """{"terms": ["Vinted"], "replacements": [{"from": "Py CLI", "to": "pi CLI"}]}""");
    PersonalDictionary.AddReplacement("Pychy", "pi CLI", url);
    PersonalDictionary.AddReplacement("pychy", "pi CLI", url);
    PersonalDictionary.AddReplacement("GPT-6 soul", "GPT-6 Sol", url);
    var added = new PersonalDictionary(url);
    Expect(added.Apply("open Pychy and Py CLI on GPT-6 soul with vinted"),
        "open pi CLI and pi CLI on GPT-6 Sol with Vinted", "added replacements apply, terms kept");
    var pairs = PersonalDictionary.LoadPairs(url);
    Expect($"{pairs.Count} [{string.Join(", ", pairs[0].From)}]", "2 [Py CLI, Pychy]", "merges into same target, no dup");
    PersonalDictionary.AddTerm("Kubernetes", url);
    PersonalDictionary.AddTerm("kubernetes", url);
    Expect(string.Join(",", PersonalDictionary.LoadTerms(url)), "Vinted,Kubernetes", "AddTerm dedupes");
    PersonalDictionary.RemoveTerm("VINTED", url);
    PersonalDictionary.RemoveReplacement("GPT-6 soul", "GPT-6 Sol", url);
    Expect($"{string.Join(",", PersonalDictionary.LoadTerms(url))} {PersonalDictionary.LoadPairs(url).Count}", "Kubernetes 1",
        "remove term and emptied rule");
    File.WriteAllText(url, """{"terms": [""");
    var refused = false;
    try { PersonalDictionary.AddReplacement("a", "b", url); } catch (Exception) { refused = true; }
    Expect($"{Lower(refused)} {File.ReadAllText(url)}", "true {\"terms\": [", "malformed file untouched");
    File.Delete(url);
}

// SpeechSegmenter

float[] Tone(double seconds, float amplitude = 0.3f) =>
    Enumerable.Range(0, (int)(seconds * 16_000)).Select(i => amplitude * MathF.Sin(i * 0.2f)).ToArray();
float[] Silence(double seconds) => new float[(int)(seconds * 16_000)];
float[] Cat(params float[][] parts) => parts.SelectMany(p => p).ToArray();

{
    var speech = Cat(Tone(4), Silence(0.6), Tone(4));
    var cut = SpeechSegmenter.NextCut(speech);
    Expect(cut is >= 64_000 and <= 73_600 ? "in pause" : $"at {cut}", "in pause", "cut lands in the pause");
    Expect(SpeechSegmenter.NextCut(Cat(Tone(3), Silence(0.6), Tone(1)))?.ToString() ?? "nil", "nil", "waits for minChunk");
    Expect(Lower(SpeechSegmenter.EndsInPause(Cat(Tone(2), Silence(0.5)))), "true", "speech then pause");
    Expect(Lower(SpeechSegmenter.EndsInPause(Cat(Tone(2), Silence(0.1)))), "false", "pause too short");
    Expect(Lower(SpeechSegmenter.EndsInPause(Silence(2))), "false", "no speech");
    Expect(SpeechSegmenter.NextCut(Cat(Tone(4, 0.002f), Silence(0.6), Tone(4)))?.ToString() ?? "nil", "nil",
        "keeps near-silent chunk attached");
    Expect(SpeechSegmenter.NextCut(Tone(8))?.ToString() ?? "nil", "nil", "no pause, below forceChunk");
    Expect(SpeechSegmenter.NextCut(Tone(15)) != null ? "cut" : "nil", "cut", "forced cut");
    Expect(SpeechSegmenter.Plan(Cat(Tone(5), Silence(0.6), Tone(5), Silence(0.6), Tone(5))).Count.ToString(), "2", "plan");

    const int window15 = 15 * 16_000;
    Expect(SpeechSegmenter.Split(Tone(10), window15).Count.ToString(), "1", "short audio stays whole");
    var longTake = Cat(Tone(12), Silence(0.4), Tone(20));
    var pieces = SpeechSegmenter.Split(longTake, window15);
    Expect(pieces.All(p => p.Length <= window15) ? "fits" : string.Join(",", pieces.Select(p => p.Length)), "fits",
        "every piece fits the window");
    Expect(pieces.Sum(p => p.Length).ToString(), longTake.Length.ToString(), "no audio lost");
    Expect(Math.Abs(pieces[0].Length - 12 * 16_000 - 3_200) <= 3_200 ? "in pause" : $"at {pieces[0].Length}", "in pause",
        "cuts in the quiet gap");
    var pauseless = SpeechSegmenter.Split(Tone(40), window15);
    Expect(pauseless.Count >= 3 && pauseless.All(p => p.Length <= window15) ? "fits" : "no", "fits",
        "pause-free speech still splits");
    Expect(SpeechSegmenter.Join(new[] { "I went to", "The store and then.", "The end." }), "I went to the store and then. The end.");
    Expect(SpeechSegmenter.Join(new[] { "Hello", "", "Bishesha said hi." }), "Hello Bishesha said hi.");
    Expect(SpeechSegmenter.Join(new[] { "It stops.", "changing words." }), "It stops changing words.", "seam period dropped");
    Expect(SpeechSegmenter.Join(new[] { "Meet at 5 p.m.", "tomorrow." }), "Meet at 5 p.m. tomorrow.", "abbreviation kept");
}

// SpeechSegmenter.FinishAsync

async Task<(string, string)> FinishCalls(float[] tail)
{
    var chunk = Tone(7);
    var calls = new List<int>();
    var text = await SpeechSegmenter.FinishAsync(Cat(chunk, tail), new[] { 0 }, new[] { "Chunk one." }, chunk.Length, null,
        s => { calls.Add(s.Length); return Task.FromResult("Tail."); });
    return (text, "[" + string.Join(", ", calls) + "]");
}
{
    var (text, calls) = await FinishCalls(Silence(1));
    Expect(text, "Chunk one.", "silent tail reuses chunk text");
    Expect(calls, "[]", "silent tail: no model call");
}
{
    var (text, calls) = await FinishCalls(Cat(Silence(0.5), Tone(0.06, 0.02f), Silence(0.44)));
    Expect(text, "Tail.", "quiet word in tail re-decodes last chunk");
    Expect(calls, $"[{7 * 16_000 + 16_000}]", "re-decode covers chunk + tail");
}
{
    var (text, calls) = await FinishCalls(Cat(Silence(0.5), Tone(0.3, 0.008f), Silence(0.2)));
    Expect(text, "Chunk one.", "sub-threshold tail reuses chunk text");
    Expect(calls, "[]", "sub-threshold tail: no model call");
}
{
    var chunk = Tone(7);
    var calls = new List<int>();
    Task<string> Fake(float[] s) { calls.Add(s.Length); return Task.FromResult("Tail."); }
    var samples = Cat(chunk, Tone(2), Silence(1));
    var spec = (chunk.Length + 2 * 16_000 + 8_000, "Spec.");
    Expect(await SpeechSegmenter.FinishAsync(samples, new[] { 0 }, new[] { "Chunk one." }, chunk.Length, spec, Fake),
        "Chunk one. Spec.", "speculation reused");
    Expect(calls.Count.ToString(), "0", "speculation: no model call");
    Expect(await SpeechSegmenter.FinishAsync(Cat(samples, Tone(1)), new[] { 0 }, new[] { "Chunk one." }, chunk.Length, spec, Fake),
        "Chunk one. Tail.", "stale speculation ignored");
}
{
    var (text, calls) = await FinishCalls(Tone(2));
    Expect(text, "Chunk one. Tail.", "speech tail decoded alone");
    Expect(calls, "[32000]", "only the tail is decoded");
}

// Paste spacing

Expect(Lower(Spacing.NeedsSpace('d')), "true", "after a word");
Expect(Lower(Spacing.NeedsSpace('.')), "true", "after a period");
Expect(Lower(Spacing.NeedsSpace(' ')), "false", "after a space");
Expect(Lower(Spacing.NeedsSpace('\n')), "false", "after a newline");
Expect(Lower(Spacing.NeedsSpace('(')), "false", "after (");
Expect(Lower(Spacing.NeedsSpace('/')), "false", "after /");
Expect(Lower(Spacing.NeedsSpace('“')), "false", "after an opening curly quote");

// The leading-space character is published before the slower caret reads.
// A budget expiry during those reads must not drop it. The timer is a gate
// the test opens, so this does not wait on the wall clock.
{
    var enteredTail = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var releaseTail = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var budget = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var lookup = CaretLookup.Start(TimeSpan.FromMilliseconds(250), deliver =>
    {
        deliver('d');
        enteredTail.SetResult();
        releaseTail.Task.GetAwaiter().GetResult();
        return 1;
    }, _ => budget.Task);
    await enteredTail.Task;
    budget.SetResult();
    var preceding = await lookup.Preceding;
    var completed = await lookup.Completed;
    var snapshot = await lookup.Snapshot;
    releaseTail.SetResult();
    Expect(preceding?.ToString() ?? "null", "d", "preceding survives a tail read that misses the budget");
    Expect(Lower(preceding is char c && Spacing.NeedsSpace(c)), "true", "that character still decides the leading space");
    Expect(Lower(completed), "false", "tail read past the budget is dropped");
    Expect(snapshot.ToString(), "0", "timed-out snapshot is empty");
}
{
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var budget = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var lookup = CaretLookup.Start(TimeSpan.FromMilliseconds(250), deliver =>
    {
        started.SetResult();
        release.Task.GetAwaiter().GetResult();
        deliver('d');
        return 1;
    }, _ => budget.Task);
    await started.Task;
    budget.SetResult();
    var preceding = await lookup.Preceding;
    var completed = await lookup.Completed;
    release.SetResult();
    Expect(preceding?.ToString() ?? "null", "null", "preceding not ready when the budget ends stays unset");
    Expect(Lower(completed), "false", "read still running at the budget does not count");
}
{
    var budget = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var done = await CaretLookup.Run(TimeSpan.FromMilliseconds(250), deliver =>
    {
        deliver('\n');
        return 1;
    }, _ => budget.Task);
    Expect(done.Preceding == '\n' ? "start" : done.Preceding?.ToString() ?? "null", "start", "caret at the start is delivered");
    Expect(Lower(done.Preceding is char c && Spacing.NeedsSpace(c)), "false", "start of field still needs no leading space");
    Expect(Lower(done.Completed), "true", "a fast read keeps the snapshot");
    Expect(done.Snapshot.ToString(), "1", "snapshot from a fast read is kept");
}

// HotkeyStateMachine

string Run(params (HotkeyInput Input, double At)[] inputs)
{
    var m = new HotkeyStateMachine();
    return string.Join(" ", inputs.Select(i => m.Handle(i.Input, i.At) switch
    {
        null => "-",
        HotkeyEvent.HandsFree => "handsFree",
        var e => e.ToString()!.ToLowerInvariant(),
    }));
}
const HotkeyInput Down = HotkeyInput.KeyDown, Up = HotkeyInput.KeyUp, Other = HotkeyInput.OtherKey,
    Char = HotkeyInput.CharacterKey, Esc = HotkeyInput.Escape;
Expect(Run((Down, 0), (Up, 1)), "start stop", "hold");
Expect(Run((Down, 0), (Up, 0.1)), "start cancel", "tap cancels");
Expect(Run((Down, 0), (Up, 0.1), (Down, 0.3), (Up, 0.4), (Down, 5), (Up, 5.1)),
    "start cancel start handsFree stop -", "double-tap locks hands-free; next press stops, release swallowed");
Expect(Run((Down, 0), (Up, 0.1), (Down, 0.3), (Up, 0.4), (Other, 1), (Char, 2)),
    "start cancel start handsFree - -", "hands-free event is emitted only when entering the mode");
Expect(Run((Down, 0), (Up, 0.1), (Down, 0.3), (Up, 2)), "start cancel start stop", "tap then hold is a normal hold");
Expect(Run((Down, 0), (Up, 0.1), (Down, 0.9), (Up, 1.0)), "start cancel start cancel", "second tap outside window is just a tap");
Expect(Run((Down, 0), (Other, 0.1), (Up, 0.5)), "start cancel -", "chord within grace cancels");
Expect(Run((Down, 0), (Other, 1), (Up, 2)), "start - stop", "other key after grace ignored");
Expect(Run((Down, 0), (Esc, 1), (Up, 2)), "start cancel -", "Esc cancels a hold");
Expect(Run((Down, 0), (Up, 0.1), (Down, 0.3), (Up, 0.4), (Esc, 3)), "start cancel start handsFree cancel", "Esc cancels hands-free");
Expect(Run((Down, 0), (Up, 1), (Esc, 1.1)), "start stop cancel", "Esc after release reaches the controller");
Expect(Run((Down, 0), (Char, 0.8), (Up, 0.9)), "start cancel -", "Alt+char after a dwell cancels");
Expect(Run((Down, 0), (Char, 3), (Up, 4)), "start - stop", "stray key mid-dictation keeps the take");
Expect(Run((Down, 0), (Up, 0.1), (Down, 0.3), (Char, 1.2), (Up, 1.3)), "start cancel start cancel -", "Alt+char cancels a second hold");
Expect(Run((Down, 0), (Up, 0.1), (Down, 0.3), (Up, 0.4), (Char, 2), (Char, 2.1), (Down, 3), (Up, 3.1)),
    "start cancel start handsFree - - stop -", "chars in hands-free are ignored");

// Settings survive relaunch

{
    var path = NewTempPath("settings") + ".json";
    var settings = new AppSettings(path);
    Expect(Lower(settings.OnboardingCompleted), "false", "fresh install needs setup");
    Expect(Lower(settings.AlwaysShowPill), "true", "pill is visible between dictations");
    Expect(settings.Hotkey.ToString(), "RightAlt", "Right Alt is the default key");
    settings.PillOrigin = (-640, 315);
    settings.OnboardingCompleted = true;
    var relaunched = new AppSettings(path);
    Expect(Lower(relaunched.OnboardingCompleted), "true", "completed setup survives relaunch");
    Expect($"{relaunched.PillOrigin?.X} {relaunched.PillOrigin?.Y}", "-640 315", "pill position survives relaunch");
    relaunched.PillOrigin = null;
    Expect(new AppSettings(path).PillOrigin == null ? "reset" : "saved", "reset", "reset position clears the saved origin");
    File.WriteAllText(path, "{ not json");
    Expect(Lower(new AppSettings(path).Sounds), "true", "corrupt settings fall back to defaults");
    File.Delete(path);
}

// History: Mac lines read as-is, and lines written here match the Mac's format

{
    const string macLine = """{"cleaned":"Ship it.","date":"2026-09-30T12:34:56Z","durationSec":1.5,"id":"A1B2","latencyMs":88,"raw":"Um, ship it."}""";
    var entry = HistoryStore.Decode(macLine);
    Expect($"{entry?.Id} {entry?.Cleaned} {entry?.Date:O} {entry?.LatencyMs}", "A1B2 Ship it. 2026-09-30T12:34:56.0000000+00:00 88",
        "reads a Mac history line");
    Expect(HistoryStore.Encode(entry!), """{"id":"A1B2","date":"2026-09-30T12:34:56Z","durationSec":1.5,"raw":"Um, ship it.","cleaned":"Ship it.","latencyMs":88}""",
        "writes the Mac's date format");
    var store = new HistoryStore(NewTempPath("history") + ".jsonl");
    for (var i = 0; i < 5; i++)
        store.Append(new HistoryEntry($"id{i}", DateTimeOffset.UnixEpoch.AddDays(i), 1, "r", $"c{i}", 10));
    Expect(string.Join(",", store.LoadLast(3).Select(e => e.Cleaned)), "c4,c3,c2", "LoadLast is newest first");
    var merged = store.Merge(new[]
    {
        new HistoryEntry("id1", DateTimeOffset.UnixEpoch, 1, "r", "dup", 10),
        new HistoryEntry("mac", DateTimeOffset.UnixEpoch.AddHours(36), 1, "r", "mac", 10),
    });
    Expect($"{merged} {string.Join(",", store.LoadAll().Select(e => e.Cleaned))}", "1 c0,c1,mac,c2,c3,c4", "merge adds new ids in date order");
    File.Delete(store.FilePath);
}

// Import from Mac

{
    var export = NewTempPath("export");
    var data = Path.Combine(export, "whisp-export");
    Directory.CreateDirectory(Path.Combine(data, "recordings"));
    File.WriteAllText(Path.Combine(data, "dictionary.json"),
        """{"terms" : ["Kubernetes", "Vinted"], "replacements" : [{"from" : ["cloud code", "clawed code"], "to" : "Claude Code"}]}""");
    File.WriteAllText(Path.Combine(data, "history.jsonl"),
        """{"cleaned":"From the Mac.","date":"2026-09-30T12:34:56Z","durationSec":1.5,"id":"MAC-1","latencyMs":88,"raw":"From the Mac."}""" + "\n");
    File.WriteAllBytes(Path.Combine(data, "recordings", "MAC-1.wav"), new byte[] { 1, 2, 3 });
    File.WriteAllText(Path.Combine(data, "settings.plist"), """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>alwaysShowPill</key><false/>
            <key>hotkeyKeyCode</key><integer>61</integer>
            <key>pillOrigin</key><array><real>12</real><real>40</real></array>
            <key>pillScale</key><real>1</real>
            <key>sounds</key><false/>
        </dict>
        </plist>
        """);
    var zip = export + ".zip";
    ZipFile.CreateFromDirectory(export, zip);

    var home = NewTempPath("home");
    var paths = new AppPaths(home, Path.Combine(home, "Models"));
    paths.EnsureCreated();
    File.WriteAllText(paths.DictionaryFile, """{"terms": ["Vinted", "Depop"]}""");
    var settings = new AppSettings(paths.SettingsFile);
    var report = MacImport.Import(zip, paths, settings);
    Expect(report.ToString(), "Imported 3 dictionary words, 1 history entry, 1 recording, 3 settings.", "import report");
    Expect(new FillerCleaner(new PersonalDictionary(paths.DictionaryFile)).Clean("Open clawed code on kubernetes and depop."),
        "Open Claude Code on Kubernetes and Depop.", "imported words merge with the PC's");
    Expect($"{Lower(settings.Sounds)} {Lower(settings.AlwaysShowPill)} {settings.PillScale} {settings.PillOrigin is null}",
        "false false 1 True", "Mac settings applied, Mac-only ones skipped");
    Expect(Lower(File.Exists(Path.Combine(paths.RecordingsDirectory, "MAC-1.wav"))), "true", "recordings copied");
    Expect(MacImport.Import(zip, paths, settings).ToString(), "Imported 3 settings.", "re-import adds nothing twice");
    Directory.Delete(export, true);
    Directory.Delete(home, true);
    File.Delete(zip);
}

// WAV round trip

{
    var path = NewTempPath("wav") + ".wav";
    using (var f = File.Create(path)) Wav.Write(f, new[] { 0f, 0.5f, -0.5f, 1f });
    Expect(string.Join(",", Wav.Read(path).Select(s => MathF.Round(s, 2))), "0,0.5,-0.5,1", "WAV round trip");
    File.Delete(path);
}

Console.WriteLine($"{passes} passed, {failures} failed");
return failures == 0 ? 0 : 1;
