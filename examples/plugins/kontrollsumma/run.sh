#!/bin/sh
# Händelsen kommer som JSON på stdin, t.ex. {"event":"action","action":"sha256","file":"/…/film.mp4",…}.
# Svaret är JSON på stdout: "message" visas i appen, "url" läggs i urklipp.
input=$(cat)
file=$(printf '%s' "$input" | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("file",""))')
[ -f "$file" ] || { echo "ingen fil" >&2; exit 2; }
size=$(/usr/bin/stat -f %z "$file")
sum=$(/usr/bin/shasum -a 256 "$file" | cut -c1-16)
printf '{"message":"%s byte, SHA-256 %s…"}\n' "$size" "$sum"
