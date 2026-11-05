#!/usr/bin/env python3
"""Data layer for scripts/speed/scoreboard.sh.

The shell script takes the benchmark lock, builds whisp-bench, fetches the test
sets, and runs the bench. Everything numeric lives here: picking the sample of
recordings, reading the bench's `{...}` JSON lines, caching per file by build
sha + engine flags, scoring WER, comparing the last word against the recorded
baseline, and printing the table.

Privacy: the owner's recordings are read in place. Nothing in here prints a
recording name or a transcript; the cache keeps sha256 prefixes of words so a
later build can be compared without storing text, and every cache file lives
under $HOME, never in the repo.

Subcommands (all state goes through the state JSON the shell creates):
  init          write the state file from the shell's git/sysctl values
  sample        pick the owner-recording sample per speed bucket
  plan          list the sampled files that are missing from the cache
  merge-live    fold one bucket's bench rows into the cache
  wer-plan      pick a corpus sample and list the files missing from the cache
  wer-merge     fold a corpus bench run into the cache
  report        print the scoreboard
  record        write docs/speed/scoreboard/{baseline-<sha>,latest}.json + latest.md
"""

import hashlib
import json
import math
import os
import re
import sys
import time
from collections import Counter

# name, low seconds (inclusive), high seconds (exclusive), target p50 ms, label
BUCKETS = [
    ("short", 1.0, 10.0, 38, "short    1-10s"),
    ("average", 10.0, 60.0, 40, "average  10-60s"),
    ("long", 300.0, float("inf"), 46, "long     5+ min"),
]
BUCKET_NAMES = [b[0] for b in BUCKETS]
WORST_TARGET_MS = 100
AUDIO_EXT = (".wav", ".flac", ".aiff", ".m4a")
SCHEMA = 1


# ---------------------------------------------------------------- helpers


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, obj):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def words(text):
    """Same split as whisp-bench's normalizedWords: lowercase, alphanumerics."""
    return re.findall(r"[^\W_]+", (text or "").lower(), re.UNICODE)


def word_hash(word):
    return hashlib.sha256(word.encode("utf-8")).hexdigest()[:16]


def text_hashes(text):
    """What a cache row keeps instead of the transcript."""
    ws = words(text)
    return {
        "lastWord": word_hash(ws[-1]) if ws else "",
        "words": sorted(word_hash(w) for w in ws),
    }


def file_key(name):
    return hashlib.sha256(os.path.basename(name).encode("utf-8")).hexdigest()[:16]


def stable_order(items, key):
    """Impartial, stable sample order: sorted by sha256 of the item's identity."""
    return sorted(items, key=lambda it: hashlib.sha256(key(it).encode("utf-8")).hexdigest())


def percentile(sorted_values, p):
    """Nearest rank, matching whisp-bench's percentile so numbers agree."""
    if not sorted_values:
        return None
    i = min(len(sorted_values) - 1, int(len(sorted_values) * p))
    return sorted_values[i]


def edit_distance(ref, hyp):
    if not ref:
        return len(hyp)
    if not hyp:
        return len(ref)
    prev = list(range(len(hyp) + 1))
    for i, rw in enumerate(ref, 1):
        cur = [i]
        for j, hw in enumerate(hyp, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (0 if rw == hw else 1)))
        prev = cur
    return prev[-1]


def load_state(path):
    state = read_json(path)
    if not state:
        die(f"scoreboard: no state at {path} (run the shell script)")
    return state


def save_state(path, state):
    write_json(path, state)


def build_dir(state):
    """Cache directory for this build: sha, plus -dirty when the tree isn't clean."""
    sha = state["build"]["sha"] + ("-dirty" if state["build"]["dirty"] else "")
    return os.path.join(state["cache"], sha)


def flags_tag(state):
    engine = state["engine"]["name"]
    gap = state["engine"]["gap_s"]
    return f"{engine}-gap{gap:g}"


def live_cache_path(state):
    return os.path.join(build_dir(state), f"live-{flags_tag(state)}.json")


def wer_cache_path(state, corpus):
    return os.path.join(build_dir(state), f"wer-{corpus}-{flags_tag(state)}.json")


def load_cache(path):
    return read_json(path, {"schema": SCHEMA, "files": {}}) or {"schema": SCHEMA, "files": {}}


# ---------------------------------------------------------------- init


def cmd_init(args):
    state = {
        "schema": SCHEMA,
        "cache": args["cache"],
        "data": args["data"],
        "root": args["root"],
        "build": {
            "sha": args["sha"],
            "engine": args["engine_sha"],
            "branch": args["branch"],
            "dirty": args["dirty"] == "1",
        },
        "machine": {
            "model": args["model"],
            "chip": args["chip"],
            "memory_gb": int(args["mem_gb"]),
            "os": args["os"],
        },
        "engine": {"name": args["engine"], "gap_s": float(args["gap"])},
        "budgets": {
            "short": float(args["budget_short"]),
            "average": float(args["budget_average"]),
            "long": float(args["budget_long"]),
        },
        "mins": {
            "short": int(args["min_short"]),
            "average": int(args["min_average"]),
            "long": int(args["min_long"]),
        },
        "wer_caps": {
            "librispeech_test_clean": int(args["cap_clean"]),
            "librispeech_test_other": int(args["cap_other"]),
            "dictation": int(args["cap_dictation"]),
            "casual": int(args["cap_casual"]),
        },
        "casual_set": args.get("casual_set") or "",
        # Wall clock from the shell's first line, so run_seconds covers the
        # build, one-time test-set setup and every replay in between.
        "started": float(args["started"]) if args.get("started") else time.time(),
    }
    state["baseline"] = baseline_ref(state)
    write_json(args["state"], state)
    return 0


def baseline_ref(state):
    """Which build the last-word delta is measured against.

    A run that records the baseline is its own baseline. Otherwise the newest
    baseline-<engine sha>.json in the repo decides, and the delta needs that
    build's cached per-file rows with the same engine flags.
    """
    build, tag = state["build"], flags_tag(state)
    if os.environ.get("WHISP_SB_THIS_IS_BASELINE") == "1":
        return {"build_sha": build["sha"], "dirty": build["dirty"],
                "engine_sha": build["engine"], "flags": tag}
    path = os.environ.get("WHISP_SB_BASELINE_FILE") or ""
    recorded = read_json(path) if path else None
    if not recorded:
        return {}
    recorded_build = recorded.get("build") or {}
    return {
        "build_sha": recorded_build.get("sha"),
        "dirty": bool(recorded_build.get("dirty")),
        "engine_sha": recorded_build.get("engine"),
        "flags": (recorded.get("engine") or {}).get("flags"),
    }


# ---------------------------------------------------------------- sample


def cmd_sample(args):
    """Pick recordings per speed bucket, cheapest-first reachable under budget."""
    state = load_state(args["state"])
    recordings = os.path.join(state["data"], "recordings")
    history = os.path.join(state["data"], "history.jsonl")

    durations = {}
    try:
        with open(history) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if isinstance(entry.get("durationSec"), (int, float)) and entry.get("id"):
                    durations[entry["id"]] = float(entry["durationSec"])
    except OSError:
        die(f"scoreboard: cannot read {history} (private dictation history)")

    present = {
        os.path.splitext(n)[0] for n in os.listdir(recordings) if n.lower().endswith(AUDIO_EXT)
    }
    candidates = {k: v for k, v in durations.items() if k in present}

    picked, counts = {}, {}
    for name, lo, hi, _, _ in BUCKETS:
        members = [
            {"id": rid, "sec": sec, "key": file_key(rid + ".wav"),
             "path": os.path.join(recordings, rid + ".wav")}
            for rid, sec in candidates.items() if lo <= sec < hi
        ]
        counts[name] = len(members)
        chosen, spent = [], 0.0
        budget = float(state["budgets"][name])
        floor = int(state["mins"][name])
        for m in stable_order(members, key=lambda it: it["id"]):
            if len(chosen) >= max(floor, 1) and spent + m["sec"] > budget:
                continue
            chosen.append(m)
            spent += m["sec"]
        picked[name] = chosen

    outside = {
        "total_recordings": len(candidates),
        "under_1s": sum(1 for s in candidates.values() if s < 1.0),
        "one_to_five_min": sum(1 for s in candidates.values() if 60.0 <= s < 300.0),
    }
    rule = (
        "sample: "
        + ", ".join(
            f"{n} {len(picked[n])} of {counts[n]:,}" for n, _, _, _, _ in BUCKETS
        )
        + f" (audio budget {state['budgets']['short']:g}/{state['budgets']['average']:g}/"
        f"{state['budgets']['long']:g} s, {state['engine']['gap_s']:g} s between takes); "
        f"{outside['total_recordings']:,} recordings: {outside['under_1s']} under 1 s and "
        f"{outside['one_to_five_min']} at 1-5 min sit outside the buckets"
    )
    sample = {
        "buckets": picked,
        "counts": counts,
        "outside": outside,
        "rule": rule,
        "chosen": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    write_json(args["sample"], sample)
    state["sample_file"] = args["sample"]
    state["sample"] = {n: len(picked[n]) for n in BUCKET_NAMES}
    state["sample_rule"] = rule
    state["outside"] = outside
    save_state(args["state"], state)
    print(rule, file=sys.stderr)
    return 0


# ---------------------------------------------------------------- plan


def cmd_plan(args):
    """Write the per-bucket file lists that still need a live replay."""
    state = load_state(args["state"])
    sample = read_json(args["sample"]) or die("scoreboard: no sample")
    cache = load_cache(live_cache_path(state))
    known = cache.get("files", {})
    out_dir = args["out_dir"]
    os.makedirs(out_dir, exist_ok=True)
    # One list for one bench process: every model load costs seconds to minutes
    # on this M1 (Core ML recompiles), so the whole sample shares a process.
    with open(os.path.join(out_dir, "need-live.txt"), "w") as f:
        for name in BUCKET_NAMES:
            entries = sample["buckets"].get(name, [])
            todo = [e for e in entries if args.get("force") or e["key"] not in known]
            for e in todo:
                f.write(e["path"] + "\n")
            print(f"{name}: {len(entries)} sampled, {len(todo)} to replay, "
                  f"{len(entries) - len(todo)} cached", file=sys.stderr)
    return 0


# ---------------------------------------------------------------- merge


def cmd_merge_live(args):
    state = load_state(args["state"])
    sample = read_json(args["sample"]) or die("scoreboard: no sample")
    entries = {}
    for name in BUCKET_NAMES:
        for e in sample["buckets"].get(name, []):
            entries[e["id"]] = {**e, "bucket": name}
    cache = load_cache(live_cache_path(state))
    files = cache.setdefault("files", {})
    merged = 0
    for row in read_rows(args["rows"]):
        rid = row.get("file")
        text = row.get("text")
        sec = row.get("sec")
        latency = row.get("latencyMs")
        if rid is None or sec is None or latency is None:
            continue
        entry = entries.get(rid)
        if entry is None:
            continue
        record = {
            "bucket": entry["bucket"],
            "sec": round(float(sec), 3),
            "latencyMs": int(latency),
        }
        record.update(text_hashes(text))
        files[entry["key"]] = record
        merged += 1
    cache["build"] = state["build"]
    cache["engine"] = state["engine"]
    write_json(live_cache_path(state), cache)
    print(f"live: merged {merged} rows ({len(files)} cached total for this build)",
          file=sys.stderr)
    return 0


def read_rows(path):
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    yield json.loads(line)
                except ValueError:
                    continue
    except OSError:
        return


# ---------------------------------------------------------------- WER


def corpus_files(directory):
    out = []
    for dirpath, _, names in os.walk(directory):
        for n in names:
            if not n.lower().endswith(AUDIO_EXT):
                continue
            path = os.path.join(dirpath, n)
            if os.path.exists(path + ".txt") or os.path.exists(
                os.path.splitext(path)[0] + ".txt"
            ):
                out.append(path)
    return sorted(out)


def corpus_sample(paths, cap):
    """Every ceil(n/cap)-th file of the sorted list: stable, spread across speakers."""
    if len(paths) <= cap:
        return list(paths), 1
    step = math.ceil(len(paths) / cap)
    return paths[::step], step


def corpus_dirs(state):
    root = state["root"]
    dirs = {
        "librispeech_test_clean": os.path.join(root, "testdata/librispeech/LibriSpeech/test-clean"),
        "librispeech_test_other": os.path.join(root, "testdata/librispeech/LibriSpeech/test-other"),
        "dictation": os.path.join(root, "testdata/dictation"),
    }
    if state.get("casual_set"):
        dirs["casual"] = state["casual_set"]
    return dirs


def cmd_wer_plan(args):
    """One file list and a map for a single decode process across every corpus."""
    state = load_state(args["state"])
    listing, mapping, rules = [], {}, {}
    for corpus, directory in corpus_dirs(state).items():
        if not os.path.isdir(directory):
            print(f"{corpus}: no {directory}, its row will read n/a", file=sys.stderr)
            continue
        everything = corpus_files(directory)
        paths, step = corpus_sample(everything, int(state["wer_caps"][corpus]))
        if not paths:
            print(f"{corpus}: no audio with a reference transcript", file=sys.stderr)
            continue
        cache = load_cache(wer_cache_path(state, corpus))
        known = cache.get("files", {})
        todo = [p for p in paths if args.get("force") or file_key(p) not in known]
        listing += todo
        for p in todo:
            mapping[file_key(p)] = corpus
        rules[corpus] = (
            f"{corpus}: {len(paths)} of {len(everything)} files"
            + (f", every {step}th" if step > 1 else "")
        )
        print(f"{rules[corpus]} ({len(todo)} to decode)", file=sys.stderr)
    with open(args["out"], "w") as f:
        for path in listing:
            f.write(path + "\n")
    write_json(args["map"], mapping)
    state["wer_rule"] = rules
    save_state(args["state"], state)
    return 0


def cmd_wer_merge(args):
    """Split one decode run's rows back into their corpus caches."""
    state = load_state(args["state"])
    mapping = read_json(args["map"]) or {}
    caches = {}
    merged = Counter()
    for row in read_rows(args["rows"]):
        path, ref, text = row.get("file"), row.get("ref"), row.get("text")
        corpus = mapping.get(file_key(path or ""))
        if not corpus or not ref or text is None:
            continue
        ref_words = words(ref)
        if not ref_words:
            continue
        cache = caches.setdefault(corpus, load_cache(wer_cache_path(state, corpus)))
        cache.setdefault("files", {})[file_key(path)] = {
            "err": edit_distance(ref_words, words(text)),
            "ref": len(ref_words),
        }
        merged[corpus] += 1
    for corpus, cache in caches.items():
        cache["corpus"] = corpus
        cache["build"] = state["build"]
        write_json(wer_cache_path(state, corpus), cache)
        print(f"{corpus}: merged {merged[corpus]} rows ({len(cache['files'])} cached)",
              file=sys.stderr)
    return 0


def wer_result(state, corpus):
    cache = read_json(wer_cache_path(state, corpus))
    if not cache or not cache.get("files"):
        return None
    err = sum(v["err"] for v in cache["files"].values())
    ref = sum(v["ref"] for v in cache["files"].values())
    if not ref:
        return None
    return {"wer": 100.0 * err / ref, "n": len(cache["files"]), "ref_words": ref,
            "errors": err}


# ---------------------------------------------------------------- report


def speed_rows(state):
    cache = load_cache(live_cache_path(state))
    files = cache.get("files", {})
    sample = read_json(state["sample_file"]) if state.get("sample_file") else None
    if sample:
        keys = {e["key"] for entries in sample["buckets"].values() for e in entries}
        files = {k: v for k, v in files.items() if k in keys}
    by_bucket = {n: [] for n in BUCKET_NAMES}
    for row in files.values():
        name = row.get("bucket")
        if name in by_bucket:
            by_bucket[name].append(row)
    out = {}
    for name, count in by_bucket.items():
        lat = sorted(r["latencyMs"] for r in count)
        out[name] = {
            "n": len(lat),
            "p50": percentile(lat, 0.5),
            "p95": percentile(lat, 0.95),
            "worst": lat[-1] if lat else None,
        }
    return out


def baseline_comparison(state):
    """Last word kept and word-loss count against the recorded baseline build."""
    baseline = state.get("baseline") or {}
    base_build = baseline.get("build_sha")
    # Same measurement, later build, or the delta would compare unlike things.
    if not base_build or baseline.get("flags") != flags_tag(state):
        return None
    base_path = os.path.join(
        state["cache"], base_build + ("-dirty" if baseline.get("dirty") else ""),
        f"live-{baseline['flags']}.json")
    base_cache = read_json(base_path)
    if not base_cache or not base_cache.get("files"):
        return None
    current = load_cache(live_cache_path(state)).get("files", {})
    base = base_cache["files"]
    common = [k for k in current if k in base]
    if not common:
        return None
    same_or_better = 0
    had_last_word = kept = dropped = 0
    for k in common:
        b, c = base[k], current[k]
        want = Counter(b.get("words", []))
        have = Counter(c.get("words", []))
        lost = sum(max(0, n - have[w]) for w, n in want.items())
        if lost == 0:
            same_or_better += 1
        # Only a recording the baseline heard a last word in can keep one.
        if b.get("lastWord"):
            had_last_word += 1
            if b["lastWord"] == c.get("lastWord"):
                kept += 1
            else:
                dropped += 1
    return {
        "n": len(common),
        "same_or_better": 100.0 * same_or_better / len(common),
        "last_word_n": had_last_word,
        "last_word_kept": 100.0 * kept / had_last_word if had_last_word else None,
        "dropped_last_words": dropped,
    }


def ms(value):
    return "n/a" if value is None else f"{value:.0f} ms"


def render(state, out=sys.stdout):
    speed = speed_rows(state)
    accuracy = state.get("wer", {})
    owner = baseline_comparison(state)
    build = state["build"]
    machine = state["machine"]
    baseline_engine = (state.get("baseline") or {}).get("engine_sha") or build["engine"]
    build_sha = build["sha"] + ("+dirty" if build["dirty"] else "")
    if build["engine"] != build_sha:
        build_bit = f"{build['branch']} @ {build['engine']} (tools {build_sha})"
    else:
        build_bit = f"{build['branch']} @ {build_sha}"

    print(
        f"Whisp scoreboard   {time.strftime('%Y-%m-%d')}   "
        f"{machine['model']}  {machine['chip']}  {machine['memory_gb']} GB",
        file=out,
    )
    print("", file=out)
    print(
        f"{'bucket':<16} {'n':>4} {'p50':>7} {'p95':>7} {'worst':>7}   "
        f"{'target':<7} {'status'}",
        file=out,
    )
    for name, _, _, target, label in BUCKETS:
        row = speed.get(name, {})
        n = row.get("n") or 0
        p50, p95, worst = row.get("p50"), row.get("p95"), row.get("worst")
        if not n:
            print(f"{label:<16} {'n/a':>4}     {'-':>7} {'-':>7} {'-':>7}   "
                  f"{f'<{target} ms':<7} {'n/a'}", file=out)
            continue
        over = (p50 is not None and p50 >= target) or (worst or 0) >= WORST_TARGET_MS
        print(
            f"{label:<16} {n:>4} {ms(p50):>7} {ms(p95):>7} {ms(worst):>7}   "
            f"{f'<{target} ms':<7} {'over' if over else 'ok'}",
            file=out,
        )
    print(f"(worst case target: under {WORST_TARGET_MS} ms in every bucket)", file=out)
    print(f"{state.get('sample_rule', 'sample: n/a')}", file=out)
    print("", file=out)
    print("accuracy", file=out)
    rows = []
    if state.get("casual_set"):
        rows.append(("casual set, real refs", accuracy.get("casual"), ""))
    for corpus, label, note in (
        ("librispeech_test_clean", "LibriSpeech test-clean", ""),
        ("librispeech_test_other", "LibriSpeech test-other", ""),
        ("dictation", "dictation set, say refs", "   [casual stand-in]"),
    ):
        rows.append((label, accuracy.get(corpus), note))
    for label, result, note in rows:
        if not result:
            print(f"{label:<26}n/a   (no run){note}", file=out)
        else:
            print(f"{label:<26}WER {result['wer']:.2f}   (n={result['n']}){note}", file=out)
    if owner is None:
        print(f"{'owner recordings':<26}same-or-better than baseline n/a   "
              f"last word kept n/a   new dropped last words: n/a", file=out)
    else:
        kept = ("n/a" if owner["last_word_kept"] is None
                else f"{owner['last_word_kept']:.1f}%")
        print(
            f"{'owner recordings':<26}same-or-better than baseline "
            f"{owner['same_or_better']:.1f}%   last word kept {kept}   "
            f"new dropped last words: {owner['dropped_last_words']}",
            file=out,
        )
    print("", file=out)
    print(f"build: {build_bit}      baseline: {baseline_engine}", file=out)
    return 0


def cmd_report(args):
    state = load_state(args["state"])
    state["wer"] = {corpus: wer_result(state, corpus) for corpus in corpus_dirs(state)}
    state["speed"] = speed_rows(state)
    state["owner"] = baseline_comparison(state)
    state["finished"] = time.time()
    state["run_seconds"] = round(state["finished"] - state["started"], 1)
    save_state(args["state"], state)
    render(state, out=open(args["out"], "w") if args.get("out") else sys.stdout)
    return 0


# ---------------------------------------------------------------- record


def record_payload(state):
    speed = state["speed"]
    baseline = state.get("baseline") or {}
    return {
        "schema": SCHEMA,
        "recorded": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "run_seconds": state.get("run_seconds"),
        "build": state["build"],
        "baseline": {
            "engine_sha": baseline.get("engine_sha") or state["build"]["engine"],
            "build_sha": baseline.get("build_sha") or state["build"]["sha"],
            "flags": baseline.get("flags") or flags_tag(state),
        },
        "machine": state["machine"],
        "engine": {**state["engine"], "flags": flags_tag(state)},
        "settings": state["budgets"],
        "sample": {
            "rule": state.get("sample_rule"),
            "buckets": state.get("sample"),
            "outside_buckets": state.get("outside"),
        },
        "speed": {
            name: {
                "n": speed[name]["n"],
                "p50_ms": speed[name]["p50"],
                "p95_ms": speed[name]["p95"],
                "worst_ms": speed[name]["worst"],
                "target_ms": target,
            }
            for name, _, _, target, _ in BUCKETS
        },
        "accuracy": {
            **{k: v for k, v in state.get("wer", {}).items() if v},
            "owner": state.get("owner"),
        },
        "worst_case_target_ms": WORST_TARGET_MS,
    }


def cmd_record(args):
    state = load_state(args["state"])
    payload = record_payload(state)
    out_dir = args["dir"]
    os.makedirs(out_dir, exist_ok=True)
    write_json(os.path.join(out_dir, f"baseline-{state['build']['engine']}.json"), payload)
    write_json(os.path.join(out_dir, "latest.json"), payload)
    with open(args["table"]) as f:
        table = f.read()
    with open(os.path.join(out_dir, "latest.md"), "w") as f:
        f.write("# Whisp scoreboard (latest)\n\n")
        f.write("Generated by `scripts/speed/scoreboard.sh --record`. Real hardware only: "
                "numbers from a VM are relative.\n\n")
        f.write("```\n" + table.rstrip("\n") + "\n```\n")
    print(f"whisp scoreboard: recorded {os.path.join(out_dir, 'latest.json')}", file=sys.stderr)
    return 0


# ---------------------------------------------------------------- main


def main(argv):
    if len(argv) < 2:
        die(__doc__ or "usage: scoreboard.py <subcommand>")
    command = argv[1]
    args = {}
    i = 2
    while i < len(argv):
        if not argv[i].startswith("--"):
            die(f"scoreboard.py: stray argument {argv[i]}")
        key = argv[i][2:].replace("-", "_")
        if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
            args[key] = argv[i + 1]
            i += 2
        else:
            args[key] = ""
            i += 1
    handlers = {
        "init": cmd_init,
        "sample": cmd_sample,
        "plan": cmd_plan,
        "merge-live": cmd_merge_live,
        "wer-plan": cmd_wer_plan,
        "wer-merge": cmd_wer_merge,
        "report": cmd_report,
        "record": cmd_record,
    }
    handler = handlers.get(command)
    if not handler:
        die(f"scoreboard.py: unknown subcommand {command}")
    return handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
