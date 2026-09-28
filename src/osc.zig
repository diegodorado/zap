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

        if (std.mem.eql(u8, address, "/load")) {
            if (typetags.len != 2 or typetags[1] != 's') {
                return error.InvalidArguments;
            }

            const path = try readOscString(packet, &pos);

            log.debug("/load {s}", .{path});

            self.player.requestLoad(path);
            return;
        }

        if (std.mem.eql(u8, address, "/n")) {
            if (typetags.len != 2 or typetags[1] != 'i') {
                return error.InvalidArguments;
            }

            const value = try readI32(packet, &pos);

            if (value < 0) {
                return error.InvalidArguments;
            }

            log.debug("/n {d}", .{value});

            self.player.requestSelect(@intCast(value));
            return;
        }

        if (std.mem.eql(u8, address, "/seek")) {
            if (typetags.len != 2) {
                return error.InvalidArguments;
            }

            const value: f64 = switch (typetags[1]) {
                'f' => @floatCast(try readF32(packet, &pos)),
                'i' => @floatFromInt(try readI32(packet, &pos)),
                else => return error.InvalidArguments,
            };

            log.debug("/seek {d:.6}", .{value});

            self.player.requestSeek(value);
            return;
        }

        if (std.mem.eql(u8, address, "/speed")) {
            if (typetags.len != 2) {
                return error.InvalidArguments;
            }

            const value: f64 = switch (typetags[1]) {
                'f' => @floatCast(try readF32(packet, &pos)),
                'i' => @floatFromInt(try readI32(packet, &pos)),
                else => return error.InvalidArguments,
            };

            log.debug("/speed {d:.6}", .{value});

            self.player.requestSpeed(value);
            return;
        }

        log.debug("unknown OSC address: {s}", .{address});
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

fn readF32(packet: []const u8, pos: *usize) !f32 {
    const bits: u32 = @bitCast(try readI32(packet, pos));
    return @bitCast(bits);
}
