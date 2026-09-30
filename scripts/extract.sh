#!/usr/bin/env bash
set -euo pipefail

SAMPLE_RATE=48000

usage() {
  echo "usage:"
  echo "  $0 INPUT.mp4"
  exit 1
}

die() {
  echo "error: $*" >&2
  exit 1
}

if (($# != 1)); then
  usage
fi

INPUT="$1"

if [[ ! -f "$INPUT" ]]; then
  die "$INPUT not found"
fi

DIR="$(dirname "$INPUT")"
NAME="$(basename "$INPUT")"
STEM="${NAME%.*}"

AUDIO_OUTPUT="$DIR/${STEM}.wav"

echo "==> extracting audio"

ffmpeg -hide_banner -loglevel warning -y \
  -i "$INPUT" \
  -map 0:a:0 \
  -vn \
  -ar "$SAMPLE_RATE" \
  -c:a pcm_s16le \
  "$AUDIO_OUTPUT"

echo
echo "done:"
echo "  audio: $AUDIO_OUTPUT"
