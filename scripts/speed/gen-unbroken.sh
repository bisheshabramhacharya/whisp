#!/bin/bash
# Generate the "unbroken take" set: 30 clips of 8-14 s of continuous speech
# with no pause long enough for the live loop to cut or speculate on
# (SpeechSegmenter: a cut needs >=350 ms of quiet, speculation 180 ms). These
# are the takes that leave a >5 s leftover for the release decode.
#
# `say` still inserts short inter-word pauses at these rates, so each clip is
# post-processed: silent 10 ms runs >=150 ms (same RMS threshold as
# SpeechSegmenter's pauseThreshold) are squeezed to ~120 ms, and the result is
# verified to hold no >=180 ms run and 8-14 s of speech. Same 16 kHz mono
# float32 WAV, ~0.15 s lead / ~1.2 s tail, and .txt reference as
# gen-dictation.sh.
#
# Usage: scripts/speed/gen-unbroken.sh [outdir]   (default testdata/unbroken)
set -euo pipefail

OUT="${1:-testdata/unbroken}"
mkdir -p "$OUT"

VOICES=(Samantha Alex Daniel Kate Karen Moira Fred Victoria)

# Comma-free run-on sentences: commas make `say` pause, so none appear here.
# ~45-60 words each -> ~10-14 s at the rates below. Numbers, names and units
# keep the transcripts word-error-sensitive.
TEXTS=(
  "okay so tomorrow I need to finish the report that I promised to send last Friday and then call the accountant about the invoice from March because the numbers still don't add up and after that pick up the dry cleaning before six"
  "the meeting with the design team got moved to two thirty on Thursday which means I have to reschedule the dentist appointment that was supposed to be at three and figure out who can pick up the kids from soccer practice at five"
  "I was thinking we could drive up to the lake on Saturday morning around eight and stop at that bakery on the way the one with the really good sourdough and then hike the north trail if the weather holds like they said it would"
  "the recipe calls for two cups of flour a teaspoon of baking soda three eggs half a cup of melted butter and about a cup of sugar then you fold in the chocolate chips and bake at three fifty for twenty two minutes until golden"
  "can you remind me to email Priya about the Kubrick screening on Tuesday and also ask Ramachandran whether the invoice from the Albuquerque office was ever paid because finance keeps asking me about it every single week"
  "we sold about one point three million units last quarter which is forty two percent more than the same period last year and most of that growth came from the sixteen inch model that launched in February at nineteen ninety nine"
  "the plumber is coming Thursday between ten and two so someone needs to be home and I should ask him about the leak in the bathroom ceiling too since it's been dripping every time we run the shower upstairs for more than a minute"
  "my flight leaves at six forty five in the morning which means I have to be at the airport by five and the address for the hotel is twenty three oh one Mission Street in case you need to send anything while I'm gone this week"
  "the user interviews showed that people don't read the onboarding screens at all they just tap through as fast as possible so we should probably make the first run experience way more interactive and shorter than five screens"
  "I think the third design works better than the first two mostly because the navigation is clearer and the buttons are bigger but I want to sleep on it before we commit since the rollout is scheduled for the middle of next month"
)

gen() { # name, voice, text, target-seconds
  local name="$1" voice="$2" text="$3" target="$4"
  local wav="$OUT/$name.wav"
  python3 - "$wav" "$voice" "$text" "$target" <<'PYEOF'
import math, struct, subprocess, sys

wav, voice, text, target = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
FRAME = 160  # 10 ms at 16 kHz

def read_pcm(path):
    data = open(path, 'rb').read()
    i = data.index(b'data')
    size = struct.unpack('<I', data[i+4:i+8])[0]
    return data[:i+8], struct.unpack('<%df' % (size // 4), data[i+8:i+8+size])

def energies(pcm):
    n = len(pcm) // FRAME
    return [math.sqrt(sum(s*s for s in pcm[f*FRAME:(f+1)*FRAME]) / FRAME)
            for f in range(n)]

def speech_span(e):
    if not e:
        return None
    loud = sorted(e)[min(len(e) - 1, int(len(e) * 0.9))]
    thresh = max(1.5e-3, loud * 0.08)          # SpeechSegmenter.pauseThreshold
    first = next((f for f in range(len(e)) if e[f] >= thresh), len(e))
    last = next((f for f in range(len(e) - 1, -1, -1) if e[f] >= thresh), first)
    return thresh, first, last

def longest_quiet_run(e, thresh, first, last):
    best = run = 0
    for f in range(first, last + 1):
        run = run + 1 if e[f] < thresh else 0
        best = max(best, run)
    return best

def squeeze(pcm, e, thresh, first, last):
    """Clamp every quiet run >=150 ms to its first ~120 ms; both splice
    points sit inside silence. Returns the kept frames' samples."""
    keeps = []
    pos = first
    f = first
    while f <= last:
        if e[f] < thresh:
            r0 = f
            while f <= last and e[f] < thresh:
                f += 1
            keeps.append((pos, r0))                    # speech before the run
            keeps.append((r0, r0 + min(f - r0, 12)))   # clamped quiet run
            pos = f
        else:
            f += 1
    keeps.append((pos, last + 1))
    return [s for a, b in keeps for s in pcm[a*FRAME:b*FRAME]]

# Re-say at a corrected rate until the post-squeeze take lands on target
# (rate is words/minute, so duration scales ~1/rate).
rate = min(340.0, max(150.0, len(text.split()) * 60.0 / (target + 2.0)))
speech = e2 = thresh2 = first2 = last2 = gap = dur2 = None
for _ in range(6):
    subprocess.run(['say', '-v', voice, '-r', str(int(rate)), '-o', wav,
                    '--data-format=LEF32@16000', text], check=True)
    header, pcm = read_pcm(wav)
    e = energies(pcm)
    thresh, first, last = speech_span(e)
    if last - first < 50:
        sys.exit('no speech in %s' % wav)
    speech = squeeze(pcm, e, thresh, first, last)
    e2 = energies(speech)
    thresh2, first2, last2 = speech_span(e2)
    gap = longest_quiet_run(e2, thresh2, first2, last2)
    dur2 = (last2 + 1 - first2) * 0.010
    if gap >= 18:
        sys.exit('%s still has a %d ms pause after squeezing' % (wav, gap * 10))
    if abs(dur2 - target) <= 1.0:
        break
    if dur2 > target and rate >= 340:
        break   # accept any landing in [8,14] when rate is maxed out
    if dur2 < target and rate <= 150:
        break
    rate = min(340.0, max(150.0, rate * dur2 / target))
else:
    if not 8.0 <= dur2 <= 14.0:
        sys.exit('could not land %s near %.1f s' % (wav, target))
if not 8.0 <= dur2 <= 14.0:
    sys.exit('%s is %.2f s of speech, outside 8-14 s' % (wav, dur2))

lead = [0.0] * (16000 * 15 // 100)
tail = [0.0] * (16000 * 12 // 10)
body = struct.pack('<%df' % (len(lead) + len(speech) + len(tail)),
                   *(lead + speech + tail))
out = header[:4] + struct.pack('<I', len(header) - 8 + len(body)) + header[8:] + body
i = out.index(b'data')
out = out[:i+4] + struct.pack('<I', len(body)) + out[i+8:]
open(wav, 'wb').write(out)
print('  %s  %5.1f s speech, longest pause %d ms' % (wav, dur2, gap * 10))
PYEOF
  printf '%s\n' "$text" > "$OUT/$name.txt"
}

for i in $(seq 0 29); do
  v=${VOICES[$((i % ${#VOICES[@]}))]}
  t=${TEXTS[$((i % ${#TEXTS[@]}))]}
  target=$(python3 -c "print(8.5 + ($i % 30) * 5.0 / 29)")
  gen "$(printf 'unbroken-%03d' "$i")" "$v" "$t" "$target"
done

echo "unbroken set: $(find "$OUT" -name '*.wav' | wc -l) clips in $OUT"
