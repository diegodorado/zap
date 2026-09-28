const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const brew_prefix = "/opt/homebrew";

    // Zig 0.17: C headers are translated by the build system.
    // The resulting module is imported in Zig with:
    //
    //     const c = @import("c");
    //
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Homebrew headers.
    //
    // FFmpeg is keg-only, so use Homebrew's stable opt symlink rather
    // than a versioned Cellar path.
    translate_c.addSystemIncludePath(.{
        .cwd_relative = b.pathJoin(&.{
            brew_prefix,
            "include",
        }),
    });

    translate_c.addSystemIncludePath(.{
        .cwd_relative = b.pathJoin(&.{
            brew_prefix,
            "opt",
            "ffmpeg",
            "include",
        }),
    });

    const c_module = translate_c.createModule();

    const exe = b.addExecutable(.{
        .name = "zap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{
                    .name = "c",
                    .module = c_module,
                },
            },
        }),
    });

    // SDL3
    exe.root_module.addLibraryPath(.{
        .cwd_relative = b.pathJoin(&.{ brew_prefix, "lib" }),
    });

    exe.root_module.linkSystemLibrary("SDL3", .{});

    // FFmpeg.
    exe.root_module.addLibraryPath(.{
        .cwd_relative = b.pathJoin(&.{
            brew_prefix,
            "opt",
            "ffmpeg",
            "lib",
        }),
    });

    exe.root_module.linkSystemLibrary("avformat", .{});
    exe.root_module.linkSystemLibrary("avcodec", .{});
    exe.root_module.linkSystemLibrary("avutil", .{});
    exe.root_module.linkSystemLibrary("swscale", .{});

    // macOS frameworks.
    exe.root_module.linkFramework("CoreAudio", .{});
    exe.root_module.linkFramework("VideoToolbox", .{});
    exe.root_module.linkFramework("Foundation", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run zap");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    const fmt_step = b.step("fmt", "Format source");
    const fmt = b.addFmt(.{
        .paths = &.{
            b.path("build.zig"),
            b.path("src"),
        },
        .check = false,
    });

    fmt_step.dependOn(&fmt.step);
}
