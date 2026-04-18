//! French locale helpers — dates in the formats French administrative
//! systems require (FEC, DGFIP filings, notary deeds, syndic reports).
//!
//! Formats covered:
//!   * `YYYYMMDD`   — FEC standard (no separators)
//!   * `DD/MM/YYYY` — French display convention
//!   * `YYYY-MM-DD` — ISO 8601, used as input format
//!
//! Number formatting (comma decimal, NBSP thousands) lives alongside
//! the project-specific fixed-point type that uses it (e.g. canon's
//! `Decimal.formatFrench`) — those methods belong with the type, not
//! in a generic helper.

const std = @import("std");
const assert = std.debug.assert;

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    /// Format as YYYYMMDD (FEC standard).
    pub fn formatFec(self: Date, buf: *[8]u8) []const u8 {
        assert(self.month >= 1 and self.month <= 12);
        assert(self.day >= 1 and self.day <= 31);

        _ = std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}", .{
            self.year, @as(u16, self.month), @as(u16, self.day),
        }) catch unreachable;
        return buf;
    }

    /// Format as DD/MM/YYYY (French display).
    pub fn formatDisplay(self: Date, buf: *[10]u8) []const u8 {
        assert(self.month >= 1 and self.month <= 12);
        assert(self.day >= 1 and self.day <= 31);

        _ = std.fmt.bufPrint(buf, "{d:0>2}/{d:0>2}/{d:0>4}", .{
            @as(u16, self.day), @as(u16, self.month), self.year,
        }) catch unreachable;
        return buf;
    }

    /// Format as YYYY-MM-DD (ISO 8601).
    pub fn formatIso(self: Date, buf: *[10]u8) []const u8 {
        assert(self.month >= 1 and self.month <= 12);
        assert(self.day >= 1 and self.day <= 31);

        _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            self.year, @as(u16, self.month), @as(u16, self.day),
        }) catch unreachable;
        return buf;
    }

    /// Parse from YYYY-MM-DD.
    pub fn parseIso(s: []const u8) error{ InvalidFormat, InvalidDate }!Date {
        if (s.len != 10 or s[4] != '-' or s[7] != '-') return error.InvalidFormat;

        const year = std.fmt.parseInt(u16, s[0..4], 10) catch return error.InvalidFormat;
        const month = std.fmt.parseInt(u8, s[5..7], 10) catch return error.InvalidFormat;
        const day = std.fmt.parseInt(u8, s[8..10], 10) catch return error.InvalidFormat;

        if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidDate;

        return .{ .year = year, .month = month, .day = day };
    }

    /// Parse from YYYYMMDD (FEC format).
    pub fn parseFec(s: []const u8) error{ InvalidFormat, InvalidDate }!Date {
        if (s.len != 8) return error.InvalidFormat;

        const year = std.fmt.parseInt(u16, s[0..4], 10) catch return error.InvalidFormat;
        const month = std.fmt.parseInt(u8, s[4..6], 10) catch return error.InvalidFormat;
        const day = std.fmt.parseInt(u8, s[6..8], 10) catch return error.InvalidFormat;

        if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidDate;

        return .{ .year = year, .month = month, .day = day };
    }

    pub fn eql(a: Date, b: Date) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Date formatFec" {
    const d = Date{ .year = 2025, .month = 3, .day = 15 };
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("20250315", d.formatFec(&buf));
}

test "Date formatFec single digit month/day" {
    const d = Date{ .year = 2025, .month = 1, .day = 5 };
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("20250105", d.formatFec(&buf));
}

test "Date formatDisplay" {
    const d = Date{ .year = 2025, .month = 3, .day = 15 };
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("15/03/2025", d.formatDisplay(&buf));
}

test "Date formatIso" {
    const d = Date{ .year = 2025, .month = 12, .day = 31 };
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("2025-12-31", d.formatIso(&buf));
}

test "Date parseIso valid" {
    const d = try Date.parseIso("2025-06-15");
    try std.testing.expectEqual(@as(u16, 2025), d.year);
    try std.testing.expectEqual(@as(u8, 6), d.month);
    try std.testing.expectEqual(@as(u8, 15), d.day);
}

test "Date parseIso invalid" {
    try std.testing.expectError(error.InvalidFormat, Date.parseIso("2025/06/15"));
    try std.testing.expectError(error.InvalidFormat, Date.parseIso("short"));
    try std.testing.expectError(error.InvalidDate, Date.parseIso("2025-13-01"));
    try std.testing.expectError(error.InvalidDate, Date.parseIso("2025-00-01"));
}

test "Date parseFec valid" {
    const d = try Date.parseFec("20250315");
    try std.testing.expectEqual(@as(u16, 2025), d.year);
    try std.testing.expectEqual(@as(u8, 3), d.month);
    try std.testing.expectEqual(@as(u8, 15), d.day);
}

test "Date parseFec invalid" {
    try std.testing.expectError(error.InvalidFormat, Date.parseFec("2025-03-15"));
    try std.testing.expectError(error.InvalidFormat, Date.parseFec("short"));
}

test "Date eql" {
    const a = Date{ .year = 2025, .month = 1, .day = 1 };
    const b = Date{ .year = 2025, .month = 1, .day = 1 };
    const c = Date{ .year = 2025, .month = 1, .day = 2 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}
