const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
const chip8 = @import("chip8");

const log = std.log;
const mem = std.mem;
const Chip8 = chip8.Chip8;

const CHIP8_WINDOW = "Chip8 Emulator";

const key_map: [0x4B]?u32 = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 } ++ [_]?u32{null} ** 39 ++ [_]u32{ 0xA, 0xB, 0xC, 0xD, 0xE, 0xF } ++ [_]?u32{null} ** 20;

fn handle_keys(key: u32, press: u1, emulator: *Chip8) void {
    if (key >= '0' and key <= 'z') {
        const key_mapped = key_map[key - '0'];
        if (key_mapped != null) {
            emulator.keys[key_mapped.?] = press;
        }
    }
}

fn handle_emulator_timers(emulator: *Chip8, ellapsed_ns: u64) void {
    if (emulator.regs.dt == 0 and emulator.regs.st == 0) {
        return;
    }

    var tick_rate: u64 = 17 * std.time.ns_per_ms;

    if (tick_rate > ellapsed_ns) {
        tick_rate -= ellapsed_ns;
    } else {
        tick_rate = 0;
    }

    std.posix.nanosleep(0, tick_rate);

    if (emulator.regs.dt != 0) {
        emulator.regs.dt -= 1;
    }

    if (emulator.regs.st != 0) {
        emulator.regs.st -= 1;
    }
}

pub fn main() !void {
    var emulator: Chip8 = Chip8.init();

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

    var event: c.SDL_Event = undefined;
    var time_end: std.time.Instant = undefined;
    var time_start: std.time.Instant = undefined;
    out: while (true) {
        time_start = try std.time.Instant.now();

        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_KEY_UP) {
                handle_keys(event.key.key, 0, &emulator);
            }
            if (event.type == c.SDL_EVENT_KEY_DOWN) {
                handle_keys(event.key.key, 1, &emulator);
                switch (event.key.scancode) {
                    c.SDL_SCANCODE_F4 => {
                        if (event.key.mod & c.SDL_KMOD_ALT != 0) {
                            break :out;
                        }
                    },
                    else => {},
                }
            }
        }
        time_end = try std.time.Instant.now();
        handle_emulator_timers(&emulator, time_end.since(time_start));
    }
}
