//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const Allocator = std.mem.Allocator;
pub const cfg = @import("config.zig").DEFAULT_CFG;

const Chip8Memory = [cfg.CHIP8_MEMORY_SIZE]u8;

const Chip8Registers = struct {
    v: [cfg.CHIP8_GPR]u8,
    i: u16, //TODO:arbitrary-bit-width https://ziglang.org/documentation/master/#toc-Runtime-Integer-Values
    pc: u16, // TODO:arbitrary-bit-width https://ziglang.org/documentation/master/#toc-Runtime-Integer-Values
    sp: u8,
    st: u8,
    dt: u8,
};

const Chip8Stack = [cfg.CHIP8_STACK]u16;

const Chip8KeyboardStatus = [cfg.CHIP8_KEYS]u1;

const Chip8Screen = [cfg.CHIP8_HEIGHT][cfg.CHIP8_WIDTH]u1;

const EmulatorError = error{ StackOverflow, StackEmpty };

fn gen_default_bitmaps() [cfg.CHIP8_CHAR_SET_SIZE]u8 {
    return .{
        0xF0, 0x90, 0x90, 0x90, 0xF0, // '0'
        0x20, 0x60, 0x20, 0x20, 0x70, // '1'
        0xF0, 0x10, 0xF0, 0x80, 0xF0, // '2'
        0xF0, 0x10, 0xF0, 0x10, 0xF0, // '3'
        0x90, 0x90, 0xF0, 0x10, 0x10, // '4'
        0xF0, 0x80, 0xF0, 0x10, 0xF0, // '5'
        0xF0, 0x80, 0xF0, 0x90, 0xF0, // '6'
        0xF0, 0x10, 0x20, 0x40, 0x40, // '7'
        0xF0, 0x90, 0xF0, 0x90, 0xF0, // '8'
        0xF0, 0x90, 0xF0, 0x10, 0xF0, // '9'
        0xF0, 0x90, 0xF0, 0x90, 0x90, // 'A'
        0xE0, 0x90, 0xE0, 0x90, 0xE0, // 'B'
        0xF0, 0x80, 0x80, 0x80, 0xF0, // 'C'
        0xE0, 0x90, 0x90, 0x90, 0xE0, // 'D'
        0xF0, 0x80, 0xF0, 0x80, 0xF0, // 'E'
        0xF0, 0x80, 0xF0, 0x80, 0x80, // 'F'
    };
}

pub const Chip8 = struct {
    // alloc: Allocator,
    memory: Chip8Memory,
    stack: Chip8Stack,
    regs: Chip8Registers,
    keys: Chip8KeyboardStatus,
    screen: Chip8Screen,

    pub fn pusha(self: *@This(), addr: u16) EmulatorError!void {
        if (self.regs.sp +% 1 >= cfg.CHIP8_STACK) {
            return error.StackOverflow;
        }
        self.regs.sp +%= 1;
        self.stack[self.regs.sp] = addr;
    }
    pub fn popa(self: *@This()) EmulatorError!u16 {
        if (self.regs.sp == std.math.maxInt(u8)) {
            return error.StackEmpty;
        }
        self.regs.sp -%= 1;
        return self.stack[self.regs.sp +% 1];
    }
    pub fn init() Chip8 {
        return .{
            .memory = gen_default_bitmaps() ++ .{0} ** (cfg.CHIP8_MEMORY_SIZE - cfg.CHIP8_CHAR_SET_SIZE),
            .screen = .{.{0} ** cfg.CHIP8_WIDTH} ** cfg.CHIP8_HEIGHT,
            .stack = .{0} ** cfg.CHIP8_STACK,
            .regs = .{
                .v = .{0} ** cfg.CHIP8_GPR,
                .i = 0,
                .pc = 0,
                .sp = std.math.maxInt(u8),
                .dt = 0,
                .st = 0,
            },
            .keys = .{0} ** cfg.CHIP8_KEYS,
        };
    }

    pub fn loadROM(self: *@This(), file_path: []const u8) !void {
        _ = self;
        var file: std.fs.File = undefined;
        // var buffer: [256]u8 = .{};
        var buffer: [4]u8 = undefined;

        if (std.fs.path.isAbsolute(file_path)) {
            file = try std.fs.openFileAbsolute(file_path, .{ .mode = .read_only });
        } else {
            file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
        }
        defer file.close();
        const reader = file.reader(&buffer);
        std.debug.print("{s}", .{reader.interface.buffer});
    }

    pub fn drawFromMemory(self: *@This(), x: u8, y: u8, sprite: []u8) void {
        for (sprite, 0..) |line, ly| {
            for (0..8) |lx| {
                // Need to draw from MSB to LSB
                if (@as(u8, 0x80) >> @intCast(lx) & line == 0) {
                    continue;
                }

                if (self.screen[(y + ly) % cfg.CHIP8_HEIGHT][(x + lx) % cfg.CHIP8_WIDTH] == 1) {
                    //Collision
                    self.regs.v[0xf] = 1;
                }

                self.screen[(y + ly) % cfg.CHIP8_HEIGHT][(x + lx) % cfg.CHIP8_WIDTH] ^= 1;
            }
        }
    }
};

const testing = std.testing;

test "init" {
    const emulator = Chip8.init();
    try std.testing.expect(std.mem.eql(u8, gen_default_bitmaps()[0..], emulator.memory[0..cfg.CHIP8_CHAR_SET_SIZE]));
}

test "stack" {
    var emulator = Chip8.init();

    try testing.expectError(EmulatorError.StackEmpty, emulator.popa());
    try testing.expect(emulator.regs.sp == std.math.maxInt(u8));

    inline for (0..cfg.CHIP8_STACK) |idx| {
        try emulator.pusha(idx);
        try testing.expect(emulator.regs.sp == idx);
    }

    try testing.expectError(EmulatorError.StackOverflow, emulator.pusha(0x01));
    try testing.expect(emulator.regs.sp == 15);

    inline for (0..cfg.CHIP8_STACK) |idx| {
        try testing.expect(try emulator.popa() == cfg.CHIP8_STACK - 1 -% idx);
    }
    try testing.expectError(EmulatorError.StackEmpty, emulator.popa());
    try testing.expect(emulator.regs.sp == std.math.maxInt(u8));
}
