const std = @import("std");
const c = @import("c");

const util = @import("util.zig");
const video = @import("video.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

/// How many concurrent pictures zap can carry. An orbit is SuperDirt's own
/// notion of an output voice, so a `/play` names one and zap keeps every orbit
/// independent: its own clip, its own slice, its own screen region, its own
/// worker.
pub const MAX_ORBITS = 8;

/// Upper bound on how many just-abandoned decoders an orbit will keep around
/// before closing them. An orbit switching clips retires its previous decoder
/// here; it is closed once the renderer is provably no longer using it.
const MAX_VIDEOS_PER_ORBIT = 16;

pub const MAX_PATH = 4096;
pub const MAX_NAME = 256;

const sample_extension = ".mp4";

/// How to read the `speed` value. Tidal sends this string, and the reading
/// changes the rate completely, so a unit that is merely ignored turns a
/// perfect sync into a video that runs at the wrong speed:
///
/// - `rate` (Tidal defaults here, also spelled "r" or "rate") — `speed` is a
///   playback rate. 1 is the source frame rate, 2 is twice as fast.
/// - `cycles` (Tidal "c") — `speed` is a cycle count the sample is stretched
///   to fill, so `speed 2` fills half a cycle. The rate a given value implies
///   depends on the tempo and on the clip, and only the player can compute it.
/// - `seconds` (Tidal "s") — `speed` is a wall-clock length in seconds.
///
/// Anything else Tidal might send is read as `rate`: SuperDirt itself maps an
/// unknown unit to an error, but zap silently falling back to a rate is the
/// least damaging reading of a sender it cannot name.
const SpeedUnit = enum { rate, cycles, seconds };

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

    /// How `speed` should be read. Defaults to a rate, which is what every
    /// event without a `unit` key gets.
    unit: SpeedUnit = .rate,

    /// Tempo in cycles per second, straight from Tidal's `cps`, which every
    /// `/play` event carries. Only meaningful when `unit` is `cycles`; the
    /// effective rate is then `speed * cps` scaled by the clip, which is why
    /// it cannot be resolved until the clip is known.
    cps: f64 = 0,
};

/// A normalized screen region. `x`/`y` are the top-left corner in normalized
/// screen units and `size` is a scalar scale, so the region keeps the source's
/// 16:9 shape: it is `size` of the width and `size` of the height of the
/// 1920x1080 logical space.
///
/// None of the three is bounded. The picture is anchored at its top-left and
/// the renderer clips whatever leaves the canvas, so `x`/`y` may be negative or
/// past the screen and `size` may exceed 1 to magnify. Defaults (0, 0, 1) are
/// the full screen, which is what a `/play` without a region has always meant.
const Region = struct {
    x: f64 = 0,
    y: f64 = 0,
    size: f64 = 1,
};

/// Mutable per-orbit state. The fields split along the same fault lines as the
/// original global state did:
///
/// - the OSC thread writes `trigger` and `region` under the player mutex;
/// - the orbit's worker reads `trigger` under the mutex and owns everything
///   else, including which decoder is `current_video`;
/// - the renderer reads `showing` (atomic) and `region`/`current_video`
///   (under the player mutex) to compose the picture.
const Orbit = struct {
    index: usize = undefined,

    /// Bumped on every event directed at this orbit. The orbit's worker
    /// applies a trigger only once, and only when it can see the whole struct,
    /// so the parameters of one event can never be applied piecemeal.
    trigger: TriggerState = .{},
    applied_trigger_generation: u64 = 0,

    /// Replaced on every event rather than accumulated: a parameter the event
    /// did not carry falls back to its default, so the region always describes
    /// the event that is playing now.
    region: Region = .{},

    /// Whether this orbit's picture should be on screen right now. The render
    /// loop has to know the difference between "waiting for the next frame of
    /// a playing slice" and "this orbit's slice is over, show nothing in its
    /// region". The mailbox cannot answer that: its last frame is still
    /// sitting there either way. So the worker owns this flag per orbit and
    /// the renderer only reads it.
    showing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    current_video: ?*video.VideoFile = null,

    /// Decoders this orbit stopped using but could not close yet, because the
    /// renderer was still uploading one of their frames. Drained by the orbit's
    /// worker.
    retired: [MAX_VIDEOS_PER_ORBIT]?*video.VideoFile = @splat(null),

    // Bounds of the slice the current trigger asked for, owned by this orbit's
    // worker and therefore lock-free. `null` means "no bound".
    stop_position_seconds: ?f64 = null,
    stop_at_ns: ?u64 = null,
    slice_finished: bool = false,

    /// Playback rate of the active trigger, sign carrying the direction. Read
    /// and written by the orbit's worker only.
    speed: f64 = 1,

    /// When this orbit's finished slice should actually go black, or null when
    /// no blackout is pending.
    ///
    /// A pattern retriggers back to back, so the moment a slice reaches its
    /// `end` or `duration` bound the next event is usually already on its way.
    /// Going black right then drops the picture for exactly that gap, and the
    /// gap lands mid display refresh often enough to read as a flicker on
    /// every single event. The orbit therefore holds its last frame instead, a
    /// new trigger cancels the pending blackout, and only a pattern that
    /// genuinely stops never reaches it.
    blackout_at_ns: ?u64 = null,
};

pub const Player = struct {
    io: std.Io,
    allocator: Allocator,

    mutex: std.Io.Mutex = .init,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// One voice per orbit, all running at once. Invariant: the only writer of
    /// the per-orbit trigger/region (the OSC thread) and the per-orbit worker
    /// both go through `mutex` for the fields they share; the rest is either
    /// worker-owned or an atomic.
    orbits: [MAX_ORBITS]Orbit = @splat(.{}),

    worker_threads: [MAX_ORBITS]?std.Thread = @splat(null),

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

        // One worker per orbit, alive for the lifetime of the process. They
        // sleep between frames, so eight mostly-idle decoders on the same
        // 1080p all-I material is well within budget, and a live pattern never
        // pays for spawning a thread in the hot path.
        for (0..MAX_ORBITS) |i| {
            self.orbits[i].index = i;
            self.worker_threads[i] = try std.Thread.spawn(
                .{},
                workerMain,
                .{ self, i },
            );
        }
    }

    pub fn stop(self: *Player) void {
        self.running.store(false, .release);

        for (&self.worker_threads) |*slot| {
            if (slot.*) |thread| {
                thread.join();
                slot.* = null;
            }
        }
    }

    pub fn deinit(self: *Player) void {
        self.stop();

        for (&self.orbits) |*orbit| {
            if (orbit.current_video) |v| {
                v.close();
                orbit.current_video = null;
            }

            for (&orbit.retired) |*entry| {
                if (entry.*) |v| {
                    v.close();
                    entry.* = null;
                }
            }
        }

        var it = self.collections.iterator();

        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.freeCollection(entry.value_ptr.*);
        }

        self.collections.deinit(self.allocator);
    }

    /// Apply one OSC event to one orbit. Every cinematic parameter is
    /// optional: an empty name keeps the orbit's current clip, so `begin`
    /// alone can re-slice what is already playing, and a trigger with nothing
    /// but a name just plays it from the start.
    ///
    /// `orbit` names the voice; out of range it names nothing, so the whole
    /// event is dropped rather than guessed at. `x`/`y`/`size` are optional
    /// and describe the region for this event only: one that is absent falls
    /// back to its default (0, 0, 1), so an event with no region is full
    /// screen even if the previous event had shrunk or moved the picture.
    pub fn requestTrigger(
        self: *Player,
        name: []const u8,
        begin: f64,
        end: f64,
        n: ?f64,
        duration: f64,
        speed: f64,
        unit: []const u8,
        cps: f64,
        orbit: i32,
        x: ?f64,
        y: ?f64,
        size: ?f64,
    ) void {
        if (name.len >= MAX_NAME) {
            std.log.warn("s: name too long ({d} bytes); ignored", .{name.len});
            return;
        }

        if (orbit < 0 or orbit >= MAX_ORBITS) {
            std.log.warn(
                "orbit {d} is out of range [0..{d}]; event ignored",
                .{ orbit, MAX_ORBITS - 1 },
            );
            return;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const target_orbit = &self.orbits[@intCast(orbit)];

        if (name.len > 0) {
            @memcpy(
                target_orbit.trigger.name[0..name.len],
                name,
            );
        }

        target_orbit.trigger.name_len = name.len;
        target_orbit.trigger.begin = clampUnit(begin);
        target_orbit.trigger.end = clampUnit(end);
        // `n` is optional and defaults to 0, so an absent `n` and an explicit
        // `n 0` are the same request. The sign is kept because `n` wraps: a
        // negative index counts back from the last clip, and collapsing it to
        // 0 here would make every negative `n` play the first clip instead.
        target_orbit.trigger.n = if (n) |value| blk: {
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
        target_orbit.trigger.duration = @max(duration, 0);
        // Only the sign and magnitude matter; the magnitude is clamped so an
        // absurd rate cannot make the pacing deadline wrap around.
        target_orbit.trigger.speed = std.math.clamp(speed, -max_speed, max_speed);
        target_orbit.trigger.unit = if (std.mem.eql(u8, unit, "c"))
            .cycles
        else if (std.mem.eql(u8, unit, "s"))
            .seconds
        else
            .rate;
        target_orbit.trigger.cps = cps;

        // The region is rebuilt from this event on every trigger. A parameter
        // the event did not carry keeps the default from `Region{ .{} }`, so
        // the region never lingers from an earlier event.
        //
        // The values are deliberately unbounded: `x`/`y` may be negative or
        // past the screen and `size` may exceed 1, because the picture is
        // anchored at its top-left and the renderer clips whatever leaves the
        // canvas. Only a non-finite value is refused, since it would poison
        // the destination rect; a negative `size` is floored at 0 so the
        // renderer never gets a negative width.
        var region = Region{};
        if (x) |value| region.x = finiteOrZero(value);
        if (y) |value| region.y = finiteOrZero(value);
        if (size) |value| region.size = @max(finiteOrZero(value), 0);
        target_orbit.region = region;

        target_orbit.trigger.generation += 1;

        std.log.info(
            "TRIGGER #{d} orbit={d} s={s} begin={d:.4} end={d:.4} n={d} duration={d:.3} speed={d:.3} unit={s} cps={d:.4} rect=({d:.3},{d:.3},{d:.3})",
            .{
                target_orbit.trigger.generation,
                orbit,
                if (name.len > 0) name else "",
                target_orbit.trigger.begin,
                target_orbit.trigger.end,
                target_orbit.trigger.n,
                target_orbit.trigger.duration,
                target_orbit.trigger.speed,
                unit,
                target_orbit.trigger.cps,
                target_orbit.region.x,
                target_orbit.region.y,
                target_orbit.region.size,
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

    /// True while this orbit has a picture. False before its first trigger and
    /// after a slice ends, which is when its region must go black.
    pub fn orbitShowsFrame(self: *Player, index: usize) bool {
        return self.orbits[index].showing.load(.acquire);
    }

    /// The orbit's current region, as normalized values. Read under the mutex
    /// because the OSC thread owns it.
    pub fn orbitRegion(self: *Player, index: usize) Region {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        return self.orbits[index].region;
    }

    pub fn takeLatestFrame(
        self: *Player,
        index: usize,
    ) ?video.FrameHandle {
        // Reading the orbit's current video and taking a slot from it are one
        // critical section. If the orbit's worker swapped clips between the
        // two, it might legally close the video this frame belongs to; taking
        // under the same lock means every access to a `VideoFile` from here is
        // ordered against the swap, and the mailbox's `displaying` slot guards
        // the upload below.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const active = self.orbits[index].current_video orelse return null;
        return active.takeLatestFrame();
    }

    pub fn releaseFrame(
        _: *Player,
        frame: video.FrameHandle,
    ) void {
        // The handle names the mailbox it came from, so an orbit switching
        // clips between take and release cannot make this return the slot to
        // the wrong one.
        frame.owner.release();
    }

    /// The clip this orbit is currently playing, or null before its first
    /// load. Guarded by the mutex because the orbit's worker assigns it, and
    /// because `takeLatestFrame` needs the read and the take to be one atomic
    /// step against a clip swap.
    fn workerMain(self: *Player, orbit_index: usize) void {
        std.log.info("orbit {d}: video worker started", .{orbit_index});

        const o = &self.orbits[orbit_index];

        var last_pts: ?i64 = null;
        var deadline_ns: u64 = 0;

        while (self.running.load(.acquire)) {
            // Close any decoder this orbit gave up on earlier, now that the
            // renderer can no longer be holding one of its frames.
            for (&o.retired) |*entry| {
                if (entry.*) |v| {
                    if (!v.mailbox.hasDisplaying()) {
                        v.close();
                        entry.* = null;
                    }
                }
            }

            var trigger: ?TriggerState = null;

            self.mutex.lockUncancelable(self.io);

            // Not marked applied here on purpose: an event that arrives while
            // a clip is still opening has to stay pending until the worker can
            // act on it as a whole.
            if (o.trigger.generation != o.applied_trigger_generation) {
                trigger = o.trigger;
            }

            self.mutex.unlock(self.io);

            if (trigger) |t| {
                self.mutex.lockUncancelable(self.io);
                o.applied_trigger_generation = t.generation;
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
                        self.activatePath(orbit_index, path);
                    }
                }

                // A new event always resumes playback and restarts pacing, and
                // it cancels a blackout the previous slice had scheduled: two
                // adjacent events must never put a black frame between them.
                o.slice_finished = false;
                o.blackout_at_ns = null;
                last_pts = null;
                deadline_ns = 0;

                o.stop_position_seconds = null;
                o.stop_at_ns = null;

                if (t.duration > 0) {
                    o.stop_at_ns = util.nowNs(self.io) + @as(
                        u64,
                        @intFromFloat(t.duration * 1_000_000_000.0),
                    );
                }

                o.speed = t.speed;

                const target = o.current_video orelse {
                    std.log.warn(
                        "trigger #{d}: no clip to play on orbit {d}",
                        .{ t.generation, orbit_index },
                    );
                    continue;
                };

                // A cycle-relative speed is not a rate until the clip and the
                // tempo exist, which is why it is resolved here and not in
                // requestTrigger. Tidal's reading: "speed 2 means samples will
                // be stretched to fill half a cycle", i.e. a speed of n fills
                // 1/n cycles. Fill time is (1/speed)/cps seconds, so the rate
                // the clip must be played at to fill that window is
                //
                //     rate = duration_seconds / ((1 / speed) / cps)
                //          = duration_seconds * speed * cps
                //
                // Once the rate is right, a slice of the clip occupies exactly
                // its wall-clock budget, and the pattern and the picture stay
                // in step without any extra synchronization. The sign tags
                // along unchanged because duration and cps are positive, so
                // reverse still reverses.
                //
                // A rate that unit c or s derives is clamped here in the same
                // way the wire value was in requestTrigger: a long clip at a
                // high tempo can otherwise imply a rate far past `max_speed`.
                // The `rate` unit never reaches this code, since the wire
                // value was already clamped before being stored.
                if (t.unit == .cycles) {
                    o.speed = std.math.clamp(
                        target.duration_seconds * o.speed * t.cps,
                        -max_speed,
                        max_speed,
                    );
                } else if (t.unit == .seconds) {
                    if (o.speed == 0) {
                        // An empty window is the speed-0 hold, not an
                        // unbounded rate; keep the degenerate case intact.
                        o.speed = 0;
                    } else {
                        o.speed = std.math.clamp(
                            target.duration_seconds / o.speed,
                            -max_speed,
                            max_speed,
                        );
                    }
                }

                const reversing = t.speed < 0;

                // A negative speed swaps the two ends, exactly as SuperDirt
                // does in `DirtEvent.orderTimeSpan`:
                //
                //     if(~speed < 0) { temp = ~end; ~end = ~begin; ~begin = temp }
                //
                // A pattern therefore always describes a slice as begin < end
                // and lets the sign of speed say which way it is read.
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
                    o.stop_position_seconds = end * target.duration_seconds;
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
                // putting a later clip's last frame in this orbit while a new
                // clip is still being opened.
                o.showing.store(true, .release);

                std.log.info(
                    "orbit {d}: trigger #{d} began at {d:.3}s / {d:.3}s, frame_pts={d}, speed={d:.3}, latency={d:.2}ms",
                    .{
                        orbit_index,
                        t.generation,
                        meta.position_seconds,
                        target.duration_seconds,
                        meta.pts,
                        o.speed,
                        @as(f64, @floatFromInt(util.nowNs(self.io) - start_ns)) /
                            1_000_000.0,
                    },
                );

                // seekNormalized already published the target frame.
                continue;
            }

            const v = o.current_video orelse {
                util.sleepNs(self.io, 1_000_000);
                continue;
            };

            if (o.slice_finished) {
                // The grace period is up and no new event claimed this orbit's
                // window, so the slice really is over: now, and only now, black
                // this orbit's region.
                if (o.blackout_at_ns) |at| {
                    if (util.nowNs(self.io) >= at) {
                        o.showing.store(false, .release);
                        o.blackout_at_ns = null;
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
            if (o.speed == 0) {
                util.sleepNs(self.io, 1_000_000);

                if (o.stop_at_ns) |deadline| {
                    if (util.nowNs(self.io) >= deadline) {
                        // Report where the picture actually is, not zero, or
                        // the log claims the slice fell off the front of the
                        // clip when nothing moved at all.
                        const held = if (last_pts) |pts|
                            @as(f64, @floatFromInt(pts)) * c.av_q2d(v.time_base)
                        else
                            0;

                        finishSlice(o, self.io, "reached duration", held);
                    }
                }

                continue;
            }

            const reversing = o.speed < 0;

            const stepped = blk: {
                if (reversing) {
                    const from_pts = last_pts orelse 0;

                    break :blk v.stepBackward(from_pts) catch |err| {
                        if (err == error.StartOfClip) {
                            // Running off the front of the clip ends the slice
                            // the same way running off the end does: the sample
                            // has played out, so the region goes black.
                            finishSlice(
                                o,
                                self.io,
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
                        // that drives zap. finishSlice takes this orbit's
                        // region to black.
                        finishSlice(
                            o,
                            self.io,
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
                        delta_seconds * 1_000_000_000.0 / @abs(o.speed),
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
            if (o.stop_position_seconds) |stop_position| {
                const reached = if (reversing)
                    meta.position_seconds <= stop_position
                else
                    meta.position_seconds >= stop_position;

                if (reached) {
                    finishSlice(o, self.io, "reached end", meta.position_seconds);
                    continue;
                }
            }

            if (o.stop_at_ns) |deadline| {
                if (util.nowNs(self.io) >= deadline) {
                    finishSlice(o, self.io, "reached duration", meta.position_seconds);
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

        std.log.info("orbit {d}: video worker stopped", .{orbit_index});
    }

    /// Stop this orbit at the current frame and keep showing it, the way a sample
    /// goes silent after its slice instead of restarting on its own. Only this
    /// orbit's picture is affected; every other orbit keeps drawing.
    fn finishSlice(
        o: *Orbit,
        io: std.Io,
        reason: []const u8,
        position: f64,
    ) void {
        if (o.slice_finished) return;

        o.slice_finished = true;

        // The picture does NOT go black here. A sample that has played its
        // slice goes silent, but the next event is normally already on its
        // way, and cutting to black for the gap between them is a black flash
        // on every event. So the frame holds and the blackout is scheduled
        // instead: a new trigger cancels it, and only a pattern that has
        // really stopped ever gets a black region.
        o.blackout_at_ns = util.nowNs(io) + blackout_grace_ns;

        std.log.info(
            "orbit {d}: slice finished at {d:.3}s: {s}",
            .{ o.index, position, reason },
        );
    }

    /// Make `path` the current clip of one orbit, reusing the decoder that
    /// orbit already has for it. A pattern can retrigger the same sample many
    /// times a second, so reopening the file per event would churn decoders.
    ///
    /// The cache is per orbit, not global: a global decoder can only serve one
    /// playhead, and two orbits may be playing the same clip at different
    /// positions at the same time.
    fn activatePath(
        self: *Player,
        orbit_index: usize,
        path: []const u8,
    ) void {
        const o = &self.orbits[orbit_index];

        self.mutex.lockUncancelable(self.io);
        const already = if (o.current_video) |v|
            std.mem.eql(u8, v.path, path)
        else
            false;
        self.mutex.unlock(self.io);

        if (already) return;

        // Open the replacement before touching the current one, so a clip that
        // cannot be opened leaves this orbit's picture exactly where it was:
        // half-applying a load would restart nothing, it would go black.
        const new_video =
            video.VideoFile.open(
                self.io,
                self.allocator,
                path,
            ) catch |err| {
                std.log.err(
                    "orbit {d}: LOAD failed path={s}: {s}",
                    .{ orbit_index, path, @errorName(err) },
                );
                return;
            };

        // Swap under the mutex, atomically against the renderer's take. The
        // old video is then retired out of the critical section; it can only
        // be closed once no slot from it is `displaying`.
        self.mutex.lockUncancelable(self.io);
        const previous = o.current_video;
        o.current_video = new_video;
        self.mutex.unlock(self.io);

        if (previous) |old| {
            recycleVideo(o, old);
        }

        std.log.info(
            "orbit {d}: loaded video path={s}",
            .{ orbit_index, path },
        );
    }

    /// Delay `old`'s close or close it immediately, whichever is safe. The
    /// renderer may be uploading one of this video's frames right now, and a
    /// mailbox with a `displaying` slot must outlive that upload, so such a
    /// video is parked in `retired` and closed by the orbit's worker once the
    /// slot frees.
    fn recycleVideo(
        o: *Orbit,
        old: *video.VideoFile,
    ) void {
        // Close anything already parked that has become safe, to make room.
        for (&o.retired) |*entry| {
            if (entry.*) |v| {
                if (!v.mailbox.hasDisplaying()) {
                    v.close();
                    entry.* = null;
                }
            }
        }

        for (&o.retired) |*entry| {
            if (entry.* == null) {
                entry.* = old;
                return;
            }
        }

        // Every parked decoder is still in use and the queue is full. The
        // renderer would have to be stalled well past a refresh for this to
        // happen; the safe move is to leave the decoder open until shutdown
        // rather than free memory the renderer could still be reading.
        std.log.warn(
            "orbit {d}: retired video queue full; a decoder stays open until shutdown",
            .{o.index},
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

/// Pass a region value through untouched except for the one thing that cannot
/// survive the trip to the renderer: a NaN or an infinity would make the
/// destination rect non-finite. Everything else, including negatives and
/// values past 1, is meaningful and is left for the canvas to clip.
fn finiteOrZero(value: f64) f64 {
    if (std.math.isFinite(value)) return value;
    return 0;
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
