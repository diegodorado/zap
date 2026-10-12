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
- parallel playback: up to 8 independent orbits, each its own worker thread
  and decoder
- per-orbit regions: `x`, `y`, `size` place each voice's picture on the screen,
  so a video plays only inside its rectangle
- collection-based sample resolution: `s` names a directory, `n` names a
  clip inside it
- a named clip is opened once per orbit and reused by later triggers
- normalized slice playback (`begin` .. `end`), black where a slice ends
- `speed` playback rate, including negative values for reverse playback
- the window is black before the first frame, never a placeholder
- wall-clock `duration` cutoff
- an event naming a sample that does not exist is dropped without touching
  the picture
- exact-frame seeking: keyframe backward, then decode forward to the target
- persistent FFmpeg demuxer/decoder
- H.264 decoding
- resolution validation (exactly 1920x1080)
- 30 fps source contract, enforced as a hard failure
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

To play samples, point zap at a media directory:

    ./zig-out/bin/zap /Users/me/my-media

The media directory is mandatory and has no default, because without it
there is nothing for a `/play` to name.

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

    info(video): opened /path/clip.mp4: 1920x1080 @ 30.000 fps, duration=6.000s
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

    ./zig-out/bin/zap /Users/me/my-media

In another terminal:

    oscsend 127.0.0.1 9000 "/play" s "s" s "bd" s "begin" f 0.25 s "end" f 0.75
    oscsend 127.0.0.1 9000 "/play" s "s" s "bd" s "delta" f 0.25 s "legato" f 0.5
    oscsend 127.0.0.1 9000 "/play" s "s" s "bd" s "n" f 3 s "begin" f 0.5

Every `/play` is logged, and the worker logs the frame it actually landed
on, which is the thing worth checking:

    info: TRIGGER #1 s=bd n=0 begin=0.2500 end=0.7500 duration=0.000
    info: trigger #1 began at 3.000s / 4.000s, frame_pts=46080, latency=2.10ms

`begin=0.25` landing on 25% of the stream is the assertion that matters: if
that number is off, the seek is snapping to a keyframe instead of landing on
the requested frame.

If an event cannot take effect, the player says so at `warning` level, which
is visible in every build mode:

    warning: trigger #7: no collection "bd" in 'my-media'; event ignored
    warning: trigger #6: n=9 with no s; an index only means something inside a collection; event ignored

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
| `speed`  | `f`   | `1`     | playback rate or cycle/seconds count, per `unit` |
| `unit`   | `s`   | `r`     | how to read `speed`: `r`ate, `c`ycles, or `s`econds |
| `cps`    | `f`   | `0`     | tempo in cycles/sec, needed only for `unit c`     |
| `delta`  | `f`   | `0`     | event length in seconds                    |
| `legato` | `f`   | `1`     | length multiplier                          |
| `orbit`  | `i`   | `0`     | voice index in `0..7`; out of range is dropped |
| `x`      | `f`   | `0`     | region left edge, normalized (top-left origin) |
| `y`      | `f`   | `0`     | region top edge, normalized                |
| `size`   | `f`   | `1`     | region scale; 16:9 aspect is preserved     |

Every other key Tidal sends (`midichan`, `note`, `velocity`, `cc*`,
`octave`, ...) is fully read and thrown away. That matters: skipping the
*value* of an unrecognized key would leave the reader misaligned, and every
field after it would be garbage.

`duration` is never transmitted. It is derived, the way SuperDirt derives
it:

    duration = delta * legato

so a video slice lasts exactly as long as the grain it belongs to. A bare
`/play s "bd"` with no `delta` plays the whole slice.

Sending `/load`, `/seek` or `/speed` as an **address** does nothing. They are
gone. That is unrelated to the `speed` *key* on `/play`: playback rate is a
parameter of the event, not a separate message.

### Types

`i` (int32), `f` (float32) and `d` (float64) are all accepted for any
numeric key, because a sender's choice of width should not change behavior.
Only the key decides what a value means.

An optional 8-byte OSC timetag between the typetag string and the arguments
is recognized and skipped, using the OSC 1.0 test for an "immediate"
timetag: top bit of the seconds word clear, top bit of the fraction word
set. A packet without one parses identically.

### Orbits and regions

`orbit` is the voice that plays the event, in SuperDirt terms. zap runs up
to **8** orbits (`0..7`), each its own worker thread, decoder, and shared
frame mailbox. Orbits play the same or different clips at the same time,
each at its own position:

    /play s "s" s "bd"  s "orbit" i 1
    /play s "s" s "hhat" s "orbit" i 2

An `orbit` outside `0..7` does not exist, so the event is dropped before it
can change any state and the screen keeps its picture exactly as it was:

    warning: orbit 9 is out of range [0..7]; event ignored

`orbit` is an integer, never a float. Audio lives in SuperDirt; each video
orbit maps one-to-one onto a SuperDirt audio orbit, which is what keeps a
pattern's picture and its sound separate.

`x`, `y` and `size` place the orbit's picture on the 1920x1080 logical
canvas. `x`/`y` are the top-left corner in normalized coordinates and
`size` scales the whole frame, keeping the 16:9 aspect:

    /play s "s" s "bd" s "orbit" i 1 s "x" f 0.5 s "y" f 0.5 s "size" f 0.25

places a quarter-height, 16:9 window whose top-left is at the center of the
screen. The region is clamped to stay on screen (`x`/`y` first shrink to
`0..1 - size`, after `size` itself is clamped to `0..1`), so a region never
hangs off the edge.

Regions are **sticky per orbit**: they only move when an event carries
`x`/`y`/`size`, so a stream that positions itself once and then retriggers
with `s` alone keeps its place. When `orbit` is omitted, the event plays on
orbit 0 at full screen, so a single-clip zap behaves exactly as before.

### Resolving `s`

`s` names a **collection**, and a collection is a directory of clips inside
the media directory:

    my-media/
      my-sample-x/
        01.mp4
        02.mp4
      my-sample-y/
        01.mp4
        03.mp4
      my-sample-z/
        01.mp4

So `zap my-media` scans each subdirectory, and `s "my-sample-x"` plays from
that collection. `s` is only ever a collection name, never a path: a value
containing a `/` does not escape the media directory, it simply fails to
match a collection.

Omitting `s` reuses the clip that orbit already has loaded. A clip is opened
once **per orbit**; later events to the same orbit resolving to the same file
reuse the open decoder instead of re-reading it. The reuse cache is never
global: a global decoder can only serve one playhead, and two orbits may be
playing the same clip at different positions at the same time.

The scan happens once at startup, so a pattern firing many events a second
never pays for a directory walk, and a broken media directory is reported
when zap starts rather than at the first `/play`:

    info: media dir 'my-media': 3 collection(s), 4 clip(s)

A collection that does not resolve drops the whole event. The picture
currently on screen is left completely untouched, because half-applying a
mistyped event (restarting the current clip) is worse than doing nothing:

    warning: trigger #7: no collection "bd" in 'my-media'; event ignored
    warning: trigger #8: collection "bd" has no clips; event ignored

### `begin` and `end`

Both are normalized positions in `0..1` mapped onto that clip's stream
duration. They are not frame numbers.

`end` defaults to `1`, so an event with no `end` plays to the end of the
clip. Once a slice reaches `end`, that orbit's region goes **black** while
every other orbit keeps its own picture, and it stays black until the next
event for that orbit. There is no auto-loop, because looping on its own would
fight the pattern that drives zap.

A frozen last frame is not held on screen indefinitely. A still that outlives
its sample by a long stretch reads as a clip that is still running, which is
exactly the wrong thing to show between two notes. A short grace period is
different: see below.

The worker owns the "is there a picture" flag and the render loop only reads
it. The frame mailbox cannot answer that question, because its last frame is
still sitting in it either way.

`end` is a position and `duration` is a wall-clock cutoff, so whichever
arrives first wins.

#### The blackout grace period

When a slice ends, zap holds the last frame in that orbit's region for
**150 ms** before going black, and any event arriving inside that window
cancels the blackout. This exists
because an event always costs a seek: `begin` is a normalized position and
`begin`/`end` are only frame-exact when the source is all-intra (GOP=1), so a
larger seek means more decode time before the first frame of the new slice
reaches the region.

Without the grace, a dense pattern blacked out once per event, because the
slice finished, the region went black, and then the next event's seek took
long enough to miss the next display refresh. Measured over a 30-event pattern
with 5-15 ms seeks, the pre-fix build presented **12 black frames**; with the
grace it presents none, and the only blackout left is the final one after the
pattern actually stops.

So the rule reads: a clip that ends and is followed by more events never
blanks, and a clip that ends because the performance ended does. The regions
are black at startup, before any clip has played.

#### Reverse playback and `begin` / `end`

`speed` is negative, and `begin` is still where playback *starts*, so `end`
still has to be on the far side of the clip from it. Under reverse that means
`end < begin`, which is the same shape a forward event has:

    speed  1   begin 0.50  end 0.60    # forward, 0.50 -> 0.60
    speed -1   begin 0.50  end 0.40    # reverse, 0.60 -> 0.50

zap swaps `begin` and `end` internally when `speed` is negative, so the slice
still runs from `begin` down to `end` and `end` is still the bound. The
ordering on the wire is the one SuperDirt expects, and it is worth being
precise about where that comes from, because getting it wrong is what makes
reverse look broken rather than merely wrong:

`DirtEvent.orderTimeSpan` in SuperDirt does the same swap. So a real
SuperDirt/Tidal event carries `begin < end` even at `speed -1`, and zap has to
read it that way to stay in step with the audio. Sentences that only ever
arrive with `begin > end` are outside that contract.

One consequence is the default `begin 0, end 1` at `speed -1`: it is a
whole-clip reverse starting at the last frame. The last frame begins one frame
interval *before* the stream duration, so `1.0` is not a position a frame
occupies; seeking to it would ask for the first frame at or after the end of
the stream, find none, and fail with `EndOfStream`. zap clamps the normalized
seek to the final frame's timestamp instead, which is why the default reverse
case works at all.

### `speed` and `unit`

`speed` is a number the pattern sends and `unit` says what that number is. A
rate is the only reading that is position-independent; the other two depend on
the tempo and on the clip, so zap resolves them once the clip's duration is
known. Getting this wrong is not a small error in pacing, it is the whole
video running at the wrong speed while the audio is correct.

`unit "r"` (or `"rate"`, or no `unit` at all) — the default. `speed` is a
playback rate: 1 is the source frame rate, 2 is twice as fast.

    speed  2    twice as fast, every frame still shown
    speed  0.5  half speed, each frame held for two display refreshes
    speed -1    reverse, at the normal rate
    speed -2    reverse, twice as fast
    speed  0    hold the frame at `begin` and do not move

`unit "c"` — `speed` is a number of cycles the sample is stretched to fill:
`speed 2` fills half a cycle. The reading extends, so `speed 2` means the
sample is to fill `1/2` cycles and `speed 0.25` fills `4`. Fill time is
`(1 / speed) / cps` seconds, so the rate the clip must be played at is

    rate = duration_seconds * speed * cps

`loopAt` patterns are the main source of this, and they make the value easy to
misread. A real event (`speed 0.25`, `unit c`, `cps 0.5208333`, a 7.9 s clip)
fills `1/0.25 = 4` cycles = 7.68 s, so the rate is `7.9 * 0.25 * 0.5208333
= 1.0286` and the audio happens to agree: each 1/32 slice = 0.2469 s of
content takes exactly its 0.24 s `delta`. Zap that treated `0.25` as a rate
ran the picture four times slower than that audio.

`unit "s"` — `speed` is a wall-clock length in seconds the sample is stretched
to fill, so `rate = duration_seconds / speed`.

The rate always scales *time*, not the frame step. At rate 2 the timeline
covers twice as much content per second, so each frame is on screen half as
long and no frames are skipped. That is the difference between "plays faster"
and "plays a longer excerpt at the same speed", and only the first one is what
a `speed` parameter means.

`speed 0` is degenerate rather than fast. There is no direction to move in, so
zap holds the frame the event landed on for the length of the slice and warns
that it did so. It does not divide by it.

**Reverse costs a seek per displayed frame.** `av_read_frame` only walks
forward, so stepping back cannot be expressed as a decode: every step back is
a real seek plus an I-frame decode. The all-intra source contract is what makes
that affordable at all. On a GOP-encoded source each backward step would decode
forward from the previous keyframe, costing a whole GOP per displayed frame,
and reverse would be unusable in real time. This is the same reason `begin`
and `end` need GOP=1, seen from the other direction.

The frame mailbox has to be told which way time is moving before any frame is
published, because with two frames in flight it has to decide which one is the
*newer*. Forward, that is the largest timestamp; reverse, it is the smallest.
Picking by timestamp alone would pin the picture on the first frame of a
reverse slice.

Rates are clamped to `±8`. Past that the wall-clock interval per frame drops
below what one seek and one decode fit inside, and extra rate stops being
extra motion and starts being dropped frames. The clamp applies to the wire
value in `requestTrigger` and again to a rate a `unit` has derived, since a
long clip at a high tempo can otherwise imply a far faster rate than a value
of 8.

### `n`

`n` is the index of a clip **inside the collection named by `s`**, counting
that collection's `.mp4` files in sorted order. The two work together:

    /play s "s" s "my-sample-y"          # my-sample-y/01.mp4   (n defaults to 0)
    /play s "s" s "my-sample-y" s "n" f 1  # my-sample-y/03.mp4

Note the second one. The collection holds `01.mp4` and `03.mp4`, so index
`1` is `03.mp4`: the index counts the clips that are actually there, it is
not the number in the filename.

`n` is optional and defaults to `0`, so an event with no `n` and an event
with `n 0` are the same request, and both mean the first clip.

`n` is meaningless without `s`, because an index only means something
relative to a collection. Such an event is refused rather than guessed at,
and an event with neither `s` nor `n` keeps the current clip, which is what
makes a bare retrigger re-slice whatever is playing:

    warning: trigger #6: n=9 with no s; an index only means something inside a collection; event ignored

Indices are sorted by filename, so they are stable as long as the file set
is.

`n` wraps. It is a signed value and the index is taken modulo the number of
clips, so `n 100` in a 27-clip collection is clip 19, `n 27` is clip 0, and
`n -1` is the last clip:

    /play s "s" s "my-sample-y" s "n" f -1   # the last clip in the collection

The reason to wrap rather than refuse is that a collection's length is not
something the sender can know without reading the directory, and a live
pattern that indexes past the end is a normal consequence of that. Refusing
would drop those events outright. Clamping to the last clip would be worse
than wrapping: it is a silent substitution, so the event looks like it fired
while showing something the pattern never asked for. Wrapping at least keeps
every event visible and lets the wrap be audible against the SuperDirt voice.

`n 0` is not a wrap of the collection; it is the default and means "the first
clip", so a bare event with no `n` is unchanged.

---

# Input video contract

The current player expects:

- MP4
- H.264
- exactly 1920x1080
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
drifts against the audio, and drifting is far more confusing to debug than a
refusal, so zap rejects it:

    error(video): unsupported frame rate: 25.000 fps; zap only accepts
    30.0 fps (within 0.10), because the picture has to divide evenly into
    the display refresh. Re-encode it.

Resolution is checked the same way, against 1920x1080 exactly:

    error(video): unsupported resolution: 1440x1080; zap only accepts
    1920x1080

Both are checked before a decoder, a packet, or a frame mailbox is
allocated, so a clip that cannot play costs one demux and nothing else.

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
    round UP to the next frame boundary         (seek target)
          |
          v
    avformat_seek_file()      -> keyframe at or BEFORE that boundary
          |
          v
    avcodec_flush_buffers()
          |
          v
    decode forward, discarding frames, until pts >= exact target
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

A normalized position is a fraction of the stream *duration*, so it almost
never lands on a frame boundary, and the first frame at or after it is one
frame *later*. Seeking straight to such a target lands on the frame before
it, which then has to be decoded and thrown away before the real frame is
decoded too. On all-I that is a wasted decode of a full 1080p I-frame and a
wasted read of it, which is the largest single cost in a seek. The seek
therefore rounds the target up to the next frame boundary, while the frame
that is accepted is still the first one at or after the exact target. Both
pick the same frame, so the output is unchanged, but an all-I source now
decodes and reads exactly one I-frame per seek instead of two. On a 417MB
all-I 1080p30 clip that moved seek latency from a 21.2ms median to 6.7ms,
and the worst case from 36.7ms to 8.8ms.

The comparison deliberately stays on the exact target. Rounding that up too
would make a seek near the end of the file ask for a frame that does not
exist and fail with `error.EndOfStream`; instead, `begin=1.0` already fails
that way, because normalized `1.0` is the stream duration and the last frame
starts one frame before it.

---

# Pacing

The video worker paces frames against an absolute deadline derived from the
frame timestamps, not by sleeping a fixed amount after each decode:

    deadline_ns += (next_pts - previous_pts) / speed

Slewing the deadline and re-syncing on drift keeps a slow decode from
permanently shifting the timeline. The earlier implementation slept the
measured frame interval *after* decoding, so decode time was added to every
frame: the same 25 fps source ran at 19-20 fps with 49-53ms frame periods
while the decoder was never actually late and the mailbox never dropped a
frame. With deadline pacing the same file runs at 25.0-25.4 fps with
39.9-40.1ms periods.

The step is a magnitude, so the same formula paces both directions: the sign
of `speed` only says which way the mailbox was told time is moving. A
forward-only test on the step would leave reverse playback unthrottled,
spinning as fast as the decoder could manage.

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

The renderer uses one texture per orbit:

    AVFrame Y/U/V   (orbit 0)
          |
          v
    small CPU frame mailbox
          |
          v
    SDL IYUV texture        ...one per orbit
          |
          v
    SDL renderer
          |
          v
    display

The mailbox avoids allocating a new 1080p buffer for every frame, every
source is 1920x1080, and every orbit's SDL texture is allocated once at
startup and never resized. The backbuffer is cleared once per refresh and
each showing orbit copies its texture into its region's rectangle; an orbit
that ended simply stops drawing, so exactly its region goes black without
erasing any other orbit's picture.

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

    my-media/bd/01.mp4  -> zap
    my-media/bd/01.wav  -> SuperDirt

A `/play s "bd" s "n" f 0 ...` event tells SuperDirt to play `01.wav` and
tells zap to show the matching slice of `01.mp4`. Both are driven by the same clock, so
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
