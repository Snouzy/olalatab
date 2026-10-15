#!/bin/bash
# End-to-end latency benchmark. Opens 10, 100 and 300 windows of TextEdit and of a throwaway
# Chrome profile, then runs `olalatab --bench` (real ⌥⇥ presses posted by the app) on each.
# Also checks that a frozen app (SIGSTOP) never blocks the switcher.
#
#   bench/run.sh                      # everything, 200 presses per case
#   ITER=50 COUNTS="100" APPS="chrome" bench/run.sh
#
# Presses come 30 ms apart, which keeps everything warm. The "spaced" cases (SPACED window
# counts, 50 presses 1.5 s apart) measure what a person gets.
#
# It takes over the keyboard and screen for a few minutes: don't type while it runs.
set -euo pipefail
cd "$(dirname "$0")/.."

ITER=${ITER:-200}
SPACED=${SPACED:-"100"}
SPACED_ITER=${SPACED_ITER:-50}
COUNTS=${COUNTS:-"10 100 300"}
APPS=${APPS:-"textedit chrome frozen"}
APP=$HOME/Applications/Olalatab.app
LABEL=io.github.olalatab
DOMAIN=gui/$(id -u)
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FIXTURE=$PWD/.build/release/olala-fixture
OUT=$PWD/bench/results/$(date +%Y%m%d-%H%M%S)
WORK=$(mktemp -d -t olalatab-bench)
mkdir -p "$OUT"

if [[ " $APPS " == *" textedit "* ]] && pgrep -x TextEdit >/dev/null; then
    echo "TextEdit is running: close it first (the bench quits it)." >&2
    exit 1
fi

# The installed agent owns ⌥⇥: stop it during the bench, restart it afterwards.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; do sleep 0.2; done

FIXTURE_PID=""
CHROME_PID=""
cleanup() {
    [ -n "$FIXTURE_PID" ] && { kill -CONT "$FIXTURE_PID" 2>/dev/null; kill "$FIXTURE_PID" 2>/dev/null; } || true
    [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null || true
    pkill -x TextEdit 2>/dev/null || true
    rm -rf "$WORK"
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || true
}
trap cleanup EXIT

# Runs one case: label, target pid, expected window count, [iterations].
bench() {
    local label=$1 pid=$2 expect=$3 iter=${4:-$ITER}; shift $(( $# < 4 ? $# : 4 ))
    echo "== $label"
    open -g -W -n --stdout "$OUT/$label.log" --stderr "$OUT/$label.log" "$APP" --args \
        --bench --iterations "$iter" --label "$label" --target-pid "$pid" \
        --expect-windows "$expect" --out "$OUT/$label.json" "$@" || true
    grep '^|' "$OUT/$label.log" | tee -a "$OUT/rows.md" || echo "   failed, see $OUT/$label.log"
}

# A stopped app in the background for every case: it must not slow anything down.
"$FIXTURE" 3 >/dev/null 2>&1 &
FIXTURE_PID=$!
sleep 1
kill -STOP "$FIXTURE_PID"

for n in $COUNTS; do
    if [[ " $APPS " == *" textedit "* ]]; then
        mkdir -p "$WORK/text-$n"
        for i in $(seq 1 "$n"); do echo "Document $i" > "$WORK/text-$n/doc-$(printf %03d "$i").txt"; done
        open -a TextEdit "$WORK/text-$n"/*.txt --args -ApplePersistenceIgnoreState YES -AppleWindowTabbingMode manual
        while ! pgrep -x TextEdit >/dev/null; do sleep 0.2; done
        bench "TextEdit-$n" "$(pgrep -x TextEdit)" "$n"
        if [[ " $SPACED " == *" $n "* ]]; then
            bench "TextEdit-$n-spaced" "$(pgrep -x TextEdit)" "$n" "$SPACED_ITER" --gap-ms 1500
        fi
        pkill -x TextEdit; while pgrep -x TextEdit >/dev/null; do sleep 0.2; done
    fi
    if [[ " $APPS " == *" chrome "* ]]; then
        profile="$WORK/chrome-$n"
        "$CHROME" --user-data-dir="$profile" --no-first-run --no-default-browser-check \
            --disable-session-crashed-bubble about:blank >/dev/null 2>&1 &
        CHROME_PID=$!
        sleep 3
        for _ in $(seq 2 "$n"); do
            "$CHROME" --user-data-dir="$profile" --new-window about:blank >/dev/null 2>&1
        done
        bench "Chrome-$n" "$CHROME_PID" "$n"
        if [[ " $SPACED " == *" $n "* ]]; then
            bench "Chrome-$n-spaced" "$CHROME_PID" "$n" "$SPACED_ITER" --gap-ms 1500
        fi
        kill "$CHROME_PID"; wait "$CHROME_PID" 2>/dev/null || true
        CHROME_PID=""
    fi
done

if [[ " $APPS " == *" frozen "* ]]; then
    # A second fixture, brought to the front by the bench and then frozen: ⌥⇥ on a hung app.
    "$FIXTURE" 3 >/dev/null 2>&1 &
    FROZEN_PID=$!
    sleep 1
    bench "Frozen-app" "$FROZEN_PID" 3 50 --freeze-target
    kill "$FROZEN_PID" 2>/dev/null || true
fi

{
    echo "| Case | Windows | Open p50 | Open p99 | In handler p50 | List p50 | List p99 | Switch p50 | Switch p99 | Failures |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    cat "$OUT/rows.md"
} > "$OUT/summary.md"
echo
cat "$OUT/summary.md"
echo
echo "Times in ms. Results: $OUT"
