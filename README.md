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
- `/load`
- `/n`
- `/seek`
- `/speed`
- asynchronous video loading
- persistent FFmpeg demuxer/decoder
- H.264 decoding
- 1920x1080 validation
- fixed-FPS metadata
- normalized position seeking
- decoder flushing after seek
- obsolete seek requests collapse to the newest request
- a seek issued before or while a video loads is held and applied on load
- planar YUV420P presentation
- two-slot decoded-frame mailbox
- basic playback timing
- arbitrary random seeking
- playback wraps to the beginning at end of file
- benchmark mode
- benchmark min/median/p95/max reporting
- explicit resource cleanup

### Known gaps

- There are no automated tests and no `zig build test` step. Everything
  listed above is verified by hand; see "Verification".
- `/load`, `/n`, `/seek` and `/speed` are the only inputs. There is no
  keyboard control in the SDL window other than quitting.
- Debug-level logs are compiled out in `-Doptimize=ReleaseFast`. Only
  `info` and `warning` are visible in a release build.

### Not implemented yet

- VideoToolbox hardware decoding
- CoreAudio audio decoding/output
- audio clock
- A/V synchronization
- variable playback-speed audio
- reverse playback
- frame-accurate presentation scheduling
- GPU-native VideoToolbox -> Metal texture path
- advanced GOP validation
- configuration files
- playlists
- effects

The first milestone deliberately concentrates on the video path.

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

Start the player with a video, then drive it:

    ./zig-out/bin/zap /Users/me/Videos/clip01.mp4

In another terminal:

    oscsend 127.0.0.1 9000 "/seek" f 0.5
    oscsend 127.0.0.1 9000 "/speed" f 0.0     # pause
    oscsend 127.0.0.1 9000 "/speed" f 2.0
    oscsend 127.0.0.1 9000 "/n" i 0

`/seek` and `/speed` are logged as `debug`, which is compiled out of
release builds. In a release build, confirm control with the `info` line
the video worker emits when a seek is actually applied:

    info: SEEK request=1 position=0.500000 frame_pts=46080 latency_ms=3.549

If a command cannot take effect, the player says so at `warning` level,
which is visible in every build mode:

    warning: seek 0.5000 held: no active video; it will apply once one is loaded
    warning: N 5 ignored: no loaded video at that index

A quiet log after a command means the packet never arrived. Check that the
sender targets UDP 9000 on the same host.

---

# OSC

OSC listens on:

    UDP 9000

All video indexes are zero-based.

### Wire format

Argument values are decoded per the OSC 1.0 specification: `int32` and
`float32` are **big-endian**. This is the opposite of the host byte order
on Apple Silicon, so a decoder must byte-swap explicitly. Getting this
wrong does not fail loudly, it produces silently wrong positions.

## /load

Load a video asynchronously.

    /load "path/to/video.mp4"

Example:

    /load "/Users/me/Videos/clip01.mp4"

The file is opened and its decoder remains alive.

---

## /n

Select an already loaded video.

    /n 0
    /n 1
    /n 2

Indexing is zero-based.

Only the active video is decoded.

An index with no loaded video behind it is refused, and the refusal is
logged:

    warning: N 5 ignored: no loaded video at that index

---

## /seek

Seek using normalized media position.

    /seek 0.0
    /seek 0.5
    /seek 0.95
    /seek 1.0

The value is NOT a frame number.

It is mapped onto the video's actual stream duration.

Rapid seeks collapse to the newest request.

For example:

    /seek 0.1
    /seek 0.8
    /seek 0.3
    /seek 0.95

will not intentionally decode all four targets.

A seek that arrives when no video is active is not dropped. It stays
pending and is applied as soon as a video is active, so this ordering is
well defined and is the normal way to script a load and a jump together:

    /seek 0.5
    /load "/Users/me/Videos/clip01.mp4"

Both orders work. Sending `/load` and `/seek` in quick succession is safe
even though opening and finding stream info take tens of milliseconds,
which is longer than the gap between two OSC packets.

---

## /speed

Playback speed:

    /speed 1.0

normal playback

    /speed 0.5

half speed

    /speed 2.0

double speed

    /speed 0.0

pause

Negative playback is currently rejected with a warning.

`speed` and `playing` are player state, not per-video state, so a speed
set before a video is loaded applies to whatever loads next.

Audio speed behavior is not currently applicable because the CoreAudio
backend is not implemented yet.

---

# Input video contract

The current player expects:

- MP4
- H.264
- 1920x1080
- progressive
- fixed frame rate
- YUV420P decoder output
- local SSD
- normal monotonic timestamps
- preferably GOP=1 / all-I

The player does not attempt to support arbitrary video formats.

There is no transcoding pipeline.

Unsupported inputs are rejected rather than silently converted.

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
    avformat_seek_file()
          |
          v
    avcodec_flush_buffers()
          |
          v
    decode target frame
          |
          v
    frame mailbox
          |
          v
    SDL YUV texture

Because the intended source material is GOP=1, there should be no need to
decode a preceding GOP to reach the target frame.

The benchmark is intended to determine whether that assumption actually gives
the desired latency on the target files.

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

Audio is currently only a stub.

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

The next optimization target is eliminating the CPU copy when using
VideoToolbox/Metal.

---

# Audio

Audio is currently a stub.

The intended architecture is:

    FFmpeg audio decoder
          |
          v
    small PCM ring buffer
          |
          v
    CoreAudio callback

The callback must remain real-time safe.

It must not:

- allocate
- perform file I/O
- call FFmpeg demuxing
- perform expensive locking
- process OSC

Once implemented, the audio clock should become the primary normal-playback
clock.

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

After video seeking is benchmarked:

    MP4
      |
      +--> video
      |
      +--> audio

Audio will maintain its own decoder and small PCM queue.

Seeking will invalidate both queues and reposition both streams to the same
media timestamp.

The audio clock will then drive normal video presentation timing.

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
