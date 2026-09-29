#!/bin/bash
# Generate the dictation test set: >= 300 `say` clips across categories,
# voices, and rates. Each clip is 16 kHz mono float32 WAV with ~0.15 s
# leading and ~1.2 s trailing silence (so release-replay offsets up to
# +1000 ms are exercisable), plus a sibling .txt reference transcript.
#
# Usage: scripts/speed/gen-dictation.sh [outdir]   (default testdata/dictation)
set -euo pipefail

OUT="${1:-testdata/dictation}"
mkdir -p "$OUT"

VOICES=(Samantha Alex Daniel Kate Karen Moira Fred Victoria)
RATES=(165 185 205)

# Per-category phrase lists. One clip per phrase; category in filename.
declare -a PHRASES

# short commands
short_cmds=(
  "open the settings menu" "paste that here" "copy this link" "send the message"
  "schedule a meeting for tomorrow" "turn on do not disturb" "new note"
  "search my email for the receipt" "reply to Sarah" "play some music"
  "volume up" "mute the mic" "screenshot this" "undo that" "scroll down"
  "close this tab" "open terminal" "lock my screen" "empty the trash"
  "remind me to call the dentist" "what time is my next meeting"
  "create a calendar event for Friday at three" "navigate home"
  "text Mike I'm running late" "set a timer for ten minutes"
)
# questions
questions=(
  "what's the weather like today" "how do you spell necessary"
  "when is the next full moon" "who wrote the declaration of independence"
  "how many ounces in a cup" "what's fifteen percent of two hundred"
  "where did I park the car" "is it going to rain this weekend"
  "what time does the store close" "how long does it take to get to the airport"
  "what's the capital of Norway" "did the Warriors win last night"
  "how do I make a folded protein" "what's the exchange rate for euros"
  "when does daylight saving time end"
)
# one-word answers
one_word=(
  "yes" "no" "maybe" "thanks" "done" "sure" "okay" "cancel" "send"
  "blue" "Tuesday" "seven" "tomorrow" "here" "perfect"
)
# trailing names/products (word-boundary critical)
trailing_names=(
  "send this to my colleague Ramachandran"
  "forward the invoice to Abernathy please"
  "book a table at Chez Panisse"
  "order another pair of AirPods"
  "look up the Zebra ZX Spectrum review"
  "is the new MacBook Pro in stock"
  "call the office of doctor Okafor"
  "email the report to Blaszczykowski"
  "add Worcestershire sauce to the list"
  "meet me at the Starbucks on Fell"
  "get directions to IKEA"
  "put it on my Amex"
  "start a chat with Nguyen"
  "message Priya about the Kubrick screening"
  "schedule time with the Albuquerque team"
)
# numbers/times/money
numbers=(
  "the total is four thousand two hundred and ninety nine dollars"
  "meeting starts at a quarter to three"
  "my number is five five five oh one seven two"
  "the flight leaves at six forty five AM"
  "we sold one point three million units"
  "the zip code is nine four one one zero"
  "it costs about nineteen ninety nine"
  "I need this by Wednesday the seventeenth"
  "the temperature is seventy two degrees"
  "three quarters of an inch"
  "we grew forty two percent year over year"
  "she was born in nineteen eighty seven"
  "meet me in building four point two"
  "the address is twenty three oh one Mission Street"
  "it took about two and a half hours"
)
# medium takes (multi-sentence, natural pauses via commas)
medium=(
  "okay so the plan for tomorrow is to pick up groceries first thing, then swing by the post office before noon, and if there's time, grab lunch at that new place on Valencia"
  "I wanted to follow up on our conversation from last week about the quarterly budget, because I think we need to move the product launch to the middle of next month"
  "can you remind everyone that the standup is moving to nine thirty, and also that we're doing the retro in the big conference room this time"
  "the main thing I noticed in the user interviews is that people don't read the onboarding screens, they just tap through, so we should probably make the first run experience more interactive"
  "note to self, the plumber is coming Thursday between ten and two, so I need to be home, and I should ask him about the leak in the bathroom ceiling too"
  "I think the third design works better than the first two, mostly because the navigation is clearer, but I want to sleep on it before we commit"
  "for the recipe I need two cups of flour, a teaspoon of baking soda, three eggs, a stick of butter, and about a cup of sugar, plus whatever chocolate chips are left"
  "tell the team the deploy went fine last night, the only rollback was the reporting service, and it recovered after about five minutes"
  "we're going to drive up Saturday morning, probably leave around eight, stop in Sacramento for lunch, and get to the lake by mid afternoon"
  "the doctor said I should take the antibiotic twice a day with food for ten days, and come back for a follow up if the pain doesn't go away"
)
# long takes with pauses (~1-3 min read of repeated sentences)
long_seed="The quick brown fox jumps over the lazy dog. A dictation app has to keep up with natural speech, including pauses where the speaker thinks. Short commands are easy, but long thoughts need the pipeline to stay warm and accurate the whole time."

# very short 0.3 s takes — single syllables/clipped words
blips=("go" "hey" "up" "no" "in" "on" "off" "now")

gen() { # name, voice, rate, text
  local name="$1" voice="$2" rate="$3" text="$4"
  local wav="$OUT/$name.wav"
  say -v "$voice" -r "$rate" -o "$wav" --data-format=LEF32@16000 "$text"
  python3 - "$wav" <<'PYEOF'
import struct, sys, random
path = sys.argv[1]
data = open(path,'rb').read()
i = data.index(b'data')
size = struct.unpack('<I', data[i+4:i+8])[0]
pcm = data[i+8:i+8+size]
lead = bytes(16000*4*15//100)          # 0.15 s digital silence head
tail = bytes(16000*4*12//10)           # 1.2 s digital silence tail
pcm = lead + pcm + tail
out = data[:i+8] + pcm
out = out[:i+4] + struct.pack('<I', len(pcm)) + out[i+8:]
out = out[:4] + struct.pack('<I', len(out)-8) + out[8:]
open(path,'wb').write(out)
PYEOF
  printf '%s\n' "$text" > "$OUT/$name.txt"
}

i=0
emit() { # category, phrase array name
  local cat="$1"; shift
  local arr=("$@")
  for p in "${arr[@]}"; do
    local v=${VOICES[$((i % ${#VOICES[@]}))]}
    local r=${RATES[$((i % ${#RATES[@]}))]}
    local name
    name=$(printf "%s-%03d" "$cat" "$i")
    gen "$name" "$v" "$r" "$p"
    i=$((i+1))
  done
}

emit cmd "${short_cmds[@]}"
emit q "${questions[@]}"
emit word "${one_word[@]}"
emit blip "${blips[@]}"
emit names "${trailing_names[@]}"
emit num "${numbers[@]}"
emit med "${medium[@]}"
# long takes: repeat the seed ~N times to reach 1-3 min each
for n in 1 2 3; do
  reps=$((10 + n * 10))
  text=$(python3 -c "print(' '.join(['$long_seed'] * $reps))")
  gen "$(printf 'long-%03d' $i)" "${VOICES[$((i % ${#VOICES[@]}))]}" "${RATES[$((i % ${#RATES[@]}))]}" "$text"
  i=$((i+1))
done

# Top up to >= 300 clips: cycle through all lists with more voice/rate combos.
while [ "$(find "$OUT" -name '*.wav' | wc -l)" -lt 300 ]; do
  for p in "${short_cmds[@]}" "${questions[@]}" "${trailing_names[@]}" "${numbers[@]}" "${medium[@]}"; do
    [ "$(find "$OUT" -name '*.wav' | wc -l)" -ge 300 ] && break
    v=${VOICES[$((i % ${#VOICES[@]}))]}
    r=${RATES[$((i % ${#RATES[@]}))]}
    name=$(printf "extra-%03d" "$i")
    gen "$name" "$v" "$r" "$p"
    i=$((i+1))
  done
done

echo "dictation set: $(find "$OUT" -name '*.wav' | wc -l) clips in $OUT"
