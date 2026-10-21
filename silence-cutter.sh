#!/usr/bin/env bash
# silence-cutter — cut silent parts from audio/video files, preview first.
# Single file, zero dependencies besides ffmpeg/ffprobe. Fully offline.
#
# Default mode only PRINTS the cut plan (dry-run). Nothing is encoded unless
# --apply -o <file> is given.

VERSION="1.0.0"
PROG="silence-cutter"

THRESHOLD="-35dB"
MIN_DUR="0.8"
PADDING="0.15"
APPLY=0
OUT=""
EDL=""
JSON=0
INPUT=""

# ---------------------------------------------------------------- colors
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_GREEN=""; C_DIM=""; C_RESET=""
fi

err()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }

usage() {
  cat <<EOF
Usage: $PROG [options] <input>

Cut silent parts from an audio/video file using ffmpeg.
Default mode prints the cut plan only (dry-run); nothing is encoded.

Options:
  --threshold DB       silence threshold, e.g. -35dB (default: -35dB)
  --min-duration SEC   minimum silence length to cut (default: 0.8)
  --padding SEC        keep SEC seconds of silence around sound (default: 0.15)
  --apply -o FILE      encode the trimmed result to FILE
  -o, --output FILE    output file for --apply
  --edl FILE           also write cut ranges as an MPlayer EDL file
  --json               print the plan as JSON instead of a table
  --version            print version and exit
  --help               print this help and exit

Exit codes: 0 ok, 1 runtime error, 2 bad usage.
Respects NO_COLOR. Fully offline; requires ffmpeg and ffprobe.

Example:
  $PROG talk.mp3
  $PROG --threshold -40dB --min-duration 1.0 --apply -o talk-tight.mp3 talk.mp3
EOF
}

# ---------------------------------------------------------------- args
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold)    THRESHOLD="${2:?}"; shift 2 ;;
    --min-duration) MIN_DUR="${2:?}"; shift 2 ;;
    --padding)      PADDING="${2:?}"; shift 2 ;;
    --apply)        APPLY=1; shift ;;
    -o|--output)    OUT="${2:?}"; shift 2 ;;
    --edl)          EDL="${2:?}"; shift 2 ;;
    --json)         JSON=1; shift ;;
    --version)      printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
    --help|-h)      usage; exit 0 ;;
    --)             shift; [ $# -gt 0 ] && INPUT="$1" && shift; break ;;
    -*)             err "unknown option: $1"; usage >&2; exit 2 ;;
    *)              if [ -n "$INPUT" ]; then err "only one input file allowed"; exit 2; fi
                    INPUT="$1"; shift ;;
  esac
done

[ -n "$INPUT" ] || { err "no input file given"; usage >&2; exit 2; }
[ -r "$INPUT" ] || { err "input not found or not readable: $INPUT"; exit 2; }
if [ "$APPLY" -eq 1 ] && [ -z "$OUT" ]; then
  err "--apply needs an output file: --apply -o <file>"; exit 2
fi

# numeric validation
num_re='^[0-9]+(\.[0-9]+)?$'
[[ "$MIN_DUR" =~ $num_re ]] || { err "--min-duration must be a positive number (got: $MIN_DUR)"; exit 2; }
[[ "$PADDING" =~ $num_re ]] || { err "--padding must be a positive number (got: $PADDING)"; exit 2; }
[[ "$THRESHOLD" =~ ^-?[0-9]+(\.[0-9]+)?dB$ ]] || { err "--threshold must look like -35dB (got: $THRESHOLD)"; exit 2; }

# ---------------------------------------------------------------- deps
for bin in ffmpeg ffprobe; do
  command -v "$bin" >/dev/null 2>&1 || {
    err "$bin is required but not installed (https://ffmpeg.org/download.html)"; exit 1; }
done

# ---------------------------------------------------------------- probe
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$INPUT" 2>/dev/null) || DUR=""
[[ "$DUR" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { err "cannot read duration (not a media file?): $INPUT"; exit 1; }
HAS_AUDIO=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 -- "$INPUT" 2>/dev/null | head -1)
[ -n "$HAS_AUDIO" ] || { err "input has no audio stream: $INPUT"; exit 1; }
HAS_VIDEO=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 -- "$INPUT" 2>/dev/null | head -1)

# ---------------------------------------------------------------- detect silence
# Output: "start end" lines, one per silence (trailing silence ends at DUR).
mapfile -t SILENCES < <(
  ffmpeg -hide_banner -nostats -i "$INPUT" \
    -af "silencedetect=noise=${THRESHOLD}:d=${MIN_DUR}" \
    -f null - 2>&1 | awk -v dur="$DUR" '
      /silence_start:/ { s=$5; pending=1; next }
      /silence_end:/ && pending { printf "%.6f %.6f\n", s, $5; pending=0; next }
      END { if (pending) printf "%.6f %.6f\n", s, dur }
    '
)
FF_STATUS=${PIPESTATUS[0]}
[ "$FF_STATUS" -eq 0 ] || { err "ffmpeg failed while detecting silence"; exit 1; }

# ---------------------------------------------------------------- compute keep segments (awk does the float math)
# kept[] = complement of (silence shrunk by padding); cut[] = removed ranges.
PLAN=$(printf '%s\n' "${SILENCES[@]}" | awk -v dur="$DUR" -v pad="$PADDING" '
  function f(x){ return sprintf("%.6f", x) }
  BEGIN { n=0; m=0; cur=0 }
  NF==2 {
    s=$1+0; e=$2+0
    if (s<0) s=0; if (e>dur) e=dur
    cs=s+pad; ce=e-pad
    if (ce > cs) {
      if (cs > cur + 1e-6) { k0[n]=cur; k1[n]=cs; n++ }
      c0[m]=cs; c1[m]=ce; m++
      cur=ce
    }
    next
  }
  END {
    if (cur < dur - 1e-6) { k0[n]=cur; k1[n]=dur; n++ }
    cut=0
    for (i=0;i<m;i++) cut += (c1[i]-c0[i])
    printf "NKEPT=%d\n", n
    for (i=0;i<n;i++) printf "K %s %s\n", f(k0[i]), f(k1[i])
    printf "NCUT=%d\n", m
    for (i=0;i<m;i++) printf "C %s %s\n", f(c0[i]), f(c1[i])
    printf "CUTSEC=%.6f\nNEW=%.6f\n", cut, dur-cut
  }
')

NKEPT=$(printf '%s\n' "$PLAN" | awk '/^NKEPT=/{print substr($0,7)}')
CUTSEC=$(printf '%s\n' "$PLAN" | awk '/^CUTSEC=/{print substr($0,8)}')
NEW=$(printf '%s\n' "$PLAN" | awk '/^NEW=/{print substr($0,5)}')
NCUT=$(printf '%s\n' "$PLAN" | awk '/^NCUT=/{print substr($0,6)}')

# entirely silent?
ALL_SILENT=$(printf '%s\n' "${SILENCES[@]}" | awk -v dur="$DUR" '
  NF==2 && $1<=0.001 && $2>=dur-0.001 { yes=1 } END { print yes+0 }')
[ "$ALL_SILENT" -eq 1 ] && { err "input appears to be entirely silent (threshold $THRESHOLD)"; exit 1; }

# build aselect/select expression from kept segments
SEL_EXPR=$(printf '%s\n' "$PLAN" | awk '/^K /{printf "%sbetween(t,%s,%s)", (c++?"+":""), $2, $3}')

# ---------------------------------------------------------------- output: EDL
if [ -n "$EDL" ]; then
  printf '%s\n' "$PLAN" | awk '/^C /{printf "%s %s 0\n", $2, $3}' > "$EDL" \
    || { err "cannot write EDL file: $EDL"; exit 1; }
  info "wrote EDL: $EDL"
fi

# ---------------------------------------------------------------- output: JSON plan
if [ "$JSON" -eq 1 ]; then
  {
    printf '{\n'
    printf '  "input": "%s",\n' "$(printf '%s' "$INPUT" | sed 's/"/\\"/g')"
    printf '  "duration": %.3f,\n' "$DUR"
    printf '  "threshold": "%s",\n  "min_duration": %s,\n  "padding": %s,\n' \
      "$THRESHOLD" "$MIN_DUR" "$PADDING"
    printf '  "silences": ['
    printf '%s\n' "${SILENCES[@]}" | awk 'NF==2{printf "%s{\"start\": %.3f, \"end\": %.3f}", (NR==1?"":", "), $1, $2} END{print ""}'
    printf '],\n  "kept": ['
    printf '%s\n' "$PLAN" | awk '/^K /{printf "%s{\"start\": %.3f, \"end\": %.3f}", (c++?", ":""), $2, $3} END{print ""}'
    printf '],\n  "cut_seconds": %.3f,\n  "new_duration": %.3f\n}\n' "$CUTSEC" "$NEW"
  }
else
  # ---------------------------------------------------------- human table
  printf '%sCut plan for %s%s\n' "$C_BOLD" "$INPUT" "$C_RESET"
  printf '%sduration %.2f s, %d silence region(s) -> cut %.2f s (%.1f%%), new duration %.2f s%s\n' \
    "$C_DIM" "$DUR" "$NCUT" "$CUTSEC" \
    "$(awk -v c="$CUTSEC" -v d="$DUR" 'BEGIN{printf "%.1f", (d>0?100*c/d:0)}')" \
    "$NEW" "$C_RESET"
  if [ "$NCUT" -eq 0 ]; then
    printf 'no silence worth cutting with these settings.\n'
  else
    printf '\n  %s#  %sstart%s      %send%s        %sduration%s\n' \
      "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '%s\n' "$PLAN" | awk -v g="$C_GREEN" -v r="$C_RESET" '/^K /{
      printf "  %2d  %8.2f  %8.2f  %s%8.2f%s\n", ++i, $2, $3, g, $3-$2, r }'
  fi
  if [ "$APPLY" -eq 0 ]; then
    printf '\n%sdry-run: nothing was encoded. Add --apply -o <file> to cut.%s\n' \
      "$C_DIM" "$C_RESET"
  fi
fi

# ---------------------------------------------------------------- apply
if [ "$APPLY" -eq 1 ]; then
  info "encoding trimmed output -> $OUT ..."
  if [ -n "$HAS_VIDEO" ]; then
    ffmpeg -hide_banner -nostats -y -i "$INPUT" \
      -vf "select='${SEL_EXPR}',setpts=N/FRAME_RATE/TB" \
      -af "aselect='${SEL_EXPR}',asetpts=N/SR/TB" \
      -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
      -c:a aac -b:a 128k -- "$OUT" 2>/tmp/sc-ffmpeg.log || {
        err "ffmpeg encode failed:"; tail -5 /tmp/sc-ffmpeg.log >&2; exit 1; }
  else
    ffmpeg -hide_banner -nostats -y -i "$INPUT" \
      -af "aselect='${SEL_EXPR}',asetpts=N/SR/TB" \
      -c:a aac -b:a 128k -- "$OUT" 2>/tmp/sc-ffmpeg.log || {
        err "ffmpeg encode failed:"; tail -5 /tmp/sc-ffmpeg.log >&2; exit 1; }
  fi
  ODUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$OUT" 2>/dev/null)
  printf '%sdone: %s (%.2f s, was %.2f s)%s\n' "$C_GREEN" "$OUT" "$ODUR" "$DUR" "$C_RESET" >&2
fi

exit 0
