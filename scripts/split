#!/usr/bin/env bash
set -euo pipefail

SAMPLE_RATE=48000
OUTPUT_FPS=30
VIDEO_WIDTH=1920
VIDEO_HEIGHT=1080

usage() {
  echo "usage:"
  echo "  $0 INPUT.mp4 WAV_DIRECTORY"
  exit 1
}

die() {
  echo "error: $*" >&2
  exit 1
}

if (($# != 2)); then
  usage
fi

INPUT="$1"
WAV_DIR="$2"

if [[ ! -f "$INPUT" ]]; then
  die "$INPUT not found"
fi

if [[ ! -d "$WAV_DIR" ]]; then
  die "$WAV_DIR is not a directory"
fi

command -v ffmpeg >/dev/null || die "ffmpeg not found"
command -v ffprobe >/dev/null || die "ffprobe not found"

# All WAV files, sorted naturally.
WAV_FILES=()

while IFS= read -r WAV; do
  WAV_FILES+=("$WAV")
done < <(
  find "$WAV_DIR" -maxdepth 1 -type f -iname '*.wav' |
    LC_ALL=C sort
)

if ((${#WAV_FILES[@]} == 0)); then
  die "no WAV files found in $WAV_DIR"
fi

echo "==> found ${#WAV_FILES[@]} WAV files"
echo

# --------------------------------------------------------------------
# Video information
# --------------------------------------------------------------------

VIDEO_DURATION="$(
  ffprobe -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT"
)"

SOURCE_FPS="$(
  ffprobe -v error \
    -select_streams v:0 \
    -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT"
)"

echo "input:"
echo "  video:       $INPUT"
echo "  source fps:  $SOURCE_FPS"
echo "  duration:    $VIDEO_DURATION sec"
echo "  target fps:  $OUTPUT_FPS"
echo

# --------------------------------------------------------------------
# Read WAV durations
# --------------------------------------------------------------------

TOTAL_SAMPLES=0

declare -a WAV_SAMPLES

for ((i = 0; i < ${#WAV_FILES[@]}; i++)); do
  WAV="${WAV_FILES[$i]}"
  WAV_NAME="$(basename "$WAV")"

  RATE="$(
    ffprobe -v error \
      -select_streams a:0 \
      -show_entries stream=sample_rate \
      -of default=noprint_wrappers=1:nokey=1 \
      "$WAV"
  )"

  if [[ "$RATE" != "$SAMPLE_RATE" ]]; then
    die "$WAV_NAME has sample rate ${RATE} Hz; expected ${SAMPLE_RATE} Hz"
  fi

  TIME_BASE="$(
    ffprobe -v error \
      -select_streams a:0 \
      -show_entries stream=time_base \
      -of default=noprint_wrappers=1:nokey=1 \
      "$WAV"
  )"

  if [[ "$TIME_BASE" != "1/${SAMPLE_RATE}" ]]; then
    die "$WAV_NAME has unexpected audio time base: $TIME_BASE"
  fi

  SAMPLES="$(
    ffprobe -v error \
      -select_streams a:0 \
      -show_entries stream=duration_ts \
      -of default=noprint_wrappers=1:nokey=1 \
      "$WAV"
  )"

  if [[ ! "$SAMPLES" =~ ^[0-9]+$ ]]; then
    die "could not determine exact sample count for $WAV_NAME (duration_ts=$SAMPLES)"
  fi

  WAV_SAMPLES[$i]="$SAMPLES"
  TOTAL_SAMPLES=$((TOTAL_SAMPLES + SAMPLES))

  printf "  %-32s %12d samples  %10.6f sec\n" \
    "$WAV_NAME" \
    "$SAMPLES" \
    "$(awk -v n="$SAMPLES" -v r="$SAMPLE_RATE" \
      'BEGIN { printf "%.6f", n / r }')"
done

echo
echo "audio total:"
echo "  samples: $TOTAL_SAMPLES"

AUDIO_DURATION="$(
  awk -v n="$TOTAL_SAMPLES" -v r="$SAMPLE_RATE" \
    'BEGIN { printf "%.9f", n / r }'
)"

echo "  duration: $AUDIO_DURATION sec"
echo

# --------------------------------------------------------------------
# Check total duration against video
# --------------------------------------------------------------------

DURATION_DIFF="$(
  awk -v a="$AUDIO_DURATION" -v v="$VIDEO_DURATION" \
    'BEGIN {
        d = a - v
        if (d < 0) d = -d
        printf "%.9f", d
      }'
)"

if ! awk -v d="$DURATION_DIFF" 'BEGIN { exit !(d <= 0.050) }'; then
  die "WAV total does not match video duration: audio=${AUDIO_DURATION}s video=${VIDEO_DURATION}s difference=${DURATION_DIFF}s"
fi

echo "duration check: OK"
echo "  difference: $DURATION_DIFF sec"
echo

# --------------------------------------------------------------------
# Output
# --------------------------------------------------------------------

# Each part is named after the WAV it was cut for, next to it, so the two
# stay coupled and can be renamed or deleted as a pair. ffmpeg's -y
# overwrites whatever is already there.
abspath() {
  (cd "$(dirname "$1")" && printf '%s/%s\n' "$PWD" "$(basename "$1")")
}

INPUT_ABS="$(abspath "$INPUT")"

for CANDIDATE in "${WAV_FILES[@]}"; do
  if [[ "$(abspath "${CANDIDATE%.*}.mp4")" == "$INPUT_ABS" ]]; then
    die "${CANDIDATE##*/} would overwrite the input video: $INPUT"
  fi
done

# --------------------------------------------------------------------
# Encode pieces
# --------------------------------------------------------------------

START_SAMPLE=0

for ((i = 0; i < ${#WAV_FILES[@]}; i++)); do
  SAMPLES="${WAV_SAMPLES[$i]}"
  WAV_NAME="$(basename "${WAV_FILES[$i]}")"

  END_SAMPLE=$((START_SAMPLE + SAMPLES))

  START_SEC="$(
    awk -v n="$START_SAMPLE" -v r="$SAMPLE_RATE" \
      'BEGIN { printf "%.9f", n / r }'
  )"

  DURATION_SEC="$(
    awk -v n="$SAMPLES" -v r="$SAMPLE_RATE" \
      'BEGIN { printf "%.9f", n / r }'
  )"

  PART=$((i + 1))
  OUTPUT="${WAV_FILES[$i]%.*}.mp4"

  echo "==> [$PART/${#WAV_FILES[@]}] $WAV_NAME"
  echo "    samples:  $START_SAMPLE -> $END_SAMPLE"
  echo "    start:    ${START_SEC}s"
  echo "    duration: ${DURATION_SEC}s"
  echo "    output:   $OUTPUT"

  ffmpeg -hide_banner -loglevel warning -y \
    -ss "$START_SEC" \
    -i "$INPUT" \
    -t "$DURATION_SEC" \
    -an \
    -vf "fps=${OUTPUT_FPS},scale=${VIDEO_WIDTH}:${VIDEO_HEIGHT}:force_original_aspect_ratio=decrease,pad=${VIDEO_WIDTH}:${VIDEO_HEIGHT}:(ow-iw)/2:(oh-ih)/2" \
    -c:v libx264 \
    -preset medium \
    -crf 18 \
    -pix_fmt yuv420p \
    -g 1 \
    "$OUTPUT"

  START_SAMPLE="$END_SAMPLE"

  echo
done

echo "done:"
echo "  parts: ${#WAV_FILES[@]} (next to the WAVs)"
