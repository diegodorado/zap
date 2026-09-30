#!/usr/bin/env bash
set -euo pipefail

for f in *.mp4; do
  printf '%-45s ' "$f"
  ffprobe -v error \
    -show_entries stream=codec_type,codec_name,width,height,avg_frame_rate,duration,bit_rate,nb_frames,sample_rate,channels \
    -of json "$f" |
    jq -r '
    .streams |
    (map(select(.codec_type=="video"))[0]) as $v |
    (map(select(.codec_type=="audio"))[0]) as $a |
    "\($v.width)x\($v.height) " +
    "\((($v.avg_frame_rate|split("/")[0]|tonumber) / ($v.avg_frame_rate|split("/")[1]|tonumber)) | tostring | .[0:6]) fps " +
    "\($v.duration)s " +
    "\($v.codec_name) " +
    "\((($v.bit_rate // "0")|tonumber)/1000|floor)kb/s " +
    "\($v.nb_frames // "?") frames " +
    "\($a.codec_name // "no-audio") \($a.sample_rate // "")Hz \($a.channels // "")ch"
  '
done
