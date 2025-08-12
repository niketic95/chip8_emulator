const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
const chip8 = @import("chip8");

const log = std.log;
const mem = std.mem;
const Chip8 = chip8.Chip8;

const CHIP8_WINDOW = "Chip8 Emulator";

pub fn main() !void {
    const emulator: Chip8 = Chip8.init();
    _ = emulator;

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        log.err("SDL_Init: {s}\n", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(CHIP8_WINDOW, chip8.cfg.CHIP8_WIDTH * chip8.cfg.CHIP8_MULTIPLIER, chip8.cfg.CHIP8_HEIGHT * chip8.cfg.CHIP8_MULTIPLIER, c.SDL_WINDOW_BORDERLESS);
    if (window == null) {
        log.err("SDL_CreateWindow: {s}", .{c.SDL_GetError()});
    }
    defer c.SDL_DestroyWindow(window);

    log.info("SDLRenderers", .{});

    for (0..@intCast(c.SDL_GetNumRenderDrivers())) |idx| {
        log.info("RenderDriver: {s}", .{c.SDL_GetRenderDriver(@intCast(idx)).?});
    }

    const renderer = c.SDL_CreateRenderer(window, null);
    defer c.SDL_DestroyRenderer(renderer);

    if (renderer == null) {
        log.err("SDL_CreateRenderer: {s}", .{c.SDL_GetError()});
    }

    if (!c.SDL_SetRenderDrawColor(renderer, 255, 0, 0, c.SDL_ALPHA_OPAQUE))
        log.err("SDL_SetRendererDrawColor: {s}", .{c.SDL_GetError()});

    if (!c.SDL_RenderClear(renderer))
        log.err("SDL_RenderClear: {s}", .{c.SDL_GetError()});

    if (!c.SDL_RenderPresent(renderer))
        log.err("SDL_RenderPresent: {s}", .{c.SDL_GetError()});

    // var alt: u1 = undefined;
    // var ctrl: u1 = undefined;
    var mod: struct {
        alt: u1,
        ctrl: u1,
    } = .{ .alt = 0, .ctrl = 0 };

    var event: c.SDL_Event = undefined;
    out: while (true) {
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_KEY_UP) {
                switch (event.key.scancode) {
                    c.SDL_SCANCODE_LCTRL, c.SDL_SCANCODE_RCTRL => mod.ctrl = 0,
                    c.SDL_SCANCODE_LALT, c.SDL_SCANCODE_RALT => mod.alt = 0,
                    else => {},
                }
            }
            if (event.type == c.SDL_EVENT_KEY_DOWN) {
                switch (event.key.scancode) {
                    c.SDL_SCANCODE_LCTRL, c.SDL_SCANCODE_RCTRL => mod.ctrl = 1,
                    c.SDL_SCANCODE_LALT, c.SDL_SCANCODE_RALT => mod.alt = 1,
                    c.SDL_SCANCODE_F4 => {
                        if (mod.alt == 1)
                            break :out;
                    },
                    else => {},
                }
            }
        }
    }
}
