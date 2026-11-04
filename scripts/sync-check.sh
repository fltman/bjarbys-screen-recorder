#!/bin/bash
# A/V-synk mot en riktig referens: en film med vit blixt och 1 kHz-pip exakt samtidigt
# varje hel sekund spelas i QuickTime Player medan appen spelar in huvudskärmen.
# Sedan mäts tiden mellan ljushoppet i skärmspåret och ljudansatsen i datorljudspåret.
#
# OBS: QuickTime fördröjer bilden med utgångsenhetens latens för att hålla synk vid
# högtalaren, medan ScreenCaptureKit fångar ljudet före hårdvaran. En liten positiv
# förskjutning (ljud före bild) på högtalarens latens är därför väntad.
set -euo pipefail
cd "$(dirname "$0")/.."
UT="${1:-prov/synk}"
mkdir -p "$UT"
REF="$UT/referens.mp4"
APP="dist/Bjarbys skärminspelare.app/Contents/MacOS/Skarminspelare"

if [ ! -f "$REF" ]; then
  ffmpeg -v error -y \
    -f lavfi -i "color=c=black:s=960x540:r=60:d=12" \
    -f lavfi -i "aevalsrc='if(lt(mod(t\,1)\,0.03)\,0.8*sin(2*PI*1000*t)\,0)':s=48000:d=12" \
    -vf "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t\,1)\,0.034)'" \
    -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k "$REF"
fi

open -a "QuickTime Player" "$REF"
sleep 2
osascript -e 'tell application "QuickTime Player" to play document 1'
"$APP" --prov-inspelning 8 --katalog "$UT" > "$UT/rapport.json"
osascript -e 'tell application "QuickTime Player" to close every document saving no' || true

PAKET=$(ls -dt "$UT"/*.bsrec | head -1)
python3 - "$PAKET" <<'PY'
import subprocess, sys, re, statistics
b = sys.argv[1] + "/recording/"
# Bild: medelluminans per ruta; blixten = hopp över mittvärdet.
out = subprocess.run(["ffprobe","-v","error","-f","lavfi","-i",
    f"movie='{b}screen-0.mov',signalstats","-show_entries",
    "frame=pts_time:frame_tags=lavfi.signalstats.YAVG","-of","csv=p=0"],
    capture_output=True, text=True).stdout
frames = []
for line in out.strip().splitlines():
    parts = line.split(",")
    if len(parts) >= 2:
        frames.append((float(parts[0]), float(parts[1])))
lo, hi = min(y for _, y in frames), max(y for _, y in frames)
mid = (lo + hi) / 2
video, prev = [], False
for t, y in frames:
    on = y > mid
    if on and not prev: video.append(t)
    prev = on
# Ljud: slut på tystnad = pipets ansats.
err = subprocess.run(["ffmpeg","-v","info","-i",b+"system-0.mov","-af",
    "silencedetect=noise=-35dB:d=0.2","-f","null","-"], capture_output=True, text=True).stderr
audio = [float(x) for x in re.findall(r"silence_end: ([0-9.]+)", err)]
pairs = []
for v in video:
    near = min(audio, key=lambda a: abs(a - v), default=None)
    if near is not None and abs(near - v) < 0.3:
        pairs.append((v - near) * 1000)
print(f"blixtar {len(video)}, pip {len(audio)}, par {len(pairs)}")
if pairs:
    print("bild minus ljud (ms):", " ".join(f"{p:+.1f}" for p in pairs))
    print(f"medel {statistics.mean(pairs):+.1f} ms, median {statistics.median(pairs):+.1f} ms, "
          f"spridning {max(pairs)-min(pairs):.1f} ms")
PY
