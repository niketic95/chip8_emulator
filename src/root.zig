//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

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

const EmulatorError = error{ StackOverflow, StackEmpty };

pub const Chip8 = struct {
    memory: Chip8Memory,
    stack: Chip8Stack,
    regs: Chip8Registers,
    keys: Chip8KeyboardStatus,

    pub fn pusha(self: *Chip8, addr: u16) EmulatorError!void {
        if (self.regs.sp +% 1 >= cfg.CHIP8_STACK) {
            return error.StackOverflow;
        }
        self.regs.sp +%= 1;
        self.stack[self.regs.sp] = addr;
    }
    pub fn popa(self: *Chip8) EmulatorError!u16 {
        if (self.regs.sp == std.math.maxInt(u8)) {
            return error.StackEmpty;
        }
        self.regs.sp -%= 1;
        return self.stack[self.regs.sp +% 1];
    }
    pub fn init() Chip8 {
        return .{
            .memory = .{0} ** cfg.CHIP8_MEMORY_SIZE,
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
};

const testing = std.testing;

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
