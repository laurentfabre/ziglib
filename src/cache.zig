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
        base_dir: []const u8,
        ttl_override: ?u64,
    ) !Cache {
        ensureDirRecursive(base_dir) catch {};
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
        base_dir: []u8,
        ttl_override: ?u64,
    ) !Cache {
        ensureDirRecursive(base_dir) catch {};
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
    pub fn get(self: *Cache, key: []const u8) ?[]const u8 {
        const path = self.keyToPath(key) catch return null;
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const stat = file.stat() catch return null;
        const now_ns: i128 = @intCast(std.time.nanoTimestamp());
        const age_ns = now_ns - stat.mtime;
        const ttl_ns: i128 = @as(i128, self.ttl_seconds) * std.time.ns_per_s;
        if (age_ns > ttl_ns) return null;

        return file.readToEndAlloc(self.allocator, std.math.maxInt(usize)) catch null;
    }

    /// Write a value to the cache. Silently drops write errors; callers
    /// treat cache writes as best-effort.
    pub fn put(self: *Cache, key: []const u8, value: []const u8) void {
        const path = self.keyToPath(key) catch return;
        defer self.allocator.free(path);
        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();
        file.writeAll(value) catch {};
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

fn ensureDirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
                if (sep > 0) {
                    try ensureDirRecursive(path[0..sep]);
                    std.fs.makeDirAbsolute(path) catch |e2| switch (e2) {
                        error.PathAlreadyExists => {},
                        else => return e2,
                    };
                }
            }
        },
        else => return err,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "Cache: put/get roundtrip" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs);

    var cache = try Cache.initAt(allocator, abs, null);
    defer cache.deinit();

    cache.put("alpha", "hello world");
    const v = cache.get("alpha") orelse return error.UnexpectedMiss;
    defer allocator.free(v);
    try std.testing.expectEqualStrings("hello world", v);
}

test "Cache: miss returns null" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs);

    var cache = try Cache.initAt(allocator, abs, null);
    defer cache.deinit();

    try std.testing.expect(cache.get("absent") == null);
}

test "Cache: expired entry returns null" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs);

    var cache = try Cache.initAt(allocator, abs, 0); // 0s TTL → always expired
    defer cache.deinit();

    cache.put("stale", "bytes");
    // With TTL=0, any positive age exceeds the window. Sleep a tick to
    // ensure mtime < now on filesystems with second-resolution timestamps.
    std.Thread.sleep(10 * std.time.ns_per_ms);
    try std.testing.expect(cache.get("stale") == null);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs);

    var cache = try Cache.initAt(allocator, abs, null);
    defer cache.deinit();

    const long_key = "x" ** 500;
    cache.put(long_key, "ok");
    const v = cache.get(long_key) orelse return error.UnexpectedMiss;
    defer allocator.free(v);
    try std.testing.expectEqualStrings("ok", v);
}
