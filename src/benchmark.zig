const std = @import("std");
const util = @import("util.zig");
const video = @import("video.zig");

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    const v = try video.VideoFile.open(
        io,
        allocator,
        path,
    );

    defer v.close();

    const count = 100;

    // Seeking past the last decodable frame yields EndOfStream, so keep
    // random positions slightly below the end of the file.
    const max_position = 0.95;

    var samples: [count]u64 = undefined;
    var recorded: usize = 0;
    var skipped: usize = 0;

    var rng_state: u64 = 0x1234_5678_9abc_def0;

    std.debug.print(
        "Benchmark\n",
        .{},
    );

    std.debug.print(
        "file={s}\n",
        .{path},
    );

    std.debug.print(
        "duration={d:.3}s fps={d:.3}\n",
        .{
            v.duration_seconds,
            v.fps,
        },
    );

    std.debug.print(
        "seeks={d}\n\n",
        .{count},
    );

    for (0..count) |i| {
        if (recorded == count) break;

        const position = max_position *
            (@as(f64, @floatFromInt(nextRandom(&rng_state))) /
                @as(f64, @floatFromInt(std.math.maxInt(u64))));

        const start_ns = util.nowNs(io);

        _ = v.seekNormalized(position) catch |err| {
            if (err == error.EndOfStream) {
                skipped += 1;
                continue;
            }

            return err;
        };

        samples[recorded] = util.nowNs(io) - start_ns;

        recorded += 1;

        if ((i + 1) % 10 == 0) {
            std.debug.print(
                "  {d}/{d}\n",
                .{
                    i + 1,
                    count,
                },
            );
        }
    }

    if (recorded == 0) {
        return error.NoSamples;
    }

    const sorted = samples[0..recorded];

    std.sort.heap(
        u64,
        sorted,
        {},
        lessThan,
    );

    const min_ns = sorted[0];
    const median_ns = sorted[recorded / 2];
    const p95_ns = sorted[(recorded * 95) / 100];
    const max_ns = sorted[recorded - 1];

    if (skipped > 0) {
        std.debug.print(
            "\nskipped={d} (no decodable frame at target)\n",
            .{skipped},
        );
    }

    std.debug.print(
        "\nResults: seek -> decoded target frame\n",
        .{},
    );

    printMetric(
        "min",
        min_ns,
    );

    printMetric(
        "median",
        median_ns,
    );

    printMetric(
        "p95",
        p95_ns,
    );

    printMetric(
        "max",
        max_ns,
    );
}

fn printMetric(
    name: []const u8,
    nanoseconds: u64,
) void {
    std.debug.print(
        "{s:>8}: {d:.3} ms\n",
        .{
            name,
            @as(f64, @floatFromInt(nanoseconds)) /
                1_000_000.0,
        },
    );
}

fn lessThan(
    _: void,
    a: u64,
    b: u64,
) bool {
    return a < b;
}

fn nextRandom(
    state: *u64,
) u64 {
    var x = state.*;

    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;

    state.* = x;

    return x;
}
