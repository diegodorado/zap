const std = @import("std");
const c = @import("c");

const Player = @import("player.zig").Player;
const video = @import("video.zig");

const log = std.log.scoped(.render);

pub const Renderer = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,

    /// Whether the texture has ever received a frame. A freshly created
    /// streaming texture holds uninitialized memory, and drawing that is what
    /// showed a green window between launch and the first decoded frame. It
    /// is tracked here so "never draw an unwritten texture" is a property of
    /// this function alone, instead of something that depends on the worker
    /// having published a frame first.
    has_frame: bool = false,

    pub fn init() !Renderer {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
            return error.SdlInitFailed;
        }

        errdefer c.SDL_Quit();

        const window = c.SDL_CreateWindow(
            "zap",
            1280,
            720,
            c.SDL_WINDOW_RESIZABLE,
        ) orelse {
            log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
            return error.SdlWindowFailed;
        };

        errdefer c.SDL_DestroyWindow(window);

        const renderer = c.SDL_CreateRenderer(window, null) orelse {
            log.err("SDL_CreateRenderer failed: {s}", .{c.SDL_GetError()});
            return error.SdlRendererFailed;
        };

        errdefer c.SDL_DestroyRenderer(renderer);

        // Vsync is not optional here. Without it SDL_RenderPresent returns
        // immediately, the loop runs at several hundred Hz, and the same
        // source frame is re-uploaded and presented many times per display
        // refresh, which is what makes the picture flicker instead of hold.
        if (!c.SDL_SetRenderVSync(renderer, 1)) {
            log.warn(
                "could not enable vsync: {s}; presentation may flicker",
                .{c.SDL_GetError()},
            );
        }

        var vsync: i32 = 0;
        if (c.SDL_GetRenderVSync(renderer, &vsync) and vsync == 0) {
            log.warn("vsync is off; presentation is not frame-locked", .{});
        }

        // Fixed logical size, so a resized window letterboxes instead of
        // stretching. The window is resizable and the default 1280x720 is
        // already 16:9, but dragging the window to any other shape must not
        // distort the picture, so the scale factor is SDL's job, not a dst
        // rect recomputed from the source on every clip change.
        if (!c.SDL_SetRenderLogicalPresentation(
            renderer,
            video.frame_width,
            video.frame_height,
            c.SDL_LOGICAL_PRESENTATION_LETTERBOX,
        )) {
            log.warn(
                "could not set logical presentation: {s}; resizing the " ++
                    "window will stretch the picture",
                .{c.SDL_GetError()},
            );
        }

        // Every source is 1920x1080, so the texture is allocated once at
        // startup and never resized. With logical presentation handling the
        // window fit, a null source rect and a null destination rect are
        // correct and there is no per-frame rect math left to get wrong.
        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_IYUV,
            c.SDL_TEXTUREACCESS_STREAMING,
            @intCast(video.frame_width),
            @intCast(video.frame_height),
        ) orelse {
            log.err("SDL_CreateTexture failed: {s}", .{c.SDL_GetError()});
            return error.SdlTextureFailed;
        };

        log.info("SDL renderer initialized", .{});

        return .{
            .window = window,
            .renderer = renderer,
            .texture = texture,
        };
    }

    pub fn deinit(self: *Renderer) void {
        c.SDL_DestroyTexture(self.texture);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn render(self: *Renderer, player: *Player) !void {
        // False before the first trigger and after a slice ends: the window is
        // black then, because there is no picture rather than a stale one.
        const live = player.showsFrame();

        if (live) {
            if (player.takeLatestFrame()) |frame| {
                defer player.releaseFrame(frame);

                const ok = c.SDL_UpdateYUVTexture(
                    self.texture,
                    null,
                    frame.y.ptr,
                    frame.luma_pitch,
                    frame.u.ptr,
                    frame.chroma_pitch,
                    frame.v.ptr,
                    frame.chroma_pitch,
                );

                if (!ok) {
                    log.err("SDL_UpdateYUVTexture failed: {s}", .{c.SDL_GetError()});
                    return error.SdlTextureUpdateFailed;
                }

                self.has_frame = true;
            }
        }

        // The draw happens on every refresh, not only when a new frame
        // arrived. SDL does not preserve the render target across
        // SDL_RenderPresent, so presenting without redrawing shows an
        // undefined backbuffer. On a 30fps source with a 60Hz display that is
        // half of the refreshes, which reads as flicker even though the frame
        // rate is correct. The texture is the durable copy, so redraw it from
        // the texture and let it hold until the next update.
        //
        // The texture is only drawn once it holds a real frame, and only while
        // a clip is playing. Between those points the clear alone stands, which
        // is what keeps the window black instead of green before the first
        // decode and instead of a frozen still after a slice ends.
        _ = c.SDL_SetRenderDrawColor(
            self.renderer,
            0,
            0,
            0,
            255,
        );

        _ = c.SDL_RenderClear(self.renderer);

        if (live and self.has_frame) {
            _ = c.SDL_RenderTexture(
                self.renderer,
                self.texture,
                null,
                null,
            );
        }

        _ = c.SDL_RenderPresent(self.renderer);
    }

    pub fn pollQuit(_: *Renderer) bool {
        var event: c.SDL_Event = undefined;

        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) {
                return true;
            }
        }

        return false;
    }
};
