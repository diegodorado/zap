const std = @import("std");
const video = @import("video.zig");

const Allocator = std.mem.Allocator;

pub const MAX_VIDEOS = 64;
pub const MAX_PATH = 4096;

pub const PlayerState = struct {
    current_video: ?usize = null,

    duration: f64 = 0,
    position: f64 = 0,

    speed: f64 = 1.0,
    playing: bool = true,

    fps: f64 = 0,

    video_width: usize = 0,
    video_height: usize = 0,

    audio_present: bool = false,
};

const CommandState = struct {
    load_pending: bool = false,
    load_path: [MAX_PATH]u8 = undefined,
    load_path_len: usize = 0,

    current_index: ?usize = null,

    seek_generation: u64 = 0,
    seek_position: f64 = 0,

    speed: f64 = 1.0,
    playing: bool = true,
};

pub const Player = struct {
    io: std.Io,
    allocator: Allocator,

    mutex: std.Io.Mutex = .init,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    command: CommandState = .{},

    state: PlayerState = .{},

    videos: [MAX_VIDEOS]?*video.VideoFile = @splat(null),

    worker: ?std.Thread = null,

    applied_seek_generation: u64 = 0,

    pub fn init(io: std.Io, allocator: Allocator) Player {
        return .{
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn start(self: *Player) !void {
        self.running.store(true, .release);

        self.worker = try std.Thread.spawn(
            .{},
            workerMain,
            .{self},
        );
    }

    pub fn stop(self: *Player) void {
        self.running.store(false, .release);

        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
    }

    pub fn deinit(self: *Player) void {
        self.stop();

        for (&self.videos) |*entry| {
            if (entry.*) |v| {
                v.close();
                entry.* = null;
            }
        }
    }

    pub fn requestLoad(
        self: *Player,
        path: []const u8,
    ) void {
        if (path.len >= MAX_PATH) {
            std.log.err("LOAD path too long", .{});
            return;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        @memcpy(
            self.command.load_path[0..path.len],
            path,
        );

        self.command.load_path_len = path.len;
        self.command.load_pending = true;

        std.log.info(
            "LOAD queued path={s}",
            .{path},
        );
    }

    pub fn requestSelect(
        self: *Player,
        index: usize,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (index >= MAX_VIDEOS) {
            std.log.err(
                "N index out of range: {d}",
                .{index},
            );
            return;
        }

        self.command.current_index = index;
    }

    pub fn requestSeek(
        self: *Player,
        position: f64,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var value = position;

        if (value < 0) value = 0;
        if (value > 1) value = 1;

        self.command.seek_position = value;
        self.command.seek_generation += 1;
    }

    pub fn requestSpeed(
        self: *Player,
        speed: f64,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (speed < 0) {
            std.log.warn(
                "negative speed is not implemented; ignoring {d}",
                .{speed},
            );
            return;
        }

        self.command.speed = speed;
        self.command.playing = speed > 0;
    }

    pub fn takeLatestFrame(
        self: *Player,
    ) ?video.FrameHandle {
        self.mutex.lockUncancelable(self.io);
        const index = self.state.current_video;
        self.mutex.unlock(self.io);

        if (index) |i| {
            if (self.videos[i]) |v| {
                return v.mailbox.takeLatest();
            }
        }

        return null;
    }

    pub fn releaseFrame(
        self: *Player,
        handle: video.FrameHandle,
    ) void {
        self.mutex.lockUncancelable(self.io);
        const index = self.state.current_video;
        self.mutex.unlock(self.io);

        if (index) |i| {
            if (self.videos[i]) |v| {
                v.mailbox.release(handle.slot_index);
                return;
            }
        }
    }

    pub fn getState(self: *Player) PlayerState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        return self.state;
    }

    fn workerMain(self: *Player) void {
        std.log.info("video worker started", .{});

        var last_pts: ?i64 = null;

        while (self.running.load(.acquire)) {
            var load_path: ?[]u8 = null;
            var selected_index: ?usize = null;
            var seek_request: ?struct {
                generation: u64,
                position: f64,
            } = null;
            var speed: f64 = 0;
            var playing = false;

            var local_path: [MAX_PATH]u8 = undefined;

            self.mutex.lockUncancelable(self.io);

            if (self.command.load_pending) {
                @memcpy(
                    local_path[0..self.command.load_path_len],
                    self.command.load_path[0..self.command.load_path_len],
                );

                load_path = local_path[0..self.command.load_path_len];
                self.command.load_pending = false;
            }

            selected_index = self.command.current_index;
            self.command.current_index = null;

            if (self.command.seek_generation !=
                self.applied_seek_generation)
            {
                seek_request = .{
                    .generation = self.command.seek_generation,
                    .position = self.command.seek_position,
                };

                self.applied_seek_generation =
                    self.command.seek_generation;
            }

            speed = self.command.speed;
            playing = self.command.playing;

            self.mutex.unlock(self.io);

            if (load_path) |path| {
                self.handleLoad(path);
                last_pts = null;
                continue;
            }

            if (selected_index) |index| {
                if (index < MAX_VIDEOS and
                    self.videos[index] != null)
                {
                    self.setActiveVideo(index);
                    last_pts = null;
                }
            }

            const active = self.getActiveVideo();

            if (active == null) {
                self.sleepNs(1_000_000);
                continue;
            }

            const v = active.?;

            if (seek_request) |request| {
                const startNs = self.nowNs();

                const meta = v.seekNormalized(
                    request.position,
                ) catch |err| {
                    std.log.err(
                        "seek failed: {s}",
                        .{@errorName(err)},
                    );
                    continue;
                };

                const latency_ns = self.nowNs() - startNs;

                self.updatePosition(
                    meta.position_seconds,
                );

                std.log.info(
                    "SEEK request={d} position={d:.6} frame_pts={d} latency_ms={d:.3}",
                    .{
                        request.generation,
                        request.position,
                        meta.pts,
                        @as(f64, @floatFromInt(latency_ns)) /
                            1_000_000.0,
                    },
                );

                last_pts = meta.pts;

                // seekNormalized doesn't publish. Publish the target frame
                // through the normal mailbox path.
                v.mailbox.publish(v.frame, meta);

                continue;
            }

            if (!playing or speed <= 0) {
                self.sleepNs(1_000_000);
                continue;
            }

            const decode_start = self.nowNs();

            const meta = v.decodeAndPublish() catch |err| {
                if (err == error.EndOfVideo) {
                    // Loop to the beginning for the MVP.
                    _ = v.seekNormalized(0) catch {};
                    last_pts = null;
                    continue;
                }

                std.log.err(
                    "decode failed: {s}",
                    .{@errorName(err)},
                );

                self.sleepNs(5_000_000);
                continue;
            };

            const decode_ns = self.nowNs() - decode_start;

            self.updatePosition(meta.position_seconds);

            if (last_pts) |previous_pts| {
                const delta_pts = meta.pts - previous_pts;

                if (delta_pts > 0) {
                    const delta_seconds =
                        @as(f64, @floatFromInt(delta_pts)) *
                        cTimeBase(v.time_base);

                    const sleep_seconds =
                        delta_seconds / speed;

                    if (sleep_seconds > 0) {
                        const sleep_ns = @as(
                            u64,
                            @intFromFloat(
                                sleep_seconds * 1_000_000_000.0,
                            ),
                        );

                        if (sleep_ns > 100_000) {
                            self.sleepNs(sleep_ns);
                        }
                    }
                }
            }

            last_pts = meta.pts;

            if (decode_ns > 20_000_000) {
                std.log.debug(
                    "slow decode {d:.3} ms pts={d}",
                    .{
                        @as(f64, @floatFromInt(decode_ns)) /
                            1_000_000.0,
                        meta.pts,
                    },
                );
            }
        }

        std.log.info("video worker stopped", .{});
    }

    fn handleLoad(
        self: *Player,
        path: []const u8,
    ) void {
        const new_video =
            video.VideoFile.open(
                self.io,
                self.allocator,
                path,
            ) catch |err| {
                std.log.err(
                    "LOAD failed path={s}: {s}",
                    .{
                        path,
                        @errorName(err),
                    },
                );
                return;
            };

        var index: ?usize = null;

        for (&self.videos, 0..) |*entry, i| {
            if (entry.* == null) {
                index = i;
                entry.* = new_video;
                break;
            }
        }

        if (index == null) {
            new_video.close();

            std.log.err(
                "video collection full ({d})",
                .{MAX_VIDEOS},
            );

            return;
        }

        const i = index.?;

        self.mutex.lockUncancelable(self.io);

        self.state.current_video = i;
        self.state.duration = new_video.duration_seconds;
        self.state.position = 0;
        self.state.fps = new_video.fps;
        self.state.video_width = new_video.width;
        self.state.video_height = new_video.height;
        self.state.audio_present = new_video.audio_present;

        self.command.current_index = null;

        self.mutex.unlock(self.io);

        std.log.info(
            "loaded video index={d} path={s}",
            .{ i, path },
        );
    }

    fn setActiveVideo(
        self: *Player,
        index: usize,
    ) void {
        if (self.videos[index]) |v| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.state.current_video = index;
            self.state.duration = v.duration_seconds;
            self.state.position = 0;
            self.state.fps = v.fps;
            self.state.video_width = v.width;
            self.state.video_height = v.height;
            self.state.audio_present = v.audio_present;

            std.log.info(
                "active video index={d} path={s}",
                .{ index, v.path },
            );
        }
    }

    fn getActiveVideo(
        self: *Player,
    ) ?*video.VideoFile {
        self.mutex.lockUncancelable(self.io);
        const index = self.state.current_video;
        self.mutex.unlock(self.io);

        if (index) |i| {
            return self.videos[i];
        }

        return null;
    }

    fn updatePosition(
        self: *Player,
        position: f64,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.state.position = position;
    }

    fn nowNs(self: *Player) u64 {
        return @intCast(std.Io.Clock.now(.awake, self.io).nanoseconds);
    }

    fn sleepNs(self: *Player, nanoseconds: u64) void {
        self.io.sleep(
            .fromNanoseconds(nanoseconds),
            .awake,
        ) catch |err| switch (err) {
            error.Canceled => {},
        };
    }

    fn cTimeBase(tb: anytype) f64 {
        return @as(f64, @floatFromInt(tb.num)) /
            @as(f64, @floatFromInt(tb.den));
    }
};
