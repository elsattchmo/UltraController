#!/usr/bin/env bash
# Side-by-side video of demo/tours/marksman_mm_review.gd (filmed with --every=2: 30 fps = real time):
# gait left, motion matching right, per stance.  bash tools/marksman/mm_compare_video.sh <tour out dir>
set -e
src="$1"
for stance in unarmed rifle; do
  for mode in gait mm; do
    ls "$src/$mode/${stance}_"*.png 2>/dev/null | sort | sed "s/^/file '/; s/$/'/" > "$src/${stance}_${mode}.txt"
    [ -s "$src/${stance}_${mode}.txt" ] || continue
    ffmpeg -y -loglevel error -f concat -safe 0 -r 30 -i "$src/${stance}_${mode}.txt" -vf "fps=30,scale=420:-2" \
      -c:v libx264 -pix_fmt yuv420p "$src/${stance}_${mode}.mp4"
  done
  if [ -f "$src/${stance}_gait.mp4" ] && [ -f "$src/${stance}_mm.mp4" ]; then
    ffmpeg -y -loglevel error -i "$src/${stance}_gait.mp4" -i "$src/${stance}_mm.mp4" \
      -filter_complex "[0:v][1:v]hstack=inputs=2:shortest=1" -c:v libx264 -pix_fmt yuv420p "$src/${stance}_gait_vs_mm.mp4"
    echo "$src/${stance}_gait_vs_mm.mp4"
  fi
done
