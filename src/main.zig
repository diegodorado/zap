const std = @import("std");

const Player = @import("player.zig").Player;
const OscServer = @import("osc.zig").OscServer;
const Renderer = @import("render.zig").Renderer;
const benchmark = @import("benchmark.zig");

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // -------------------------------------------------------------------------
    // Command-line arguments
    // -------------------------------------------------------------------------

    var args = init.minimal.args.iterate();

    var benchmark_path: ?[]const u8 = null;
    var initial_path: ?[]const u8 = null;
    var media_dir: ?[]const u8 = null;

    _ = args.next(); // executable name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--benchmark")) {
            benchmark_path = args.next() orelse {
                log.err("--benchmark requires a video path", .{});
                return error.MissingBenchmarkPath;
            };
            break;
        }

        if (std.mem.eql(u8, arg, "--media")) {
            media_dir = args.next() orelse {
                log.err("--media requires a directory", .{});
                return error.MissingMediaDir;
            };
            continue;
        }

        if (initial_path == null) {
            initial_path = arg;
        }
    }

    // -------------------------------------------------------------------------
    // Benchmark mode
    // -------------------------------------------------------------------------

    if (benchmark_path) |path| {
        try benchmark.run(io, allocator, path);
        return;
    }

    // -------------------------------------------------------------------------
    // Core systems
    // -------------------------------------------------------------------------

    var player = Player.init(io, allocator);
    defer player.deinit();

    if (media_dir) |dir| {
        try player.setMediaDir(dir);
    }

    try player.start();

    var renderer = try Renderer.init();
    defer renderer.deinit();

    var osc = OscServer.init(
        allocator,
        &player,
    );
    defer osc.stop();

    try osc.start();

    // -------------------------------------------------------------------------
    // Optional initial video
    // -------------------------------------------------------------------------

    if (initial_path) |path| {
        player.requestLoad(path);
    }

    log.info("zap started", .{});

    // -------------------------------------------------------------------------
    // Main/render loop
    // -------------------------------------------------------------------------

    while (!renderer.pollQuit()) {
        // No sleep: SDL_RenderPresent blocks until the next display refresh,
        // so the loop is paced by the display. Sleeping here added latency and
        // hid the fact that vsync was not doing the pacing.
        try renderer.render(&player);
    }

    log.info("shutting down", .{});
}
