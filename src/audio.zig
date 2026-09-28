const std = @import("std");

pub const AudioManager = struct {
    initialized: bool = false,

    pub fn init() !AudioManager {
        std.log.info(
            "AUDIO backend: stub; CoreAudio integration pending",
            .{},
        );

        return .{
            .initialized = true,
        };
    }

    pub fn deinit(self: *AudioManager) void {
        _ = self;
    }

    pub fn clockSeconds(
        self: *AudioManager,
    ) ?f64 {
        _ = self;

        // No audio clock yet.
        return null;
    }

    pub fn seek(
        self: *AudioManager,
        position_seconds: f64,
    ) void {
        _ = self;
        _ = position_seconds;
    }

    pub fn setSpeed(
        self: *AudioManager,
        speed: f64,
    ) void {
        _ = self;
        _ = speed;
    }
};
