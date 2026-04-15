//! Small text-processing helpers for CLI output: token-budget truncation
//! and ANSI escape stripping (for when stdout is piped).

const std = @import("std");

/// Truncate `content` so it fits in approximately `max_tokens` tokens.
/// Uses 3.5 bytes/token as a conservative estimate for mixed code+prose.
/// Cuts at the last newline before the byte limit to avoid mid-line splits.
pub fn truncateToTokens(content: []const u8, max_tokens: usize) []const u8 {
    const max_bytes = max_tokens * 7 / 2; // 3.5 bytes per token
    if (content.len <= max_bytes) return content;

    var cut = max_bytes;
    while (cut > 0 and content[cut - 1] != '\n') : (cut -= 1) {}
    if (cut == 0) cut = max_bytes; // no newline found → hard cut
    return content[0..cut];
}

/// Return a copy of `input` with CSI escape sequences (ESC [ … letter)
/// removed. Caller owns the returned slice. Non-CSI ESC sequences are
/// left alone — this targets the ANSI color codes used by terminal UIs.
pub fn stripAnsi(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\x1b' and i + 1 < input.len and input[i + 1] == '[') {
            i += 2;
            while (i < input.len and !std.ascii.isAlphabetic(input[i])) : (i += 1) {}
            if (i < input.len) i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

// ── Tests ─────────────────────────────────────────────────────────────

test "truncateToTokens: short input unchanged" {
    const s = "hello";
    try std.testing.expectEqualStrings(s, truncateToTokens(s, 100));
}

test "truncateToTokens: cuts at newline under the budget" {
    const s = "line one\nline two\nline three\n";
    // 10 tokens → 35 bytes. Input is 30 bytes, so nothing cut.
    try std.testing.expect(truncateToTokens(s, 10).len == s.len);
    // 3 tokens → 10 bytes. Cut at last '\n' ≤ 10, which is after "line one\n" (9).
    try std.testing.expectEqualStrings("line one\n", truncateToTokens(s, 3));
}

test "truncateToTokens: no newline forces hard cut" {
    const s = "abcdefghij";
    // 2 tokens → 7 bytes. No newline → hard cut at 7.
    try std.testing.expectEqualStrings("abcdefg", truncateToTokens(s, 2));
}

test "stripAnsi: removes CSI color codes" {
    const allocator = std.testing.allocator;
    const input = "\x1b[31merror\x1b[0m: something";
    const out = try stripAnsi(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("error: something", out);
}

test "stripAnsi: no escapes passes through" {
    const allocator = std.testing.allocator;
    const out = try stripAnsi(allocator, "plain text");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("plain text", out);
}
