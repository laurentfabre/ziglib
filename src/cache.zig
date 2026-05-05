//! Disk-backed TTL cache.
//!
//! Flat on-disk layout: keys are SHA-256-hashed into filenames under a
//! caller-provided base directory. Values are arbitrary bytes. Freshness
//! is judged by file mtime vs. the configured TTL.
//!
//! The caller owns the base directory path and its layout semantics
//! (e.g. versioning, multi-cache separation). This module provides no
//! opinions about subdirectories or extensions — embed whatever
//! categorization you need in the key.
//!
//! Errors are intentionally swallowed in `get`/`put` so cache misbehavior
//! never breaks the calling program. A corrupt or unreachable cache acts
//! like a perpetual miss.

const std = @import("std");
const Io = std.Io;

pub const Cache = struct {
    allocator: std.mem.Allocator,
    /// Absolute path to the cache directory. Owned by the caller unless
    /// `base_dir_owned` is true, in which case we free it on deinit.
    base_dir: []const u8,
    base_dir_owned: bool = false,
    ttl_seconds: u64,

    pub const default_ttl_seconds: u64 = 3600;

    /// Construct a cache at `base_dir`. The directory is created if it does
    /// not exist (recursively). If `ttl_override` is null, uses default 1h.
    pub fn initAt(
        allocator: std.mem.Allocator,
        io: Io,
        base_dir: []const u8,
        ttl_override: ?u64,
    ) !Cache {
        ensureDirRecursive(io, base_dir) catch {};
        return .{
            .allocator = allocator,
            .base_dir = base_dir,
            .base_dir_owned = false,
            .ttl_seconds = ttl_override orelse default_ttl_seconds,
        };
    }

    /// Same as `initAt`, but the cache takes ownership of the base_dir slice
    /// and frees it on `deinit`. Useful when the caller built the path with
    /// an allocator (e.g. from `std.fmt.allocPrint`) and wants the cache to
    /// own the lifetime.
    pub fn initAtOwned(
        allocator: std.mem.Allocator,
        io: Io,
        base_dir: []u8,
        ttl_override: ?u64,
    ) !Cache {
        ensureDirRecursive(io, base_dir) catch {};
        return .{
            .allocator = allocator,
            .base_dir = base_dir,
            .base_dir_owned = true,
            .ttl_seconds = ttl_override orelse default_ttl_seconds,
        };
    }

    pub fn deinit(self: *Cache) void {
        if (self.base_dir_owned) self.allocator.free(self.base_dir);
    }

    /// Read a cached value. Caller owns the returned bytes and must call
    /// `allocator.free`. Returns null on miss, expiry, or any I/O error.
    pub fn get(self: *Cache, io: Io, key: []const u8) ?[]const u8 {
        const path = self.keyToPath(key) catch return null;
        defer self.allocator.free(path);

        var file = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
        defer file.close(io);

        const stat = file.stat(io) catch return null;
        const now_ts = Io.Clock.Timestamp.now(io, .real);
        const age_ns = now_ts.raw.nanoseconds - stat.mtime.nanoseconds;
        const ttl_ns: i96 = @as(i96, @intCast(self.ttl_seconds)) * std.time.ns_per_s;
        if (age_ns > ttl_ns) return null;

        var read_buf: [4096]u8 = undefined;
        var fr = file.reader(io, &read_buf);
        return fr.interface.allocRemaining(self.allocator, .unlimited) catch null;
    }

    /// Read a cached value, bypassing the TTL check — returns whatever
    /// is on disk regardless of age. Intended for offline fallback:
    /// callers normally use `get`, then fall back to `getStale` only
    /// when the live fetch has already failed. Caller owns the returned
    /// bytes; null on miss or any I/O error.
    pub fn getStale(self: *Cache, io: Io, key: []const u8) ?[]const u8 {
        const path = self.keyToPath(key) catch return null;
        defer self.allocator.free(path);

        var file = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
        defer file.close(io);

        var read_buf: [4096]u8 = undefined;
        var fr = file.reader(io, &read_buf);
        return fr.interface.allocRemaining(self.allocator, .unlimited) catch null;
    }

    /// Write a value to the cache. Silently drops write errors; callers
    /// treat cache writes as best-effort.
    pub fn put(self: *Cache, io: Io, key: []const u8, value: []const u8) void {
        const path = self.keyToPath(key) catch return;
        defer self.allocator.free(path);
        var file = Io.Dir.createFileAbsolute(io, path, .{}) catch return;
        defer file.close(io);
        var write_buf: [4096]u8 = undefined;
        var fw = file.writer(io, &write_buf);
        fw.interface.writeAll(value) catch return;
        fw.interface.flush() catch return;
    }

    /// Convenience: build a cache key by joining `components` with ':'.
    /// Caller owns the returned slice. Useful for composing a key from
    /// a (version, operation, params...) tuple so invalidation is easy.
    pub fn makeKey(
        allocator: std.mem.Allocator,
        components: []const []const u8,
    ) ![]const u8 {
        var total: usize = 0;
        for (components) |c| total += c.len;
        if (components.len > 0) total += components.len - 1; // separators

        const buf = try allocator.alloc(u8, total);
        var i: usize = 0;
        for (components, 0..) |c, idx| {
            if (idx > 0) {
                buf[i] = ':';
                i += 1;
            }
            @memcpy(buf[i .. i + c.len], c);
            i += c.len;
        }
        return buf;
    }

    fn keyToPath(self: *Cache, key: []const u8) ![]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &hash, .{});
        const hex = std.fmt.bytesToHex(hash, .lower);
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}.bin",
            .{ self.base_dir, &hex },
        );
    }
};

fn ensureDirRecursive(io: Io, path: []const u8) !void {
    // 0.16's `createDirPath` walks the chain itself; treat
    // `PathAlreadyExists` as success.
    Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────
//
// `tmpDir` returns a directory under `.zig-cache/tmp/<random>/`. We compose
// an absolute path against that random sub-path for the cache root.

fn tmpAbsPath(allocator: std.mem.Allocator, io: Io, sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &cwd_buf);
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..n], sub_path });
}

test "Cache: put/get roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmpAbsPath(allocator, io, &tmp.sub_path);
    defer allocator.free(abs);

    var cache = try Cache.initAt(allocator, io, abs, null);
    defer cache.deinit();

    cache.put(io, "alpha", "hello world");
    const v = cache.get(io, "alpha") orelse return error.UnexpectedMiss;
    defer allocator.free(v);
    try std.testing.expectEqualStrings("hello world", v);
}

test "Cache: miss returns null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmpAbsPath(allocator, io, &tmp.sub_path);
    defer allocator.free(abs);

    var cache = try Cache.initAt(allocator, io, abs, null);
    defer cache.deinit();

    try std.testing.expect(cache.get(io, "absent") == null);
}

test "Cache: expired entry returns null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmpAbsPath(allocator, io, &tmp.sub_path);
    defer allocator.free(abs);

    var cache = try Cache.initAt(allocator, io, abs, 0); // 0s TTL → always expired
    defer cache.deinit();

    cache.put(io, "stale", "bytes");
    // With TTL=0, any positive age exceeds the window. Sleep a tick to
    // ensure mtime < now on filesystems with second-resolution timestamps.
    Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    try std.testing.expect(cache.get(io, "stale") == null);
}

test "Cache: getStale returns expired entries that get() drops" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmpAbsPath(allocator, io, &tmp.sub_path);
    defer allocator.free(abs);

    var cache = try Cache.initAt(allocator, io, abs, 0); // 0s TTL → always expired
    defer cache.deinit();

    cache.put(io, "alpha", "still useful offline");
    Io.sleep(io, .fromMilliseconds(10), .awake) catch {};

    try std.testing.expect(cache.get(io, "alpha") == null);
    const stale = cache.getStale(io, "alpha") orelse return error.UnexpectedMiss;
    defer allocator.free(stale);
    try std.testing.expectEqualStrings("still useful offline", stale);
}

test "Cache: getStale returns null when the key has never been written" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmpAbsPath(allocator, io, &tmp.sub_path);
    defer allocator.free(abs);

    var cache = try Cache.initAt(allocator, io, abs, null);
    defer cache.deinit();

    try std.testing.expect(cache.getStale(io, "never-written") == null);
}

test "Cache: makeKey joins components with ':'" {
    const allocator = std.testing.allocator;
    const key = try Cache.makeKey(allocator, &.{ "v1", "lib", "react" });
    defer allocator.free(key);
    try std.testing.expectEqualStrings("v1:lib:react", key);
}

test "Cache: put with long key is hashed into filename" {
    // A 500-byte key still hashes into a fixed-length filename (64 hex + .bin).
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmpAbsPath(allocator, io, &tmp.sub_path);
    defer allocator.free(abs);

    var cache = try Cache.initAt(allocator, io, abs, null);
    defer cache.deinit();

    const long_key = "x" ** 500;
    cache.put(io, long_key, "ok");
    const v = cache.get(io, long_key) orelse return error.UnexpectedMiss;
    defer allocator.free(v);
    try std.testing.expectEqualStrings("ok", v);
}
