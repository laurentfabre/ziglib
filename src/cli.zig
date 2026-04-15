//! CLI argument-parsing primitives and a few string helpers commonly
//! needed by CLIs: URL encoding, $HOME lookup.
//!
//! Stateless and allocator-explicit — functions that return owned slices
//! take an allocator parameter and the caller frees.

const std = @import("std");

// ── Flag inspection ──────────────────────────────────────────────────

/// True if `flag` appears anywhere in `args`.
pub fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

/// Return the argument immediately after `flag`, or null if the flag is
/// absent or the next token starts with '-' (looks like another flag).
pub fn getFlagValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, flag)) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                return args[i + 1];
            }
        }
    }
    return null;
}

/// Parse the value after `flag` as an integer of type `T`. Returns null on
/// absence or parse failure. Example: `parseIntFlag(usize, args, "--max-tokens")`.
pub fn parseIntFlag(comptime T: type, args: []const []const u8, flag: []const u8) ?T {
    const val = getFlagValue(args, flag) orelse return null;
    return std.fmt.parseInt(T, val, 10) catch null;
}

// ── Positional collection ────────────────────────────────────────────

/// Return positional arguments (skipping flags and the values of any flag
/// in `value_flags`). Caller owns the returned slice.
///
/// `value_flags` lets you declare which flags consume the next arg —
/// this mirrors how `--api-key X` should not treat `X` as a positional.
pub fn positionals(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    value_flags: []const []const u8,
) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-")) {
            if (containsFlag(value_flags, arg)) i += 1;
        } else {
            try result.append(allocator, arg);
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Join positional arguments into a single space-separated string. Useful
/// for search queries expressed as `ctx7 query react "useEffect cleanup"`
/// where the remaining args collapse into a natural-language phrase.
pub fn collectKeywords(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    value_flags: []const []const u8,
) ![]const u8 {
    const pos = try positionals(allocator, args, value_flags);
    defer allocator.free(pos);
    if (pos.len == 0) return "";
    var buf: std.ArrayList(u8) = .empty;
    for (pos, 0..) |word, i| {
        if (i > 0) try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, word);
    }
    return buf.toOwnedSlice(allocator);
}

fn containsFlag(flags: []const []const u8, needle: []const u8) bool {
    for (flags) |f| {
        if (std.mem.eql(u8, f, needle)) return true;
    }
    return false;
}

// ── String helpers ───────────────────────────────────────────────────

/// Percent-encode a string per RFC 3986 "unreserved" set. Caller owns
/// the returned slice.
pub fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(allocator, c);
        } else {
            try buf.writer(allocator).print("%{X:0>2}", .{c});
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Read the user's `$HOME`. Returns `error.NoHomeDir` if the variable is
/// unset or empty. Always returns an owned slice — callers should prefer
/// this over raw `posix.getenv` so ownership semantics stay uniform.
pub fn homeDir(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHomeDir;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "hasFlag" {
    const args = [_][]const u8{ "--json", "react", "--compact" };
    try std.testing.expect(hasFlag(&args, "--json"));
    try std.testing.expect(hasFlag(&args, "--compact"));
    try std.testing.expect(!hasFlag(&args, "--missing"));
}

test "getFlagValue: returns next arg" {
    const args = [_][]const u8{ "--max-tokens", "2000", "react" };
    try std.testing.expectEqualStrings("2000", getFlagValue(&args, "--max-tokens").?);
}

test "getFlagValue: skips when next looks like a flag" {
    const args = [_][]const u8{ "--max-tokens", "--compact" };
    try std.testing.expect(getFlagValue(&args, "--max-tokens") == null);
}

test "parseIntFlag" {
    const args = [_][]const u8{ "--max-tokens", "2000" };
    try std.testing.expectEqual(@as(?usize, 2000), parseIntFlag(usize, &args, "--max-tokens"));
    try std.testing.expectEqual(@as(?usize, null), parseIntFlag(usize, &args, "--absent"));
}

test "positionals: excludes flags and their values" {
    const args = [_][]const u8{ "--api-key", "SECRET", "react", "--json", "useEffect" };
    const value_flags = [_][]const u8{"--api-key"};

    const pos = try positionals(std.testing.allocator, &args, &value_flags);
    defer std.testing.allocator.free(pos);

    try std.testing.expectEqual(@as(usize, 2), pos.len);
    try std.testing.expectEqualStrings("react", pos[0]);
    try std.testing.expectEqualStrings("useEffect", pos[1]);
}

test "collectKeywords: joins with spaces" {
    const args = [_][]const u8{ "--json", "useEffect", "cleanup" };
    const s = try collectKeywords(std.testing.allocator, &args, &.{});
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("useEffect cleanup", s);
}

test "urlEncode: unreserved chars pass through" {
    const s = try urlEncode(std.testing.allocator, "abc-_.~XYZ");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("abc-_.~XYZ", s);
}

test "urlEncode: reserved chars become %XX" {
    const s = try urlEncode(std.testing.allocator, "hello world/?&");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("hello%20world%2F%3F%26", s);
}
