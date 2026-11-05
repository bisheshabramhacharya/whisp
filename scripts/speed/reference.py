#!/usr/bin/env python3
"""Reference text for the owner's recordings, from two independent models.

BIS-20. Every accuracy gate today compares a build against our own previous
output, which catches regressions and cannot catch a word that was always wrong.
This builds the other side of that comparison: for each recording, two big slow
models that disagree with each other in different ways, and where they agree we
treat that text as correct.

Engines, both on this Mac, nothing in the cloud:
  A  whisper large-v3-turbo q5_0, through whisper.cpp with Metal, 574 MB
  B  Apple's on-device transcriber, macOS 26, no download, a different vendor
     and a different architecture, which is what makes agreement mean anything

Two flags per recording, because the gap between them is the interesting part:
  strict  the word sequences match exactly, case included
  loose   they match once case is ignored, so a "GitHub" against "Github"
          spelling difference lands here rather than in a misheard word

Disagreement is recorded, never guessed: both texts are kept and the recording
is left out of the agreed set.

Audio is read in place and never copied. The cache lives outside his data folder
and outside the repo, and nothing here ships with the app:

  ~/.whisp-reference/models   reference weights (A only; B is in macOS)
  ~/.whisp-reference/text     one small JSON per recording, both texts, both flags
  ~/.whisp-reference/set      the agreed set: a symlink to his audio plus a .txt
                              per recording, the shape WHISP_REFERENCE feeds to
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
MODEL = os.path.join(REFERENCE, "models", "ggml-large-v3-turbo-q5_0.bin")
WHISPER_CPP = os.environ.get("WHISPER_CPP", os.path.join(HOME, ".capy/work/whisper.cpp/build/bin"))
APPLE_BINARY = os.path.join(REFERENCE, "bin", "apple-stt")
APPLE_SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "apple-stt.swift")
LONG_SECONDS = 300          # the scoreboard's long bucket
AVERAGE_SECONDS = 10
PORT = 8231


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


def compare(whisper_text, apple_text):
    a, b = words(whisper_text), words(apple_text)
    return {
        "strict": a == b,
        "loose": [w.lower() for w in a] == [w.lower() for w in b],
        "words": len(a),
    }


def record_path(name):
    return os.path.join(REFERENCE, "text", os.path.splitext(name)[0] + ".json")


def write_agreed_set(records):
    """Symlinks to his audio plus the agreed text, the shape the scoreboard reads."""
    directory = os.path.join(REFERENCE, "set")
    os.makedirs(directory, exist_ok=True)
    for existing in os.listdir(directory):
        os.remove(os.path.join(directory, existing))
    agreed = 0
    for record in records:
        if not record.get("strict"):
            continue
        name = record["file"]
        link = os.path.join(directory, name)
        if not os.path.exists(link):
            os.symlink(os.path.join(RECORDINGS, name), link)
        with open(os.path.join(directory, os.path.splitext(name)[0] + ".txt"), "w") as f:
            f.write(record["whisper"].strip() + "\n")
        agreed += 1
    notify(f"agreed set: {agreed} recordings in {directory}")
    return agreed


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
    return [r for r in records if r.get("file")]


def stats(records):
    done = len(records)
    strict = sum(1 for r in records if r.get("strict"))
    loose = sum(1 for r in records if r.get("loose"))
    no_agreement = sum(1 for r in records if not r.get("loose"))
    hours = sum(r.get("seconds", 0) for r in records) / 3600.0
    notify(f"cache: {done} recordings, {hours:.1f} h")
    if not done:
        return
    notify(f"strict agreement {100.0 * strict / done:.1f}%  ({strict})")
    notify(f"loose agreement  {100.0 * loose / done:.1f}%  ({loose})")
    notify(f"case and spelling only: {100.0 * (loose - strict) / done:.1f}% of all, "
           f"{100.0 * (loose - strict) / max(loose, 1):.1f}% of the agreed ones")
    notify(f"no agreement at all: {no_agreement} recordings, "
           f"{100.0 * no_agreement / done:.1f}%")
    by_bucket = {}
    for record in records:
        entry = by_bucket.setdefault(record.get("bucket", "?"), [0, 0])
        entry[0] += 1
        entry[1] += 1 if record.get("strict") else 0
    for name, (total, ok) in sorted(by_bucket.items()):
        notify(f"  {name}: {100.0 * ok / total:.1f}% strict of {total}")


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
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--budget-hours", type=float, default=10.0, help="audio hours in the slice (default 10)")
    parser.add_argument("--force", action="store_true", help="redo recordings already in the cache")
    parser.add_argument("--stats", action="store_true", help="report the cache and exit")
    parser.add_argument("--skip-apple", action="store_true", help="only whisper, for a throughput probe")
    parser.add_argument("--limit", type=int, default=0, help="stop after this many recordings")
    parser.add_argument("--probe", type=int, default=0,
                        help="time this many recordings across the buckets and exit, cache untouched")
    args = parser.parse_args()

    os.makedirs(os.path.join(REFERENCE, "text"), exist_ok=True)
    records = load_records()
    if args.probe:
        return probe(args.probe)
    if args.stats:
        stats(records)
        return 0

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
        apple_texts = apple_batch(batch)
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
        write_agreed_set(records)
    notify(f"took {(time.time() - started) / 60:.1f} min")
    return 0


if __name__ == "__main__":
    sys.exit(main())
