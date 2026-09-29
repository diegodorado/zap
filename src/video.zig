const std = @import("std");
const c = @import("c");

const util = @import("util.zig");

const log = std.log.scoped(.video);

/// The source contract. Every clip zap accepts is exactly 1920x1080 at 30 fps,
/// because that is what the SuperDirt clock expects and what divides evenly
/// into a 60 Hz refresh. Anything else is rejected instead of played wrong.
pub const frame_width: usize = 1920;
pub const frame_height: usize = 1080;

const uv_width: usize = frame_width / 2;
const uv_height: usize = frame_height / 2;

/// Plane strides, which are fixed because the frame size is fixed. The mailbox
/// copies planes tightly packed, so the stride is simply the row length.
pub const luma_pitch: i32 = @intCast(frame_width);
pub const chroma_pitch: i32 = @intCast(uv_width);

const y_size: usize = frame_width * frame_height;
const uv_size: usize = uv_width * uv_height;

/// 29.97 (30000/1001) is the NTSC flavour of 30 and stays inside this window.
const expected_fps: f64 = 30.0;
const fps_tolerance: f64 = 0.1;

pub const FrameMeta = struct {
    pts: i64,
    position_seconds: f64,
};

pub const FrameHandle = struct {
    y: []const u8,
    u: []const u8,
    v: []const u8,

    luma_pitch: i32,
    chroma_pitch: i32,

    meta: FrameMeta,

    /// The mailbox this frame was taken from. Carrying it means a release
    /// cannot land in a different clip's mailbox when a trigger switches the
    /// active video between take and release.
    owner: *FrameMailbox,
};

const FrameSlot = struct {
    y: []u8,
    u: []u8,
    v: []u8,

    meta: FrameMeta = .{
        .pts = 0,
        .position_seconds = 0,
    },

    state: State = .free,

    const State = enum {
        free,
        ready,
        displaying,
    };
};

/// Copy one plane, row by row, out of a decoder buffer whose stride may be
/// padded, into a tightly packed destination.
fn copyPlane(
    dst: []u8,
    src: [*c]u8,
    src_pitch: i32,
    width: usize,
    height: usize,
) void {
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const from = src + row * @as(usize, @intCast(src_pitch));
        const to = row * width;
        @memcpy(dst[to .. to + width], from[0..width]);
    }
}

pub const FrameMailbox = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    slots: [slot_count]FrameSlot,

    mutex: std.Io.Mutex = .init,

    /// One slot is being uploaded to the GPU, the other is being decoded into.
    const slot_count = 2;

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !FrameMailbox {
        var mailbox = FrameMailbox{
            .io = io,
            .allocator = allocator,
            .slots = undefined,
        };

        for (&mailbox.slots) |*slot| {
            slot.* = .{
                .y = try allocator.alloc(u8, y_size),
                .u = try allocator.alloc(u8, uv_size),
                .v = try allocator.alloc(u8, uv_size),
            };
        }

        return mailbox;
    }

    pub fn deinit(self: *FrameMailbox) void {
        for (&self.slots) |*slot| {
            self.allocator.free(slot.y);
            self.allocator.free(slot.u);
            self.allocator.free(slot.v);
        }
    }

    pub fn clear(self: *FrameMailbox) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (&self.slots) |*slot| {
            if (slot.state == .ready) {
                slot.state = .free;
            }
        }
    }

    pub fn publish(
        self: *FrameMailbox,
        frame: [*c]c.AVFrame,
        meta: FrameMeta,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const f = frame.*;

        var selected: ?*FrameSlot = null;

        for (&self.slots) |*slot| {
            if (slot.state == .free) {
                selected = slot;
                break;
            }
        }

        // If no free slot exists, replace the oldest ready frame.
        if (selected == null) {
            var oldest: ?*FrameSlot = null;

            for (&self.slots) |*slot| {
                if (slot.state != .ready) {
                    continue;
                }

                if (oldest == null or
                    slot.meta.pts < oldest.?.meta.pts)
                {
                    oldest = slot;
                }
            }

            selected = oldest;
        }

        const slot = selected orelse {
            // Both slots are either displaying or otherwise unavailable.
            // Drop this decoded frame instead of blocking the decoder.
            return;
        };

        copyPlane(slot.y, f.data[0], f.linesize[0], frame_width, frame_height);
        copyPlane(slot.u, f.data[1], f.linesize[1], uv_width, uv_height);
        copyPlane(slot.v, f.data[2], f.linesize[2], uv_width, uv_height);

        slot.meta = meta;
        slot.state = .ready;
    }

    pub fn takeLatest(self: *FrameMailbox) ?FrameHandle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var selected: ?usize = null;

        for (self.slots, 0..) |slot, index| {
            if (slot.state != .ready) {
                continue;
            }

            if (selected == null or
                slot.meta.pts > self.slots[selected.?].meta.pts)
            {
                selected = index;
            }
        }

        const index = selected orelse return null;

        // Discard all other ready frames.
        for (&self.slots, 0..) |*slot, i| {
            if (i != index and slot.state == .ready) {
                slot.state = .free;
            }
        }

        const slot = &self.slots[index];
        slot.state = .displaying;

        return .{
            .y = slot.y[0..y_size],
            .u = slot.u[0..uv_size],
            .v = slot.v[0..uv_size],

            .luma_pitch = luma_pitch,
            .chroma_pitch = chroma_pitch,

            .meta = slot.meta,

            .owner = self,
        };
    }

    pub fn release(self: *FrameMailbox) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (&self.slots) |*slot| {
            if (slot.state == .displaying) {
                slot.state = .free;
            }
        }
    }
};

pub const VideoFile = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    path: []u8,

    format_ctx: [*c]c.AVFormatContext,
    codec_ctx: [*c]c.AVCodecContext,
    packet: [*c]c.AVPacket,
    frame: [*c]c.AVFrame,

    video_stream_index: usize,
    time_base: c.AVRational,

    fps: f64,

    duration_ts: i64,
    duration_seconds: f64,

    mailbox: FrameMailbox,

    eof: bool = false,

    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !*VideoFile {
        var format_ctx: [*c]c.AVFormatContext = null;

        const path_z = try allocator.allocSentinel(u8, path.len, 0);
        @memcpy(path_z[0..path.len], path);
        defer allocator.free(path_z);

        var ret = c.avformat_open_input(
            &format_ctx,
            path_z.ptr,
            null,
            null,
        );

        if (ret < 0) {
            log.err("avformat_open_input failed: {d}", .{ret});
            return error.OpenFailed;
        }

        errdefer c.avformat_close_input(&format_ctx);

        if (format_ctx == null) {
            return error.OpenFailed;
        }

        const fmt = format_ctx;
        ret = c.avformat_find_stream_info(fmt, null);
        if (ret < 0) {
            log.err("avformat_find_stream_info failed: {d}", .{ret});
            return error.StreamInfoFailed;
        }

        const video_index = c.av_find_best_stream(
            fmt,
            c.AVMEDIA_TYPE_VIDEO,
            -1,
            -1,
            null,
            0,
        );

        if (video_index < 0) {
            return error.NoVideoStream;
        }

        const stream_index: usize = @intCast(video_index);
        const video_stream_ptr = fmt.*.streams[stream_index];
        const video_stream = video_stream_ptr.*;

        const codecpar_ptr = video_stream.codecpar orelse {
            return error.InvalidCodecParameters;
        };
        const codecpar = codecpar_ptr.*;

        if (codecpar.codec_id != c.AV_CODEC_ID_H264) {
            log.err(
                "unsupported codec: expected H.264, got {d}",
                .{codecpar.codec_id},
            );
            return error.UnsupportedCodec;
        }

        // Everything about the source is checked before anything is allocated
        // for it, so a clip that cannot be played costs one demux and no
        // decoder, no packet, and no mailbox.
        const width: usize = @intCast(codecpar.width);
        const height: usize = @intCast(codecpar.height);

        if (width != frame_width or height != frame_height) {
            log.err(
                "unsupported resolution: {d}x{d}; zap only accepts {d}x{d}",
                .{ width, height, frame_width, frame_height },
            );
            return error.UnsupportedResolution;
        }

        const guessed_fps = c.av_guess_frame_rate(
            fmt,
            video_stream_ptr,
            null,
        );

        var fps: f64 = 0;

        if (guessed_fps.den != 0) {
            fps = @as(f64, @floatFromInt(guessed_fps.num)) /
                @as(f64, @floatFromInt(guessed_fps.den));
        }

        if (fps <= 0 or @abs(fps - expected_fps) > fps_tolerance) {
            log.err(
                "unsupported frame rate: {d:.3} fps; zap only accepts {d:.1} fps (within {d:.2}), because the picture has to divide evenly into the display refresh. Re-encode it.",
                .{ fps, expected_fps, fps_tolerance },
            );
            return error.UnsupportedFrameRate;
        }

        const decoder = c.avcodec_find_decoder(codecpar.codec_id) orelse {
            return error.DecoderNotFound;
        };

        var codec_ctx = c.avcodec_alloc_context3(decoder) orelse {
            return error.CodecContextAllocFailed;
        };

        errdefer c.avcodec_free_context(&codec_ctx);

        ret = c.avcodec_parameters_to_context(codec_ctx, codecpar_ptr);
        if (ret < 0) {
            return error.CodecContextSetupFailed;
        }

        codec_ctx.*.pkt_timebase = video_stream.time_base;

        ret = c.avcodec_open2(codec_ctx, decoder, null);
        if (ret < 0) {
            log.err("avcodec_open2 failed: {d}", .{ret});
            return error.CodecOpenFailed;
        }

        var packet = c.av_packet_alloc() orelse {
            return error.PacketAllocFailed;
        };

        errdefer c.av_packet_free(&packet);

        var frame = c.av_frame_alloc() orelse {
            return error.FrameAllocFailed;
        };

        errdefer c.av_frame_free(&frame);

        var duration_ts = video_stream.duration;

        if (duration_ts == c.AV_NOPTS_VALUE) {
            duration_ts = fmt.*.duration;
        }

        var duration_seconds: f64 = 0;

        if (duration_ts != c.AV_NOPTS_VALUE) {
            duration_seconds = @as(f64, @floatFromInt(duration_ts)) *
                c.av_q2d(
                    if (video_stream.duration != c.AV_NOPTS_VALUE)
                        video_stream.time_base
                    else
                        c.AV_TIME_BASE_Q,
                );
        }

        // Audio is deliberately ignored: sound is driven by SuperDirt over a
        // matching wav, so the mp4 only has to carry the picture. The demuxer
        // still holds the audio packets and the decode loop below skips them.
        const owned_path = try allocator.dupe(u8, path);

        errdefer allocator.free(owned_path);

        const mailbox = try FrameMailbox.init(
            io,
            allocator,
        );

        const self = try allocator.create(VideoFile);

        self.* = .{
            .io = io,
            .allocator = allocator,
            .path = owned_path,

            .format_ctx = fmt,
            .codec_ctx = codec_ctx,
            .packet = packet,
            .frame = frame,

            .video_stream_index = stream_index,
            .time_base = video_stream.time_base,

            .fps = fps,

            .duration_ts = duration_ts,
            .duration_seconds = duration_seconds,

            .mailbox = mailbox,
        };

        log.info(
            "opened {s}: {d}x{d} @ {d:.3} fps, duration={d:.3}s",
            .{
                path,
                frame_width,
                frame_height,
                fps,
                duration_seconds,
            },
        );

        return self;
    }

    pub fn close(self: *VideoFile) void {
        self.mailbox.deinit();

        c.av_frame_free(&self.frame);
        c.av_packet_free(&self.packet);
        c.avcodec_free_context(&self.codec_ctx);
        c.avformat_close_input(&self.format_ctx);

        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn seekNormalized(self: *VideoFile, normalized: f64) !FrameMeta {
        const clamped = std.math.clamp(normalized, 0.0, 1.0);

        self.mailbox.clear();

        const duration = self.duration_ts;

        if (duration == c.AV_NOPTS_VALUE or duration <= 0) {
            return error.UnknownDuration;
        }

        const target: i64 = @intFromFloat(
            @as(f64, @floatFromInt(duration)) * clamped,
        );

        const start_ns = util.nowNs(self.io);

        // Seek to the keyframe at or before the target, not to the next one.
        // With AVSEEK_FLAG_ANY the demuxer happily hands back a later keyframe,
        // which silently shifts every slice boundary by up to a full GOP.
        const ret = c.avformat_seek_file(
            self.format_ctx,
            @intCast(self.video_stream_index),
            std.math.minInt(i64),
            target,
            std.math.maxInt(i64),
            0,
        );

        if (ret < 0) {
            log.err("seek failed: {d}", .{ret});
            return error.SeekFailed;
        }

        c.avcodec_flush_buffers(self.codec_ctx);
        c.av_packet_unref(self.packet);

        self.eof = false;

        // Decode forward to the target frame. Dropping these frames is the
        // price of an exact landing point; how many that costs is exactly the
        // GOP length, which is why all-intra source encodes matter here.
        const meta = while (true) {
            const candidate = try self.decodeOneFrame();

            if (candidate.pts >= target) break candidate;
        };

        self.mailbox.publish(self.frame, meta) catch {};

        log.debug(
            "seek {d:.4} -> {d:.3}s in {d:.2}ms",
            .{
                clamped,
                meta.position_seconds,
                @as(f64, @floatFromInt(util.nowNs(self.io) - start_ns)) /
                    1_000_000.0,
            },
        );

        return meta;
    }

    fn decodeOneFrame(self: *VideoFile) !FrameMeta {
        while (true) {
            var ret = c.avcodec_receive_frame(
                self.codec_ctx,
                self.frame,
            );

            if (ret == 0) {
                const frame = self.frame.*;

                const pts =
                    if (frame.best_effort_timestamp != c.AV_NOPTS_VALUE)
                        frame.best_effort_timestamp
                    else if (frame.pts != c.AV_NOPTS_VALUE)
                        frame.pts
                    else
                        return error.FrameHasNoTimestamp;

                if (frame.format != c.AV_PIX_FMT_YUV420P) {
                    log.err(
                        "decoder returned unsupported pixel format {d}",
                        .{frame.format},
                    );
                    return error.UnsupportedPixelFormat;
                }

                const seconds =
                    @as(f64, @floatFromInt(pts)) *
                    c.av_q2d(self.time_base);

                return .{
                    .pts = pts,
                    .position_seconds = seconds,
                };
            }

            if (ret == -c.EAGAIN) {
                ret = c.av_read_frame(
                    self.format_ctx,
                    self.packet,
                );

                if (ret == c.AVERROR_EOF) {
                    _ = c.avcodec_send_packet(
                        self.codec_ctx,
                        null,
                    );

                    self.eof = true;
                    continue;
                }

                if (ret < 0) {
                    return error.ReadPacketFailed;
                }

                defer c.av_packet_unref(self.packet);

                if (@as(usize, @intCast(self.packet.*.stream_index)) !=
                    self.video_stream_index)
                {
                    continue;
                }

                ret = c.avcodec_send_packet(
                    self.codec_ctx,
                    self.packet,
                );

                if (ret < 0 and ret != -c.EAGAIN) {
                    return error.SendPacketFailed;
                }

                continue;
            }

            if (ret == c.AVERROR_EOF) {
                self.eof = true;
                return error.EndOfStream;
            }

            if (ret < 0) {
                return error.DecodeFailed;
            }
        }
    }

    pub fn decodeAndPublish(self: *VideoFile) !FrameMeta {
        const meta = try self.decodeOneFrame();

        try self.mailbox.publish(
            self.frame,
            meta,
        );

        return meta;
    }

    pub fn takeLatestFrame(self: *VideoFile) ?FrameHandle {
        return self.mailbox.takeLatest();
    }
};
