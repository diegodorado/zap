const std = @import("std");

/// Monotonic nanoseconds, the one clock zap paces against. It is not a wall
/// clock: frame deadlines have to survive the system clock being adjusted
/// underneath a performance.
pub fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.now(.awake, io).nanoseconds);
}

pub fn sleepNs(io: std.Io, nanoseconds: u64) void {
    io.sleep(
        .fromNanoseconds(nanoseconds),
        .awake,
    ) catch |err| switch (err) {
        error.Canceled => {},
    };
}
