//! ziglib — shared Zig library for CLI/daemon projects in ~/Projects/Pro.
//!
//! Module index (import as `@import("ziglib").<name>`):
//!   * otel   — OpenTelemetry tracer (OTLP/HTTP JSON export, W3C traceparent).
//!   * term   — terminal primitives: ANSI, spinner, raw-mode keys, prompts.
//!   * cache  — disk-backed TTL cache with flat hash-keyed layout.
//!   * cli    — argument parsing: flags, values, positionals, urlEncode, homeDir.
//!   * text   — token-budget truncation, ANSI-escape stripping.
//!   * french — French locale helpers: date parsing/formatting (FEC, display, ISO).

pub const otel = @import("otel.zig");
pub const term = @import("term.zig");
pub const cache = @import("cache.zig");
pub const cli = @import("cli.zig");
pub const text = @import("text.zig");
pub const french = @import("french.zig");

test {
    // Discover nested tests.
    _ = otel;
    _ = term;
    _ = cache;
    _ = cli;
    _ = text;
    _ = french;
}
