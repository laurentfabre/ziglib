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
// `std.fs.File.deprecatedWriter()` is a 0.15-only shim that 0.16 will
// remove. The replacement (`File.writer(buf) -> Writer{ .interface }`)
// requires both the buffer and the `File.Writer` struct to live at a
// stable address while in use, because `drain` recovers the parent via
// `@fieldParentPtr("interface", io_w)`.
//
// To keep call sites compact, callers stack-allocate one of these
// structs and hand its `writer()` method out as a `*std.Io.Writer`.
// Zero-byte buffer means writes go straight to the syscall — same
// observable behavior as `deprecatedWriter`, no `flush()` required.
//
//     var sw: term.StdoutWriter = .{};
//     try run(args, sw.writer());

pub const StdoutWriter = struct {
    buf: [0]u8 = undefined,
    fw: std.fs.File.Writer = undefined,
    initialized: bool = false,

    pub fn writer(self: *StdoutWriter) *std.Io.Writer {
        if (!self.initialized) {
            self.fw = std.fs.File.stdout().writer(&self.buf);
            self.initialized = true;
        }
        return &self.fw.interface;
    }
};

pub const StderrWriter = struct {
    buf: [0]u8 = undefined,
    fw: std.fs.File.Writer = undefined,
    initialized: bool = false,

    pub fn writer(self: *StderrWriter) *std.Io.Writer {
        if (!self.initialized) {
            self.fw = std.fs.File.stderr().writer(&self.buf);
            self.initialized = true;
        }
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
///     var spinner = term.Spinner.init("Doing thing...");
///     spinner.run();
///     defer spinner.stop();
///     // ... do work ...
///     spinner.succeed("Done");
pub const Spinner = struct {
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    message: []const u8,

    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    pub fn init(message: []const u8) Spinner {
        return .{
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
        const w = std.fs.File.stderr().deprecatedWriter();
        var i: usize = 0;
        while (self.running.load(.acquire)) {
            w.print("\r" ++ Style.clear_line ++ Style.cyan ++ "{s}" ++ Style.reset ++ " {s}", .{
                frames[i % frames.len],
                self.message,
            }) catch {};
            std.Thread.sleep(80 * std.time.ns_per_ms);
            i +%= 1;
        }
    }

    pub fn succeed(self: *Spinner, msg: []const u8) void {
        self.stop();
        const w = std.fs.File.stderr().deprecatedWriter();
        w.print("\r" ++ Style.clear_line ++ Style.green ++ "✔" ++ Style.reset ++ " {s}\n", .{msg}) catch {};
    }

    pub fn fail(self: *Spinner, msg: []const u8) void {
        self.stop();
        const w = std.fs.File.stderr().deprecatedWriter();
        w.print("\r" ++ Style.clear_line ++ Style.red ++ "✖" ++ Style.reset ++ " {s}\n", .{msg}) catch {};
    }

    pub fn warn(self: *Spinner, msg: []const u8) void {
        self.stop();
        const w = std.fs.File.stderr().deprecatedWriter();
        w.print("\r" ++ Style.clear_line ++ Style.yellow ++ "⚠" ++ Style.reset ++ " {s}\n", .{msg}) catch {};
    }

    pub fn stop(self: *Spinner) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        const w = std.fs.File.stderr().deprecatedWriter();
        w.writeAll("\r" ++ Style.clear_line) catch {};
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

pub fn readKey() !Key {
    const reader = std.fs.File.stdin().deprecatedReader();
    const c = reader.readByte() catch return .ctrl_c;

    return switch (c) {
        '\r', '\n' => .enter,
        ' ' => .space,
        127, 8 => .backspace,
        '\t' => .tab,
        3 => .ctrl_c,
        27 => blk: {
            const c2 = reader.readByte() catch break :blk .escape;
            if (c2 != '[') break :blk .escape;
            const c3 = reader.readByte() catch break :blk .unknown;
            break :blk switch (c3) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                '3' => del: {
                    _ = reader.readByte() catch {};
                    break :del .delete;
                },
                else => .unknown,
            };
        },
        else => .{ .char = c },
    };
}

// ── Prompts ───────────────────────────────────────────────────────────

pub fn input(allocator: std.mem.Allocator, prompt_text: []const u8) ![]const u8 {
    const w = std.fs.File.stderr().deprecatedWriter();
    try w.print(Style.cyan ++ "?" ++ Style.reset ++ " " ++ Style.bold ++ "{s}" ++ Style.reset ++ " ", .{prompt_text});

    const reader = std.fs.File.stdin().deprecatedReader();
    const line = try reader.readUntilDelimiterAlloc(allocator, '\n', 4096);
    return line;
}

pub fn confirm(prompt_text: []const u8, default: bool) !bool {
    const w = std.fs.File.stderr().deprecatedWriter();
    const hint: []const u8 = if (default) "(Y/n)" else "(y/N)";
    try w.print(Style.cyan ++ "?" ++ Style.reset ++ " " ++ Style.bold ++ "{s}" ++ Style.reset ++ " {s} ", .{ prompt_text, hint });

    const reader = std.fs.File.stdin().deprecatedReader();
    var buf: [64]u8 = undefined;
    const line = reader.readUntilDelimiter(&buf, '\n') catch return default;
    const answer = std.mem.trim(u8, line, " \t\r");

    if (answer.len == 0) return default;
    return answer[0] == 'y' or answer[0] == 'Y';
}

pub const SelectOption = struct {
    label: []const u8,
    value: []const u8,
    description: ?[]const u8 = null,
};

pub fn selectPrompt(prompt_text: []const u8, options: []const SelectOption) !?usize {
    if (options.len == 0) return null;

    const w = std.fs.File.stderr().deprecatedWriter();
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

        const key = try readKey();
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
    prompt_text: []const u8,
    options: []const SelectOption,
    max_select: usize,
) ![]usize {
    if (options.len == 0) return &[_]usize{};

    const w = std.fs.File.stderr().deprecatedWriter();
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

        const key = try readKey();
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
