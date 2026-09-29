const std = @import("std");
const c = @import("c");

const Player = @import("player.zig").Player;
const video = @import("video.zig");

const log = std.log.scoped(.render);

pub const Renderer = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: ?*c.SDL_Texture = null,

    texture_width: i32 = 0,
    texture_height: i32 = 0,

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

        // Fixed source resolution, preserving aspect ratio.
        _ = c.SDL_SetRenderLogicalPresentation(
            renderer,
            1920,
            1080,
            c.SDL_LOGICAL_PRESENTATION_LETTERBOX,
        );

        log.info("SDL renderer initialized", .{});

        return .{
            .window = window,
            .renderer = renderer,
        };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.texture) |texture| {
            c.SDL_DestroyTexture(texture);
            self.texture = null;
        }

        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    fn ensureTexture(
        self: *Renderer,
        width: i32,
        height: i32,
    ) !void {
        if (self.texture != null and
            self.texture_width == width and
            self.texture_height == height)
        {
            return;
        }

        if (self.texture) |texture| {
            c.SDL_DestroyTexture(texture);
            self.texture = null;
        }

        const texture = c.SDL_CreateTexture(
            self.renderer,
            c.SDL_PIXELFORMAT_IYUV,
            c.SDL_TEXTUREACCESS_STREAMING,
            width,
            height,
        ) orelse {
            log.err("SDL_CreateTexture failed: {s}", .{c.SDL_GetError()});
            return error.SdlTextureFailed;
        };

        self.texture = texture;
        self.texture_width = width;
        self.texture_height = height;
    }

    pub fn render(self: *Renderer, player: *Player) !void {
        if (player.takeLatestFrame()) |frame| {
            defer player.releaseFrame(frame);

            try self.ensureTexture(frame.width, frame.height);

            const texture = self.texture orelse return error.NoTexture;

            const ok = c.SDL_UpdateYUVTexture(
                texture,
                null,
                frame.y.ptr,
                frame.y_pitch,
                frame.u.ptr,
                frame.u_pitch,
                frame.v.ptr,
                frame.v_pitch,
            );

            if (!ok) {
                log.err("SDL_UpdateYUVTexture failed: {s}", .{c.SDL_GetError()});
                return error.SdlTextureUpdateFailed;
            }
        }

        // The draw happens on every refresh, not only when a new frame
        // arrived. SDL does not preserve the render target across
        // SDL_RenderPresent, so presenting without redrawing shows an
        // undefined backbuffer. On a 30fps source with a 60Hz display that is
        // half of the refreshes, which reads as flicker even though the frame
        // rate is correct. The texture is the durable copy, so redraw it from
        // the texture and let it hold until the next update.
        const texture = self.texture orelse {
            // Nothing decoded yet: nothing to draw.
            _ = c.SDL_RenderPresent(self.renderer);
            return;
        };

        _ = c.SDL_SetRenderDrawColor(
            self.renderer,
            0,
            0,
            0,
            255,
        );

        _ = c.SDL_RenderClear(self.renderer);

        // Logical presentation is 1920x1080, so the whole texture can
        // be rendered into the logical coordinate system. The cached texture
        // size is used rather than the frame's, because the frame handle is
        // only available on the update path.
        const dst = c.SDL_FRect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.texture_width),
            .h = @floatFromInt(self.texture_height),
        };

        _ = c.SDL_RenderTexture(
            self.renderer,
            texture,
            null,
            &dst,
        );

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
