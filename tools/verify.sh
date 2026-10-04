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
