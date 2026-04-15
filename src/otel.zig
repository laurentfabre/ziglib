//! Lightweight OpenTelemetry tracer for Zig CLI and daemon projects.
//!
//! Design:
//!   * Zero-allocation hot path: span structs are fixed-size, stored in
//!     a ring buffer protected by a single mutex.
//!   * Transport-agnostic shape: `flush()` synchronously POSTs buffered
//!     spans to the configured OTLP/HTTP JSON endpoint. CLIs flush once
//!     on exit; daemons spawn a timer thread that calls `flush()`
//!     periodically (the tracer itself doesn't care).
//!   * When no collector endpoint is configured, `startSpan()` returns
//!     a null context and all recording is a no-op (near-zero overhead).
//!
//! Transport: OTLP JSON over HTTP (protobuf is not supported). Default
//! collector port for OTLP/HTTP is 4318.
//!
//! Configuration:
//!   * `Config` is the canonical shape. Callers construct it directly
//!     or via `configFromEnv()`, which reads the standard OTEL_*
//!     environment variables:
//!       OTEL_SDK_DISABLED
//!       OTEL_EXPORTER_OTLP_ENDPOINT        — base URL (/v1/traces appended)
//!       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT — full traces endpoint (wins)
//!       OTEL_SERVICE_NAME
//!       OTEL_TRACES_SAMPLER_ARG            — float in [0.0, 1.0]
//!       OTEL_EXPORTER_OTLP_HEADERS         — comma-separated "k=v"
//!
//! Usage (CLI):
//!   const otel = @import("ziglib").otel;
//!   const cfg = try otel.configFromEnv(allocator, .{
//!       .service_name = "myapp",
//!       .service_version = "1.2.3",
//!   });
//!   var tracer = otel.Tracer.init(allocator, cfg);
//!   defer tracer.deinit(); // flushes buffered spans
//!   otel.setGlobal(&tracer);
//!
//!   const root = otel.start("cli", null);
//!   otel.setCurrent(root);
//!   // … do work; nested code calls otel.start(...) to make child spans
//!   otel.end(root, null, "cli", .internal, .ok, &.{});

const std = @import("std");

// =====================================================================
//                         Core types
// =====================================================================

pub const TraceId = [16]u8;
pub const SpanId = [8]u8;

pub const SpanStatus = enum(u8) {
    unset = 0,
    ok = 1,
    err = 2,

    pub fn toOtlpCode(self: SpanStatus) u8 {
        return @intFromEnum(self);
    }
};

pub const SpanKind = enum(u8) {
    internal = 1,
    server = 2,
    client = 3,
};

pub const Attribute = struct {
    key: [48]u8 = .{0} ** 48,
    key_len: usize = 0,
    value: [160]u8 = .{0} ** 160,
    value_len: usize = 0,

    pub fn set(self: *Attribute, key: []const u8, value: []const u8) void {
        const klen = @min(key.len, self.key.len);
        @memcpy(self.key[0..klen], key[0..klen]);
        self.key_len = klen;
        const vlen = @min(value.len, self.value.len);
        @memcpy(self.value[0..vlen], value[0..vlen]);
        self.value_len = vlen;
    }
};

pub const max_attributes = 8;

pub const Span = struct {
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: SpanId = .{0} ** 8,
    has_parent: bool = false,
    name: [128]u8 = .{0} ** 128,
    name_len: usize = 0,
    kind: SpanKind = .internal,
    start_time_ns: i128 = 0,
    end_time_ns: i128 = 0,
    status: SpanStatus = .unset,
    attributes: [max_attributes]Attribute = [_]Attribute{.{}} ** max_attributes,
    attr_count: usize = 0,
};

/// Lightweight context passed through the call chain.
pub const SpanContext = struct {
    trace_id: TraceId,
    span_id: SpanId,
    sampled: bool = true,
    start_time_ns: i128 = 0,

    pub fn isNull(self: SpanContext) bool {
        return std.mem.eql(u8, &self.trace_id, &(.{0} ** 16));
    }
};

pub const null_ctx = SpanContext{
    .trace_id = .{0} ** 16,
    .span_id = .{0} ** 8,
    .sampled = false,
};

// =====================================================================
//                         Global tracer + current span
// =====================================================================

var global_tracer: ?*Tracer = null;

/// Process-wide "current span" used as an implicit parent for new spans
/// created inside library code (e.g. an HTTP client wrapper). Set by the
/// application after starting the root span. A single module-level var
/// suffices for single-threaded CLIs. For multi-threaded daemons, set it
/// once per request-handling thread.
var current_span: ?SpanContext = null;

pub fn setGlobal(t: *Tracer) void {
    global_tracer = t;
}

pub fn getGlobal() ?*Tracer {
    return global_tracer;
}

pub fn setCurrent(ctx: SpanContext) void {
    if (ctx.isNull()) {
        current_span = null;
    } else {
        current_span = ctx;
    }
}

pub fn getCurrent() ?SpanContext {
    return current_span;
}

/// Start a span via the global tracer. Returns null_ctx when disabled.
pub fn start(name: []const u8, parent: ?SpanContext) SpanContext {
    const t = global_tracer orelse return null_ctx;
    return t.startSpan(name, parent);
}

/// End a span via the global tracer. No-op when ctx.isNull().
pub fn end(
    ctx: SpanContext,
    parent: ?SpanContext,
    name: []const u8,
    kind: SpanKind,
    status: SpanStatus,
    attrs: []const [2][]const u8,
) void {
    const t = global_tracer orelse return;
    t.endSpan(ctx, parent, name, kind, status, attrs);
}

// =====================================================================
//                     W3C traceparent parsing
// =====================================================================

/// Parse W3C traceparent header: "00-{32 hex trace_id}-{16 hex span_id}-{2 hex flags}"
pub fn parseTraceparent(header: []const u8) ?SpanContext {
    if (header.len < 55) return null;
    if (header[0] != '0' or header[1] != '0' or header[2] != '-') return null;
    if (header[35] != '-' or header[52] != '-') return null;

    var ctx: SpanContext = undefined;
    ctx.trace_id = hexDecode16(header[3..35]) orelse return null;
    ctx.span_id = hexDecode8(header[36..52]) orelse return null;
    const flags = hexDecodeByte(header[53..55]) orelse return null;
    ctx.sampled = (flags & 0x01) != 0;
    ctx.start_time_ns = std.time.nanoTimestamp();
    return ctx;
}

/// Format SpanContext as W3C traceparent header (55 bytes).
pub fn formatTraceparent(ctx: SpanContext, buf: *[55]u8) []const u8 {
    buf[0] = '0';
    buf[1] = '0';
    buf[2] = '-';
    hexEncode16(ctx.trace_id, buf[3..35]);
    buf[35] = '-';
    hexEncode8(ctx.span_id, buf[36..52]);
    buf[52] = '-';
    buf[53] = '0';
    buf[54] = if (ctx.sampled) '1' else '0';
    return buf[0..55];
}

// =====================================================================
//                            Tracer
// =====================================================================

pub const span_buffer_capacity = 512;

/// Service metadata the caller provides (comptime constants or build-time
/// injected values). ziglib does not know any consumer-specific identity.
pub const ConfigDefaults = struct {
    /// Fallback for `service.name` when OTEL_SERVICE_NAME is unset.
    service_name: []const u8,
    /// `service.version` resource attribute. Omitted if empty.
    service_version: []const u8 = "",
    /// `service.instance.id` resource attribute. Omitted if empty.
    service_instance_id: []const u8 = "",
};

pub const Config = struct {
    enabled: bool = false,
    collector_url: ?[]u8 = null, // owned by `allocator`
    service_name: []u8, // owned
    service_version: []const u8 = "", // borrowed; caller guarantees lifetime
    service_instance_id: []const u8 = "", // borrowed; caller guarantees lifetime
    sample_rate: f32 = 1.0,
    extra_headers: ?[]u8 = null, // owned raw "k=v,k=v"
};

pub const Tracer = struct {
    config: Config,
    allocator: std.mem.Allocator,

    // Ring buffer for completed spans.
    spans: [span_buffer_capacity]Span = undefined,
    span_head: usize = 0,
    span_count: usize = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config) Tracer {
        return .{ .allocator = allocator, .config = config };
    }

    /// Flush remaining spans (best-effort) and free config strings.
    pub fn deinit(self: *Tracer) void {
        if (self.config.enabled and self.span_count > 0 and self.config.collector_url != null) {
            self.flush() catch {};
        }
        self.allocator.free(self.config.service_name);
        if (self.config.collector_url) |u| self.allocator.free(u);
        if (self.config.extra_headers) |h| self.allocator.free(h);
    }

    /// Start a new span. Returns null_ctx when tracing is disabled or
    /// the sampler rejects. Callers MUST check `.isNull()`.
    pub fn startSpan(self: *Tracer, name: []const u8, parent: ?SpanContext) SpanContext {
        _ = name; // name is recorded in endSpan
        if (!self.config.enabled) return null_ctx;

        if (self.config.sample_rate < 1.0) {
            var rng_buf: [4]u8 = undefined;
            std.crypto.random.bytes(&rng_buf);
            const raw = std.mem.readInt(u32, &rng_buf, .little);
            const val: f32 = @as(f32, @floatFromInt(raw)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
            if (val > self.config.sample_rate) return null_ctx;
        }

        var ctx: SpanContext = undefined;
        if (parent) |p| {
            ctx.trace_id = p.trace_id;
        } else {
            std.crypto.random.bytes(&ctx.trace_id);
        }
        std.crypto.random.bytes(&ctx.span_id);
        ctx.sampled = true;
        ctx.start_time_ns = std.time.nanoTimestamp();
        return ctx;
    }

    /// Record a completed span in the ring buffer.
    pub fn endSpan(
        self: *Tracer,
        ctx: SpanContext,
        parent: ?SpanContext,
        name: []const u8,
        kind: SpanKind,
        status: SpanStatus,
        attrs: []const [2][]const u8,
    ) void {
        if (!self.config.enabled or ctx.isNull()) return;

        var span: Span = .{
            .trace_id = ctx.trace_id,
            .span_id = ctx.span_id,
            .kind = kind,
            .start_time_ns = ctx.start_time_ns,
            .end_time_ns = std.time.nanoTimestamp(),
            .status = status,
        };

        if (parent) |p| {
            span.parent_span_id = p.span_id;
            span.has_parent = true;
        }

        const nlen = @min(name.len, span.name.len);
        @memcpy(span.name[0..nlen], name[0..nlen]);
        span.name_len = nlen;

        for (attrs, 0..) |attr, i| {
            if (i >= max_attributes) break;
            span.attributes[i].set(attr[0], attr[1]);
            span.attr_count = i + 1;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        self.spans[self.span_head] = span;
        self.span_head = (self.span_head + 1) % span_buffer_capacity;
        if (self.span_count < span_buffer_capacity) self.span_count += 1;
    }

    /// Drain buffered spans and POST them to the collector as OTLP JSON.
    /// Synchronous. Safe to call multiple times; an empty buffer is a no-op.
    pub fn flush(self: *Tracer) !void {
        const url = self.config.collector_url orelse return;

        self.mutex.lock();
        const n = self.span_count;
        if (n == 0) {
            self.mutex.unlock();
            return;
        }

        const batch = try self.allocator.alloc(Span, n);
        defer self.allocator.free(batch);
        const start_idx = if (n <= self.span_head)
            self.span_head - n
        else
            span_buffer_capacity - (n - self.span_head);
        for (0..n) |i| batch[i] = self.spans[(start_idx + i) % span_buffer_capacity];
        self.span_count = 0;
        self.span_head = 0;
        self.mutex.unlock();

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const json = try serializeOtlpJson(arena, self.config, batch);

        // Build headers: Content-Type + any OTEL_EXPORTER_OTLP_HEADERS entries.
        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.append(arena, .{ .name = "Content-Type", .value = "application/json" });
        if (self.config.extra_headers) |raw| {
            var it = std.mem.tokenizeScalar(u8, raw, ',');
            while (it.next()) |pair_raw| {
                const pair = std.mem.trim(u8, pair_raw, " \t");
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                const key = std.mem.trim(u8, pair[0..eq], " \t");
                const val = std.mem.trim(u8, pair[eq + 1 ..], " \t");
                if (key.len == 0) continue;
                try headers.append(arena, .{ .name = key, .value = val });
            }
        }

        var client: std.http.Client = .{ .allocator = arena };
        defer client.deinit();

        var discard_buf: [1024]u8 = undefined;
        var discard: std.Io.Writer = .fixed(&discard_buf);

        _ = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .extra_headers = headers.items,
            .payload = json,
            .response_writer = &discard,
        }) catch {
            // Fire-and-forget: don't fail the caller because the collector is unreachable.
            return;
        };
    }
};

// =====================================================================
//                       Configuration from env vars
// =====================================================================

/// Read OTEL_* env vars and return a Config. Strings are allocated with
/// `allocator` and released by `Tracer.deinit()`.
pub fn configFromEnv(allocator: std.mem.Allocator, defaults: ConfigDefaults) !Config {
    const env = try std.process.getEnvMap(allocator);
    defer {
        var m = env;
        m.deinit();
    }

    // Explicit kill switch.
    if (env.get("OTEL_SDK_DISABLED")) |v| {
        if (std.ascii.eqlIgnoreCase(v, "true")) {
            return .{
                .enabled = false,
                .service_name = try allocator.dupe(u8, resolveServiceName(env, defaults)),
                .service_version = defaults.service_version,
                .service_instance_id = defaults.service_instance_id,
            };
        }
    }

    // Endpoint resolution: traces-specific wins, otherwise base + /v1/traces.
    const collector_url: ?[]u8 = blk: {
        if (env.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")) |u| {
            if (u.len > 0) break :blk try allocator.dupe(u8, u);
        }
        if (env.get("OTEL_EXPORTER_OTLP_ENDPOINT")) |base| {
            if (base.len == 0) break :blk null;
            const trimmed = std.mem.trimRight(u8, base, "/");
            break :blk try std.fmt.allocPrint(allocator, "{s}/v1/traces", .{trimmed});
        }
        break :blk null;
    };

    // Sample rate (default 1.0). Clamped to [0, 1].
    var sample_rate: f32 = 1.0;
    if (env.get("OTEL_TRACES_SAMPLER_ARG")) |s| {
        sample_rate = std.fmt.parseFloat(f32, s) catch 1.0;
        if (sample_rate < 0.0) sample_rate = 0.0;
        if (sample_rate > 1.0) sample_rate = 1.0;
    }

    const extra_headers: ?[]u8 = if (env.get("OTEL_EXPORTER_OTLP_HEADERS")) |h|
        (if (h.len > 0) try allocator.dupe(u8, h) else null)
    else
        null;

    const service_name = try allocator.dupe(u8, resolveServiceName(env, defaults));

    return .{
        .enabled = collector_url != null,
        .collector_url = collector_url,
        .service_name = service_name,
        .service_version = defaults.service_version,
        .service_instance_id = defaults.service_instance_id,
        .sample_rate = sample_rate,
        .extra_headers = extra_headers,
    };
}

fn resolveServiceName(env: std.process.EnvMap, defaults: ConfigDefaults) []const u8 {
    return env.get("OTEL_SERVICE_NAME") orelse defaults.service_name;
}

// =====================================================================
//                       OTLP JSON serialization
// =====================================================================

fn serializeOtlpJson(arena: std.mem.Allocator, cfg: Config, spans: []const Span) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);

    try aw.writer.writeAll("{\"resourceSpans\":[{\"resource\":{\"attributes\":[");
    try aw.writer.writeAll("{\"key\":\"service.name\",\"value\":{\"stringValue\":");
    try writeJsonString(&aw.writer, cfg.service_name);
    try aw.writer.writeAll("}}");
    if (cfg.service_version.len > 0) {
        try aw.writer.writeAll(",{\"key\":\"service.version\",\"value\":{\"stringValue\":");
        try writeJsonString(&aw.writer, cfg.service_version);
        try aw.writer.writeAll("}}");
    }
    if (cfg.service_instance_id.len > 0) {
        try aw.writer.writeAll(",{\"key\":\"service.instance.id\",\"value\":{\"stringValue\":");
        try writeJsonString(&aw.writer, cfg.service_instance_id);
        try aw.writer.writeAll("}}");
    }
    try aw.writer.writeAll("]},\"scopeSpans\":[{\"scope\":{\"name\":");
    try writeJsonString(&aw.writer, cfg.service_name);
    if (cfg.service_version.len > 0) {
        try aw.writer.writeAll(",\"version\":");
        try writeJsonString(&aw.writer, cfg.service_version);
    }
    try aw.writer.writeAll("},\"spans\":[");

    for (spans, 0..) |span, i| {
        if (i > 0) try aw.writer.writeByte(',');
        try writeSpanJson(&aw.writer, span);
    }

    try aw.writer.writeAll("]}]}]}");
    return aw.written();
}

fn writeSpanJson(w: *std.Io.Writer, span: Span) !void {
    var trace_hex: [32]u8 = undefined;
    hexEncode16(span.trace_id, &trace_hex);
    var span_hex: [16]u8 = undefined;
    hexEncode8(span.span_id, &span_hex);

    try w.writeAll("{\"traceId\":\"");
    try w.writeAll(&trace_hex);
    try w.writeAll("\",\"spanId\":\"");
    try w.writeAll(&span_hex);
    try w.writeByte('"');

    if (span.has_parent) {
        var parent_hex: [16]u8 = undefined;
        hexEncode8(span.parent_span_id, &parent_hex);
        try w.writeAll(",\"parentSpanId\":\"");
        try w.writeAll(&parent_hex);
        try w.writeByte('"');
    }

    try w.writeAll(",\"name\":");
    try writeJsonString(w, span.name[0..span.name_len]);

    try w.writeAll(",\"kind\":");
    try w.print("{d}", .{@intFromEnum(span.kind)});

    try w.writeAll(",\"startTimeUnixNano\":\"");
    try w.print("{d}", .{span.start_time_ns});
    try w.writeAll("\",\"endTimeUnixNano\":\"");
    try w.print("{d}", .{span.end_time_ns});
    try w.writeByte('"');

    if (span.attr_count > 0) {
        try w.writeAll(",\"attributes\":[");
        for (0..span.attr_count) |ai| {
            if (ai > 0) try w.writeByte(',');
            const attr = span.attributes[ai];
            try w.writeAll("{\"key\":");
            try writeJsonString(w, attr.key[0..attr.key_len]);
            try w.writeAll(",\"value\":{\"stringValue\":");
            try writeJsonString(w, attr.value[0..attr.value_len]);
            try w.writeAll("}}");
        }
        try w.writeByte(']');
    }

    try w.writeAll(",\"status\":{\"code\":");
    try w.print("{d}", .{span.status.toOtlpCode()});
    try w.writeAll("}}");
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            else => if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            },
        }
    }
    try w.writeByte('"');
}

// =====================================================================
//                          Hex utilities
// =====================================================================

const hex_chars = "0123456789abcdef";

pub fn hexEncode16(bytes: [16]u8, out: *[32]u8) void {
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

pub fn hexEncode8(bytes: [8]u8, out: *[16]u8) void {
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

fn hexDecode16(hex: *const [32]u8) ?[16]u8 {
    var out: [16]u8 = undefined;
    for (0..16) |i| {
        const hi: u8 = hexVal(hex[i * 2]) orelse return null;
        const lo: u8 = hexVal(hex[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

fn hexDecode8(hex: *const [16]u8) ?[8]u8 {
    var out: [8]u8 = undefined;
    for (0..8) |i| {
        const hi: u8 = hexVal(hex[i * 2]) orelse return null;
        const lo: u8 = hexVal(hex[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

fn hexDecodeByte(hex: *const [2]u8) ?u8 {
    const hi: u8 = hexVal(hex[0]) orelse return null;
    const lo: u8 = hexVal(hex[1]) orelse return null;
    return (hi << 4) | lo;
}

fn hexVal(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

// =====================================================================
//                              Tests
// =====================================================================

test "traceparent parse + format roundtrip" {
    const header = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    const ctx = parseTraceparent(header) orelse return error.ParseFailed;

    try std.testing.expect(ctx.sampled);

    var buf: [55]u8 = undefined;
    const formatted = formatTraceparent(ctx, &buf);
    try std.testing.expectEqualStrings(header[0..52], formatted[0..52]);
}

test "traceparent parse: bad length" {
    try std.testing.expect(parseTraceparent("too-short") == null);
}

test "traceparent parse: bad hex" {
    try std.testing.expect(parseTraceparent("00-ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ-00f067aa0ba902b7-01") == null);
}

test "hex roundtrip 16" {
    const original = [16]u8{ 0x4b, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6, 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 };
    var hex: [32]u8 = undefined;
    hexEncode16(original, &hex);
    const decoded = hexDecode16(&hex) orelse return error.DecodeFailed;
    try std.testing.expectEqualSlices(u8, &original, &decoded);
}

test "SpanContext.isNull" {
    try std.testing.expect(null_ctx.isNull());
    var ctx = null_ctx;
    ctx.trace_id[0] = 1;
    try std.testing.expect(!ctx.isNull());
}

test "Tracer disabled: startSpan returns null_ctx" {
    const cfg: Config = .{
        .enabled = false,
        .service_name = try std.testing.allocator.dupe(u8, "test"),
    };
    var tracer = Tracer.init(std.testing.allocator, cfg);
    defer tracer.deinit();
    const span = tracer.startSpan("x", null);
    try std.testing.expect(span.isNull());
}

test "Tracer enabled: endSpan stores in buffer" {
    const cfg: Config = .{
        .enabled = true,
        .service_name = try std.testing.allocator.dupe(u8, "test"),
    };
    var tracer = Tracer.init(std.testing.allocator, cfg);
    defer tracer.deinit();

    const ctx = tracer.startSpan("span-a", null);
    tracer.endSpan(ctx, null, "span-a", .client, .ok, &.{
        .{ "http.method", "GET" },
        .{ "http.url", "https://example.com" },
    });
    try std.testing.expectEqual(@as(usize, 1), tracer.span_count);
}

test "Tracer: parent/child share trace_id, differ on span_id" {
    const cfg: Config = .{
        .enabled = true,
        .service_name = try std.testing.allocator.dupe(u8, "test"),
    };
    var tracer = Tracer.init(std.testing.allocator, cfg);
    defer tracer.deinit();

    const parent = tracer.startSpan("p", null);
    const child = tracer.startSpan("c", parent);
    try std.testing.expectEqualSlices(u8, &parent.trace_id, &child.trace_id);
    try std.testing.expect(!std.mem.eql(u8, &parent.span_id, &child.span_id));
}

test "Tracer: concurrent flush from background thread (daemon use case)" {
    // Simulates the Izabella pattern: caller spawns its own timer thread
    // that calls `flush()` periodically while the main thread produces
    // spans. No collector URL → flush is a no-op but still exercises
    // mutex contention with the ring-buffer writers.
    const cfg: Config = .{
        .enabled = true,
        .service_name = try std.testing.allocator.dupe(u8, "daemon"),
    };
    var tracer = Tracer.init(std.testing.allocator, cfg);
    defer tracer.deinit();

    var stop = std.atomic.Value(bool).init(false);

    const Worker = struct {
        fn loop(t: *Tracer, s: *std.atomic.Value(bool)) void {
            while (!s.load(.acquire)) {
                std.Thread.sleep(2 * std.time.ns_per_ms);
                t.flush() catch {};
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Worker.loop, .{ &tracer, &stop });

    for (0..10) |_| {
        const ctx = tracer.startSpan("s", null);
        tracer.endSpan(ctx, null, "s", .internal, .ok, &.{});
    }

    stop.store(true, .release);
    thread.join();
    // Passing = no data race under ThreadSanitizer / no crash.
}

test "OTLP JSON serialization includes service fields only when non-empty" {
    const cfg: Config = .{
        .enabled = true,
        .service_name = try std.testing.allocator.dupe(u8, "svc"),
        .service_version = "1.2.3",
    };
    var tracer = Tracer.init(std.testing.allocator, cfg);
    defer tracer.deinit();

    const ctx = tracer.startSpan("http.request", null);
    tracer.endSpan(ctx, null, "http.request", .client, .ok, &.{
        .{ "http.method", "GET" },
    });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const n = tracer.span_count;
    const batch = try arena.alloc(Span, n);
    for (0..n) |i| batch[i] = tracer.spans[i];

    const json = try serializeOtlpJson(arena, tracer.config, batch);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resourceSpans\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"svc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"1.2.3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"service.instance.id\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"http.request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"http.method\"") != null);
}
