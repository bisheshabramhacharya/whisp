#!/usr/bin/env python3
"""The casual set: fast, casual dictation with a reference transcript.

BIS-20, second half. The scoreboard's casual slot has been a stand-in made with
macOS `say`, which is slow, tidy, studio speech, and his dictation is fast and
messy, so that row has been measuring the wrong thing. This replaces it with his
own speech and the reference text built by scripts/speed/reference.py.

It builds a directory of symlinks, never copies:

  <out>/<id>.wav   symlink to the recording, read where it lies
  <out>/<id>.txt   the reference text

Point the scoreboard at it: WHISP_CASUAL_SET=<out> scripts/speed/scoreboard.sh

"Fast" is words per second in the reference text divided by the recording's length,
and the set keeps the fastest takes, which is the shape of speech that breaks the
engine: no pauses to lean on. Nothing private enters the repo, and the audio is
never copied or moved.

  scripts/speed/casual-set.py                    # build with the defaults
  scripts/speed/casual-set.py --per-bucket 100
  scripts/speed/casual-set.py --stats            # what the set looks like
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference

HOME = os.path.expanduser("~")
REFERENCE = os.environ.get("WHISP_REFERENCE", os.path.join(HOME, ".whisp-reference"))
DEFAULT_OUT = os.path.join(REFERENCE, "casual")


def notify(message):
    print(f"casual: {message}", file=sys.stderr)


def records():
    """The usable ones, the same rule reference.py applies to its set: a real
    reference text, a length, and no flag against the recording."""
    return [record for record in reference.load_records()
            if not record.get("wild")
            and (record.get("whisper") or "").strip()
            and record.get("words") and record.get("seconds")]


def words_per_second(record):
    return record["words"] / max(record["seconds"], 0.1)


def pick(per_bucket):
    """Usable recordings only, fastest first inside each bucket, so the set is
    weighted the way he actually talks and not by how long it happens to be."""
    usable = records()
    if not usable:
        notify("no usable recordings in the cache; run scripts/speed/reference.py first")
        return []
    chosen = []
    for bucket in ("short", "average", "long"):
        pool = sorted((r for r in usable if r.get("bucket") == bucket),
                      key=words_per_second, reverse=True)
        chosen += pool[:per_bucket]
    return chosen


def build(out, per_bucket):
    chosen = pick(per_bucket)
    if not chosen:
        return 1
    os.makedirs(out, exist_ok=True)
    for existing in os.listdir(out):
        os.remove(os.path.join(out, existing))
    recordings = os.environ.get("WHISP_DATA", os.path.join(HOME, "whisp-data"))
    total_seconds = 0.0
    for record in chosen:
        name = record["file"]
        source = os.path.join(recordings, "recordings", name)
        if not os.path.exists(source):
            continue
        os.symlink(source, os.path.join(out, name))
        stem = os.path.splitext(name)[0]
        with open(os.path.join(out, stem + ".txt"), "w") as f:
            f.write(record["whisper"].strip() + "\n")
        total_seconds += record["seconds"]
    notify(f"{len(chosen)} recordings, {total_seconds / 60:.1f} min of audio in {out}")
    notify(f"mean speed {sum(words_per_second(r) for r in chosen) / len(chosen):.2f} words per second")
    notify("point the scoreboard at it: WHISP_CASUAL_SET=" + out)
    return 0


def stats(out):
    files = [f for f in os.listdir(out) if f.endswith(".wav")] if os.path.isdir(out) else []
    if not files:
        notify(f"no set in {out}")
        return 1
    total = 0
    speeds = []
    for name in files:
        path = os.path.join(out, name)
        import wave
        try:
            with wave.open(path) as w:
                seconds = w.getnframes() / float(w.getframerate())
        except Exception:
            continue
        text_path = os.path.join(out, os.path.splitext(name)[0] + ".txt")
        if not os.path.exists(text_path):
            continue
        with open(text_path) as f:
            words = len(f.read().split())
        total += seconds
        speeds.append(words / max(seconds, 0.1))
    if not speeds:
        notify("no readable pairs")
        return 1
    speeds.sort()
    notify(f"{len(speeds)} recordings, {total / 60:.1f} min of audio")
    notify(f"words per second: median {speeds[len(speeds) // 2]:.2f}, "
           f"fastest {speeds[-1]:.2f}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--per-bucket", type=int, default=80,
                        help="how many recordings to keep from each length bucket (default 80)")
    parser.add_argument("--stats", action="store_true")
    args = parser.parse_args()
    if args.stats:
        return stats(args.out)
    return build(args.out, args.per_bucket)


if __name__ == "__main__":
    sys.exit(main())
