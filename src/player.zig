const std = @import("std");
const video = @import("video.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const MAX_VIDEOS = 64;
pub const MAX_PATH = 4096;
pub const MAX_NAME = 256;

const default_media_dir = "media";
const sample_extension = ".mp4";

pub const PlayerState = struct {
    current_video: ?usize = null,

    duration: f64 = 0,
    position: f64 = 0,

    fps: f64 = 0,

    video_width: usize = 0,
    video_height: usize = 0,
};

/// One OSC event, in SuperDirt shape.
///
/// Mirrors what a grain carries: which sample, which slice of it, which
/// occurrence, and how long it lasts. `begin`/`end` are normalized 0..1 so a
/// pattern can address any clip without knowing its length.
const TriggerState = struct {
    /// Bumped on every event. The worker applies a trigger only once, and
    /// only when it can see the whole struct, so the parameters of one event
    /// can never be applied piecemeal.
    generation: u64 = 0,

    /// Empty means "keep the current clip", which is what a bare retrigger
    /// should do.
    name: [MAX_NAME]u8 = undefined,
    name_len: usize = 0,

    begin: f64 = 0,
    end: f64 = 0,
    /// Sample number. Optional, defaulting to 0. Because SuperDirt sends `n`
    /// on every event with 0 as its default, 0 cannot mean "the first file" or
    /// every event would resolve to the first clip in the directory. So only a
    /// number greater than 0 selects by position; 0 leaves the sample name in
    /// charge.
    n: i32 = 0,
    duration: f64 = 0,
};

const CommandState = struct {
    load_pending: bool = false,
    load_path: [MAX_PATH]u8 = undefined,
    load_path_len: usize = 0,

    trigger: TriggerState = .{},
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

    applied_trigger_generation: u64 = 0,

    // Bounds of the slice the current trigger asked for, owned by the video
    // worker and therefore lock-free. `null` means "no bound".
    stop_position_seconds: ?f64 = null,
    stop_at_ns: ?u64 = null,
    slice_finished: bool = false,

    /// Where `s` names are looked up. Owned only when it differs from the
    /// default, so the common case needs no allocation.
    media_dir: []const u8 = default_media_dir,
    owned_media_dir: ?[]u8 = null,

    pub fn init(io: std.Io, allocator: Allocator) Player {
        return .{
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn setMediaDir(
        self: *Player,
        dir: []const u8,
    ) !void {
        if (self.owned_media_dir) |owned| {
            self.allocator.free(owned);
            self.owned_media_dir = null;
        }

        if (std.mem.eql(u8, dir, default_media_dir)) {
            self.media_dir = default_media_dir;
            return;
        }

        const owned = try self.allocator.dupe(u8, dir);
        self.owned_media_dir = owned;
        self.media_dir = owned;
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

        if (self.owned_media_dir) |owned| {
            self.allocator.free(owned);
            self.owned_media_dir = null;
        }
    }

    /// Apply one OSC event. Every parameter is optional: an empty name keeps
    /// the current clip, so `begin` alone can re-slice what is already
    /// playing, and a trigger with nothing but a name just plays it from the
    /// start.
    pub fn requestTrigger(
        self: *Player,
        name: []const u8,
        begin: f64,
        end: f64,
        n: ?f64,
        duration: f64,
    ) void {
        if (name.len >= MAX_NAME) {
            std.log.warn("s: name too long ({d} bytes); ignored", .{name.len});
            return;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (name.len > 0) {
            @memcpy(self.command.trigger.name[0..name.len], name);
        }

        self.command.trigger.name_len = name.len;
        self.command.trigger.begin = clampUnit(begin);
        self.command.trigger.end = clampUnit(end);
        // `n` is optional and defaults to 0, so an absent `n` and an explicit
        // `n 0` are the same request.
        self.command.trigger.n = if (n) |value| blk: {
            const index = @as(i64, @intFromFloat(@round(value)));
            break :blk if (index > 0) @as(i32, @intCast(index)) else 0;
        } else 0;
        self.command.trigger.duration = @max(duration, 0);
        self.command.trigger.generation += 1;

        std.log.info(
            "TRIGGER #{d} s={s} begin={d:.4} end={d:.4} n={d} duration={d:.3}",
            .{
                self.command.trigger.generation,
                if (name.len > 0) name else "",
                self.command.trigger.begin,
                self.command.trigger.end,
                self.command.trigger.n,
                self.command.trigger.duration,
            },
        );
    }

    /// Resolve a SuperDirt-style sample name to a file on disk.
    ///
    /// A name that looks like a path is used as-is, which keeps CLI and patch
    /// usage working. Otherwise the media directory is searched for clips whose
    /// basename matches, and `n` picks among the matches in sorted order, the
    /// same way `n` picks among samples sharing a name in SuperDirt.
    /// Copies the file name of the `n`-th `.mp4` in the media directory, in
    /// sorted order, into `buffer`. `n` is an absolute index into that
    /// listing, not a variant of a named sample.
    fn resolveIndex(
        self: *Player,
        n: i32,
        buffer: []u8,
    ) ![]const u8 {
        if (n < 0) return error.IndexOutOfRange;

        var dir = Dir.cwd().openDir(
            self.io,
            self.media_dir,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.SampleNotFound,
            else => return err,
        };
        defer dir.close(self.io);

        var matches: std.ArrayList([]u8) = .empty;
        defer {
            for (matches.items) |entry| self.allocator.free(entry);
            matches.deinit(self.allocator);
        }

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.ascii.endsWithIgnoreCase(entry.name, sample_extension)) continue;

            try matches.append(
                self.allocator,
                try self.allocator.dupe(u8, entry.name),
            );
        }

        std.mem.sort([]u8, matches.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        // Out of range is an error, never a clamp: silently playing the last
        // file would look like a working trigger while showing the wrong clip.
        if (@as(usize, @intCast(n)) >= matches.items.len) {
            return error.IndexOutOfRange;
        }

        const chosen = matches.items[@intCast(n)];
        const dir_len = self.media_dir.len;

        if (dir_len + 1 + chosen.len > buffer.len) return error.NameTooLong;

        @memcpy(buffer[0..dir_len], self.media_dir);
        buffer[dir_len] = '/';
        @memcpy(buffer[dir_len + 1 ..][0..chosen.len], chosen);

        return buffer[0 .. dir_len + 1 + chosen.len];
    }

    fn resolveSample(
        self: *Player,
        name: []const u8,
        n: i32,
        buffer: []u8,
    ) !?[]const u8 {
        // A sample number greater than 0 is self-sufficient: it addresses a
        // file directly by position, so any name on the same event is ignored.
        if (n > 0) return try self.resolveIndex(n, buffer);

        if (name.len == 0) return null;

        const looks_like_path =
            std.mem.indexOfScalar(u8, name, '/') != null or
            std.ascii.endsWithIgnoreCase(name, sample_extension);

        if (looks_like_path) {
            var file = Dir.cwd().openFile(self.io, name, .{}) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };
            file.close(self.io);

            if (name.len > buffer.len) return error.NameTooLong;

            @memcpy(buffer[0..name.len], name);
            return buffer[0..name.len];
        }

        const dir_len = self.media_dir.len;
        const entry_name = name;

        if (dir_len + 1 + entry_name.len + sample_extension.len > buffer.len) {
            return error.NameTooLong;
        }

        // Non-recursive existence check: a name is a file, not a directory to
        // walk, so a single open is both the test and the answer.
        @memcpy(buffer[0..dir_len], self.media_dir);
        buffer[dir_len] = '/';
        @memcpy(buffer[dir_len + 1 ..][0..entry_name.len], entry_name);
        @memcpy(
            buffer[dir_len + 1 + entry_name.len ..][0..sample_extension.len],
            sample_extension,
        );

        const path = buffer[0 .. dir_len + 1 + entry_name.len + sample_extension.len];

        var file = Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.SampleNotFound,
            else => return err,
        };
        file.close(self.io);

        return path;
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
        var deadline_ns: u64 = 0;

        var resolve_buffer: [MAX_PATH]u8 = undefined;

        while (self.running.load(.acquire)) {
            var load_path: ?[]u8 = null;
            var trigger: ?TriggerState = null;

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

            // Not marked applied here on purpose: an event that arrives while
            // a clip is still opening has to stay pending until the worker can
            // act on it as a whole.
            if (self.command.trigger.generation !=
                self.applied_trigger_generation)
            {
                trigger = self.command.trigger;
            }

            self.mutex.unlock(self.io);

            if (load_path) |path| {
                self.handleLoad(path);
                last_pts = null;
                deadline_ns = 0;
                continue;
            }

            if (trigger) |t| {
                self.mutex.lockUncancelable(self.io);
                self.applied_trigger_generation = t.generation;
                self.mutex.unlock(self.io);

                if (t.name_len > 0 or t.n > 0) {
                    // A sample number addresses a file by position and makes
                    // the name meaningless, so only look the name up when
                    // there is no index.
                    const name = if (t.n == 0)
                        t.name[0..t.name_len]
                    else
                        "";

                    const resolved = self.resolveSample(
                        name,
                        t.n,
                        &resolve_buffer,
                    ) catch |err| {
                        // Drop the whole event. Half-applying it would restart
                        // whatever is on screen, which is the one thing a typo
                        // must never do mid-performance.
                        if (err == error.SampleNotFound) {
                            std.log.warn(
                                "trigger #{d}: s \"{s}\" n={d} is not in '{s}'; event ignored",
                                .{ t.generation, name, t.n, self.media_dir },
                            );
                        } else if (err == error.IndexOutOfRange) {
                            std.log.warn(
                                "trigger #{d}: n={d} is past the end of '{s}'; event ignored",
                                .{ t.generation, t.n, self.media_dir },
                            );
                        } else {
                            std.log.warn(
                                "trigger #{d}: s \"{s}\" n={d}: {s}; event ignored",
                                .{ t.generation, name, t.n, @errorName(err) },
                            );
                        }

                        continue;
                    };

                    if (resolved) |path| {
                        self.activatePath(path);
                    }
                }

                // A new event always resumes playback and restarts pacing.
                self.slice_finished = false;
                last_pts = null;
                deadline_ns = 0;

                self.stop_position_seconds = null;
                self.stop_at_ns = null;

                if (t.duration > 0) {
                    self.stop_at_ns = self.nowNs() + @as(
                        u64,
                        @intFromFloat(t.duration * 1_000_000_000.0),
                    );
                }

                const target = self.getActiveVideo() orelse {
                    std.log.warn(
                        "trigger #{d} ignored: no clip to play",
                        .{t.generation},
                    );
                    continue;
                };

                if (t.end > t.begin) {
                    self.stop_position_seconds = t.end * target.duration_seconds;
                }

                const startNs = self.nowNs();

                const meta = target.seekNormalized(t.begin) catch |err| {
                    std.log.err(
                        "trigger #{d}: seek to {d:.4} failed: {s}",
                        .{ t.generation, t.begin, @errorName(err) },
                    );
                    continue;
                };

                self.updatePosition(meta.position_seconds);
                last_pts = meta.pts;

                std.log.info(
                    "trigger #{d} began at {d:.3}s / {d:.3}s, frame_pts={d}, latency={d:.2}ms",
                    .{
                        t.generation,
                        meta.position_seconds,
                        target.duration_seconds,
                        meta.pts,
                        @as(f64, @floatFromInt(self.nowNs() - startNs)) /
                            1_000_000.0,
                    },
                );

                // seekNormalized already published the target frame.
                continue;
            }

            const active = self.getActiveVideo();

            if (active == null) {
                self.sleepNs(1_000_000);
                continue;
            }

            const v = active.?;

            if (self.slice_finished) {
                self.sleepNs(1_000_000);
                continue;
            }

            const decode_start = self.nowNs();

            const meta = v.decodeAndPublish() catch |err| {
                if (err == error.EndOfStream) {
                    // Hold the last frame. A sample plays its slice once and
                    // waits for the next event; looping on its own would fight
                    // the pattern that drives zap.
                    self.finishSlice("reached the end of the clip");

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

                    const interval_ns: u64 = @intFromFloat(
                        delta_seconds * 1_000_000_000.0,
                    );

                    // Pace against an absolute deadline instead of sleeping a
                    // whole frame interval after decoding. Sleeping the full
                    // interval makes the real period decode_time + interval,
                    // which runs the whole video slow and spreads decode jitter
                    // across every frame boundary.
                    if (deadline_ns == 0) {
                        deadline_ns = self.nowNs();
                    }
                    deadline_ns += interval_ns;

                    const now = self.nowNs();
                    if (deadline_ns > now) {
                        self.sleepNs(deadline_ns - now);
                    } else {
                        // Behind schedule: resync instead of carrying the debt
                        // forward, otherwise one slow frame shifts every later
                        // frame boundary and the drift never recovers.
                        deadline_ns = now;
                    }
                }
            }

            last_pts = meta.pts;

            // The slice ends at whichever of `end` or `duration` arrives
            // first. Both are bounds on this trigger only; the next trigger
            // clears them.
            if (self.stop_position_seconds) |stop_position| {
                if (meta.position_seconds >= stop_position) {
                    self.finishSlice("reached end");
                    continue;
                }
            }

            if (self.stop_at_ns) |deadline| {
                if (self.nowNs() >= deadline) {
                    self.finishSlice("reached duration");
                    continue;
                }
            }

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

    /// Stop at the current frame and keep showing it, the way a sample goes
    /// silent after its slice instead of restarting on its own.
    fn finishSlice(
        self: *Player,
        reason: []const u8,
    ) void {
        if (self.slice_finished) return;

        self.slice_finished = true;

        std.log.info(
            "slice finished at {d:.3}s: {s}",
            .{ self.state.position, reason },
        );
    }

    /// Make `path` the active clip, reusing an already opened one. A pattern
    /// can retrigger the same sample many times a second, so reopening the
    /// file per event would churn decoders and fill the slot table.
    fn activatePath(
        self: *Player,
        path: []const u8,
    ) void {
        for (&self.videos, 0..) |*entry, i| {
            if (entry.*) |v| {
                if (std.mem.eql(u8, v.path, path)) {
                    self.setActiveVideo(i);
                    return;
                }
            }
        }

        self.handleLoad(path);
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

fn clampUnit(value: f64) f64 {
    if (std.math.isNan(value)) return 0;
    return std.math.clamp(value, 0, 1);
}
