#!/bin/bash
# CPU, wake-ups and memory of the installed olalatab at rest (nobody pressing ⌥⇥).
set -euo pipefail
SECONDS_AT_REST=${1:-60}
pid=$(pgrep -f "Olalatab.app/Contents/MacOS/olalatab" | head -1)
[ -n "$pid" ] || { echo "olalatab is not running (make install)" >&2; exit 1; }

cpu_seconds() { ps -o time= -p "$pid" | awk -F'[:.]' '{ print ($1 * 60 + $2) + ("0." $3) }'; }
before=$(cpu_seconds)
echo "Watching pid $pid for ${SECONDS_AT_REST}s at rest…"
top -l 2 -s "$SECONDS_AT_REST" -pid "$pid" -stats pid,cpu,idlew,mem | tail -1 | \
    awk '{ printf "top (last %ss): CPU %s%%, idle wake-ups %s, mem %s\n", '"$SECONDS_AT_REST"', $2, $3, $4 }'
after=$(cpu_seconds)
echo "CPU time used: $(echo "$after - $before" | bc) s over ${SECONDS_AT_REST}s"
footprint "$pid" 2>/dev/null | grep -E "Footprint:" | head -1 || true
