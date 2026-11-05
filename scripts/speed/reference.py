#!/usr/bin/env python3
"""Reference text for the owner's recordings, from a big slow model.

BIS-20. Every accuracy gate today compares a build against our own previous
output, which catches regressions and cannot catch a word that was always wrong.
This builds the other side of that comparison: for each recording, text from a
model that was not tuned for this app and does not ship with it.

One reference, one flag. Asking two models to agree turned out to be the wrong
test: on 650 of his own recordings they agreed exactly on 0.8% of them, and the
median word-level gap between them was 13.6%. Real dictation, with names and
product spellings, is not audio two engines transcribe identically. So:

  reference  the big model's text, for every recording, taken at face value
  flag       a second engine transcribes the same audio only to catch the cases
             where the reference itself is not to be trusted: silence, a
             collapsed repeat loop, or two texts that are not the same speech.
             A flagged recording is dropped from the set rather than guessed at.

That means the reference has its own error rate, and the doc says so. WER
against it is a stable number to track across builds, not a claim that the
text is right word for word.

Engines, both on this Mac, nothing in the cloud:
  reference  whisper large-v3-turbo q5_0 (574 MB) through whisper.cpp with
             Metal, or large-v3 full (1.1 GB) with --model large-v3
  flag       Apple's on-device transcriber, macOS 26, no download, a different
             vendor and a different architecture

Audio is read in place and never copied. The cache lives outside his data folder
and outside the repo, and nothing here ships with the app:

  ~/.whisp-reference/models   reference weights (the flag engine is in macOS)
  ~/.whisp-reference/text     one small JSON per recording, both texts, the
                              disagreement, and why a recording was flagged
  ~/.whisp-reference/set      the reference set: a symlink to his audio plus the
                              reference .txt, the shape WHISP_REFERENCE feeds to
                              the scoreboard

The slice is sized by audio, not by file count: every long take, then a stable
random fill of the average and short buckets up to a budget. Rerunning resumes
where it stopped; --force redoes everything.

  scripts/speed/reference.py --budget-hours 10
  scripts/speed/reference.py --stats          # report the cache, build nothing
"""
import argparse
import json
import os
import random
import subprocess
import sys
import time
import urllib.request
import wave

HOME = os.path.expanduser("~")
REFERENCE = os.environ.get("WHISP_REFERENCE", os.path.join(HOME, ".whisp-reference"))
DATA = os.environ.get("WHISP_DATA", os.path.join(HOME, "whisp-data"))
RECORDINGS = os.path.join(DATA, "recordings")
MODELS = {
    "turbo": os.path.join(REFERENCE, "models", "ggml-large-v3-turbo-q5_0.bin"),
    "large-v3": os.path.join(REFERENCE, "models", "ggml-large-v3-q5_0.bin"),
}
MODEL_NAME = os.environ.get("WHISP_REFERENCE_MODEL", "turbo")
MODEL = MODELS.get(MODEL_NAME, MODELS["turbo"])
WHISPER_CPP = os.environ.get("WHISPER_CPP", os.path.join(HOME, ".capy/work/whisper.cpp/build/bin"))
APPLE_BINARY = os.path.join(REFERENCE, "bin", "apple-stt")
APPLE_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "apple-stt.swift")
LONG_SECONDS = 300          # the scoreboard's long bucket
AVERAGE_SECONDS = 10
PORT = 8231
# Two texts this far apart are not describing the same speech, so neither is a
# reference. The measured median gap is 13.6% and the p90 is 30%, so this only
# catches the tail, which is what it is for.
WILD_PERCENT = 35.0


def notify(message):
    print(f"reference: {message}", file=sys.stderr)


# ---------------------------------------------------------------- the corpus

def duration(path):
    try:
        with wave.open(path) as w:
            return w.getnframes() / float(w.getframerate())
    except Exception:
        return None


def bucket(seconds):
    if seconds >= LONG_SECONDS:
        return "long"
    return "average" if seconds >= AVERAGE_SECONDS else "short"


def stable_order(names):
    """Same order the scoreboard uses: sorted by sha256 of the name, so the same
    slice is picked every time and two people get the same set."""
    import hashlib
    return sorted(names, key=lambda n: hashlib.sha256(os.path.basename(n).encode()).hexdigest())


def choose_slice(budget_seconds):
    names = [n for n in os.listdir(RECORDINGS) if n.endswith(".wav")]
    if not names:
        notify(f"no recordings in {RECORDINGS}")
        return []
    order = stable_order(names)
    entries = []
    for name in order:
        seconds = duration(os.path.join(RECORDINGS, name))
        if seconds:
            entries.append((name, seconds, bucket(seconds)))
    long_entries = [(n, s, b) for n, s, b in entries if b == "long"]
    picked = list(long_entries)
    spent = sum(s for _, s, _ in picked)
    # Long takes are the ones that used to be wrong, so they all go in. The rest
    # is filled in stable hash order, average before short, until the budget.
    for wanted in ("average", "short"):
        for name, seconds, bucket_name in entries:
            if spent >= budget_seconds:
                break
            if bucket_name != wanted:
                continue
            picked.append((name, seconds, bucket_name))
            spent += seconds
    return [(name, seconds) for name, seconds, _ in picked]


# ---------------------------------------------------------------- whisper.cpp

class Whisper:
    """whisper.cpp over HTTP so the 574 MB model loads once for the whole run.
    Falls back to one process per file if the server will not start."""

    def __init__(self):
        self.process = None
        self.cli = os.path.join(WHISPER_CPP, "whisper-cli")

    def start(self):
        server = os.path.join(WHISPER_CPP, "whisper-server")
        if not (os.path.exists(server) and os.path.exists(MODEL)):
            return
        self.process = subprocess.Popen(
            [server, "-m", MODEL, "--host", "127.0.0.1", "--port", str(PORT),
             "-l", "en", "-nt", "--no-prints"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(120):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{PORT}/", timeout=1)
                notify("whisper server ready")
                return
            except Exception:
                time.sleep(0.5)
        notify("whisper server did not answer, one process per file instead")
        self.stop()

    def stop(self):
        if self.process:
            self.process.terminate()
            self.process.wait(timeout=30)
            self.process = None

    def transcribe(self, path):
        if self.process:
            return self._over_http(path)
        return self._one_process(path)

    def _over_http(self, path):
        boundary = "----whispReference"
        with open(path, "rb") as f:
            audio = f.read()
        body = b"".join([
            f"--{boundary}\r\n".encode(),
            b'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n',
            b"Content-Type: audio/wav\r\n\r\n", audio, b"\r\n",
            f"--{boundary}\r\n".encode(),
            b'Content-Disposition: form-data; name="response_format"\r\n\r\njson\r\n',
            f"--{boundary}\r\n".encode(),
            b'Content-Disposition: form-data; name="temperature"\r\n\r\n0\r\n',
            f"--{boundary}--\r\n".encode(),
        ])
        request = urllib.request.Request(
            f"http://127.0.0.1:{PORT}/inference", data=body,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
        with urllib.request.urlopen(request, timeout=1800) as response:
            payload = json.loads(response.read().decode("utf-8", "replace"))
        return (payload.get("text") or "").strip()

    def _one_process(self, path):
        if not os.path.exists(self.cli):
            raise RuntimeError(f"no whisper binary in {WHISPER_CPP}")
        out = subprocess.run(
            [self.cli, "-m", MODEL, "-f", path, "-l", "en", "-nt", "--no-prints"],
            capture_output=True, text=True, timeout=3600)
        return " ".join(out.stdout.split())


# ---------------------------------------------------------------- Apple

def build_apple():
    os.makedirs(os.path.dirname(APPLE_BINARY), exist_ok=True)
    if os.path.exists(APPLE_BINARY):
        return APPLE_BINARY
    notify("building the Apple transcriber once")
    out = subprocess.run(["swiftc", "-O", APPLE_SOURCE, "-o", APPLE_BINARY],
                         capture_output=True, text=True)
    if out.returncode != 0:
        notify(f"Apple transcriber did not build: {out.stderr.strip().splitlines()[-1:]}")
        return None
    return APPLE_BINARY


def apple_batch(paths):
    """Apple's transcriber over a batch, one process, one JSON line per file."""
    if not paths:
        return {}
    out = subprocess.run([APPLE_BINARY] + paths, capture_output=True, text=True, timeout=7200)
    texts = {}
    for line in out.stdout.splitlines():
        try:
            row = json.loads(line)
        except Exception:
            continue
        name = row.get("file")
        if name and row.get("text") is not None:
            texts[name] = row["text"].strip()
        elif name:
            notify(f"apple: {name}: {row.get('error')}")
    return texts


# ---------------------------------------------------------------- agreement

def words(text):
    """The scoreboard's own split, so agreement and WER mean the same thing."""
    import re
    return re.findall(r"[^\W_]+", text or "", re.UNICODE)


def edit_distance(ref, hyp):
    if not ref:
        return len(hyp)
    prev = list(range(len(hyp) + 1))
    for i, rw in enumerate(ref, 1):
        cur = [i]
        for j, hw in enumerate(hyp, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (0 if rw == hw else 1)))
        prev = cur
    return prev[-1]


def wild_reason(reference_words, flag_words, gap):
    """Why this recording is not usable as a reference, or "" when it is.

    A reference that is wrong by a word in eight is still worth measuring
    against. One where the two engines describe different speech is not: an
    empty second text, a decoder that looped a phrase until the word count
    doubled, or a gap so wide that neither text is the same sentence.
    """
    if not reference_words:
        return "no reference text"
    if not flag_words:
        return "no second text"
    big, small = max(len(reference_words), len(flag_words)), min(len(reference_words), len(flag_words))
    if big >= 2 * small:
        return "word count differs 2x"
    if gap is not None and gap >= WILD_PERCENT:
        return "too far apart"
    return ""


def compare(whisper_text, apple_text):
    """The reference's own numbers: how far the flag engine is from it, and
    whether that far is too far to use."""
    a, b = words(whisper_text), words(apple_text)
    gap = None
    if a and b:
        gap = round(100.0 * edit_distance(a, b) / len(a), 1)
    return {
        "strict": a == b,
        "loose": [w.lower() for w in a] == [w.lower() for w in b],
        "words": len(a),
        "gap": gap,
        "wild": wild_reason(a, b, gap),
    }


def record_path(name):
    return os.path.join(REFERENCE, "text", os.path.splitext(name)[0] + ".json")


def write_reference_set(records):
    """Symlinks to his audio plus the reference text, the shape the scoreboard reads."""
    directory = os.path.join(REFERENCE, "set")
    os.makedirs(directory, exist_ok=True)
    for existing in os.listdir(directory):
        os.remove(os.path.join(directory, existing))
    kept, dropped = 0, 0
    for record in records:
        if record.get("wild") or not (record.get("whisper") or "").strip():
            dropped += 1
            continue
        name = record["file"]
        link = os.path.join(directory, name)
        if not os.path.exists(link):
            os.symlink(os.path.join(RECORDINGS, name), link)
        with open(os.path.join(directory, os.path.splitext(name)[0] + ".txt"), "w") as f:
            f.write(record["whisper"].strip() + "\n")
        kept += 1
    notify(f"reference set: {kept} recordings in {directory}, {dropped} flagged out")
    return kept


def load_records():
    directory = os.path.join(REFERENCE, "text")
    if not os.path.isdir(directory):
        return []
    records = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(directory, name)) as f:
                records.append(json.load(f))
        except Exception:
            continue
    records = [r for r in records if r.get("file")]
    # Recompute from the stored texts, so records written before the flag
    # existed read the same as new ones.
    for record in records:
        record.update(compare(record.get("whisper", ""), record.get("apple", "")))
    return records


def median(values):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None, None
    return values[len(values) // 2], values[3 * len(values) // 4]


def stats(records):
    """What the cache holds, and what the reference is worth. Printed rather
    than stored, so the same numbers can be quoted in the doc and the PR."""
    import statistics
    done = len(records)
    hours = sum(r.get("seconds", 0) for r in records) / 3600.0
    notify(f"cache: {done} recordings, {hours:.1f} h, reference model {MODEL_NAME}")
    if not done:
        return
    flagged = [r for r in records if r.get("wild")]
    kept = [r for r in records if not r.get("wild") and (r.get("whisper") or "").strip()]
    notify(f"reference set: {len(kept)} usable, {len(flagged)} flagged out")
    reasons = {}
    for record in flagged:
        reasons[record["wild"]] = reasons.get(record["wild"], 0) + 1
    for reason, count in sorted(reasons.items(), key=lambda kv: -kv[1]):
        notify(f"  flagged: {reason}: {count}")
    gaps = [r.get("gap") for r in kept]
    strict = sum(1 for r in kept if r.get("strict"))
    notify(f"the reference's own error, measured against a second engine:")
    if gaps:
        notify(f"  median {statistics.median(gaps):.1f}% of words, "
               f"p25 {statistics.quantiles(gaps, n=4)[0]:.1f}%, "
               f"p75 {statistics.quantiles(gaps, n=4)[2]:.1f}%")
    notify(f"  exact match on {100.0 * strict / max(len(kept), 1):.1f}% of the kept recordings")
    by_bucket = {}
    for record in kept:
        entry = by_bucket.setdefault(record.get("bucket", "?"), [0, []])
        entry[0] += 1
        if record.get("gap") is not None:
            entry[1].append(record["gap"])
    for name, (total, bucket_gaps) in sorted(by_bucket.items()):
        middle = statistics.median(bucket_gaps) if bucket_gaps else None
        notify(f"  {name}: {total} kept, "
               + (f"median gap {middle:.1f}%" if middle is not None else "no gap measured"))


def probe(count):
    """Throughput on a spread of short, average and a couple of longer takes, so
    the estimate for a full block is measured and not guessed."""
    entries = []
    for name in stable_order([n for n in os.listdir(RECORDINGS) if n.endswith(".wav")]):
        seconds = duration(os.path.join(RECORDINGS, name))
        if seconds:
            entries.append((name, seconds))
    wanted = {"short": max(1, count // 4), "average": max(1, count // 2), "long": max(1, count - count // 4 - count // 2)}
    picked = []
    for kind, many in wanted.items():
        pool = [e for e in entries if bucket(e[1]) == kind and e[1] <= (180 if kind != "short" else 10)]
        picked += pool[:many]
    audio = sum(s for _, s in picked)
    notify(f"probe: {len(picked)} recordings, {audio:.0f} s of audio")

    whisper = Whisper()
    whisper.start()
    started = time.time()
    try:
        for name, _ in picked:
            whisper.transcribe(os.path.join(RECORDINGS, name))
    finally:
        whisper.stop()
    whisper_seconds = time.time() - started
    notify(f"whisper: {whisper_seconds:.1f} s for {audio:.0f} s of audio = "
           f"{audio / max(whisper_seconds, 0.1):.1f}x realtime")

    apple = build_apple()
    if apple:
        started = time.time()
        texts = apple_batch([os.path.join(RECORDINGS, name) for name, _ in picked])
        apple_seconds = time.time() - started
        notify(f"apple: {apple_seconds:.1f} s for {audio:.0f} s of audio = "
               f"{audio / max(apple_seconds, 0.1):.1f}x realtime, {len(texts)} of {len(picked)} transcribed")

    slice_entries = choose_slice(10 * 3600)
    hours = sum(s for _, s in slice_entries) / 3600.0
    total = (whisper_seconds + (apple_seconds if apple else 0)) / max(audio, 1) * hours * 3600
    notify(f"projected for the 10 h slice: {total / 60:.0f} min of wall clock")
    return 0


def main():
    global MODEL_NAME, MODEL
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--budget-hours", type=float, default=10.0, help="audio hours in the slice (default 10)")
    parser.add_argument("--force", action="store_true", help="redo recordings already in the cache")
    parser.add_argument("--stats", action="store_true", help="report the cache and exit")
    parser.add_argument("--skip-apple", action="store_true", help="only whisper, for a throughput probe")
    parser.add_argument("--limit", type=int, default=0, help="stop after this many recordings")
    parser.add_argument("--probe", type=int, default=0,
                        help="time this many recordings across the buckets and exit, cache untouched")
    parser.add_argument("--model", choices=sorted(MODELS), default=MODEL_NAME,
                        help=f"the reference model (default {MODEL_NAME}); switching it means redoing the cache")
    parser.add_argument("--set", action="store_true",
                        help="rebuild the reference set from the cache and exit, no model loaded")
    args = parser.parse_args()

    MODEL_NAME = args.model
    MODEL = MODELS[args.model]

    os.makedirs(os.path.join(REFERENCE, "text"), exist_ok=True)
    records = load_records()
    if args.probe:
        return probe(args.probe)
    if args.stats:
        stats(records)
        return 0
    if args.set:
        stats(records)
        return 0 if write_reference_set(records) else 1

    slice_entries = choose_slice(args.budget_hours * 3600)
    if not slice_entries:
        return 1
    known = {r["file"] for r in records}
    todo = [(n, s) for n, s in slice_entries if args.force or n not in known]
    audio_hours = sum(s for _, s in slice_entries) / 3600.0
    notify(f"slice: {len(slice_entries)} recordings, {audio_hours:.1f} h of audio; "
           f"{len(todo)} to transcribe this pass")
    if args.limit:
        todo = todo[:args.limit]

    apple = None if args.skip_apple else build_apple()
    whisper = Whisper()
    started = time.time()

    if apple:
        # Apple first and in batches, because it is the cheaper of the two and it
        # tells us right away whether the assets are there at all.
        batch = [os.path.join(RECORDINGS, name) for name, _ in todo]
        notify(f"apple: {len(batch)} files")
        # In chunks, so a failure late in the list keeps the work already done.
        apple_texts = {}
        for start in range(0, len(batch), 100):
            apple_texts.update(apple_batch(batch[start:start + 100]))
            notify(f"apple: {min(start + 100, len(batch))}/{len(batch)}")
        if not apple_texts:
            notify("apple produced nothing; falling back is a decision for the Captain, "
                   "not a silent substitution")
            apple = None
        else:
            for name, seconds in todo:
                record = {"file": name, "seconds": seconds, "bucket": bucket(seconds),
                          "apple": apple_texts.get(os.path.splitext(name)[0], "")}
                with open(record_path(name) + ".apple", "w") as f:
                    json.dump(record, f)
            notify(f"apple done in {time.time() - started:.0f} s")

    whisper.start()
    try:
        done = 0
        for name, seconds in todo:
            record = {"file": name, "seconds": seconds, "bucket": bucket(seconds), "whisper": ""}
            try:
                record["whisper"] = whisper.transcribe(os.path.join(RECORDINGS, name))
            except Exception as error:
                notify(f"whisper failed on {name}: {error}")
                continue
            half = record_path(name) + ".apple"
            if os.path.exists(half):
                with open(half) as f:
                    record["apple"] = json.load(f).get("apple", "")
            else:
                record["apple"] = ""
            if record["apple"]:
                record.update(compare(record["whisper"], record["apple"]))
            with open(record_path(name), "w") as f:
                json.dump(record, f, sort_keys=True)
            if os.path.exists(half):
                os.remove(half)
            done += 1
            if done % 25 == 0:
                rate = (time.time() - started) / done
                notify(f"{done}/{len(todo)} files, {rate:.1f} s each, "
                       f"{rate * (len(todo) - done) / 60:.0f} min left")
    finally:
        whisper.stop()

    records = load_records()
    stats(records)
    if args.budget_hours and not args.limit:
        write_reference_set(records)
    notify(f"took {(time.time() - started) / 60:.1f} min")
    return 0


if __name__ == "__main__":
    sys.exit(main())
