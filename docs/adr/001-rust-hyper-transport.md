# ADR-001: Adopt Rust (`tokio` + `hyper`) as the Default HTTP Transport

- **Status**: Accepted
- **Date**: 2026-11-22

## Context

Leant requires high concurrent HTTP/1.1 throughput and predictable tail latency while keeping routing, middleware, binding, data access, and authorization logic in Lean 4 so core invariants can be machine-checked.

## Benchmark Evidence

Benchmarked on Linux x86_64 (2 vCPU, Lean `v4.36.0`, Go Gin `v1.12.0` release mode; full results in [transport-comparison.md](../../bench/results/transport-comparison.md)):

- Pure `Std.Http.Server` peaked at ~3.2k RPS (6.1%–8.5% of Gin) and experienced 181–221 timeouts with 1.33s p99 latency at 512 concurrent connections.
- A Rust (`tokio` + `hyper` 1.x) HTTP/1.1 transport calling Lean 4 via a thin C ABI shim achieved 94.8k–101.7k RPS (~2x–2.7x Gin) with 13.7ms p99 latency, 0 errors, and flat ~14 MB RSS.

## Decision

1. Keep `Leant.Transport.Backend` as a pluggable transport interface so alternative transports (including future `Std.Http` versions) can be swapped in cleanly.
2. Ship `Leant.Transport.RustHyper` as the default backend:
   - Rust (`transport/rust-http`) builds as a `staticlib` orchestrated automatically by Lake into a single native binary.
   - A thin C shim (`transport/c/bridge.c`) isolates Lean internal object layouts via `<lean/lean.h>`.
   - Before spawning Tokio worker threads, the handler/router closure graph is marked thread-shared (`lean_mark_mt`); each worker registers with `lean_initialize_thread` / `lean_finalize_thread`.
3. **Trusted Computing Base (TCB)**: The Rust HTTP transport and C shim sit inside the network I/O TCB (replacing `Std.Http` + `libuv`), leaving all formal verification guarantees for routing, ORM queries, and authorization intact.
