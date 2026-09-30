#!/bin/bash
# Download LibriSpeech test-clean (all 2620 files) and test-other, extract, and
# write a `<file>.txt` reference transcript next to every .flac so whisp-bench
# can score WER. Idempotent: re-running skips work already done.
#
#   scripts/speed/fetch-librispeech.sh [DESTDIR]
#
# DESTDIR defaults to <repo>/testdata/librispeech. The two tarballs stay cached
# for re-extraction; delete them to save ~675 MB once refs are written.
set -euo pipefail

DEST="${1:-$(cd "$(dirname "$0")/../.." && pwd)/testdata/librispeech}"
mkdir -p "$DEST"
cd "$DEST"

for part in test-clean test-other; do
    if [ ! -d "LibriSpeech/$part" ]; then
        if [ ! -f "$part.tar.gz" ]; then
            echo "downloading $part.tar.gz"
            curl -fsSL -o "$part.tar.gz" "https://www.openslr.org/resources/12/$part.tar.gz"
        fi
        echo "extracting $part.tar.gz"
        tar xzf "$part.tar.gz"
    fi
done

# One .txt sibling per .flac, from each chapter's <speaker>-<chapter>.trans.txt
# manifest (format: "<utt-id> <uppercase words>").
python3 - "$DEST" <<'PY'
import os, sys

root = os.path.join(sys.argv[1], "LibriSpeech")
written = 0
for part in ("test-clean", "test-other"):
    part_dir = os.path.join(root, part)
    for dirpath, _, files in os.walk(part_dir):
        for name in files:
            if not name.endswith(".trans.txt"):
                continue
            for line in open(os.path.join(dirpath, name), encoding="utf-8"):
                utt, _, text = line.partition(" ")
                text = text.strip()
                if not utt or not text:
                    continue
                flac = os.path.join(dirpath, utt + ".flac")
                if os.path.exists(flac):
                    with open(flac + ".txt", "w", encoding="utf-8") as f:
                        f.write(text + "\n")
                    written += 1
print(f"wrote {written} reference transcripts")
PY

echo "test-clean files: $(find LibriSpeech/test-clean -name '*.flac' | wc -l | tr -d ' ')"
echo "test-other files: $(find LibriSpeech/test-other -name '*.flac' | wc -l | tr -d ' ')"
