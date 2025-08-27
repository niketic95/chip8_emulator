//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Timer = std.time.Timer;

pub const cfg = @import("config.zig").DEFAULT_CFG;
const OPCODE_SIZE = 0x2;
const DISPLAY_FREQ_HZ = 60;
const DISPLAY_TIMER_TICK_RATE = @divTrunc(std.time.ns_per_s, DISPLAY_FREQ_HZ);

const Chip8Memory = [cfg.CHIP8_MEMORY_SIZE]u8;
const Chip8Registers = struct {
    v: [cfg.CHIP8_GPR]u8,
    i: u12,
    pc: u12,
    sp: u8,
    st: u8,
    dt: u8,
};
const Chip8Stack = [cfg.CHIP8_STACK]u12;
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

pub const Chip8 = struct {
    // alloc: Allocator,
    memory: Chip8Memory,
    stack: Chip8Stack,
    regs: Chip8Registers,
    keys: Chip8KeyboardStatus,
    screen_buffer: Chip8Screen,
    halt: ?u4,

    pub fn pusha(self: *@This(), addr: u12) EmulatorError!void {
        if (self.regs.sp +% 1 >= cfg.CHIP8_STACK) {
            return error.StackOverflow;
        }
        self.regs.sp +%= 1;
        self.stack[self.regs.sp] = addr;
    }
    pub fn popa(self: *@This()) EmulatorError!u12 {
        if (self.regs.sp == std.math.maxInt(u8)) {
            return error.StackEmpty;
        }
        self.regs.sp -%= 1;
        return self.stack[self.regs.sp +% 1];
    }
    pub fn init() Chip8 {
        return .{
            .memory = gen_default_bitmaps() ++ .{0} ** (cfg.CHIP8_MEMORY_SIZE - cfg.CHIP8_CHAR_SET_SIZE),
            .screen_buffer = .{.{0} ** cfg.CHIP8_WIDTH} ** cfg.CHIP8_HEIGHT,
            .stack = .{0} ** cfg.CHIP8_STACK,
            .regs = .{
                .v = .{0} ** cfg.CHIP8_GPR,
                .i = 0,
                .pc = cfg.CHIP8_PROGRAM_LOAD_ADDR, //Start of loaded program
                .sp = std.math.maxInt(u8),
                .dt = 0,
                .st = 0,
            },
            .keys = .{0} ** cfg.CHIP8_KEYS,
            .halt = null,
        };
    }

    pub fn step(self: *@This()) EmulatorError!void {
        if (self.regs.pc >= self.memory.len and self.regs.pc < cfg.CHIP8_PROGRAM_LOAD_ADDR) {
            std.log.err("pc overflow: {x:0>5}", .{self.regs.pc});
            return error.ExecutionError;
        }

        if (self.halt != null) {
            return;
        }

        std.log.debug("pc:{x:0>5}", .{self.regs.pc});
        const step_addr = pc_val: {
            const opcode = std.mem.readInt(u16, self.memory[self.regs.pc..][0..2], .big);
            std.log.debug("op:{x:0>5}", .{opcode});
            switch (@as(u4, @truncate(opcode >> 12))) {
                0x0 => {
                    switch (opcode) {
                        // clr
                        0xE0 => {
                            @memset(&self.screen_buffer, .{0} ** 64);
                        },
                        // ret
                        0xEE => {
                            self.regs.pc = self.popa() catch |err| {
                                std.log.err("Failed to pop address:{}", .{err});
                                return err;
                            };
                            break :pc_val 0;
                        },
                        // int?
                        else => {
                            std.log.warn("Unsuported instruction! op@{x:0>5}:{x:0>5}", .{ self.regs.pc, opcode });
                        },
                    }
                },
                // jmp
                0x1 => {
                    const nnn: u12 = @truncate(opcode);
                    self.regs.pc = nnn;
                    break :pc_val 0;
                },
                // call
                0x2 => {
                    const nnn: u12 = @truncate(opcode);
                    self.pusha(self.regs.pc + OPCODE_SIZE) catch |err| {
                        std.log.err("Failed to push address:{}!", .{err});
                        return err;
                    };
                    self.regs.pc = nnn;
                    break :pc_val 0;
                },
                // seq
                0x3 => {
                    const nn: u8 = @truncate(opcode);
                    const x: u4 = @truncate(opcode >> 8);
                    const seq: u3 = @shlExact(@as(u2, @intFromBool(self.regs.v[x] == nn)), 1);
                    break :pc_val OPCODE_SIZE + seq;
                },
                // sneq
                0x4 => {
                    const nn: u8 = @truncate(opcode);
                    const x: u4 = @truncate(opcode >> 8);
                    const sneq: u3 = @shlExact(@as(u2, @intFromBool(self.regs.v[x] != nn)), 1);
                    break :pc_val OPCODE_SIZE + sneq;
                },
                // sreq
                0x5 => {
                    const n: u4 = @truncate(opcode);
                    const y: u4 = @truncate(opcode >> 4);
                    const x: u4 = @truncate(opcode >> 8);

                    if (n != 0) {
                        std.log.err("Illegal instruction! op@{x:0>5}:{x:0>5}", .{ self.regs.pc, opcode });
                        return EmulatorError.ExecutionError;
                    }

                    const sreq: u3 = @shlExact(@as(u2, @intFromBool(self.regs.v[x] == self.regs.v[y])), 1);
                    break :pc_val OPCODE_SIZE + sreq;
                },
                // mov vx immediate
                0x6 => {
                    const nn: u8 = @truncate(opcode);
                    const x: u4 = @truncate(opcode >> 8);

                    self.regs.v[x] = nn;
                },
                // add vx immediate
                0x7 => {
                    const nn: u8 = @truncate(opcode);
                    const x: u4 = @truncate(opcode >> 8);

                    self.regs.v[x] +%= nn;
                },
                0x8 => {
                    const sub_op: u4 = @truncate(opcode);
                    const y: u4 = @truncate(opcode >> 4);
                    const x: u4 = @truncate(opcode >> 8);
                    switch (sub_op) {
                        // mov vx vy
                        0x0 => {
                            self.regs.v[x] = self.regs.v[y];
                        },
                        // or Vx Vy
                        0x1 => {
                            self.regs.v[x] |= self.regs.v[y];
                            //chip8 quirk
                            self.regs.v[0xf] = 0x0;
                        },
                        // and vx vy
                        0x2 => {
                            self.regs.v[x] &= self.regs.v[y];
                            //chip8 quirk
                            self.regs.v[0xf] = 0x0;
                        },
                        // xor vx vy
                        0x3 => {
                            self.regs.v[x] ^= self.regs.v[y];
                            //chip8 quirk
                            self.regs.v[0xf] = 0x0;
                        },
                        // add vx vy
                        0x4 => {
                            const sum = @addWithOverflow(self.regs.v[x], self.regs.v[y]);
                            self.regs.v[x] = sum[0]; // Actual sum
                            self.regs.v[0xf] = sum[1]; // Overflow
                        },
                        // sub vx vy
                        0x5 => {
                            const dif = @subWithOverflow(self.regs.v[x], self.regs.v[y]);
                            self.regs.v[x] = dif[0]; // Actual sum
                            self.regs.v[0xf] = ~dif[1]; // Overflow
                        },
                        // rsh vx 1
                        0x6 => {
                            //Chip8 Quirk
                            if (true) {
                                self.regs.v[x] = self.regs.v[y];
                            }

                            const flag = self.regs.v[x] & 0x1;
                            self.regs.v[x] >>= 1;
                            self.regs.v[0xf] = flag;
                        },
                        // sub vx vy (alt.)
                        0x7 => {
                            const dif = @subWithOverflow(self.regs.v[y], self.regs.v[x]);
                            self.regs.v[x] = dif[0];
                            self.regs.v[0xf] = ~dif[1]; // Overflow
                        },
                        // lsh vx 1
                        0xe => {
                            //Chip8 Quirk
                            if (true) {
                                self.regs.v[x] = self.regs.v[y];
                            }

                            const lsh = @shlWithOverflow(self.regs.v[x], 1);
                            self.regs.v[x] = lsh[0];
                            self.regs.v[0xf] = lsh[1];
                        },
                        else => {
                            std.log.err("Illegal instruction! op@{x:0>5}:{x:0>5}", .{ self.regs.pc, opcode });
                            return EmulatorError.ExecutionError;
                        },
                    }
                },
                // srneq
                0x9 => {
                    const n: u4 = @truncate(opcode);
                    const y: u4 = @truncate(opcode >> 4);
                    const x: u4 = @truncate(opcode >> 8);

                    if (n != 0) {
                        std.log.err("Illegal instruction! op@{x:0>5}:{x:0>5}", .{ self.regs.pc, opcode });
                        return EmulatorError.ExecutionError;
                    }

                    const srneq: u3 = @shlExact(@as(u2, @intFromBool(self.regs.v[x] != self.regs.v[y])), 1);
                    break :pc_val OPCODE_SIZE + srneq;
                },
                // seti
                0xA => {
                    const nnn: u12 = @truncate(opcode);
                    self.regs.i = nnn;
                },
                // acc v0
                0xB => {
                    const nnn: u12 = @truncate(opcode);
                    self.regs.pc = nnn + @as(u12, self.regs.v[0]);
                    break :pc_val 0;
                },
                // rand vx
                0xC => {
                    const nn: u8 = @truncate(opcode);
                    const x: u4 = @truncate(opcode >> 8);
                    self.regs.v[x] = nn & std.crypto.random.intRangeAtMost(u8, 0, 255);
                },
                // drw vx vy n
                0xD => {
                    const n: u4 = @truncate(opcode);
                    const y: u4 = @truncate(opcode >> 4);
                    const x: u4 = @truncate(opcode >> 8);

                    self.drawFromMemory(self.regs.v[x], self.regs.v[y], self.memory[self.regs.i..][0..n]);
                },
                // key ops
                0xE => {
                    const sub_op: u8 = @truncate(opcode);
                    const x: u4 = @truncate(opcode >> 8);
                    const key: u4 = @truncate(self.regs.v[x]);
                    switch (sub_op) {
                        // keq vx
                        0x9E => {
                            const skip: u3 = @shlExact(@as(u2, @intCast(self.keys[key])), 1);
                            break :pc_val OPCODE_SIZE + skip;
                        },
                        // kneq vx
                        0xA1 => {
                            const skip: u3 = @shlExact(@as(u2, @intCast(~self.keys[key])), 1);
                            break :pc_val OPCODE_SIZE + skip;
                        },
                        else => {
                            std.log.err("Illegal instruction! op@{x:0>5}:{x:0>5}", .{ self.regs.pc, opcode });
                            return EmulatorError.ExecutionError;
                        },
                    }
                },
                0xF => {
                    const sub_op: u8 = @truncate(opcode);
                    const x: u4 = @truncate(opcode >> 8);
                    switch (sub_op) {
                        //mov vx dt
                        0x07 => self.regs.v[x] = self.regs.dt,
                        //waitkey
                        0x0A => {
                            for (self.keys, 0..) |key, idx| {
                                if (key == 1) {
                                    self.regs.v[x] = @intCast(idx);
                                    self.halt = @intCast(idx);
                                    break :pc_val OPCODE_SIZE;
                                }
                            }
                            break :pc_val 0;
                        },
                        //mov dt vx
                        0x15 => self.regs.dt = self.regs.v[x],
                        //mov st vx
                        0x18 => self.regs.st = self.regs.v[x],
                        //add i vx
                        0x1E => self.regs.i += self.regs.v[x],
                        //mov i vx*5
                        0x29 => self.regs.i = self.regs.v[x] * 5,
                        //bcd i vx
                        0x33 => {
                            const num = self.regs.v[x];
                            inline for (0..3) |offset| {
                                const denominator = comptime std.math.pow(u8, 10, 2 - offset);
                                self.memory[self.regs.i + offset] = @divTrunc(num, denominator) % 10;
                            }
                        },
                        //ctx str
                        0x55 => {
                            for (0..x) |reg_idx| {
                                self.memory[self.regs.i + reg_idx] = self.regs.v[reg_idx];
                            }

                            self.memory[self.regs.i + x] = self.regs.v[x];

                            // Chip8 Quirk
                            if (true) {
                                self.regs.i += x + 1;
                            }
                        },
                        //ctx rst
                        0x65 => {
                            for (0..x) |reg_idx| {
                                self.regs.v[reg_idx] = self.memory[self.regs.i + reg_idx];
                            }

                            self.regs.v[x] = self.memory[self.regs.i + x];

                            // Chip8 Quirk
                            if (true) {
                                self.regs.i += x + 1;
                            }
                        },
                        else => {
                            std.log.err("Illegal instruction! op@{x:0>5}:{x:0>5}", .{ self.regs.pc, opcode });
                            return EmulatorError.ExecutionError;
                        },
                    }
                },
            }
            break :pc_val OPCODE_SIZE;
        };
        self.regs.pc += step_addr;
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

                //Chip8 clipping quirk
                if (true) {
                    const wrapped_x = x % cfg.CHIP8_WIDTH;
                    const wrapped_y = y % cfg.CHIP8_HEIGHT;

                    if (wrapped_x + lx > cfg.CHIP8_WIDTH or
                        wrapped_y + ly > cfg.CHIP8_HEIGHT)
                    {
                        continue;
                    }
                }

                if (self.screen_buffer[(y + ly) % cfg.CHIP8_HEIGHT][(x + lx) % cfg.CHIP8_WIDTH] == 1) {
                    self.regs.v[0xf] = 1;
                }

                self.screen_buffer[(y + ly) % cfg.CHIP8_HEIGHT][(x + lx) % cfg.CHIP8_WIDTH] ^= 1;
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
