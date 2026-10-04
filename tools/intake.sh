#!/usr/bin/env bash
# Process animation intake: Mixamo FBX (intake/mixamo) and Blender GLB (intake/blender)
# become the `mixamo/` and `blender/` animation libraries on the mannequin.
#   bash tools/intake.sh
set -e
cd "$(dirname "$0")/.."
G="${GODOT_BIN:-/c/Dev/Godot_v4.7.1-stable_win64.exe}"
"$G" --headless --path . --import > /dev/null 2>&1 || true
"$G" --headless --path . res://tools/tool_runner.tscn -- --tool=res://tools/intake.gd --mode=prepare 2>&1 | grep "intake:" || true
"$G" --headless --path . --import 2>&1 | grep "UltraController intake" || true
"$G" --headless --path . res://tools/tool_runner.tscn -- --tool=res://tools/intake.gd --mode=finalize 2>&1 | grep "intake:" || true
