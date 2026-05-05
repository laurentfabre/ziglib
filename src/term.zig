//! Terminal primitives for CLI projects: ANSI colors, spinner, raw-mode
//! key reading, interactive prompts (input, confirm, select, checkbox).
//!
//! POSIX-only (relies on `std.posix`). Writes to stderr for UI output so
//! stdout stays reserved for structured data.
//!
//! No allocator ownership — prompt results that return owned slices are
//! allocated with a caller-provided allocator and must be freed by the
//! caller.

const std = @import("std");
const posix = std.posix;
const Io = std.Io;

// ── ANSI escape helpers ───────────────────────────────────────────────

pub const Style = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const italic = "\x1b[3m";
    pub const underline = "\x1b[4m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";
    pub const gray = "\x1b[90m";
    pub const clear_line = "\x1b[2K";
    pub const hide_cursor = "\x1b[?25l";
    pub const show_cursor = "\x1b[?25h";
    pub const move_up = "\x1b[A";
};

pub fn isTTY() bool {
    return posix.isatty(posix.STDOUT_FILENO);
}

// ── Writergate bridges ────────────────────────────────────────────────
//
// 0.16 `File.writer(io, &buf)` returns a `File.Writer` whose `.interface`
// is the `*std.Io.Writer` we expose to callers. Both buffer and the
// `File.Writer` struct must live at a stable address while in use, since
// `drain` recovers the parent via `@fieldParentPtr("interface", io_w)`.
//
// Callers stack-allocate one of these structs and call `init(io)` once,
// then pass `writer()` out as a `*std.Io.Writer`. Zero-byte buffer means
// writes go straight to the syscall — same observable behavior as the
// 0.15 `deprecatedWriter`, no `flush()` required for ad-hoc prints.
//
//     var sw: term.StdoutWriter = .{};
//     sw.init(io);
//     try run(args, sw.writer());

pub const StdoutWriter = struct {
    buf: [0]u8 = undefined,
    fw: Io.File.Writer = undefined,
    initialized: bool = false,

    pub fn init(self: *StdoutWriter, io: Io) void {
        if (!self.initialized) {
            self.fw = Io.File.stdout().writer(io, &self.buf);
            self.initialized = true;
        }
    }

    pub fn writer(self: *StdoutWriter) *Io.Writer {
        std.debug.assert(self.initialized);
        return &self.fw.interface;
    }
};

pub const StderrWriter = struct {
    buf: [0]u8 = undefined,
    fw: Io.File.Writer = undefined,
    initialized: bool = false,

    pub fn init(self: *StderrWriter, io: Io) void {
        if (!self.initialized) {
            self.fw = Io.File.stderr().writer(io, &self.buf);
            self.initialized = true;
        }
    }

    pub fn writer(self: *StderrWriter) *Io.Writer {
        std.debug.assert(self.initialized);
        return &self.fw.interface;
    }
};

// ── Spinner ───────────────────────────────────────────────────────────

/// Animated terminal spinner. Two-phase init/run pattern is required so the
/// background thread can hold a stable pointer to the caller-owned struct;
/// using a single-call factory that returns by value would leave the thread
/// dereferencing a freed stack slot.
///
/// Usage:
///     var spinner = term.Spinner.init(io, "Doing thing...");
///     spinner.run();
///     defer spinner.stop();
///     // ... do work ...
///     spinner.succeed("Done");
pub const Spinner = struct {
    io: Io,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    message: []const u8,

    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    pub fn init(io: Io, message: []const u8) Spinner {
        return .{
            .io = io,
            .running = std.atomic.Value(bool).init(true),
            .message = message,
            .thread = null,
        };
    }

    /// Spawn the animation thread. Must be called on a Spinner whose storage
    /// outlives `stop()` — typically a `var spinner = ...; spinner.run();`
    /// pair in the caller's frame.
    pub fn run(self: *Spinner) void {
        self.thread = std.Thread.spawn(.{}, animateLoop, .{self}) catch null;
    }

    fn animateLoop(self: *Spinner) void {
        var buf: [0]u8 = undefined;
        var fw = Io.File.stderr().writer(self.io, &buf);
        const w = &fw.interface;
        var i: usize = 0;
        while (self.running.load(.acquire)) {
            w.print("\r" ++ Style.clear_line ++ Style.cyan ++ "{s}" ++ Style.reset ++ " {s}", .{
                frames[i % frames.len],
                self.message,
            }) catch {};
            Io.sleep(self.io, .fromMilliseconds(80), .awake) catch return;
            i +%= 1;
        }
    }

    pub fn succeed(self: *Spinner, msg: []const u8) void {
        self.stop();
        var buf: [0]u8 = undefined;
        var fw = Io.File.stderr().writer(self.io, &buf);
        fw.interface.print("\r" ++ Style.clear_line ++ Style.green ++ "✔" ++ Style.reset ++ " {s}\n", .{msg}) catch {};
    }

    pub fn fail(self: *Spinner, msg: []const u8) void {
        self.stop();
        var buf: [0]u8 = undefined;
        var fw = Io.File.stderr().writer(self.io, &buf);
        fw.interface.print("\r" ++ Style.clear_line ++ Style.red ++ "✖" ++ Style.reset ++ " {s}\n", .{msg}) catch {};
    }

    pub fn warn(self: *Spinner, msg: []const u8) void {
        self.stop();
        var buf: [0]u8 = undefined;
        var fw = Io.File.stderr().writer(self.io, &buf);
        fw.interface.print("\r" ++ Style.clear_line ++ Style.yellow ++ "⚠" ++ Style.reset ++ " {s}\n", .{msg}) catch {};
    }

    pub fn stop(self: *Spinner) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        var buf: [0]u8 = undefined;
        var fw = Io.File.stderr().writer(self.io, &buf);
        fw.interface.writeAll("\r" ++ Style.clear_line) catch {};
    }
};

// ── Terminal raw mode ─────────────────────────────────────────────────

pub fn enableRawMode() !posix.termios {
    const original = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = original;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    return original;
}

pub fn disableRawMode(original: posix.termios) void {
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original) catch {};
}

// ── Key reading ───────────────────────────────────────────────────────

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    enter,
    space,
    backspace,
    tab,
    escape,
    ctrl_c,
    delete,
    unknown,
};

fn readByteFrom(r: *Io.Reader) !u8 {
    var byte: [1]u8 = undefined;
    const n = try r.readSliceShort(&byte);
    if (n == 0) return error.EndOfStream;
    return byte[0];
}

pub fn readKey(io: Io) !Key {
    var buf: [16]u8 = undefined;
    var fr = Io.File.stdin().reader(io, &buf);
    const reader = &fr.interface;
    const c = readByteFrom(reader) catch return .ctrl_c;

    return switch (c) {
        '\r', '\n' => .enter,
        ' ' => .space,
        127, 8 => .backspace,
        '\t' => .tab,
        3 => .ctrl_c,
        27 => blk: {
            const c2 = readByteFrom(reader) catch break :blk .escape;
            if (c2 != '[') break :blk .escape;
            const c3 = readByteFrom(reader) catch break :blk .unknown;
            break :blk switch (c3) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                '3' => del: {
                    _ = readByteFrom(reader) catch {};
                    break :del .delete;
                },
                else => .unknown,
            };
        },
        else => .{ .char = c },
    };
}

// ── Prompts ───────────────────────────────────────────────────────────

pub fn input(allocator: std.mem.Allocator, io: Io, prompt_text: []const u8) ![]const u8 {
    var wbuf: [0]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &wbuf);
    try fw.interface.print(Style.cyan ++ "?" ++ Style.reset ++ " " ++ Style.bold ++ "{s}" ++ Style.reset ++ " ", .{prompt_text});

    var rbuf: [4096]u8 = undefined;
    var fr = Io.File.stdin().reader(io, &rbuf);
    return try fr.interface.takeDelimiterExclusive('\n').dupe(allocator);
}

pub fn confirm(io: Io, prompt_text: []const u8, default: bool) !bool {
    var wbuf: [0]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &wbuf);
    const hint: []const u8 = if (default) "(Y/n)" else "(y/N)";
    try fw.interface.print(Style.cyan ++ "?" ++ Style.reset ++ " " ++ Style.bold ++ "{s}" ++ Style.reset ++ " {s} ", .{ prompt_text, hint });

    var rbuf: [128]u8 = undefined;
    var fr = Io.File.stdin().reader(io, &rbuf);
    const line = fr.interface.takeDelimiterExclusive('\n') catch return default;
    const answer = std.mem.trim(u8, line, " \t\r");

    if (answer.len == 0) return default;
    return answer[0] == 'y' or answer[0] == 'Y';
}

pub const SelectOption = struct {
    label: []const u8,
    value: []const u8,
    description: ?[]const u8 = null,
};

pub fn selectPrompt(io: Io, prompt_text: []const u8, options: []const SelectOption) !?usize {
    if (options.len == 0) return null;

    var wbuf: [0]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &wbuf);
    const w = &fw.interface;
    try w.print(Style.cyan ++ "?" ++ Style.reset ++ " " ++ Style.bold ++ "{s}" ++ Style.reset ++ "\n", .{prompt_text});

    const original = try enableRawMode();
    defer disableRawMode(original);

    try w.writeAll(Style.hide_cursor);
    defer w.writeAll(Style.show_cursor) catch {};

    var cursor: usize = 0;

    while (true) {
        for (options, 0..) |opt, i| {
            if (i == cursor) {
                try w.print("  " ++ Style.cyan ++ "❯" ++ Style.reset ++ " " ++ Style.bold ++ "{s}" ++ Style.reset, .{opt.label});
                if (opt.description) |desc| {
                    try w.print(" " ++ Style.dim ++ "— {s}" ++ Style.reset, .{desc});
                }
            } else {
                try w.print("    " ++ Style.dim ++ "{s}" ++ Style.reset, .{opt.label});
            }
            try w.writeByte('\n');
        }

        const key = try readKey(io);
        switch (key) {
            .up => cursor = if (cursor > 0) cursor - 1 else options.len - 1,
            .down => cursor = if (cursor + 1 < options.len) cursor + 1 else 0,
            .enter => {
                for (options) |_| {
                    try w.writeAll(Style.move_up ++ Style.clear_line);
                }
                try w.print("  " ++ Style.green ++ "✔" ++ Style.reset ++ " {s}\n", .{options[cursor].label});
                return cursor;
            },
            .ctrl_c => {
                for (options) |_| {
                    try w.writeAll(Style.move_up ++ Style.clear_line);
                }
                return null;
            },
            else => {},
        }

        for (options) |_| {
            try w.writeAll(Style.move_up ++ Style.clear_line);
        }
    }
}

pub fn checkbox(
    allocator: std.mem.Allocator,
    io: Io,
    prompt_text: []const u8,
    options: []const SelectOption,
    max_select: usize,
) ![]usize {
    if (options.len == 0) return &[_]usize{};

    var wbuf: [0]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &wbuf);
    const w = &fw.interface;
    try w.print(Style.cyan ++ "?" ++ Style.reset ++ " " ++ Style.bold ++ "{s}" ++ Style.reset ++ " " ++ Style.dim ++ "(space to toggle, enter to confirm)" ++ Style.reset ++ "\n", .{prompt_text});

    const original = try enableRawMode();
    defer disableRawMode(original);

    try w.writeAll(Style.hide_cursor);
    defer w.writeAll(Style.show_cursor) catch {};

    var selected = try allocator.alloc(bool, options.len);
    defer allocator.free(selected);
    @memset(selected, false);

    var cursor: usize = 0;
    var count: usize = 0;

    while (true) {
        for (options, 0..) |opt, i| {
            const marker: []const u8 = if (selected[i]) Style.green ++ "◉" ++ Style.reset else "○";
            if (i == cursor) {
                try w.print("  " ++ Style.cyan ++ "❯" ++ Style.reset ++ " {s} " ++ Style.bold ++ "{s}" ++ Style.reset, .{ marker, opt.label });
                if (opt.description) |desc| {
                    try w.print(" " ++ Style.dim ++ "— {s}" ++ Style.reset, .{desc});
                }
            } else {
                try w.print("    {s} " ++ Style.dim ++ "{s}" ++ Style.reset, .{ marker, opt.label });
            }
            try w.writeByte('\n');
        }

        const key = try readKey(io);
        switch (key) {
            .up => cursor = if (cursor > 0) cursor - 1 else options.len - 1,
            .down => cursor = if (cursor + 1 < options.len) cursor + 1 else 0,
            .space => {
                if (selected[cursor]) {
                    selected[cursor] = false;
                    count -= 1;
                } else if (max_select == 0 or count < max_select) {
                    selected[cursor] = true;
                    count += 1;
                }
            },
            .enter => {
                for (options) |_| {
                    try w.writeAll(Style.move_up ++ Style.clear_line);
                }
                var result: std.ArrayList(usize) = .empty;
                for (selected, 0..) |sel, i| {
                    if (sel) try result.append(allocator, i);
                }
                return result.toOwnedSlice(allocator);
            },
            .ctrl_c => {
                for (options) |_| {
                    try w.writeAll(Style.move_up ++ Style.clear_line);
                }
                return &[_]usize{};
            },
            else => {},
        }

        for (options) |_| {
            try w.writeAll(Style.move_up ++ Style.clear_line);
        }
    }
}
