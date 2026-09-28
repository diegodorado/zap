const std = @import("std");
const c = @import("c");

const log = std.log.scoped(.video);

pub const FrameMeta = struct {
    pts: i64,
    position_seconds: f64,
};

pub const FrameHandle = struct {
    width: i32,
    height: i32,

    y: []const u8,
    u: []const u8,
    v: []const u8,

    y_pitch: i32,
    u_pitch: i32,
    v_pitch: i32,

    meta: FrameMeta,

    slot_index: usize,
};

const FrameSlot = struct {
    y: []u8,
    u: []u8,
    v: []u8,

    y_len: usize = 0,
    u_len: usize = 0,
    v_len: usize = 0,

    y_pitch: i32 = 0,
    u_pitch: i32 = 0,
    v_pitch: i32 = 0,

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

pub const FrameMailbox = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    width: usize,
    height: usize,

    slots: [2]FrameSlot,

    mutex: std.Io.Mutex = .init,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        width: usize,
        height: usize,
    ) !FrameMailbox {
        const y_size = width * height;
        const uv_size = (width / 2) * (height / 2);

        var mailbox = FrameMailbox{
            .io = io,
            .allocator = allocator,
            .width = width,
            .height = height,
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

        const y_pitch = f.linesize[0];
        const u_pitch = f.linesize[1];
        const v_pitch = f.linesize[2];

        const y_height = self.height;
        const uv_height = self.height / 2;

        var y_offset: usize = 0;
        var u_offset: usize = 0;
        var v_offset: usize = 0;

        const y_ptr = f.data[0];
        const u_ptr = f.data[1];
        const v_ptr = f.data[2];

        var row: usize = 0;
        while (row < y_height) : (row += 1) {
            const src = y_ptr + row * @as(usize, @intCast(y_pitch));
            const dst = slot.y[y_offset .. y_offset + self.width];

            @memcpy(dst, src[0..self.width]);

            y_offset += self.width;
        }

        const uv_width = self.width / 2;

        row = 0;
        while (row < uv_height) : (row += 1) {
            const u_src = u_ptr + row * @as(usize, @intCast(u_pitch));
            const v_src = v_ptr + row * @as(usize, @intCast(v_pitch));

            @memcpy(
                slot.u[u_offset .. u_offset + uv_width],
                u_src[0..uv_width],
            );

            @memcpy(
                slot.v[v_offset .. v_offset + uv_width],
                v_src[0..uv_width],
            );

            u_offset += uv_width;
            v_offset += uv_width;
        }

        slot.y_len = y_offset;
        slot.u_len = u_offset;
        slot.v_len = v_offset;

        slot.y_pitch = @intCast(self.width);
        slot.u_pitch = @intCast(uv_width);
        slot.v_pitch = @intCast(uv_width);

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
            .width = @intCast(self.width),
            .height = @intCast(self.height),

            .y = slot.y[0..slot.y_len],
            .u = slot.u[0..slot.u_len],
            .v = slot.v[0..slot.v_len],

            .y_pitch = slot.y_pitch,
            .u_pitch = slot.u_pitch,
            .v_pitch = slot.v_pitch,

            .meta = slot.meta,

            .slot_index = index,
        };
    }

    pub fn release(self: *FrameMailbox, slot_index: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (slot_index < self.slots.len) {
            const slot = &self.slots[slot_index];

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

    width: usize,
    height: usize,

    fps: f64,

    duration_ts: i64,
    duration_seconds: f64,

    audio_present: bool,

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

        const width: usize = @intCast(codecpar.width);
        const height: usize = @intCast(codecpar.height);

        if (width != 1920 or height != 1080) {
            log.err(
                "expected 1920x1080, got {d}x{d}",
                .{ width, height },
            );
            return error.UnsupportedResolution;
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

        var audio_present = false;

        var i: usize = 0;
        while (i < fmt.*.nb_streams) : (i += 1) {
            const s = fmt.*.streams[i].*;

            const s_codecpar = s.codecpar orelse continue;

            if (s_codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
                audio_present = true;
                break;
            }
        }

        const owned_path = try allocator.dupe(u8, path);

        errdefer allocator.free(owned_path);

        const mailbox = try FrameMailbox.init(
            io,
            allocator,
            width,
            height,
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

            .width = width,
            .height = height,

            .fps = fps,

            .duration_ts = duration_ts,
            .duration_seconds = duration_seconds,

            .audio_present = audio_present,

            .mailbox = mailbox,
        };

        log.info(
            "opened {s}: {d}x{d}, fps={d:.3}, duration={d:.3}s",
            .{
                path,
                width,
                height,
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

        const start_ns = std.Io.Clock.now(.awake, self.io).nanoseconds;

        const ret = c.avformat_seek_file(
            self.format_ctx,
            @intCast(self.video_stream_index),
            std.math.minInt(i64),
            target,
            std.math.maxInt(i64),
            c.AVSEEK_FLAG_ANY,
        );

        if (ret < 0) {
            log.err("seek failed: {d}", .{ret});
            return error.SeekFailed;
        }

        c.avcodec_flush_buffers(self.codec_ctx);
        c.av_packet_unref(self.packet);

        self.eof = false;

        const meta = try self.decodeOneFrame();

        self.mailbox.publish(self.frame, meta) catch {};

        const elapsed_ns = std.Io.Clock.now(.awake, self.io).nanoseconds - start_ns;

        log.debug(
            "seek {d:.4} -> {d:.3}s in {d:.2}ms",
            .{
                clamped,
                meta.position_seconds,
                @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
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

    pub fn releaseFrame(
        self: *VideoFile,
        frame: FrameHandle,
    ) void {
        self.mailbox.release(frame.slot_index);
    }
};
