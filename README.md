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
- **Verified ORM (`Leant/Data`)**:
  - Deeply embedded typed schema and expression GADT with SQL injection non-interference proofs, placeholder arity soundness, semantic row-level tenant isolation (RLS), and SQLite driver with connection pooling and transactions (see [ADR-002](docs/adr/002-verified-orm-design.md)).
- **Verified Authorization & Security (`Leant/Authz`, `Leant/Security`)**:
  - Pure RBAC + resource ownership + explicit forbid + tenant-isolation policy engine with 10 machine-checked theorems (`tenant_isolation`, `deny_overrides`, `default_deny`, `authorized_implies_same_tenant`, `guard_sound`, `role_monotonicity`, `forbid_monotonicity`, `role_grant_no_cross_tenant_escalation`, `role_grant_no_forbid_bypass`, `rls_principal_alignment`).
  - Proof-carrying `Authorized` tokens, declarative `requires ... on ... with auth => ...` guard macro, and `PolicyDiff` auditor.
  - Pure-Rust audited crypto primitives (`HMAC-SHA256`, constant-time equality, OS CSPRNG), signed stateless session/bearer tokens, double-submit cookie CSRF protection, and thread-safe token-bucket rate limiting.

## Quick Start

```bash
# Build framework library (automatically compiles Rust HTTP/crypto staticlib & C shims)
lake build

# Run unit, formal proof, SQLite, security, and in-memory HTTP tests
lake test

# Build and run examples
lake build hello && ./.lake/build/bin/hello
lake build todo  && ./.lake/build/bin/todo
lake build saas  && ./.lake/build/bin/saas
```

## Documentation & Benchmarks

- [ADR-001: Rust Hyper HTTP Transport](docs/adr/001-rust-hyper-transport.md)
- [ADR-002: Formally Verified ORM Architecture](docs/adr/002-verified-orm-design.md)
- [Transport Evaluation Benchmarks](bench/results/transport-comparison.md)
- [HTTP Framework Benchmarks](bench/results/http-benchmarks.md)
