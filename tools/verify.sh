#!/usr/bin/env bash
# Verification on a fresh LOCAL copy of the project (stale class caches hang boot when a
# class_name script is added; a copy also keeps tests out of your user:// data).
#
# Usage:  bash tools/verify.sh [m1|m2|...|all] [--keep] [--tour]
#   --keep  reuse the previous copy's .godot/ import cache (only safe when no class_name
#           script was added since the last run)
#   --tour  also run the windowed capture tour for the suite (screenshots for review)
set -u

SUITE="${1:-m1}"
KEEP=0
TOUR=0
for a in "$@"; do
	[ "$a" = "--keep" ] && KEEP=1
	[ "$a" = "--tour" ] && TOUR=1
done

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${ULTRA_VERIFY_DIR:-/c/Dev/verify/ultra}"
DST="$ROOT/project"
ENGINE="${GODOT_BIN:-/c/Dev/Godot_v4.7.1-stable_win64.exe}"
LOGS="$ROOT/logs"
mkdir -p "$LOGS"

# --- static checks (before Godot): no hard-coded keys outside the input layer
echo "verify: static checks"
BAD=$(grep -rnE "\bKEY_[A-Z0-9_]+|MOUSE_BUTTON_[A-Z]+|JOY_BUTTON_[A-Z]+|is_key_pressed|is_physical_key_pressed|is_mouse_button_pressed|is_joy_button_pressed" \
	--include=*.gd "$SRC/addons" "$SRC/demo" | grep -v "/input/" || true)
if [ -n "$BAD" ]; then
	echo "verify: FAILED - hard-coded input outside addons/ultra_controller/input:"
	echo "$BAD"
	exit 1
fi

# --- project copy
if [ "$KEEP" = "1" ] && [ -d "$DST/.godot" ]; then
	mv "$DST/.godot" "$ROOT/.godot_keep"
fi
rm -rf "$DST"
mkdir -p "$DST"
for item in "$SRC"/* "$SRC"/.gitattributes; do
	name="$(basename "$item")"
	case "$name" in
		art_src|verify|export|builds) continue ;;
	esac
	cp -r "$item" "$DST/"
done
find "$DST" -name "*.uid" -delete
printf '[application]\n\nconfig/custom_user_dir_name="UltraController_verify"\nconfig/use_custom_user_dir=true\n' > "$DST/override.cfg"
if [ -d "$ROOT/.godot_keep" ]; then
	mv "$ROOT/.godot_keep" "$DST/.godot"
fi

fail=0
run() {   # run <name> <timeout-seconds> <godot args...>
	local name="$1"; local secs="$2"; shift 2
	local log="$LOGS/$name.log"
	timeout "$secs" "$ENGINE" --path "$DST" "$@" > "$log" 2>&1
	local code=$?
	if grep -qE "SCRIPT ERROR|Parse Error|Failed to load script" "$log"; then
		echo "verify: $name produced script errors:"
		grep -E -A2 "SCRIPT ERROR|Parse Error|Failed to load script" "$log" | head -30
		code=1
	fi
	if [ $code -ne 0 ]; then
		echo "verify: $name FAILED (exit $code) - $log"
		grep -E "FAIL|✗" "$log" | head -40
		fail=1
	else
		echo "verify: $name ok ($(grep -cE '^ok ' "$log") tests)"
	fi
	return $code
}

echo "verify: importing"
if [ ! -d "$DST/.godot" ]; then
	timeout 900 "$ENGINE" --headless --path "$DST" --import > "$LOGS/import_first.log" 2>&1
fi
timeout 900 "$ENGINE" --headless --path "$DST" --import > "$LOGS/import.log" 2>&1
if grep -qE "SCRIPT ERROR|Parse Error" "$LOGS/import.log"; then
	echo "verify: import produced script errors"; grep -E -A2 "SCRIPT ERROR|Parse Error" "$LOGS/import.log" | head; exit 1
fi

run "tests_$SUITE" 1200 --headless --fixed-fps 60 res://tests/test_runner.tscn -- --suite="$SUITE"

# --- real multi-process netcode: dedicated server + headless clients over localhost ENet
net_case() {   # net_case <name> <client-count> <client net args...>
	local name="$1"; local clients="$2"; shift 2
	local port=$((24700 + RANDOM % 250))
	timeout 60 "$ENGINE" --headless --path "$DST" -- --server --port=$port --net-report --quit-after=28 ${SERVER_ARGS:-} > "$LOGS/net_${name}_server.log" 2>&1 &
	local spid=$!
	sleep 2
	local pids=()
	for ((k=0; k<clients; k++)); do
		local extra=""
		local course="course_full"
		[ "$clients" -gt 1 ] && extra="--expect-remotes=$((clients-1))"
		[ "$k" -gt 0 ] && course="circle_east"
		[ -n "${CLIENT_BOT:-}" ] && course="$CLIENT_BOT"
		timeout 60 "$ENGINE" --headless --path "$DST" -- --connect=127.0.0.1:$port --bot=$course --net-report --quit-after=22 --user-dir=c$k $extra "$@" > "$LOGS/net_${name}_client$k.log" 2>&1 &
		pids+=($!)
		sleep 0.5
	done
	local bad=0
	for pid in "${pids[@]}"; do wait $pid || bad=1; done
	wait $spid || bad=1
	for f in "$LOGS"/net_${name}_*.log; do
		grep -qE "SCRIPT ERROR|Parse Error" "$f" && { echo "verify: script errors in $f"; bad=1; }
	done
	if [ $bad -ne 0 ]; then
		echo "verify: net $name FAILED"
		grep -h "NETREPORT" "$LOGS"/net_${name}_*.log | head -20
		fail=1
	else
		echo "verify: net $name ok  $(grep -h 'NETREPORT player=' "$LOGS"/net_${name}_client0.log | head -1 | cut -c11-)"
	fi
}
if [ "$SUITE" = "m2" ] || [ "$SUITE" = "net" ] || [ "$SUITE" = "all" ]; then
	net_case clean 1 --expect-no-corrections
	net_case lag120 1 --lag=120 --jitter=20 --loss=2
	net_case bad 1 --lag=250 --jitter=80 --loss=5
	net_case two_clients 2 --lag=80 --jitter=10 --loss=1
	SERVER_ARGS="--spawn=platform_elevator" CLIENT_BOT="walk_short" net_case platform 1 --lag=120 --jitter=20 --loss=2 --max-correction=0.05
fi

if [ "$TOUR" = "1" ] && [ -f "$DST/demo/tours/$SUITE.gd" ]; then
	echo "verify: windowed tour $SUITE"
	timeout 300 "$ENGINE" --path "$DST" --resolution 1280x720 --disable-vsync -- --tour="$SUITE" --out="$ROOT/review/$SUITE" > "$LOGS/tour_$SUITE.log" 2>&1
	grep -q "TOUR DONE" "$LOGS/tour_$SUITE.log" && echo "verify: screenshots in $ROOT/review/$SUITE" || { echo "verify: tour FAILED"; fail=1; }
fi

if [ $fail -ne 0 ]; then
	echo "verify: RED"
	exit 1
fi
echo "verify: GREEN"
