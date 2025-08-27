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
const DELAY_TIMER_TICK_RATE = @divTrunc(std.time.ns_per_s, TIMER_FREQ_HZ);
const DISPLAY_FREQ_HZ = 30;
const DISPLAY_TIMER_TICK_RATE = @divTrunc(std.time.ns_per_s, DISPLAY_FREQ_HZ);
const EMULATOR_FREQ_HZ = 600;
const EMULATOR_EXEC_RATE = @divTrunc(std.time.ns_per_s, EMULATOR_FREQ_HZ);

const key_map: [0x4B]?u32 = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 } ++ [_]?u32{null} ** 39 ++ [_]u32{ 0xA, 0xB, 0xC, 0xD, 0xE, 0xF } ++ [_]?u32{null} ** 20;

fn handleKeys(key: u32, press: u1, emulator: *Chip8) void {
    if (key >= '0' and key <= 'z') {
        if (key_map[key - '0']) |mapped_key| {
            emulator.keys[mapped_key] = press;
            if (emulator.halt) |halt| {
                if (halt == mapped_key) {
                    emulator.halt = null;
                }
            }
        }
    }
}

fn generateTone(samples: []f32, sr: u32, tone: u32, volume: f32) void {
    for (samples, 0..) |*sample, sine_sample| {
        sample.* = c.SDL_sinf(@as(f32, @floatFromInt(sine_sample)) * @as(f32, @floatFromInt(tone)) / @as(f32, @floatFromInt(sr)) * 2.0 * c.SDL_PI_F) * volume;
    }
}

fn handleEmulatorExec(emulator: *Chip8, timer: *std.time.Timer) !void {
    if (timer.read() < EMULATOR_EXEC_RATE) return;

    timer.reset();
    try emulator.step();
}

fn handleEmulatorTimers(emulator: *Chip8, timer: *std.time.Timer, stream: ?*c.SDL_AudioStream, samples: []const f32) void {
    if (timer.read() < DELAY_TIMER_TICK_RATE) return;

    if (emulator.regs.dt != 0) {
        emulator.regs.dt -= 1;
    }

    if (emulator.regs.st != 0) {
        const queued_samples: u64 = @intCast(c.SDL_GetAudioStreamQueued(stream));
        const samples_needed_for_timer: u64 = @divTrunc(@as(u64, emulator.regs.st) * DELAY_TIMER_TICK_RATE * AUDIO_SAMPLE_RATE, std.time.ns_per_s);

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

fn handleScreen(emu: *Chip8, renderer: ?*c.SDL_Renderer, timer: *std.time.Timer) void {
    if (timer.read() < DISPLAY_TIMER_TICK_RATE) {
        return;
    }

    timer.reset();

    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE);
    _ = c.SDL_RenderClear(renderer);

    _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE);
    for (emu.screen_buffer, 0..) |line, y| {
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

fn handleSDLEvents(emulator: *Chip8) bool {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        if (event.type == c.SDL_EVENT_KEY_UP) {
            handleKeys(event.key.key, 0, emulator);
        }
        if (event.type == c.SDL_EVENT_KEY_DOWN) {
            handleKeys(event.key.key, 1, emulator);
            switch (event.key.scancode) {
                c.SDL_SCANCODE_F4 => {
                    if (event.key.mod & c.SDL_KMOD_ALT != 0) {
                        return true;
                    }
                },
                else => {},
            }
        }
    }
    return false;
}

pub fn main() !void {
    var emulator: Chip8 = Chip8.init();
    var stream: ?*c.SDL_AudioStream = null;
    var samples: [AUDIO_SAMPLE_RATE]f32 = .{0} ** AUDIO_SAMPLE_RATE;
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    var delay_timer: std.time.Timer = undefined;
    var emulator_timer: std.time.Timer = undefined;
    var display_timer: std.time.Timer = undefined;
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

    generateTone(&samples, AUDIO_SAMPLE_RATE, 329, 0.5);

    try emulator.loadROM(rom_file_path);

    _ = c.SDL_ResumeAudioStreamDevice(stream);

    delay_timer = try std.time.Timer.start();
    emulator_timer = try std.time.Timer.start();
    display_timer = try std.time.Timer.start();

    while (true) {
        if (handleSDLEvents(&emulator)) break;
        try handleEmulatorExec(&emulator, &emulator_timer);
        handleScreen(&emulator, renderer, &display_timer);
        handleEmulatorTimers(&emulator, &delay_timer, stream, &samples);
    }
}
