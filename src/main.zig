const std = @import("std");

const Player = @import("player.zig").Player;
const OscServer = @import("osc.zig").OscServer;
const Renderer = @import("render.zig").Renderer;
const benchmark = @import("benchmark.zig");

const log = std.log.scoped(.main);

const usage = "usage: zap [--benchmark] [--fullscreen] <media-dir>";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Command-line arguments

    var args = init.minimal.args.iterate();

    var benchmark_mode = false;
    var fullscreen = false;
    var media_dir: ?[]const u8 = null;

    _ = args.next(); // executable name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--benchmark")) {
            benchmark_mode = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--fullscreen")) {
            fullscreen = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            log.err("unknown option '{s}'", .{arg});
            log.err(usage, .{});
            return error.UnknownArgument;
        }

        if (media_dir != null) {
            log.err("unexpected extra argument '{s}'", .{arg});
            log.err(usage, .{});
            return error.UnexpectedArgument;
        }

        media_dir = arg;
    }

    // The media directory is not optional. Without it there is nothing for a
    // `/play` to name, and silently defaulting to a relative "media" that may
    // not exist is how a working setup turns into a silent one.

    const path = media_dir orelse {
        log.err("missing <media-dir>", .{});
        log.err(usage, .{});
        return error.MissingMediaDir;
    };

    // Benchmark mode: the same positional argument, pointed at a clip instead
    // of at a collection root.

    if (benchmark_mode) {
        try benchmark.run(io, allocator, path);
        return;
    }

    // Core systems

    var player = Player.init(io, allocator, path);
    defer player.deinit();

    player.scan() catch |err| {
        log.err(
            "cannot use '{s}' as a media directory: {s}",
            .{ path, @errorName(err) },
        );
        return error.MediaDirUnusable;
    };

    try player.start();

    var renderer = try Renderer.init(fullscreen);
    defer renderer.deinit();

    var osc = OscServer.init(
        allocator,
        &player,
    );
    defer osc.stop();

    try osc.start();

    log.info("zap started", .{});

    // render loop
    while (!renderer.pollQuit()) {
        // No sleep: SDL_RenderPresent blocks until the next display refresh,
        // so the loop is paced by the display. Sleeping here added latency and
        // hid the fact that vsync was not doing the pacing.
        try renderer.render(&player);
    }

    log.info("shutting down", .{});
}
