#!/bin/bash
# Edge-case test set: transforms a few dictation clips into the hostile
# release conditions called out in the brief. Outputs WAV + .txt refs to
# testdata/edge (default) or $1. Pure python3 stdlib + wave reading via
# manual WAV parse (float32 LE).
#
# Usage: scripts/speed/gen-edge.sh [srcdir] [outdir]
set -euo pipefail

SRC="${1:-testdata/dictation}"
OUT="${2:-testdata/edge}"
mkdir -p "$OUT"

python3 - "$SRC" "$OUT" <<'PYEOF'
import os, struct, sys, math, random
random.seed(7)

src, out = sys.argv[1], sys.argv[2]

def read_wav(path):
    d = open(path, 'rb').read()
    i = d.index(b'data')
    size = struct.unpack('<I', d[i+4:i+8])[0]
    pcm = struct.unpack('<%df' % (size//4), d[i+8:i+8+size])
    return list(pcm), d[:i+8]

def write_wav(path, samples):
    pcm = struct.pack('<%df' % len(samples), *samples)
    hdr = b'RIFF' + struct.pack('<I', 36+len(pcm)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16,3,1,16000,64000,4,32) + b'data' + struct.pack('<I', len(pcm))
    open(path,'wb').write(hdr+pcm)

def rms(x):
    return math.sqrt(sum(s*s for s in x)/max(len(x),1))

def fade(x):  # linear fade in/out 20ms
    n=320
    for i in range(min(n,len(x))): x[i]*=i/n; x[-1-i]*=i/n
    return x

files = sorted(f for f in os.listdir(src) if f.endswith('.wav'))[:60]
made = 0
for f in files:
    base = f[:-4]
    ref = os.path.join(src, base+'.txt')
    if not os.path.exists(ref): continue
    txt = open(ref).read().strip()
    x, _ = read_wav(os.path.join(src, f))
    if len(x) < 16000*2: continue  # want room for the tail transforms
    n = len(x)
    # find last non-silent point (energy over 10ms frames)
    last = n-1
    for i in range(n-160, 1600, -160):
        if rms(x[i:i+160]) > 1e-3:
            last = i+160; break
    peak = max(abs(s) for s in x[:last]) or 1.0

    variants = {}

    # quiet final word: attenuate the last 400 ms of speech by -20 / -30 dB
    for db in (20, 30):
        g = 10**(-db/20)
        y = list(x[:last])
        k = min(6400, len(y))
        for i in range(len(y)-k, len(y)): y[i] *= g
        variants[f"{base}-quiet{db}"] = y + x[last:]

    # cough mid-take: 80 ms burst of shaped noise at the midpoint
    y = list(x)
    mid = last//2
    burst = [ (random.random()*2-1) for _ in range(1280) ]
    env = [math.sin(math.pi*i/1280)**2 for i in range(1280)]
    bpk = peak*0.9
    for i in range(1280):
        if mid+i < len(y): y[mid+i] += burst[i]*env[i]*bpk
    variants[f"{base}-cough"] = y

    # noise bed at 10 dB and 20 dB SNR over the whole clip
    clip_rms = rms(x[:last]) or 1e-3
    for snr in (10, 20):
        g = clip_rms / (10**(snr/20))
        y = [s + (random.random()*2-1)*g for s in x]
        variants[f"{base}-noise{snr}"] = y

    # low gain: whole clip -15 dB
    g = 10**(-15/20)
    variants[f"{base}-lowgain"] = [s*g for s in x]

    # clipped mic: hard clip at 40% of peak
    thr = peak*0.4
    variants[f"{base}-clipped"] = [max(-thr, min(thr, s)) for s in x]

    # trailing breath: 400 ms decaying noise appended after last word
    breath = [(random.random()*2-1)*peak*0.15*math.exp(-i/24000) for i in range(6400)]
    variants[f"{base}-breath"] = x[:last] + breath + x[last:]

    for name, samples in variants.items():
        write_wav(os.path.join(out, name+'.wav'), samples)
        open(os.path.join(out, name+'.txt'), 'w').write(txt + '\n')
        made += 1

    # mid-last-word release clip: truncate 200 ms into the last word
    cut = last - 3200
    if cut > 1600:
        write_wav(os.path.join(out, base+'-midword.wav'), x[:cut])
        open(os.path.join(out, base+'-midword.txt'), 'w').write(txt + '\n')
        made += 1

print(f"edge set: {made} clips in {out}")
PYEOF
