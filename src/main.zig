const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
const chip8 = @import("chip8");

const log = std.log;
const mem = std.mem;
const Chip8 = chip8.Chip8;

const CHIP8_WINDOW = "Chip8 Emulator";
const AUDIO_SAMPLE_RATE = 8000; // 8KHz sample rate
const CHANNELS = 1; // Mono
const TIMER_FREQ_HZ = 60;

const key_map: [0x4B]?u32 = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 } ++ [_]?u32{null} ** 39 ++ [_]u32{ 0xA, 0xB, 0xC, 0xD, 0xE, 0xF } ++ [_]?u32{null} ** 20;

fn handleKeys(key: u32, press: u1, emulator: *Chip8) void {
    if (key >= '0' and key <= 'z') {
        const key_mapped = key_map[key - '0'];
        if (key_mapped != null) {
            emulator.keys[key_mapped.?] = press;
        }
    }
}

fn generateTone(samples: []f32, sr: u32, tone: u32, volume: f32) void {
    for (samples, 0..) |*sample, sine_sample| {
        sample.* = c.SDL_sinf(@as(f32, @floatFromInt(sine_sample)) * @as(f32, @floatFromInt(tone)) / @as(f32, @floatFromInt(sr)) * 2.0 * c.SDL_PI_F) * volume;
    }
}

fn handleEmulatorTimers(emulator: *Chip8, ellapsed_ns: u64, stream: ?*c.SDL_AudioStream, samples: []const f32) void {
    if (emulator.regs.dt == 0 and emulator.regs.st == 0) {
        return;
    }

    const tick_rate: u64 = @divTrunc(std.time.ns_per_s, 60);

    if (tick_rate > ellapsed_ns) {
        c.SDL_DelayNS(tick_rate - ellapsed_ns);
    }

    if (emulator.regs.dt != 0) {
        emulator.regs.dt -= 1;
    }

    if (emulator.regs.st != 0) {
        const queued_samples: u64 = @intCast(c.SDL_GetAudioStreamQueued(stream));
        const samples_needed_for_timer: u64 = @divTrunc(emulator.regs.st * tick_rate * AUDIO_SAMPLE_RATE, std.time.ns_per_s);

        // Check if we need ot feed more samples to the audio stream
        if (queued_samples < samples_needed_for_timer) {
            const additional_samples_to_queue = samples_needed_for_timer - queued_samples;
            for (0..@divTrunc(additional_samples_to_queue, AUDIO_SAMPLE_RATE)) |_| {
                _ = c.SDL_PutAudioStreamData(stream, samples.ptr, @intCast(samples.len * @sizeOf(f32)));
            }
            const left = samples[0 .. additional_samples_to_queue % AUDIO_SAMPLE_RATE];
            _ = c.SDL_PutAudioStreamData(stream, left.ptr, @intCast(left.len * @sizeOf(f32)));
        }

        emulator.regs.st -= 1;
    }
}

fn handleScreen(emu: *const Chip8, renderer: ?*c.SDL_Renderer) void {
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE);
    _ = c.SDL_RenderClear(renderer);

    _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE);
    for (emu.screen, 0..) |line, y| {
        for (line, 0..) |pixel, x| {
            if (pixel == 1) {
                _ = c.SDL_RenderFillRect(renderer, &.{
                    .x = @floatFromInt(x * chip8.cfg.CHIP8_MULTIPLIER),
                    .y = @floatFromInt(y * chip8.cfg.CHIP8_MULTIPLIER),
                    .w = chip8.cfg.CHIP8_MULTIPLIER,
                    .h = chip8.cfg.CHIP8_MULTIPLIER,
                });
            }
        }
    }
    _ = c.SDL_RenderPresent(renderer);
}

fn processArgs(alloc: std.mem.Allocator) ![]const u8 {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    const iter_mem = args.next() orelse {
        std.log.err("Path to ROM image is required!", .{});
        std.process.exit(1);
    };

    return alloc.dupe(u8, iter_mem);
}

pub fn main() !void {
    var emulator: Chip8 = Chip8.init();
    var event: c.SDL_Event = undefined;
    var time_end: std.time.Instant = undefined;
    var time_start: std.time.Instant = undefined;
    var stream: ?*c.SDL_AudioStream = null;
    var samples: [AUDIO_SAMPLE_RATE]f32 = .{0} ** AUDIO_SAMPLE_RATE;
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const alloc = gpa.allocator();
    const spec: c.SDL_AudioSpec = .{ .channels = CHANNELS, .format = c.SDL_AUDIO_F32, .freq = AUDIO_SAMPLE_RATE };

    defer {
        if (gpa.deinit() == .leak) {
            std.log.err("Leak detected!", .{});
        }
    }

    const rom_file_path = try processArgs(alloc);
    defer alloc.free(rom_file_path);

    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO)) {
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

    stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);

    if (stream == null) {
        log.err("SDL_OpenAudioDeviceStream: {s}", .{c.SDL_GetError()});
    }

    generateTone(&samples, AUDIO_SAMPLE_RATE, 329, 1.0);

    try emulator.loadROM(rom_file_path);

    _ = c.SDL_ResumeAudioStreamDevice(stream);

    // ** TO DETELETE **
    emulator.regs.st = 250;
    emulator.drawFromMemory(0, 0, emulator.memory[0..5]);
    emulator.drawFromMemory(16, 30, emulator.memory[5..10]);
    emulator.drawFromMemory(60, 30, emulator.memory[0..5]);
    emulator.drawFromMemory(30, 15, emulator.memory[10..15]);
    emulator.screen[0][1] = 1; // For testing collision
    // ** TO DELETE **

    time_start = try std.time.Instant.now();
    out: while (true) {
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_KEY_UP) {
                handleKeys(event.key.key, 0, &emulator);
            }
            if (event.type == c.SDL_EVENT_KEY_DOWN) {
                handleKeys(event.key.key, 1, &emulator);
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
        handleScreen(&emulator, renderer);
        time_end = try std.time.Instant.now();
        handleEmulatorTimers(&emulator, time_end.since(time_start), stream, &samples);
        time_start = try std.time.Instant.now();
    }
}
