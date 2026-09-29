const std = @import("std");
const c = @import("c");

const util = @import("util.zig");
const video = @import("video.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const MAX_VIDEOS = 64;
pub const MAX_PATH = 4096;
pub const MAX_NAME = 256;

const sample_extension = ".mp4";

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

    /// The collection to play from, which is a directory of clips under the
    /// media directory. Empty means "keep the current clip", so a retrigger
    /// that only re-slices needs no name.
    name: [MAX_NAME]u8 = undefined,
    name_len: usize = 0,

    begin: f64 = 0,
    end: f64 = 0,
    /// Which clip inside the named collection, counted from 0 in sorted order.
    /// SuperDirt sends 0 on every event as its default, so 0 meaning "the
    /// first clip" is not a collision: an absent `n` and an explicit `n 0` are
    /// the same request, and both mean the first clip of the collection.
    /// The value wraps against the collection size, so a pattern may index
    /// past the end or below zero without the event being dropped.
    n: i32 = 0,
    duration: f64 = 0,

    /// Playback rate. 1 is the source frame rate, 2 is twice as fast, and a
    /// negative value plays the clip backwards. Zero is degenerate rather than
    /// fast: it asks for no movement at all, so the worker holds the frame it
    /// landed on instead of dividing by it.
    speed: f64 = 1,
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

    /// Whether a picture should be on screen right now. The render loop runs
    /// on its own thread and has to know the difference between "waiting for
    /// the next frame of a playing clip" and "playback is over, show nothing".
    /// The mailbox cannot answer that: its last frame is still sitting there
    /// either way. So the worker owns this flag and the renderer only reads it.
    showing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    command: CommandState = .{},

    current_video: ?usize = null,

    videos: [MAX_VIDEOS]?*video.VideoFile = @splat(null),

    worker: ?std.Thread = null,

    applied_trigger_generation: u64 = 0,

    // Bounds of the slice the current trigger asked for, owned by the video
    // worker and therefore lock-free. `null` means "no bound".
    stop_position_seconds: ?f64 = null,
    stop_at_ns: ?u64 = null,
    slice_finished: bool = false,

    /// Playback rate of the active trigger, with its sign carrying the
    /// direction. Read by the worker only, written when a trigger is applied.
    speed: f64 = 1,

    /// When a finished slice should actually go black, or null when no
    /// blackout is pending.
    ///
    /// A pattern retriggers back to back, so the moment a slice reaches its
    /// `end` or `duration` bound the next event is usually already on its way.
    /// Going black right then drops the picture for exactly that gap, and the
    /// gap is a few milliseconds wide and lands mid display refresh often
    /// enough to read as a flicker on every single event. The picture
    /// therefore holds its last frame instead, a new trigger cancels the
    /// pending blackout, and only a pattern that genuinely stops ever reaches
    /// it.
    blackout_at_ns: ?u64 = null,

    /// Root that holds the collections. Required, and fixed for the lifetime
    /// of the process, so it is borrowed from the command line rather than
    /// owned and re-owned by a setter that nothing needs.
    media_dir: []const u8,

    /// Collection name -> that directory's clips, sorted. Built once at
    /// startup because the media directory is known before the first event:
    /// the layout is then reported immediately instead of at the worst possible
    /// moment, and a pattern firing many events a second never pays for a
    /// rescan.
    collections: std.StringArrayHashMapUnmanaged([][]u8) = .empty,

    scanned: bool = false,

    pub fn init(
        io: std.Io,
        allocator: Allocator,
        media_dir: []const u8,
    ) Player {
        return .{
            .io = io,
            .allocator = allocator,
            .media_dir = media_dir,
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

        var it = self.collections.iterator();

        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.freeCollection(entry.value_ptr.*);
        }

        self.collections.deinit(self.allocator);
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
        speed: f64,
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
        // `n 0` are the same request. The sign is kept because `n` wraps: a
        // negative index counts back from the last clip, and collapsing it to
        // 0 here would make every negative `n` play the first clip instead.
        self.command.trigger.n = if (n) |value| blk: {
            if (!std.math.isFinite(value)) break :blk 0;

            // Clamped rather than wrapped so the narrowing cast below cannot
            // trap on a wildly out of range value. The modulo that actually
            // chooses a clip happens in resolveSample, which is where the
            // collection length is known.
            const wide: i64 = @intFromFloat(@round(value));

            break :blk @as(i32, @intCast(std.math.clamp(
                wide,
                -max_n,
                max_n,
            )));
        } else 0;
        self.command.trigger.duration = @max(duration, 0);
        // Only the sign and magnitude matter; the magnitude is clamped so an
        // absurd rate cannot make the pacing deadline wrap around.
        self.command.trigger.speed = std.math.clamp(speed, -max_speed, max_speed);
        self.command.trigger.generation += 1;

        std.log.info(
            "TRIGGER #{d} s={s} begin={d:.4} end={d:.4} n={d} duration={d:.3} speed={d:.3}",
            .{
                self.command.trigger.generation,
                if (name.len > 0) name else "",
                self.command.trigger.begin,
                self.command.trigger.end,
                self.command.trigger.n,
                self.command.trigger.duration,
                self.command.trigger.speed,
            },
        );
    }

    /// Write "<media_dir>/<name>" into `buffer` and return it.
    fn joinMediaDir(
        self: *Player,
        buffer: []u8,
        name: []const u8,
    ) ![]const u8 {
        const dir_len = self.media_dir.len;

        if (dir_len + 1 + name.len > buffer.len) {
            return error.NameTooLong;
        }

        @memcpy(buffer[0..dir_len], self.media_dir);
        buffer[dir_len] = '/';
        @memcpy(buffer[dir_len + 1 ..][0..name.len], name);

        return buffer[0 .. dir_len + 1 + name.len];
    }

    fn freeCollection(
        self: *Player,
        paths: [][]u8,
    ) void {
        for (paths) |path| self.allocator.free(path);
        self.allocator.free(paths);
    }

    /// Read the media directory: every subdirectory is one `s` collection, and
    /// every clip in it takes the next index in sorted order.
    ///
    /// Scanning up front is what makes a `s`/`n` pair a lookup instead of a
    /// filesystem walk. It also fails at startup, where a missing directory is
    /// an honest error, instead of at the first `/play`, where the same
    /// problem would look like a bad pattern.
    pub fn scan(self: *Player) !void {
        var dir = Dir.cwd().openDir(
            self.io,
            self.media_dir,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.MediaDirNotFound,
            else => return err,
        };
        defer dir.close(self.io);

        var skipped_loose: usize = 0;
        var collection_count: usize = 0;
        var clip_count: usize = 0;

        var scratch: [MAX_PATH]u8 = undefined;
        var iterator = dir.iterate();

        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .directory) {
                if (entry.kind == .file and
                    std.ascii.endsWithIgnoreCase(entry.name, sample_extension))
                {
                    skipped_loose += 1;
                }
                continue;
            }

            // A clip whose full path cannot even be addressed in MAX_PATH is
            // unusable, so it does not belong in the listing.
            const collection_dir = self.joinMediaDir(&scratch, entry.name) catch {
                skipped_loose += 1;
                continue;
            };

            const paths = self.scanCollection(collection_dir) catch |err| {
                std.log.warn(
                    "could not read collection \"{s}\": {s}; skipped",
                    .{ entry.name, @errorName(err) },
                );
                continue;
            };

            // The key must be owned: `entry.name` points into the iterator's
            // own buffer, which the next `next()` call and `close()` both
            // invalidate, so storing it as-is would leave every lookup reading
            // freed memory.
            const key = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(key);

            try self.collections.put(self.allocator, key, paths);

            collection_count += 1;
            clip_count += paths.len;
        }

        if (skipped_loose > 0) {
            std.log.warn(
                "{d} .mp4 file(s) sit directly in '{s}'; clips are grouped " ++
                    "per subdirectory, so those are not playable",
                .{ skipped_loose, self.media_dir },
            );
        }

        if (collection_count == 0) {
            std.log.warn(
                "no collections (subdirectories) found in '{s}'; " ++
                    "every /play will be ignored",
                .{self.media_dir},
            );
        }

        self.scanned = true;

        std.log.info(
            "media dir '{s}': {d} collection(s), {d} clip(s)",
            .{ self.media_dir, collection_count, clip_count },
        );
    }

    /// The sorted clips of one collection directory, as full paths. Sorted by
    /// name so the index a pattern uses is stable across runs.
    fn scanCollection(
        self: *Player,
        collection_dir: []const u8,
    ) ![][]u8 {
        var dir = Dir.cwd().openDir(
            self.io,
            collection_dir,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.SampleNotFound,
            else => return err,
        };
        defer dir.close(self.io);

        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit(self.allocator);
        }

        var scratch: [MAX_PATH]u8 = undefined;
        var iterator = dir.iterate();

        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.ascii.endsWithIgnoreCase(entry.name, sample_extension)) continue;

            if (collection_dir.len + 1 + entry.name.len > scratch.len) continue;

            @memcpy(
                scratch[0..collection_dir.len],
                collection_dir,
            );
            scratch[collection_dir.len] = '/';
            @memcpy(
                scratch[collection_dir.len + 1 ..][0..entry.name.len],
                entry.name,
            );

            const path = scratch[0 .. collection_dir.len + 1 + entry.name.len];

            try paths.append(
                self.allocator,
                try self.allocator.dupe(u8, path),
            );
        }

        std.mem.sort([]u8, paths.items, {}, lessThanBytes);

        return paths.toOwnedSlice(self.allocator);
    }

    /// Resolve an event to a clip: `name` picks the collection and `n` picks
    /// the clip inside it. Returns null when the event carries neither, which
    /// means "keep whatever is playing".
    ///
    /// The returned path is owned by the listing and lives as long as the
    /// process, so callers must copy it rather than free it.
    fn resolveSample(
        self: *Player,
        name: []const u8,
        n: i32,
    ) !?[]const u8 {
        if (name.len == 0) {
            // `n` alone cannot address anything: an index is only meaningful
            // relative to a collection. A plain retrigger carries neither and
            // keeps the current clip.
            if (n != 0) return error.IndexWithoutCollection;
            return null;
        }

        const paths = self.collections.get(name) orelse {
            return error.SampleNotFound;
        };

        if (paths.len == 0) return error.CollectionEmpty;

        // `n` wraps instead of failing. A pattern walking off the end of the
        // collection keeps playing, which is what indexing a fixed set of
        // clips means, and an error here would silently drop the event and
        // leave a hole in the middle of a performance. Modulo on a
        // nonnegative `n` also keeps "0 is the first clip" true, because
        // 0 % len is 0, and a negative `n` counts back from the last clip.
        const count: i32 = @intCast(paths.len);
        const index: i32 = @mod(n, count);

        return paths[@intCast(index)];
    }

    /// True while a clip is playing. False before the first trigger and after
    /// a slice ends, which is when the window must go black.
    pub fn showsFrame(self: *Player) bool {
        return self.showing.load(.acquire);
    }

    pub fn takeLatestFrame(
        self: *Player,
    ) ?video.FrameHandle {
        const active = self.activeVideo() orelse return null;
        return active.takeLatestFrame();
    }

    pub fn releaseFrame(
        _: *Player,
        frame: video.FrameHandle,
    ) void {
        // The handle names the mailbox it came from, so a clip switch between
        // take and release cannot make this return the slot to the wrong one.
        frame.owner.release();
    }

    /// The clip the pattern is currently playing, or null before the first
    /// load. Entries are only ever set from null and closed at shutdown, so a
    /// pointer read here stays valid for the rest of the process.
    fn activeVideo(
        self: *Player,
    ) ?*video.VideoFile {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const index = self.current_video orelse return null;
        return self.videos[index];
    }

    fn assignActive(
        self: *Player,
        index: usize,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.current_video = index;
    }

    fn workerMain(self: *Player) void {
        std.log.info("video worker started", .{});

        var last_pts: ?i64 = null;
        var deadline_ns: u64 = 0;

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
                    const name = t.name[0..t.name_len];

                    // Drop the whole event on any failure. Half-applying it
                    // would restart whatever is on screen, which is the one
                    // thing a typo must never do mid-performance.
                    const resolved = self.resolveSample(name, t.n) catch |err| {
                        switch (err) {
                            error.SampleNotFound => std.log.warn(
                                "trigger #{d}: no collection \"{s}\" in '{s}'; event ignored",
                                .{ t.generation, name, self.media_dir },
                            ),
                            error.CollectionEmpty => std.log.warn(
                                "trigger #{d}: collection \"{s}\" has no clips; event ignored",
                                .{ t.generation, name },
                            ),
                            error.IndexWithoutCollection => std.log.warn(
                                "trigger #{d}: n={d} with no s; an index only means something inside a collection; event ignored",
                                .{ t.generation, t.n },
                            ),
                            // No catch-all: an unhandled resolution failure is
                            // a compile error here, so a new failure mode can
                            // never reach a live performance unannounced.
                        }

                        continue;
                    };

                    if (resolved) |path| {
                        self.activatePath(path);
                    }
                }

                // A new event always resumes playback and restarts pacing, and
                // it cancels a blackout the previous slice had scheduled: two
                // adjacent events must never put a black frame between them.
                self.slice_finished = false;
                self.blackout_at_ns = null;
                last_pts = null;
                deadline_ns = 0;

                self.stop_position_seconds = null;
                self.stop_at_ns = null;

                if (t.duration > 0) {
                    self.stop_at_ns = util.nowNs(self.io) + @as(
                        u64,
                        @intFromFloat(t.duration * 1_000_000_000.0),
                    );
                }

                self.speed = t.speed;

                const target = self.activeVideo() orelse {
                    std.log.warn(
                        "trigger #{d} ignored: no clip to play",
                        .{t.generation},
                    );
                    continue;
                };

                const reversing = t.speed < 0;

                // A negative speed swaps the two ends, exactly as SuperDirt
                // does in `DirtEvent.orderTimeSpan`:
                //
                //     if(~speed < 0) { temp = ~end; ~end = ~begin; ~begin = temp }
                //
                // A pattern therefore always describes a slice as begin < end
                // and lets the sign of speed say which way it is read. Reading
                // the pair literally instead is what made every reverse slice
                // wrong in two separate ways: with the default begin 0 / end 1
                // it seeked to 0 and then ran off the front of the clip on the
                // first step, which is a black screen; and with a real pair
                // like begin 0.5 end 0.75, `end` sits ahead in the direction of
                // travel, so the bound was silently dropped and the slice ran
                // all the way back to the start of the clip.
                var begin = t.begin;
                var end = t.end;

                if (reversing) {
                    const first = begin;
                    begin = end;
                    end = first;
                }

                // The mailbox has to know which way time is moving before any
                // frame is published, because it decides which of two pending
                // frames is the newer one.
                target.setDirection(if (reversing) .reverse else .forward);

                if (t.speed == 0) {
                    std.log.warn(
                        "trigger #{d}: speed 0 asks for no playback; holding the frame at begin={d:.4}",
                        .{ t.generation, begin },
                    );
                }

                // After the swap `end` is the far end in the direction of
                // travel, so one test serves both directions. A slice whose
                // `end` is behind its `begin` has no far end: it is bound only
                // by `duration`, and runs to the start of the clip.
                if (end > begin) {
                    self.stop_position_seconds = end * target.duration_seconds;
                }

                const start_ns = util.nowNs(self.io);

                const meta = target.seekNormalized(begin) catch |err| {
                    std.log.err(
                        "trigger #{d}: seek to {d:.4} failed: {s}",
                        .{ t.generation, begin, @errorName(err) },
                    );
                    continue;
                };

                last_pts = meta.pts;

                // The seek has already published the target frame, so there is
                // now something real to show. Raising the flag here rather than
                // at the top of the trigger is what keeps the renderer from
                // putting a previous clip's last frame on screen while a new
                // clip is still being opened.
                self.showing.store(true, .release);

                std.log.info(
                    "trigger #{d} began at {d:.3}s / {d:.3}s, frame_pts={d}, speed={d:.3}, latency={d:.2}ms",
                    .{
                        t.generation,
                        meta.position_seconds,
                        target.duration_seconds,
                        meta.pts,
                        t.speed,
                        @as(f64, @floatFromInt(util.nowNs(self.io) - start_ns)) /
                            1_000_000.0,
                    },
                );

                // seekNormalized already published the target frame.
                continue;
            }

            const v = self.activeVideo() orelse {
                util.sleepNs(self.io, 1_000_000);
                continue;
            };

            if (self.slice_finished) {
                // The grace period is up and no new event claimed the window,
                // so the slice really is over: now, and only now, black.
                if (self.blackout_at_ns) |at| {
                    if (util.nowNs(self.io) >= at) {
                        self.showing.store(false, .release);
                        self.blackout_at_ns = null;
                    }
                }

                util.sleepNs(self.io, 1_000_000);
                continue;
            }

            const decode_start = util.nowNs(self.io);

            // Speed 0 is the one rate that is not a rate. Holding the frame
            // the trigger seek already published is the only honest reading of
            // it, and skipping the whole step here also keeps the pacing
            // division below from dividing by zero. Only `duration` can end
            // such a slice: the timeline never travels, so an `end` bound is
            // a position it can never arrive at.
            if (self.speed == 0) {
                util.sleepNs(self.io, 1_000_000);

                if (self.stop_at_ns) |deadline| {
                    if (util.nowNs(self.io) >= deadline) {
                        // Report where the picture actually is, not zero, or
                        // the log claims the slice fell off the front of the
                        // clip when nothing moved at all.
                        const held = if (last_pts) |pts|
                            @as(f64, @floatFromInt(pts)) * c.av_q2d(v.time_base)
                        else
                            0;

                        self.finishSlice("reached duration", held);
                    }
                }

                continue;
            }

            const reversing = self.speed < 0;

            const stepped = blk: {
                if (reversing) {
                    const from_pts = last_pts orelse 0;

                    break :blk v.stepBackward(from_pts) catch |err| {
                        if (err == error.StartOfClip) {
                            // Running off the front of the clip ends the slice
                            // the same way running off the end does: the sample
                            // has played out, so the picture goes black.
                            self.finishSlice(
                                "reached the start of the clip",
                                0,
                            );

                            break :blk null;
                        }

                        std.log.err("reverse step failed: {s}", .{@errorName(err)});

                        util.sleepNs(self.io, 5_000_000);

                        break :blk null;
                    };
                }

                break :blk v.decodeAndPublish() catch |err| {
                    if (err == error.EndOfStream) {
                        // A sample plays its slice once and waits for the next
                        // event; looping on its own would fight the pattern
                        // that drives zap. finishSlice takes the picture to
                        // black.
                        self.finishSlice(
                            "reached the end of the clip",
                            v.duration_seconds,
                        );

                        break :blk null;
                    }

                    std.log.err(
                        "decode failed: {s}",
                        .{@errorName(err)},
                    );

                    util.sleepNs(self.io, 5_000_000);

                    break :blk null;
                };
            };

            // A null here means the step already ended the slice or backed off
            // after a failure; both cases have done their logging and cleanup.
            const meta = stepped orelse continue;

            const decode_ns = util.nowNs(self.io) - decode_start;

            if (last_pts) |previous_pts| {
                // The magnitude is what sets the interval; the sign only says
                // which way the mailbox was told time is moving. Pacing on the
                // magnitude is what lets one formula serve both directions,
                // where a forward-only `delta_pts > 0` test would leave reverse
                // playback completely unthrottled and spinning as fast as the
                // decoder can manage.
                const delta_pts = @abs(meta.pts - previous_pts);

                if (delta_pts > 0) {
                    const delta_seconds =
                        @as(f64, @floatFromInt(delta_pts)) *
                        c.av_q2d(v.time_base);

                    // Wall time per frame is content time divided by the rate.
                    // At speed 1 that is the source frame interval; at speed 2
                    // the same content interval is shown in half the time.
                    const interval_ns: u64 = @intFromFloat(
                        delta_seconds * 1_000_000_000.0 / @abs(self.speed),
                    );

                    // Pace against an absolute deadline instead of sleeping a
                    // whole frame interval after decoding. Sleeping the full
                    // interval makes the real period decode_time + interval,
                    // which runs the whole video slow and spreads decode jitter
                    // across every frame boundary.
                    if (deadline_ns == 0) {
                        deadline_ns = util.nowNs(self.io);
                    }
                    deadline_ns += interval_ns;

                    const now = util.nowNs(self.io);
                    if (deadline_ns > now) {
                        util.sleepNs(self.io, deadline_ns - now);
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
            // clears them. The position test has to follow the direction of
            // travel, because under reverse the position is counting down and
            // a `>=` test would never fire.
            if (self.stop_position_seconds) |stop_position| {
                const reached = if (reversing)
                    meta.position_seconds <= stop_position
                else
                    meta.position_seconds >= stop_position;

                if (reached) {
                    self.finishSlice("reached end", meta.position_seconds);
                    continue;
                }
            }

            if (self.stop_at_ns) |deadline| {
                if (util.nowNs(self.io) >= deadline) {
                    self.finishSlice("reached duration", meta.position_seconds);
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
        position: f64,
    ) void {
        if (self.slice_finished) return;

        self.slice_finished = true;

        // The picture does NOT go black here. A sample that has played its
        // slice goes silent, but the next event is normally already on its
        // way, and cutting to black for the gap between them is a black flash
        // on every event. So the frame holds and the blackout is scheduled
        // instead: a new trigger cancels it, and only a pattern that has
        // really stopped ever gets a black window.
        self.blackout_at_ns = util.nowNs(self.io) + blackout_grace_ns;

        std.log.info(
            "slice finished at {d:.3}s: {s}",
            .{ position, reason },
        );
    }

    /// Make `path` the active clip, reusing an already opened one. A pattern
    /// can retrigger the same sample many times a second, so reopening the
    /// file per event would churn decoders and fill the slot table.
    fn activatePath(
        self: *Player,
        path: []const u8,
    ) void {
        for (self.videos, 0..) |entry, i| {
            if (entry) |v| {
                if (std.mem.eql(u8, v.path, path)) {
                    self.assignActive(i);

                    std.log.info(
                        "active video index={d} path={s}",
                        .{ i, v.path },
                    );

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

        self.assignActive(index.?);

        std.log.info(
            "loaded video index={d} path={s}",
            .{ index.?, path },
        );
    }
};

fn lessThanBytes(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn clampUnit(value: f64) f64 {
    if (std.math.isNan(value)) return 0;
    return std.math.clamp(value, 0, 1);
}

/// The fastest playback rate accepted. Above 1 the frame interval shrinks in
/// proportion, so the cap is really a floor on how small a wall-clock interval
/// can get before one seek and one decode can no longer fit inside it. Past
/// this, extra speed stops being extra motion and starts being dropped frames.
const max_speed: f64 = 8;

/// How long a finished slice keeps showing its last frame before the window
/// goes black.
///
/// This is the gap a pattern is given to deliver its next event before the
/// picture is declared over. It has to cover the inter-onset interval of a
/// dense pattern, because anything arriving inside it must find a live window
/// to draw into, or every event boundary becomes a black flash. 150 ms is
/// about a sixteenth note at 160 BPM, so ordinary fast material retriggers
/// well inside it, while a pattern that has actually stopped still goes black
/// promptly instead of leaving a still on screen.
const blackout_grace_ns: u64 = 150 * 1_000_000;

/// Widest `n` accepted from the wire, so an absurd index cannot trap the cast.
/// It is far past any real collection length; the modulo in resolveSample is
/// what actually maps it onto a clip.
const max_n: i64 = std.math.maxInt(i32);
