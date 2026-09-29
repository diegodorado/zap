# zap

Small, low-latency OSC-controlled macOS video player written in Zig.

The intended use is live audiovisual performance with TidalCycles or another
OSC source.

This is intentionally NOT a general-purpose media player.

## Current status

### Implemented

- Zig implementation
- SDL3 window and rendering
- OSC UDP receiver
- `/play` single-event trigger: SuperDirt key/value pairs, any order
- sample-name resolution against a media directory (`--media`)
- a named clip is opened once and reused by later triggers
- normalized slice playback (`begin` .. `end`) with the last frame held
- wall-clock `duration` cutoff
- an event naming a sample that does not exist is dropped without touching
  the picture
- exact-frame seeking: keyframe backward, then decode forward to the target
- persistent FFmpeg demuxer/decoder
- H.264 decoding
- resolution validation (any even size up to 3840x2160)
- 30 fps source contract, enforced with a warning
- fixed-FPS metadata
- decoder flushing after seek
- absolute-deadline frame pacing
- planar YUV420P presentation
- two-slot decoded-frame mailbox
- vsync-locked presentation
- benchmark mode
- benchmark min/median/p95/max reporting
- explicit resource cleanup

### Known gaps

- There are no automated tests and no `zig build test` step. Everything
  listed above is verified by hand; see "Verification".
- `/play` is the only OSC address. There is no keyboard control in the SDL
  window other than quitting.
- Audio is not handled here at all. SuperDirt plays the matching WAV; see
  "Audio".
- Debug-level logs are compiled out in `-Doptimize=ReleaseFast`. Only
  `info` and `warning` are visible in a release build.

### Not implemented yet

- VideoToolbox hardware decoding
- reverse playback
- frame-accurate presentation scheduling
- GPU-native VideoToolbox -> Metal texture path
- configuration files
- playlists
- effects

---

# Requirements

Primary target:

- macOS
- Apple Silicon
- Zig 0.17.0-dev
- Homebrew

The code targets the Zig 0.17.0 development series (developed against
0.17.0-dev.1099+7db2ef610). It uses the `std.Io` interfaces introduced in
0.17: `std.Io.Mutex` for the mailbox and player state, and
`Io.sleep` / `Clock.now` for pacing and timing. It will not build on 0.16.

Install dependencies:

    brew install zig
    brew install sdl3
    brew install ffmpeg

Optional, for sending OSC by hand:

    brew install liblo   # provides oscsend

Verify:

    zig version
    brew --prefix sdl3
    brew --prefix ffmpeg

The default build assumes Apple Silicon Homebrew:

    /opt/homebrew

That prefix is hardcoded as `brew_prefix` in `build.zig`. There is no
`-Dbrew-prefix` build option. On an Intel Homebrew installation, change
`brew_prefix` in `build.zig` to `/usr/local` before building.

---

# Build

Release build:

    zig build -Doptimize=ReleaseFast

Debug build:

    zig build

Run:

    zig build run

or:

    ./zig-out/bin/zap

To load a video immediately:

    zig build run -- /Users/me/Videos/clip01.mp4

The executable can also be invoked directly:

    ./zig-out/bin/zap /Users/me/Videos/clip01.mp4

To play samples by name from a media directory:

    ./zig-out/bin/zap --media /Users/me/Videos

The directory is searched for `<name>.mp4` when a `/play` event omits a
path. It defaults to `media`.

---

# Verification

There is no automated test suite yet. The two checks below cover the parts
that actually break: the FFmpeg/SDL path, and the OSC control path.

## 1. Headless: seek benchmark

This does not open a window. It exercises demux, seek, decode, frame
mailbox and the monotonic clock:

    zig build -Doptimize=ReleaseFast
    ./zig-out/bin/zap --benchmark /Users/me/Videos/clip01.mp4

Expected shape:

    info(video): opened ...: 1920x1080, fps=30.000, duration=...
    Results: seek -> decoded target frame
         min: 1.2 ms
      median: 12.0 ms
         p95: 20.2 ms
         max: 21.5 ms

It performs 100 deterministic pseudo-random seeks (fixed seed, so runs are
comparable). Targets are clamped to 95% of the file, because a seek past
the last decodable frame has nothing to decode and yields
`error.EndOfStream`; any such sample is skipped and reported as `skipped=N`
rather than being folded into the percentiles.

## 2. Live: OSC control

Start the player against a media directory, then drive it:

    ./zig-out/bin/zap --media /Users/me/Videos

In another terminal:

    oscsend 127.0.0.1 9000 "/play" s "s" s "clip01" s "begin" f 0.25 s "end" f 0.75
    oscsend 127.0.0.1 9000 "/play" s "s" s "clip01" s "delta" f 0.25 s "legato" f 0.5
    oscsend 127.0.0.1 9000 "/play" s "n" f 0 s "begin" f 0.5

Every `/play` is logged, and the worker logs the frame it actually landed
on, which is the thing worth checking:

    info: TRIGGER #1 s=clip01 begin=0.2500 end=0.7500 n=null duration=0.000
    info: trigger #1 began at 3.000s / 4.000s, frame_pts=46080, latency=2.10ms

`begin=0.25` landing on 25% of the stream is the assertion that matters: if
that number is off, the seek is snapping to a keyframe instead of landing on
the requested frame.

If an event cannot take effect, the player says so at `warning` level, which
is visible in every build mode:

    warning: trigger #7: s "bd" n=null is not in 'media'; event ignored
    warning: trigger #6: n=9 is past the end of 'media'; event ignored

A quiet log after a command means the packet never arrived. Check that the
sender targets UDP 9000 on the same host.

Note that `oscsend` requires an explicit type tag before every value,
including the key strings, so an event is verbose to type by hand. A bare
number is silently not sent at all, and the event arrives with fewer
arguments than you wrote. For anything beyond a smoke test, send from Tidal
or a small script rather than by hand.

---

# OSC

OSC listens on:

    UDP 9000

The port is hardcoded, so only one zap instance can bind it at a time.

### Wire format

Argument values are decoded per the OSC 1.0 specification: `int32`,
`float32` and `float64` are **big-endian**. This is the opposite of the host
byte order on Apple Silicon, so a decoder must byte-swap explicitly. Getting
this wrong does not fail loudly, it produces silently wrong positions.

## /play

The only address zap answers. It carries one grain: which sample, which slice
of it, which occurrence, and how long it lasts.

Fields are sent as **key/value pairs in any order**, exactly as SuperDirt
receives them. Each pair is a string key followed by a value whose type is
part of the typetag string:

    /play s "s" s "bd3" s "begin" f 0.2 s "end" f 0.4 s "delta" f 0.5

zap reads these keys:

| key      | type  | default | meaning                                    |
|----------|-------|---------|--------------------------------------------|
| `s`      | `s`   | none    | sample name or path; omit to reuse the clip |
| `begin`  | `f`   | `0`     | normalized start position                  |
| `end`    | `f`   | `1`     | normalized end position                    |
| `n`      | `f`   | `0`     | sample number; only > 0 selects by index   |
| `delta`  | `f`   | `0`     | event length in seconds                    |
| `legato` | `f`   | `1`     | length multiplier                          |

Every other key Tidal sends (`cps`, `midichan`, `note`, `velocity`,
`cc*`, `octave`, ...) is fully read and thrown away. That matters: skipping
the *value* of an unrecognized key would leave the reader misaligned, and
every field after it would be garbage.

`duration` is never transmitted. It is derived, the way SuperDirt derives
it:

    duration = delta * legato

so a video slice lasts exactly as long as the grain it belongs to. A bare
`/play s "bd"` with no `delta` plays the whole slice.

Sending `/load`, `/seek` or `/speed` does nothing. They are gone.

### Types

`i` (int32), `f` (float32) and `d` (float64) are all accepted for any
numeric key, because a sender's choice of width should not change behavior.
Only the key decides what a value means.

An optional 8-byte OSC timetag between the typetag string and the arguments
is recognized and skipped, using the OSC 1.0 test for an "immediate"
timetag: top bit of the seconds word clear, top bit of the fraction word
set. A packet without one parses identically.

### Resolving `s`

If `s` contains a `/` or ends in `.mp4` it is treated as a path. Otherwise
it is a sample name looked up in the media directory (`--media`, default
`media`) as `<name>.mp4`.

Omitting `s` reuses the clip that is already loaded. A clip is opened once;
later events naming the same sample reuse the open decoder instead of
re-reading the file.

A sample name that does not resolve drops the whole event. The picture
currently on screen is left completely untouched, because half-applying a
mistyped event (restarting the current clip) is worse than doing nothing:

    warning: trigger #7: s "bd" n=null is not in 'media'; event ignored

### `begin` and `end`

Both are normalized positions in `0..1` mapped onto that clip's stream
duration. They are not frame numbers.

`end` defaults to `1`, so an event with no `end` plays to the end of the
clip. Once the slice reaches `end` the last frame is held until the next
event. There is no auto-loop: a sample plays its slice once and waits,
because looping on its own would fight the pattern that drives zap.

`end` is a position and `duration` is a wall-clock cutoff, so whichever
arrives first wins.

### `n`

`n` is an absolute sample number: the index of a file in the media
directory, counting `.mp4` files in sorted order.

    /play s "n" f 0 f "begin" f 0 s "n" f 3    # the 4th .mp4

`n` is optional and defaults to `0`, so an event with no `n` and an event
with `n 0` are the same request.

`n` addresses a file directly, so it makes a name redundant: **when `n` is
greater than 0, `s` on the same event is ignored.** A real SuperDirt event
carries both, which is fine, because zap only needs the number.

`0` selects nothing, because it is SuperDirt's own default and Tidal sends
`n` on every event. Treating 0 as "the first file" would make every event
resolve to the first clip in the directory and the name would never be
used. So 0 leaves the name in charge.

The listing is sorted, so index `0` is the alphabetically first `.mp4` in
the media directory and indices are stable as long as the file set is. An
index past the end of the listing is refused, never clamped, because
silently playing the last file would look like a working event while
showing the wrong clip:

    warning: trigger #6: n=9 is past the end of 'media'; event ignored

---

# Input video contract

The current player expects:

- MP4
- H.264
- any even resolution up to 3840x2160 (1080p and 1440x1080 both work)
- progressive
- fixed frame rate, 30 fps
- YUV420P decoder output
- local SSD
- normal monotonic timestamps
- preferably GOP=1 / all-I

The player does not attempt to support arbitrary video formats.

There is no transcoding pipeline.

Unsupported inputs are rejected rather than silently converted.

### Why 30 fps

Two reasons, and the second is the one that makes the picture look wrong.

The prepared sources are normalized to 30 fps so the picture stays aligned
with the SuperDirt clock driving the matching WAV. A clip at another rate
still plays, but it drifts against the audio, which is far more confusing
than a refusal, so zap warns loudly instead of rejecting it:

    warning: bd.mp4 runs at 25.000 fps, not 30.0 fps: it will drift against
    the SuperDirt clock. Re-encode it to 30 fps.

The display refresh is the other reason. Presentation is vsync-locked, so
every source frame is shown for a whole number of display refreshes. On a
60 Hz display, 30 fps divides evenly: every frame is shown exactly twice,
and the motion is perfectly even. 25 fps does not divide evenly (2.4
refreshes per frame), so frames are held for 2 refreshes and then 3 in an
alternating pattern, which reads as a stutter even when nothing is
actually dropping. Measured on a 25 fps source: the worker publishes a
correct 25 fps, the renderer takes a correct 25 fps, and the result still
judders, because 60 is not a multiple of 25.

Pacing itself is always driven by the stream's own frame timestamps, not by
a hardcoded frame duration, so a 29.97 (30000/1001) source is accepted and
plays correctly.

---

# Seeking architecture

A loaded video owns:

- AVFormatContext
- AVCodecContext
- AVPacket
- AVFrame

The decoder stays open.

A seek performs:

    normalized position
          |
          v
    stream timestamp
          |
          v
    avformat_seek_file()      -> keyframe at or BEFORE the target
          |
          v
    avcodec_flush_buffers()
          |
          v
    decode forward, discarding frames, until pts >= target
          |
          v
    frame mailbox
          |
          v
    SDL YUV texture

The demuxer flag matters. `AVSEEK_FLAG_ANY` lets it return a later
keyframe, which silently shifts the landing point by up to a full GOP; on a
30 fps GOP-30 file, `begin=0.25` on a 6 second clip landed at 2.0s instead
of 1.5s. Since `begin` and `end` are slice boundaries, that error is
audible as the wrong footage, not just as latency. Seeking backward to the
containing keyframe and decoding forward lands on the exact frame.

The cost of that correctness is decoding the frames between the keyframe and
the target, so seek latency is proportional to GOP length. On all-I sources
(GOP=1) it is a single frame, which is why the intended source material is
GOP=1 / all-I. On a GOP-30 clip the extra cost measured 1.4ms to 14ms.

---

# Pacing

The video worker paces frames against an absolute deadline derived from the
frame timestamps, not by sleeping a fixed amount after each decode:

    deadline_ns += next_pts - previous_pts

Slewing the deadline and re-syncing on drift keeps a slow decode from
permanently shifting the timeline. The earlier implementation slept the
measured frame interval *after* decoding, so decode time was added to every
frame: the same 25 fps source ran at 19-20 fps with 49-53ms frame periods
while the decoder was never actually late and the mailbox never dropped a
frame. With deadline pacing the same file runs at 25.0-25.4 fps with
39.9-40.1ms periods.

Because the source is 30 fps and the display is 60 Hz, two frames are
presented per display refresh.

---

# Thread model

Current implementation:

    Main thread
        SDL events
        rendering

    OSC thread
        UDP
        OSC parsing
        control requests

    Video worker
        loading
        FFmpeg demux
        decoding
        seeking

There is no audio thread, because zap does not decode or output audio.

OSC never directly accesses FFmpeg objects.

---

# Frame mailbox

The video worker publishes frames through a two-slot mailbox.

The renderer owns a slot while uploading it to SDL.

If the renderer falls behind, an older ready frame can be replaced by a newer
one.

The design intentionally favors low latency over displaying every decoded
frame.

---

# Benchmark

Run:

    zig build -Doptimize=ReleaseFast

Then:

    ./zig-out/bin/zap --benchmark /Users/me/Videos/clip01.mp4

The benchmark performs 100 deterministic random seeks.

It measures:

    seek requested
        |
        v
    demuxer repositioned
        |
        v
    target frame decoded

It reports:

    min
    median
    p95
    max

Display/vsync latency is intentionally excluded.

See "Verification" for the full expected output, including the `skipped=N`
count for seek targets with no decodable frame behind them.

---

# Current decoder

The first decoder backend is software FFmpeg H.264.

The intended future architecture is:

    VideoDecoder
        |
        +-- FFmpeg software
        |
        +-- VideoToolbox

The current code deliberately does not pretend that VideoToolbox is already
implemented.

---

# Rendering

Decoded H.264 frames are currently expected to arrive as YUV420P.

The renderer uses:

    AVFrame Y/U/V
          |
          v
    small CPU frame mailbox
          |
          v
    SDL IYUV texture
          |
          v
    SDL renderer
          |
          v
    display

The mailbox avoids allocating a new 1080p buffer for every frame.

Presentation is vsync-locked: `SDL_SetRenderVSync(renderer, 1)`, and the
main loop has no sleep of its own, because `SDL_RenderPresent` already
blocks until the next display refresh. Measured on a 30 fps source the loop
runs at exactly 60 iterations per second, taking a new frame 30 times per
second.

This is load-bearing, not a nicety. Without it `SDL_RenderPresent` returns
immediately, the loop runs at ~140 Hz, and the same frame is re-uploaded
into the streaming texture and presented four or five times per refresh.
That is what the picture flickers.

The draw runs on **every** refresh, not only when a new frame has been
decoded. SDL does not preserve the render target across `SDL_RenderPresent`,
so presenting without redrawing shows an undefined backbuffer. On a 30 fps
source with a 60 Hz display that is half of all refreshes, which flickers at
30 Hz even though the frame rate is correct. The texture is the durable copy,
so the texture is redrawn on every refresh and the upload stays on the
update path.

The next optimization target is eliminating the CPU copy when using
VideoToolbox/Metal.

---

# Audio

zap has no audio path. It does not decode, mix, or output sound, and it does
not synchronize video to an audio clock.

Audio is SuperDirt's job. The intended workflow is a prepared pair per
sample:

    media/bd.mp4      -> zap
    media/bd.wav      -> SuperDirt

A `/play s "bd" ...` event tells SuperDirt to play `bd.wav` and tells zap to
show the matching slice of `bd.mp4`. Both are driven by the same clock, so
zap only has to be correct about *which* frames to show and *when* each slice
starts, not about sample-accurate A/V alignment.

This is why sources are normalized to 30 fps and 48 kHz: the 48 kHz half
matters to the WAV and to SuperDirt, and zap deliberately ignores the
container's audio track entirely.

Keeping audio out of zap removes the hardest real-time constraint from the
project: a CoreAudio render callback that must never allocate, block, or
lock. There is no such callback here.

---

# Architecture decisions to revisit after benchmarking

The first benchmark should answer:

1. How fast is avformat_seek_file() on the actual MP4 files?
2. How fast is software H.264 decode of a single 1080p I-frame?
3. How much time is spent copying YUV planes?
4. How much time is spent uploading the texture?
5. How much latency is introduced by SDL presentation/vsync?
6. Does VideoToolbox materially reduce seek-to-frame latency?
7. Can VideoToolbox output be passed to Metal/SDL with fewer copies?

Do not optimize these before measuring them.

---

# Future VideoToolbox milestone

The intended next implementation is:

    MP4
      |
      v
    FFmpeg demux
      |
      v
    H.264 packet
      |
      v
    VideoToolbox
      |
      v
    CVPixelBuffer
      |
      v
    Metal / SDL
      |
      v
    display

The software decoder remains useful as a reference implementation and
benchmark baseline.

---

# Future audio milestone

None, by design. Audio belongs to SuperDirt.

If zap ever needs to know where the sound actually is (for example to
compensate for output latency), the right move is to have SuperDirt send
that information over OSC rather than to reintroduce a decoder and a
real-time audio callback.

---

# Important performance principle

Do not assume that a more complicated architecture is faster.

The intended development sequence is:

1. establish working software decoder
2. benchmark 100 random seeks
3. measure each stage
4. implement VideoToolbox
5. benchmark again
6. remove measured bottlenecks
7. only then introduce more complicated GPU/audio synchronization
