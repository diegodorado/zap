const std = @import("std");
const c = @import("c");

const Player = @import("player.zig").Player;

const log = std.log.scoped(.osc);

const OSC_PORT: u16 = 9000;
const MAX_PACKET_SIZE: usize = 65536;

pub const OscServer = struct {
    allocator: std.mem.Allocator,
    player: *Player,

    socket_fd: c_int = -1,
    thread: ?std.Thread = null,

    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        player: *Player,
    ) OscServer {
        return .{
            .allocator = allocator,
            .player = player,
        };
    }

    pub fn start(self: *OscServer) !void {
        if (self.running.load(.acquire)) {
            return;
        }

        const fd = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
        if (fd < 0) {
            return error.SocketCreateFailed;
        }

        self.socket_fd = fd;

        var reuse: c_int = 1;
        if (c.setsockopt(
            fd,
            c.SOL_SOCKET,
            c.SO_REUSEADDR,
            &reuse,
            @sizeOf(c_int),
        ) < 0) {
            _ = c.close(fd);
            self.socket_fd = -1;
            return error.SocketOptionFailed;
        }

        // 100 ms receive timeout so stop() doesn't have to wait forever.
        var timeout = c.struct_timeval{
            .tv_sec = 0,
            .tv_usec = 100_000,
        };

        if (c.setsockopt(
            fd,
            c.SOL_SOCKET,
            c.SO_RCVTIMEO,
            &timeout,
            @sizeOf(c.struct_timeval),
        ) < 0) {
            _ = c.close(fd);
            self.socket_fd = -1;
            return error.SocketOptionFailed;
        }

        var address = std.mem.zeroes(c.struct_sockaddr_in);
        address.sin_family = c.AF_INET;
        address.sin_port = c.htons(OSC_PORT);
        address.sin_addr.s_addr = c.htonl(c.INADDR_ANY);

        if (c.bind(
            fd,
            @ptrCast(&address),
            @sizeOf(c.struct_sockaddr_in),
        ) < 0) {
            _ = c.close(fd);
            self.socket_fd = -1;
            return error.BindFailed;
        }

        self.running.store(true, .release);

        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});

        log.info("listening on UDP {d}", .{OSC_PORT});
    }

    pub fn stop(self: *OscServer) void {
        if (!self.running.swap(false, .acq_rel)) {
            return;
        }

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        if (self.socket_fd >= 0) {
            _ = c.close(self.socket_fd);
            self.socket_fd = -1;
        }

        log.info("stopped", .{});
    }

    fn threadMain(self: *OscServer) void {
        var buffer: [MAX_PACKET_SIZE]u8 = undefined;

        while (self.running.load(.acquire)) {
            var from = std.mem.zeroes(c.struct_sockaddr_in);
            var from_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);

            const received = c.recvfrom(
                self.socket_fd,
                @ptrCast(&buffer),
                buffer.len,
                0,
                @ptrCast(&from),
                &from_len,
            );

            if (received < 0) {
                const err = std.c._errno().*;

                if (!self.running.load(.acquire)) {
                    break;
                }

                if (err == c.EAGAIN or err == c.EWOULDBLOCK) {
                    continue;
                }

                log.warn("recvfrom failed: errno={d}", .{err});
                continue;
            }

            if (received == 0) {
                continue;
            }

            self.parsePacket(buffer[0..@intCast(received)]) catch |err| {
                log.warn("invalid OSC packet: {s}", .{@errorName(err)});
            };
        }
    }

    fn parsePacket(self: *OscServer, packet: []const u8) !void {
        var pos: usize = 0;

        const address = try readOscString(packet, &pos);
        const typetags = try readOscString(packet, &pos);

        if (typetags.len == 0 or typetags[0] != ',') {
            return error.InvalidTypeTags;
        }

        // OSC 1.0 allows an 8-byte timetag immediate between the typetag
        // string and the arguments, and the reader that zap mirrors treats it
        // as optional. It is only recognized as a timetag when the top bit of
        // the seconds word is clear and the top bit of the fraction word is
        // set; anything else is argument data. A string or float argument
        // cannot pass that test, so this cannot misfire on a packet that has
        // no timetag.
        if (pos + 8 <= packet.len) {
            const seconds = packet[pos..][0..4];
            const fraction = packet[pos + 4 ..][0..4];

            if ((seconds[0] & 0x80) == 0 and (fraction[0] & 0x80) != 0) {
                pos += 8;
            }
        }

        if (std.mem.eql(u8, address, "/play")) {
            try self.parsePlayEvent(packet, typetags, &pos);
            return;
        }

        log.debug("unknown OSC address: {s}", .{address});
    }

    /// `/play` as SuperDirt sends it: a flat list of key/value pairs, in any
    /// order, where the value's type is not known until the key is read.
    ///
    ///     /play s "s" s "bd3" s "begin" f 0.2 s "end" f 0.4 s "delta" f 0.5
    ///
    /// Keys zap does not use are still fully consumed. Skipping the value of
    /// an unrecognized key would leave the reader mid-packet, and every later
    /// field would be garbage.
    fn parsePlayEvent(
        self: *OscServer,
        packet: []const u8,
        typetags: []const u8,
        pos: *usize,
    ) !void {
        const arg_tags = typetags[1..];

        if (arg_tags.len % 2 != 0) return error.InvalidArguments;

        var name: []const u8 = "";
        var begin: ?f64 = null;
        var end: ?f64 = null;
        var n: ?f64 = null;
        var delta: ?f64 = null;
        var legato: ?f64 = null;
        var speed: ?f64 = null;
        var unit: []const u8 = "r";
        // `cps` is always on the wire (`/play` events carry it) and is never
        // zero, so it is read as-is instead of defaulted.
        var cps: f64 = undefined;
        // `orbit` is an int32, exactly as SuperDirt sends it. It selects which
        // of zap's voices this event drives; out of range it is refused.
        var orbit: i32 = 0;
        // `x`/`y`/`size` are optional, so they stay optional until the player
        // decides whether to move this orbit's region.
        var x: ?f64 = null;
        var y: ?f64 = null;
        var size: ?f64 = null;

        var i: usize = 0;
        while (i < arg_tags.len) : (i += 2) {
            if (arg_tags[i] != 's') return error.InvalidArguments;

            const key = try readOscString(packet, pos);

            switch (arg_tags[i + 1]) {
                's' => {
                    const value = try readOscString(packet, pos);
                    if (std.mem.eql(u8, key, "s")) {
                        name = value;
                    } else if (std.mem.eql(u8, key, "unit")) {
                        unit = value;
                    }
                },
                'i' => {
                    const value = try readI32(packet, pos);
                    if (std.mem.eql(u8, key, "orbit")) {
                        orbit = value;
                    }
                },
                'f', 'd' => {
                    const value: f64 = switch (arg_tags[i + 1]) {
                        'f' => @floatCast(try readF32(packet, pos)),
                        else => try readF64(packet, pos),
                    };

                    if (std.mem.eql(u8, key, "begin")) {
                        begin = value;
                    } else if (std.mem.eql(u8, key, "end")) {
                        end = value;
                    } else if (std.mem.eql(u8, key, "n")) {
                        n = value;
                    } else if (std.mem.eql(u8, key, "delta")) {
                        delta = value;
                    } else if (std.mem.eql(u8, key, "legato")) {
                        legato = value;
                    } else if (std.mem.eql(u8, key, "speed")) {
                        speed = value;
                    } else if (std.mem.eql(u8, key, "cps")) {
                        cps = value;
                    } else if (std.mem.eql(u8, key, "x")) {
                        x = value;
                    } else if (std.mem.eql(u8, key, "y")) {
                        y = value;
                    } else if (std.mem.eql(u8, key, "size")) {
                        size = value;
                    }
                },
                'h' => _ = try readI64(packet, pos),
                'c' => _ = try readChar(packet, pos),
                // Timetags and the no-payload pseudo-types.
                'T', 'F', 'N', 'I' => {},
                else => return error.UnsupportedType,
            }
        }

        // duration is derived, never transmitted: SuperDirt plays a grain for
        // delta * legato, so a video slice has to last exactly as long.
        const duration = (delta orelse 0) * (legato orelse 1);

        // `n` is optional: an absent key is the same as 0, which is
        // SuperDirt's own default for it.
        //
        // `speed` is likewise optional and defaults to 1. A negative value is
        // not clamped away: it is what asks for reverse playback, so the only
        // value rejected here is a non-finite one, which would poison every
        // pacing calculation downstream.
        const requested_speed = speed orelse 1.0;

        if (!std.math.isFinite(requested_speed)) {
            std.log.warn(
                "speed {d} is not a number; treating this event as speed 1",
                .{requested_speed},
            );
            self.player.requestTrigger(
                name,
                begin orelse 0,
                end orelse 1,
                n orelse 0,
                duration,
                1.0,
                unit,
                cps,
                orbit,
                x,
                y,
                size,
            );
            return;
        }

        self.player.requestTrigger(
            name,
            begin orelse 0,
            end orelse 1,
            n orelse 0,
            duration,
            requested_speed,
            unit,
            cps,
            orbit,
            x,
            y,
            size,
        );
    }
};

fn readOscString(packet: []const u8, pos: *usize) ![]const u8 {
    if (pos.* >= packet.len) {
        return error.TruncatedPacket;
    }

    const start = pos.*;

    while (pos.* < packet.len and packet[pos.*] != 0) {
        pos.* += 1;
    }

    if (pos.* >= packet.len) {
        return error.TruncatedPacket;
    }

    const result = packet[start..pos.*];

    pos.* += 1;

    while ((pos.* & 3) != 0) {
        if (pos.* >= packet.len) {
            return error.TruncatedPacket;
        }
        pos.* += 1;
    }

    return result;
}

fn readI32(packet: []const u8, pos: *usize) !i32 {
    if (pos.* + 4 > packet.len) {
        return error.TruncatedPacket;
    }

    // OSC argument types are big-endian by specification.
    const value = std.mem.readInt(
        i32,
        &packet[pos.*..][0..4].*,
        .big,
    );

    pos.* += 4;
    return value;
}

fn readI64(packet: []const u8, pos: *usize) !i64 {
    if (pos.* + 8 > packet.len) {
        return error.TruncatedPacket;
    }

    const value = std.mem.readInt(
        i64,
        &packet[pos.*..][0..8].*,
        .big,
    );

    pos.* += 8;
    return value;
}

fn readChar(packet: []const u8, pos: *usize) !u8 {
    if (pos.* + 4 > packet.len) {
        return error.TruncatedPacket;
    }

    pos.* += 4;
    return packet[pos.* - 4];
}

fn readF32(packet: []const u8, pos: *usize) !f32 {
    const bits: u32 = @bitCast(try readI32(packet, pos));
    return @bitCast(bits);
}

fn readF64(packet: []const u8, pos: *usize) !f64 {
    if (pos.* + 8 > packet.len) {
        return error.TruncatedPacket;
    }

    // OSC floats and doubles are big-endian by specification.
    const bits = std.mem.readInt(
        u64,
        &packet[pos.*..][0..8].*,
        .big,
    );

    pos.* += 8;
    return @bitCast(bits);
}
