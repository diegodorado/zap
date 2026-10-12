const std = @import("std");
const c = @import("c");

const player_mod = @import("player.zig");
const Player = player_mod.Player;
const video = @import("video.zig");

const log = std.log.scoped(.render);

pub const Renderer = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,

    /// One texture per orbit, the companion of the per-orbit mailbox: every
    /// clip is 1920x1080, so a texture is allocated once per voice at startup
    /// and never resized.
    textures: [player_mod.MAX_ORBITS]*c.SDL_Texture,

    /// Whether each orbit's texture has ever received a frame. A freshly
    /// created streaming texture holds uninitialized memory, and drawing that
    /// is what showed green before the first decoded frame. Tracked here so
    /// "never draw an unwritten texture" is a property of this function alone.
    has_frame: [player_mod.MAX_ORBITS]bool = @splat(false),

    /// The default windowed size for a plain launch.
    const default_width = 1280;
    const default_height = 720;

    fn createWindow(fullscreen: bool) ?*c.SDL_Window {
        if (!fullscreen) {
            return c.SDL_CreateWindow(
                "zap",
                default_width,
                default_height,
                c.SDL_WINDOW_RESIZABLE,
            );
        }

        // Cover the display the cursor is on, so a multi-monitor setup opens
        // on the monitor you are looking at; fall back to the primary one.
        var mouse_x: f32 = 0;
        var mouse_y: f32 = 0;
        _ = c.SDL_GetGlobalMouseState(&mouse_x, &mouse_y);

        const at_cursor = c.SDL_GetDisplayForPoint(&.{
            .x = @intFromFloat(mouse_x),
            .y = @intFromFloat(mouse_y),
        });
        const display = if (at_cursor != 0) at_cursor else c.SDL_GetPrimaryDisplay();

        var bounds: c.SDL_Rect = undefined;
        if (!c.SDL_GetDisplayBounds(display, &bounds)) {
            log.warn(
                "could not get display bounds: {s}; fullscreen window opens at its default size",
                .{c.SDL_GetError()},
            );
            return c.SDL_CreateWindow(
                "zap",
                default_width,
                default_height,
                c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_BORDERLESS,
            );
        }

        const props = c.SDL_CreateProperties();
        defer c.SDL_DestroyProperties(props);

        _ = c.SDL_SetStringProperty(
            props,
            c.SDL_PROP_WINDOW_CREATE_TITLE_STRING,
            "zap",
        );
        _ = c.SDL_SetNumberProperty(
            props,
            c.SDL_PROP_WINDOW_CREATE_X_NUMBER,
            bounds.x,
        );
        _ = c.SDL_SetNumberProperty(
            props,
            c.SDL_PROP_WINDOW_CREATE_Y_NUMBER,
            bounds.y,
        );
        _ = c.SDL_SetNumberProperty(
            props,
            c.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER,
            bounds.w,
        );
        _ = c.SDL_SetNumberProperty(
            props,
            c.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER,
            bounds.h,
        );
        _ = c.SDL_SetBooleanProperty(
            props,
            c.SDL_PROP_WINDOW_CREATE_BORDERLESS_BOOLEAN,
            true,
        );
        _ = c.SDL_SetBooleanProperty(
            props,
            c.SDL_PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN,
            true,
        );

        return c.SDL_CreateWindowWithProperties(props);
    }

    /// `fullscreen` opens a borderless window that covers the whole display it
    /// appears on: a video wall or projector feed wants the screen filled edge
    /// to edge. It cannot stay a small borderless window waiting for its
    /// tiling window manager to fill it, because macOS gives a borderless
    /// window no fullscreen button and a tiler like AeroSpace floats such
    /// windows instead of managing their size.
    pub fn init(fullscreen: bool) !Renderer {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
            return error.SdlInitFailed;
        }

        errdefer c.SDL_Quit();

        const window = createWindow(fullscreen) orelse {
            log.err("SDL window creation failed: {s}", .{c.SDL_GetError()});
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
        // distort the picture, so the scale factor is SDL's job, not dst rects
        // recomputed from the source on every clip change. Orbit regions live
        // in this same logical coordinate space, so a 1920x1080 coordinate
        // maps one-to-one onto the letterboxed canvas.
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

        // One streaming IYUV texture per orbit, sized for the fixed source
        // resolution.
        var textures: [player_mod.MAX_ORBITS]*c.SDL_Texture = undefined;

        for (&textures) |*texture| {
            texture.* = c.SDL_CreateTexture(
                renderer,
                c.SDL_PIXELFORMAT_IYUV,
                c.SDL_TEXTUREACCESS_STREAMING,
                @intCast(video.frame_width),
                @intCast(video.frame_height),
            ) orelse {
                log.err("SDL_CreateTexture failed: {s}", .{c.SDL_GetError()});
                return error.SdlTextureFailed;
            };
        }

        errdefer for (&textures) |texture| {
            c.SDL_DestroyTexture(texture);
        };

        log.info("SDL renderer initialized", .{});

        return .{
            .window = window,
            .renderer = renderer,
            .textures = textures,
        };
    }

    pub fn deinit(self: *Renderer) void {
        for (&self.textures) |texture| {
            c.SDL_DestroyTexture(texture);
        }
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn render(self: *Renderer, player: *Player) !void {
        // Upload: pull this frame from each live orbit and copy it into that
        // orbit's texture. Nothing is drawn in this pass; the draw pass below
        // owns what lands on the backbuffer, so dropping a frame here only
        // re-presents the previous one.
        for (0..player_mod.MAX_ORBITS) |i| {
            // False before this orbit's first trigger and after its slice
            // ends: its region is black then, because there is no picture
            // rather than a stale one.
            if (!player.orbitShowsFrame(i)) continue;

            if (player.takeLatestFrame(i)) |frame| {
                defer player.releaseFrame(frame);

                const ok = c.SDL_UpdateYUVTexture(
                    self.textures[i],
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

                self.has_frame[i] = true;
            }
        }

        // The draw happens on every refresh, not only when a new frame
        // arrived. SDL does not preserve the render target across
        // SDL_RenderPresent, so presenting without redrawing shows an
        // undefined backbuffer. On a 30fps source with a 60Hz display that is
        // half of the refreshes, which reads as flicker even though the frame
        // rate is correct. The textures are the durable copies, so redraw from
        // them and let the composition hold until the next update.
        //
        // There are no layers: the backbuffer is the full screen, one color per
        // refresh. Each live orbit blits its texture into a rect derived from
        // its normalized region, so the picture displayed anywhere is just the
        // last orbit that drew there. An orbit that ends simply stops drawing,
        // and only its region returns to black while every other region keeps
        // redrawing from the texture that still holds its last frame.
        _ = c.SDL_SetRenderDrawColor(
            self.renderer,
            0,
            0,
            0,
            255,
        );

        _ = c.SDL_RenderClear(self.renderer);

        const render_w: f32 = @floatFromInt(video.frame_width);
        const render_h: f32 = @floatFromInt(video.frame_height);

        for (0..player_mod.MAX_ORBITS) |i| {
            if (!player.orbitShowsFrame(i)) continue;
            if (!self.has_frame[i]) continue;

            const region = player.orbitRegion(i);

            var dst = c.SDL_FRect{
                .x = @as(f32, @floatCast(region.x)) * render_w,
                .y = @as(f32, @floatCast(region.y)) * render_h,
                .w = @as(f32, @floatCast(region.size)) * render_w,
                .h = @as(f32, @floatCast(region.size)) * render_h,
            };

            _ = c.SDL_RenderTexture(
                self.renderer,
                self.textures[i],
                null,
                &dst,
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
