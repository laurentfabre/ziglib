# ziglib — shared Zig primitives for Pro/ CLIs

Reusable modules consumed by canon, ppr, ft, zlsx, c7 via path deps in each project's `build.zig.zon`. Zig 0.15.x. No external runtime deps.

## Quick reference

```
zig build               # builds nothing useful on its own (it's a lib)
zig build test          # runs all module tests
```

## Module index (`@import("ziglib").<name>`)

| Module | LOC | What | Heavy consumers |
|---|---:|---|---|
| `otel` | ~27 KB | OpenTelemetry tracer — OTLP/HTTP JSON export, W3C traceparent, span ring buffer | ft, ppr, canon |
| `term` | ~14 KB | Terminal primitives — ANSI, spinner, raw-mode key input, prompts | ppr, canon, c7 |
| `cache` | ~10 KB | Disk-backed TTL cache — flat SHA-256-keyed layout, atomic writes | ppr, c7 |
| `cli` | ~7 KB | Argument parsing — flags, values, positionals, urlEncode, homeDir | all |
| `french` | ~6 KB | French locale helpers — date parsing/formatting (FEC, display, ISO) | canon, ppr |
| `text` | ~3 KB | Token-budget truncation, ANSI-escape stripping | c7 |
| `xlsx` | ~48 KB | Read-only OOXML spreadsheet reader — shared strings, typed cells | zlsx (wrapper) |

`root.zig` is the authoritative re-export list — keep module comments there in sync with this table when adding a module.

## Conventions

- **Allocator passing** — every public function takes an `Allocator` parameter; no globals.
- **errdefer everywhere** — every resource acquisition has a matching `errdefer` release.
- **Tests in-file** — each module has its own `test` blocks at the bottom; no separate test dirs.
- **Zero deps outside std** — `build.zig.zon` has an empty `dependencies` map. Don't add one without a very strong justification.
- **Opaque to consumers** — callers never see internal file paths; only `ziglib.<module>.<symbol>` is load-bearing.

## When touching this repo

Breaking an API affects every consumer in `Pro/`. Before renaming a public symbol:

```bash
# Check blast radius across the workspace
rg -l 'ziglib\.<symbol>' ~/Projects/Pro ~/Projects/Izabella
```

## Deep-dive references

- `docs/xlsx_test_corpus.md` — xlsx test corpus documentation. Load when working on xlsx.zig.

## Pre-commit

Tracked hooks under `scripts/githooks/`. Activate on a fresh clone with `bash scripts/install-hooks.sh`.
