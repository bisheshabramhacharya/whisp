# Formatting

What Whisp does to a take after cleanup, before it pastes. Three steps, always in
this order:

1. **clean** — removes fillers and stutters (`FillerCleaner`).
2. **format** — writes the same words the way you would write them (`TextFormatter`).
3. **paste**.

The format step is fixed rules only: no model, no network, nothing that can add a
second of wait. It is timed on its own and printed with the other stages in the log:

```
dictation done: audio=6.20s ... clean=1ms format=895us paste=9ms release→paste=51ms
```

Budget: under 5 ms for five minutes of dictation, checked by the test suite on an
896 word take (five minutes and 58 seconds of speech). On the base M1 the whole
text step measured 1.403 ms before this step existed and 2.300 ms with it, so the
format step itself is 0.895 ms. The same gate measured 1.383 ms on a busier run of
the machine, so read it as about one millisecond.

## What it does

**Numbers.** A spelled number of twenty or more is written in digits, with money and
percentages folded in, and ordinals keep their suffix.

| said | pasted |
|---|---|
| twenty five | 25 |
| two hundred fifty | 250 |
| one hundred and five | 105 |
| three hundred thousand | 300000 |
| twenty five dollars | $25 |
| two hundred fifty dollars | $250 |
| twenty five percent | 25% |
| twenty fifth | 25th |

**Clock times**, after a time word and only with a minute spoken: `at five thirty` →
`at 5:30`, `at five oh five` → `at 5:05`.

**Spoken file paths.** `src slash main dot swift` → `src/main.swift`,
`src slash components` → `src/components`, `www dot example dot com` →
`www.example.com`. A dot-file at the start of a sentence: `Dot env is the config
file` → `.env is the config file`. "forward slash" works, "backslash" is written as
a slash.

**Sentences.** A closing stop if the take has none and is three words or longer, a
capital letter at each sentence start, a question mark on sentences that open like a
question (`Is it working` → `Is it working?`, `what is done is done` stays a
statement, `do not do that` stays a statement), a question mark on `, right` and
`, okay` tags, and a comma after a short list of openers (`Yes I think so` →
`Yes, I think so`).

## Where it stops, on purpose

Wrong text is worse than plain text, so each rule gives up rather than guess.

- **A year or a price said the way people say it stays words.** "we met in
  twenty nineteen", "twenty twelve", "that costs two fifty", "three ninety nine",
  "in twenty twenty four", "flight twenty five twenty": a number word touching
  another one means the speaker said a year or a price read aloud, and half a
  reading would write a wrong number, so none of it is converted.
- **Numbers under twenty stay words.** "five minutes" reads better than "5 minutes",
  and "one thing" must never become "1 thing". A lone "hundred" stays a word too
  ("I've told you a hundred times"), as does "five dollars".
- **A bare hour stays a word.** "meet me at five" is left alone, because the same
  shape turns "at one point" into "at 1 point".
- **One spoken "dot" on its own does not join words.** "package dot json" is left as
  words: a fixed rule cannot tell it apart from "Edit dot env". Two separators or a
  slash always join, and "dot env" at a start of a sentence becomes ".env".
- **A run never starts right after a separator word**, so "we slash prices slash
  costs" stays three words and two verbs instead of becoming "prices/costs".
- **"star" is not rewritten as "\*".**
- **A separator word doing grammar is left alone**: "we slash prices today" stays
  words, and so does "a dot of paint".
- **No reordering, no rephrasing, no word invented.** Formatting may only shorten a
  written form (a number, a path, a money word), never drop a word that carries
  meaning. The tests assert that no word disappears from every case, and that
  formatting twice gives the same text.
