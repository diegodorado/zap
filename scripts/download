#!/usr/bin/env bash
set -euo pipefail

URL="$1"

if [[ ! "$URL" ]]; then
  die "$URL not found"
fi

yt-dlp \
  -f "bv*[height<=1080][vcodec^=avc1][ext=mp4]+ba[acodec^=mp4a][ext=m4a]" \
  --merge-output-format mp4 \
  --embed-metadata \
  --restrict-filenames \
  "$URL"
