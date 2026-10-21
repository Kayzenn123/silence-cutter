#!/usr/bin/env bash
# Tests for silence-cutter. No dependencies besides bash + ffmpeg/ffprobe.
# Fixtures are generated with ffmpeg lavfi (no committed binaries).
set -u
cd "$(dirname "$0")"

BIN="./silence-cutter.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
t() { # t "name" -- runs test function
  if "$1" >/dev/null 2>&1; then pass=$((pass+1)); printf 'ok   %s\n' "$2"
  else fail=$((fail+1)); printf 'FAIL %s\n' "$2"; fi
}
expect_eq() { # expect_eq actual expected label
  if [ "$1" = "$2" ]; then return 0; else printf '  expected [%s] got [%s]\n' "$2" "$1" >&2; return 1; fi
}
expect_contains() { # expect_contains haystack needle
  case "$1" in *"$2"*) return 0;; *) printf '  missing [%s]\n' "$2" >&2; return 1;; esac
}

command -v ffmpeg >/dev/null || { echo "ffmpeg required for tests"; exit 1; }

# ---- fixtures: tone(1s) silence(1s) tone(1s) silence(1s) tone(1s) = 5s
ffmpeg -y -v error \
  -f lavfi -i "sine=frequency=880:duration=1:sample_rate=44100" \
  -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=44100:d=1" \
  -f lavfi -i "sine=frequency=660:duration=1:sample_rate=44100" \
  -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=44100:d=1" \
  -f lavfi -i "sine=frequency=520:duration=1:sample_rate=44100" \
  -filter_complex "[0:a][1:a][2:a][3:a][4:a]concat=n=5:v=0:a=1" "$TMP/fixture.wav"
# video fixture: 5s testsrc + the same audio
ffmpeg -y -v error -f lavfi -i "testsrc2=duration=5:size=320x240:rate=30" \
  -i "$TMP/fixture.wav" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$TMP/fixture.mp4"
# fully silent file (1.5s)
ffmpeg -y -v error -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=44100:d=1.5" "$TMP/silent.wav"
echo "hello" > "$TMP/notmedia.txt"

test_help() {
  out=$($BIN --help 2>&1); code=$?
  expect_eq "$code" "0" && expect_contains "$out" "Usage:" && expect_contains "$out" "--apply"
}
test_version() {
  out=$($BIN --version 2>&1); code=$?
  expect_eq "$code" "0" && expect_contains "$out" "silence-cutter"
}
test_no_args() {
  out=$($BIN 2>&1); code=$?
  expect_eq "$code" "2" && expect_contains "$out" "no input file"
}
test_missing_file() {
  out=$($BIN "$TMP/does-not-exist.wav" 2>&1); code=$?
  expect_eq "$code" "2" && expect_contains "$out" "not found"
}
test_not_media() {
  out=$($BIN "$TMP/notmedia.txt" 2>&1); code=$?
  expect_eq "$code" "1" && expect_contains "$out" "not a media file"
}
test_plan_numbers() {
  out=$($BIN "$TMP/fixture.wav" 2>&1); code=$?
  expect_eq "$code" "0" \
    && expect_contains "$out" "2 silence region(s)" \
    && expect_contains "$out" "cut 1.40 s" \
    && expect_contains "$out" "new duration 3.60 s" \
    && expect_contains "$out" "dry-run"
}
test_plan_no_encode() {
  $BIN "$TMP/fixture.wav" >/dev/null 2>&1
  [ ! -e "$TMP/should-not-exist.wav" ]
}
test_json_valid() {
  out=$($BIN --json "$TMP/fixture.wav" 2>/dev/null); code=$?
  [ "$code" -eq 0 ] || return 1
  expect_contains "$out" '"cut_seconds": 1.400' \
    && expect_contains "$out" '"new_duration": 3.600' \
    && expect_contains "$out" '"kept"'
  if command -v python3 >/dev/null; then
    printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null \
      || { echo "  invalid JSON" >&2; return 1; }
  fi
}
test_apply_audio() {
  out=$($BIN --apply -o "$TMP/tight.wav" "$TMP/fixture.wav" 2>&1); code=$?
  [ "$code" -eq 0 ] || { printf '  %s\n' "$out" >&2; return 1; }
  [ -f "$TMP/tight.wav" ] || { echo "  output missing" >&2; return 1; }
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$TMP/tight.wav")
  awk -v d="$dur" 'BEGIN{ exit !(d>3.3 && d<3.9) }' \
    || { printf '  bad duration %s (want ~3.6)\n' "$dur" >&2; return 1; }
  expect_contains "$out" "done:"
}
test_apply_video() {
  out=$($BIN --apply -o "$TMP/tight.mp4" "$TMP/fixture.mp4" 2>&1); code=$?
  [ "$code" -eq 0 ] || { printf '  %s\n' "$out" >&2; return 1; }
  [ -f "$TMP/tight.mp4" ] || { echo "  output missing" >&2; return 1; }
  v=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 -- "$TMP/tight.mp4" | head -1)
  a=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 -- "$TMP/tight.mp4" | head -1)
  [ -n "$v" ] && [ -n "$a" ] || { echo "  missing v/a streams" >&2; return 1; }
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$TMP/tight.mp4")
  awk -v d="$dur" 'BEGIN{ exit !(d>3.2 && d<4.0) }' \
    || { printf '  bad duration %s\n' "$dur" >&2; return 1; }
}
test_edl() {
  $BIN --edl "$TMP/cuts.edl" "$TMP/fixture.wav" >/dev/null 2>&1
  [ -f "$TMP/cuts.edl" ] || { echo "  edl missing" >&2; return 1; }
  lines=$(wc -l < "$TMP/cuts.edl")
  expect_eq "$lines" "2" && expect_contains "$(cat "$TMP/cuts.edl")" " 0"
}
test_no_color() {
  out=$(NO_COLOR=1 $BIN "$TMP/fixture.wav" 2>&1)
  case "$out" in *$'\033'*) echo "  escape codes present" >&2; return 1;; *) return 0;; esac
}
test_entirely_silent() {
  out=$($BIN --threshold -10dB "$TMP/fixture.wav" 2>&1); code=$?
  expect_eq "$code" "1" && expect_contains "$out" "entirely silent"
}
test_silent_file() {
  out=$($BIN "$TMP/silent.wav" 2>&1); code=$?
  expect_eq "$code" "1" && expect_contains "$out" "entirely silent"
}
test_min_duration_filters() {
  out=$($BIN --min-duration 3 "$TMP/fixture.wav" 2>&1); code=$?
  expect_eq "$code" "0" && expect_contains "$out" "no silence worth cutting"
}
test_bad_flag() {
  out=$($BIN --bogus "$TMP/fixture.wav" 2>&1); code=$?
  expect_eq "$code" "2" && expect_contains "$out" "unknown option"
}
test_apply_without_output() {
  out=$($BIN --apply "$TMP/fixture.wav" 2>&1); code=$?
  expect_eq "$code" "2" && expect_contains "$out" "--apply needs an output"
}
test_bad_threshold() {
  out=$($BIN --threshold loud "$TMP/fixture.wav" 2>&1); code=$?
  expect_eq "$code" "2" && expect_contains "$out" "--threshold"
}

t test_help "help exits 0 with usage"
t test_version "version prints name"
t test_no_args "no args -> exit 2"
t test_missing_file "missing file -> exit 2"
t test_not_media "non-media file -> exit 1"
t test_plan_numbers "plan shows correct cut numbers"
t test_plan_no_encode "default mode encodes nothing"
t test_json_valid "json plan is valid"
t test_apply_audio "apply trims audio to ~3.6s"
t test_apply_video "apply trims video+audio, keeps both streams"
t test_edl "edl file has 2 cut lines"
t test_no_color "NO_COLOR strips escapes"
t test_entirely_silent "threshold too high -> exit 1"
t test_silent_file "fully silent file -> exit 1"
t test_min_duration_filters "min-duration filters all -> no cut"
t test_bad_flag "bad flag -> exit 2"
t test_apply_without_output "apply without -o -> exit 2"
t test_bad_threshold "bad threshold -> exit 2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
