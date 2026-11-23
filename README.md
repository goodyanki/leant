# Leant `v0.5.0`

A formally verified backend web framework written in **Lean 4**.

> **Ergonomic Gin-style developer experience + high-throughput Rust (`tokio` + `hyper`) HTTP transport + 30 machine-checked theorems covering routing, SQL injection immunity, row-level tenant isolation, authorization, and static file path safety.**

## Architecture

- **HTTP Transport (`transport/rust-http`, `transport/c/bridge.c`)**: Multi-threaded HTTP/1.1 engine built on Rust `tokio` + `hyper` with configurable header/request timeouts, connection limits, and graceful `SIGINT`/`SIGTERM` drain, bridged to Lean 4 via a thin C ABI shim ([ADR-001](docs/adr/001-rust-hyper-transport.md)).
- **Web Core (`Leant/Core`, `Leant/Router`, `Leant/Binding`, `Leant/Middleware`, `Leant/App`)**:
  - Total segment-trie router (`static > :param > *wildcard` with backtracking, 404/405 dispatch) + 8 formal routing theorems.
  - Compile-time checked route DSL (`route!`) verifying path parameter types against handler signatures.
  - Route groups, onion-model middleware (`logger`, `recovery`, `requestId`, `cors`, `bodyLimit`, `timeout`), secure-default cookies (`HttpOnly; Secure; SameSite=Lax`), SSE/streaming, path-traversal-proof static file serving (`App.static`), and in-memory HTTP testing (`Leant.Testing`).
  - Proof-carrying refined binding types (`NonEmpty`, `Bounded`, `NonEmptyBounded`, `Email`, `PositiveNat`).
- **Verified ORM (`Leant/Data`)**:
  - Declarative `leant_table` / `leant_tenant_table` macros, deeply embedded typed `Expr` GADT, `INNER`/`LEFT JOIN` queries, versioned schema migrations (`diffSchema`, `migrateUp`, `rollbackLast`), SQLite & pure-Rust PostgreSQL drivers, connection pooling, transactions, and 11 formal ORM/RLS theorems ([ADR-002](docs/adr/002-verified-orm-design.md)).
- **Verified Authorization & Security (`Leant/Authz`, `Leant/Security`)**:
  - Pure RBAC + resource ownership + explicit forbid + tenant-isolation policy engine with 10 machine-checked theorems, `Authorized` proof tokens, declarative `requires ... on ... with auth => ...` macro, and `PolicyDiff` auditor.
  - Pure-Rust audited cryptography (`HMAC-SHA256`, `Argon2id` password hashing, constant-time equality, OS CSPRNG), signed stateless session/bearer tokens, double-submit cookie CSRF protection, and thread-safe token-bucket rate limiting.

## Quick Start

```bash
# Build framework library (automatically compiles Rust transport/crypto/postgres & C shims)
lake build

# Run unit, formal proof, SQLite, security, static, and in-memory HTTP tests
lake test

# Build and run examples
lake build hello && ./.lake/build/bin/hello
lake build todo  && ./.lake/build/bin/todo
lake build saas  && ./.lake/build/bin/saas
```

## Documentation & Benchmarks

- [Verified Guarantees & TCB](docs/SECURITY_PROOFS.md)
- [ADR-001: Rust Hyper HTTP Transport](docs/adr/001-rust-hyper-transport.md)
- [ADR-002: Formally Verified ORM Architecture](docs/adr/002-verified-orm-design.md)
- [Benchmarks: Leant vs Gin (Plaintext, JSON, SQLite DB, Authz + RLS)](docs/benchmarks/BENCHMARKS.md)
- [HTTP Transport Evaluation](docs/benchmarks/transport-comparison.md)
