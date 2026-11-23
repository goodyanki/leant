# Leant

A formally verified backend web framework written in **Lean 4**.

> **Ergonomic Gin-style developer experience + high-throughput Rust (`tokio` + `hyper`) HTTP transport + machine-checked guarantees for routing, data access, and authorization.**

## Architecture

- **HTTP Transport (`transport/rust-http`, `transport/c/bridge.c`)**: Multi-threaded HTTP/1.1 engine built on Rust `tokio` + `hyper` with configurable header/request timeouts, connection limits, and graceful `SIGINT`/`SIGTERM` drain, bridged to the Lean 4 runtime through a thin C ABI shim (see [ADR-001](docs/adr/001-rust-hyper-transport.md)).
- **Web Core (`Leant/Core`, `Leant/Router`, `Leant/Binding`, `Leant/Middleware`, `Leant/App`)**:
  - Total segment-trie router (`static > :param > *wildcard` with backtracking, 404/405 dispatch) with machine-checked precedence and roundtrip theorems.
  - Compile-time checked route DSL (`route!`) verifying path parameter types against handler signatures.
  - Route groups, onion-model middleware (`logger`, `recovery`, `requestId`, `cors`, `bodyLimit`, `timeout`), secure-default cookies (`HttpOnly; Secure; SameSite=Lax`), SSE/streaming, and in-memory HTTP testing (`Leant.Testing`).
  - Proof-carrying refined binding types (`NonEmpty`, `Bounded`, `NonEmptyBounded`, `Email`, `PositiveNat`).
- **Verified Data & Authorization (`Leant/Data`, `Leant/Authz`)**:
  - Type-safe query AST with SQL injection non-interference proofs, semantic row-level tenant isolation, and SQLite driver with connection pooling (see [ADR-002](docs/adr/002-verified-orm-design.md)).
  - Pure policy evaluation engine with proof-carrying guards and verified security invariants (tenant isolation, deny overrides, default deny).

## Quick Start

```bash
# Build framework library (automatically compiles Rust HTTP transport & C shims)
lake build

# Run unit, formal proof, and in-memory HTTP tests
lake test

# Build and run examples
lake build hello && ./.lake/build/bin/hello
lake build todo  && ./.lake/build/bin/todo
```

## Documentation & Benchmarks

- [ADR-001: Rust Hyper HTTP Transport](docs/adr/001-rust-hyper-transport.md)
- [ADR-002: Formally Verified ORM Architecture](docs/adr/002-verified-orm-design.md)
- [Transport Evaluation Benchmarks](bench/results/transport-comparison.md)
- [HTTP Framework Benchmarks](bench/results/http-benchmarks.md)
