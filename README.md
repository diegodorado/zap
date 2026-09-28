# zigvideo

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
- planar YUV420P presentation
- two-slot decoded-frame mailbox
- basic playback timing
- arbitrary random seeking
- benchmark mode
- benchmark min/median/p95/max reporting
- explicit resource cleanup

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
- Zig 0.16.0
- Homebrew

Zig 0.16.0 is the intended compiler version.

Install dependencies:

    brew install zig
    brew install sdl3
    brew install ffmpeg

Verify:

    zig version
    brew --prefix sdl3
    brew --prefix ffmpeg

The default build assumes Apple Silicon Homebrew:

    /opt/homebrew

For Intel Homebrew:

    zig build -Dbrew-prefix=/usr/local

---

# Build

Release build:

    zig build -Doptimize=ReleaseFast

Debug build:

    zig build

Run:

    zig build run

or:

    zig-out/bin/zigvideo

To load a video immediately:

    zig build run -- /Users/me/Videos/clip01.mp4

The executable can also be invoked directly:

    ./zig-out/bin/zigvideo /Users/me/Videos/clip01.mp4

---

# OSC

OSC listens on:

    UDP 9000

All video indexes are zero-based.

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

Negative playback is currently rejected.

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

    ./zig-out/bin/zigvideo --benchmark /Users/me/Videos/clip01.mp4

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
