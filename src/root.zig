//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const Allocator = std.mem.Allocator;
pub const cfg = @import("config.zig").DEFAULT_CFG;

const OPCODE_SIZE = 0x2;

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

const EmulatorError = error{ StackOverflow, StackEmpty, ExecutionError };

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

const CatOp = fn (self: *Chip8, opcode: u12) void;

fn cat0_op(emu: *Chip8, opcode: u12) void {
    switch (opcode) {
        0xE0 => {
            @memset(&emu.screen, .{0} ** 64);
            emu.regs.pc += 2;
        },
        0xEE => {
            emu.regs.pc = emu.popa() catch |err| {
                std.log.err("Failed to pop address:{}", .{err});
                std.process.abort();
            };
        },
        else => {},
    }
}

fn cat1_op(emu: *Chip8, opcode: u12) void {
    emu.regs.pc = opcode;
}

fn cat2_op(emu: *Chip8, opcode: u12) void {
    emu.pusha(emu.regs.pc + 2) catch |err| {
        std.log.err("Failed to push address:{}", .{err});
        std.process.abort();
    };
    emu.regs.pc = opcode;
}

fn cat3_op(emu: *Chip8, opcode: u12) void {
    const skip = @as(u8, @intFromBool(emu.regs.v[opcode >> 8] == opcode & 0xff)) * 2;
    emu.regs.pc += 2 + skip;
}

fn cat4_op(emu: *Chip8, opcode: u12) void {
    const skip = @as(u8, @intFromBool(emu.regs.v[opcode >> 8] != opcode & 0xff)) * 2;
    emu.regs.pc += 2 + skip;
}

fn cat5_op(emu: *Chip8, opcode: u12) void {
    const skip = @as(u8, @intFromBool(emu.regs.v[opcode >> 8] == emu.regs.v[(opcode >> 4) & 0xf])) * 2;
    emu.regs.pc += 2 + skip;
}

fn cat6_op(emu: *Chip8, opcode: u12) void {
    emu.regs.v[opcode >> 8] = @intCast(opcode & 0xff);
    emu.regs.pc += 2;
}

fn cat7_op(emu: *Chip8, opcode: u12) void {
    emu.regs.v[opcode >> 8] +%= @intCast(opcode & 0xff);
    emu.regs.pc += 2;
}

fn cat8_op(emu: *Chip8, opcode: u12) void {
    switch (opcode & 0xf) {
        0 => {
            emu.regs.v[opcode >> 8] = emu.regs.v[(opcode >> 4) & 0xf];
        },
        1 => {
            emu.regs.v[opcode >> 8] |= emu.regs.v[(opcode >> 4) & 0xf];
        },
        2 => {
            emu.regs.v[opcode >> 8] &= emu.regs.v[(opcode >> 4) & 0xf];
        },
        3 => {
            emu.regs.v[opcode >> 8] ^= emu.regs.v[(opcode >> 4) & 0xf];
        },
        4 => {
            const res = @addWithOverflow(emu.regs.v[opcode >> 8], emu.regs.v[(opcode >> 4) & 0xf]);
            emu.regs.v[opcode >> 8] = res[0];
            emu.regs.v[0xf] = res[1];
        },
        5 => {
            const res = @subWithOverflow(emu.regs.v[opcode >> 8], emu.regs.v[(opcode >> 4) & 0xf]);
            emu.regs.v[opcode >> 8] = res[0];
            emu.regs.v[0xf] = ~res[1];
        },
        6 => {
            const tmp = emu.regs.v[opcode >> 8] & 0x1;
            emu.regs.v[opcode >> 8] >>= 1;
            emu.regs.v[0xf] = tmp;
        },
        7 => {
            const res = @subWithOverflow(emu.regs.v[(opcode >> 4) & 0xf], emu.regs.v[opcode >> 8]);
            emu.regs.v[opcode >> 8] = res[0];
            emu.regs.v[0xf] = ~res[1];
        },
        0xE => {
            const res = @shlWithOverflow(emu.regs.v[opcode >> 8], 1);
            emu.regs.v[opcode >> 8] = res[0];
            emu.regs.v[0xf] = res[1];
        },
        else => {},
    }
    emu.regs.pc += 2;
}

fn cat9_op(emu: *Chip8, opcode: u12) void {
    const skip = @as(u8, @intFromBool(emu.regs.v[opcode >> 8] != emu.regs.v[(opcode >> 4) & 0xf])) * 2;
    emu.regs.pc += 2 + skip;
}

fn catA_op(emu: *Chip8, opcode: u12) void {
    emu.regs.i = opcode;
    emu.regs.pc += 2;
}

fn catB_op(emu: *Chip8, opcode: u12) void {
    emu.regs.pc = opcode + emu.regs.v[0];
}

fn catC_op(emu: *Chip8, opcode: u12) void {
    emu.regs.v[opcode >> 8] = @as(u8, @intCast(opcode & 0xff)) & std.crypto.random.intRangeAtMost(u8, 0, 255);
    emu.regs.pc += 2;
}

fn catD_op(emu: *Chip8, opcode: u12) void {
    emu.drawFromMemory(emu.regs.v[opcode >> 8], emu.regs.v[(opcode >> 4) & 0xf], emu.memory[emu.regs.i..][0..(opcode & 0xf)]);
    emu.regs.pc += 2;
}

fn catE_op(emu: *Chip8, opcode: u12) void {
    switch (opcode & 0xff) {
        0x9e => {
            emu.regs.pc += @as(u8, emu.keys[emu.regs.v[opcode >> 8]]) * 2;
        },
        0xa1 => {
            emu.regs.pc += @as(u8, ~emu.keys[emu.regs.v[opcode >> 8]]) * 2;
        },
        else => {},
    }
    emu.regs.pc += 2;
}

fn catF_op(emu: *Chip8, opcode: u12) void {
    switch (opcode & 0xff) {
        0x0A => {
            for (emu.keys, 0..) |key, idx| {
                if (key == 1) {
                    emu.regs.v[opcode >> 8] = @intCast(idx);
                    emu.regs.pc += 2;
                }
            }
            emu.regs.pc -= 2;
        },
        0x15 => {
            emu.regs.dt = emu.regs.v[opcode >> 8];
        },
        0x18 => {
            emu.regs.st = emu.regs.v[opcode >> 8];
        },
        0x1E => {
            emu.regs.i += emu.regs.v[opcode >> 8];
        },
        0x29 => {
            emu.regs.i = emu.regs.v[opcode >> 8] * 0x5;
        },
        0x33 => {
            const num = emu.regs.v[opcode >> 8];
            emu.memory[emu.regs.i] = @divTrunc(num, 100);
            emu.memory[emu.regs.i + 1] = @divTrunc(num, 10) % 10;
            emu.memory[emu.regs.i + 2] = num % 10;
        },
        0x55 => {
            for (0..(opcode >> 8) + 1) |offset| {
                emu.memory[emu.regs.i + offset] = emu.regs.v[offset];
            }
        },
        0x65 => {
            for (0..(opcode >> 8) + 1) |offset| {
                emu.regs.v[offset] = emu.memory[emu.regs.i + offset];
            }
        },
        else => {},
    }
    emu.regs.pc += 2;
}

const instruction_cat_table: [0x10]*const CatOp = .{
    cat0_op,
    cat1_op,
    cat2_op,
    cat3_op,
    cat4_op,
    cat5_op,
    cat6_op,
    cat7_op,
    cat8_op,
    cat9_op,
    catA_op,
    catB_op,
    catC_op,
    catD_op,
    catE_op,
    catF_op,
};

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
                .pc = cfg.CHIP8_PROGRAM_LOAD_ADDR, //Start of loaded program
                // .pc = 0,
                .sp = std.math.maxInt(u8),
                .dt = 0,
                .st = 0,
            },
            .keys = .{0} ** cfg.CHIP8_KEYS,
        };
    }
    pub fn step(self: *@This()) EmulatorError!void {
        if (self.regs.pc + 1 > self.memory[cfg.CHIP8_PROGRAM_LOAD_ADDR..].len) {
            return error.ExecutionError;
        }

        const opcode: u16 = std.mem.readInt(u16, self.memory[self.regs.pc..][0..2], .big);
        if (opcode == 0) @panic("Unknown Instruction");

        instruction_cat_table[opcode >> 12](self, @intCast(opcode & (0x0fff)));
    }

    pub fn loadROM(self: *@This(), file_path: []const u8) !void {
        var file: std.fs.File = undefined;
        var buffer: [1024]u8 = undefined;
        var reader: std.fs.File.Reader = undefined;
        var writer: std.Io.Writer = undefined;

        if (std.fs.path.isAbsolute(file_path)) {
            file = try std.fs.openFileAbsolute(file_path, .{ .mode = .read_only });
        } else {
            file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
        }
        defer file.close();

        // Source is ROM file
        reader = file.reader(&buffer);

        // Sink is the emulator's memory region meant to load the ROM
        writer = std.Io.Writer.fixed(self.memory[cfg.CHIP8_PROGRAM_LOAD_ADDR..]);
        // Stream all the data into the memory region in kB chunks
        _ = try reader.interface.streamRemaining(&writer);
        try writer.flush(); // Don't forget to flush! Although since sink is memory, flush is a noop
    }

    pub fn drawFromMemory(self: *@This(), x: u8, y: u8, sprite: []u8) void {
        self.regs.v[0xf] = 0;
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
    try testing.expect(std.mem.eql(u8, gen_default_bitmaps()[0..], emulator.memory[0..cfg.CHIP8_CHAR_SET_SIZE]));
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

test "loader" {
    var emulator = Chip8.init();

    var file_buffer: [256]u8 = undefined;
    var file = try std.fs.cwd().createFile("test.bin", .{
        .truncate = true,
        .read = false,
    });
    defer file.close();
    var file_writer = file.writer(&file_buffer);
    try file_writer.interface.splatBytesAll(&.{ 0xDE, 0xAD, 0xC0, 0xDE }, 0x100);
    try file_writer.interface.flush();

    try testing.expectError(error.FileNotFound, emulator.loadROM("test1.bin"));
    try emulator.loadROM("test.bin");
    // Verify that the ROM is loaded in the proper place
    try testing.expect(std.mem.eql(u8, &(.{ 0xDE, 0xAD, 0xC0, 0xDE } ** 0x100), emulator.memory[cfg.CHIP8_PROGRAM_LOAD_ADDR .. cfg.CHIP8_PROGRAM_LOAD_ADDR + 0x400]));
    try testing.expect(std.mem.eql(u8, gen_default_bitmaps()[0..], emulator.memory[0..cfg.CHIP8_CHAR_SET_SIZE]));
    try testing.expect(std.mem.eql(u8, &(.{0} ** (cfg.CHIP8_PROGRAM_LOAD_ADDR - cfg.CHIP8_CHAR_SET_SIZE)), emulator.memory[cfg.CHIP8_CHAR_SET_SIZE..cfg.CHIP8_PROGRAM_LOAD_ADDR]));

    try file_writer.interface.splatBytesAll(&.{ 0xDE, 0xAD, 0xC0, 0xDE }, 0x1000);
    try file_writer.interface.flush();

    // Binary too big for the emulator to load
    try testing.expectError(error.WriteFailed, emulator.loadROM("test.bin"));
    try std.fs.cwd().deleteFile("test.bin");
}
