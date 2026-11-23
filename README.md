# Leant `v0.5.0`

A formally verified backend web framework written in **Lean 4**.

> **Ergonomic Gin-style developer experience + high-throughput Rust (`tokio` + `hyper`) HTTP transport + 40 machine-checked theorems covering routing, SQL injection immunity, row-level tenant isolation, authorization, and static file path safety.**

---

## Table of Contents

- [Highlights](#highlights)
- [Environment Setup](#environment-setup)
- [Quick Start: Run Your First Server](#quick-start-run-your-first-server)
- [Core Usage Examples](#core-usage-examples)
- [Running the Built-in Examples](#running-the-built-in-examples)
- [Testing & Verification](#testing--verification)
- [Performance (Leant vs Gin)](#performance-leant-vs-gin)
- [Architecture & Project Layout](#architecture--project-layout)
- [Documentation](#documentation)

---

## Highlights

- **HTTP Transport (`transport/rust-http`, `transport/c/bridge.c`)**: Multi-threaded HTTP/1.1 engine built on Rust `tokio` + `hyper` with configurable header/request timeouts, connection limits, and graceful `SIGINT`/`SIGTERM` drain ([ADR-001](docs/adr/001-rust-hyper-transport.md)).
- **Web Core (`Leant/Core`, `Leant/Router`, `Leant/Binding`, `Leant/Middleware`, `Leant/App`)**:
  - Total segment-trie router (`static > :param > *wildcard` with backtracking, automatic 404/405 dispatch) backed by **8 formal routing theorems**.
  - Compile-time typed route DSL (`route!`) verifying path parameter types against handler signatures.
  - Route groups, onion-model middleware (`logger`, `recovery`, `requestId`, `cors`, `bodyLimit`, `timeout`), secure-default cookies (`HttpOnly; Secure; SameSite=Lax`), SSE/streaming, path-traversal-proof static file serving (`App.static`), and in-memory HTTP testing (`Leant.Testing`).
  - Proof-carrying refined binding types (`NonEmpty`, `Bounded n`, `NonEmptyBounded n`, `Email`, `PositiveNat`).
- **Verified ORM (`Leant/Data`)**:
  - Declarative `leant_table` / `leant_tenant_table` macros, deeply embedded typed `Expr` GADT, proof-carrying single-table & `INNER`/`LEFT JOIN` queries, versioned schema migrations (`diffSchema`, `migrateUp`, `rollbackLast`), SQLite & pure-Rust PostgreSQL drivers (`INSERT ... RETURNING`), connection pooling, dialect-aware transactions, and **20 formal ORM/JOIN/RLS theorems** ([ADR-002](docs/adr/002-verified-orm-design.md)).
- **Verified Authorization & Security (`Leant/Authz`, `Leant/Security`)**:
  - Pure RBAC + resource ownership + explicit forbid + tenant-isolation policy engine with **11 machine-checked theorems**, `Authorized` proof tokens, `filterAuthorized`, declarative `requires ... on ... with auth => ...` macro, and `PolicyDiff` auditor.
  - Pure-Rust audited cryptography (`HMAC-SHA256`, `Argon2id` password hashing, constant-time equality, OS CSPRNG), wall-clock TTL-enforced stateless session/bearer tokens, double-submit cookie CSRF protection, and thread-safe token-bucket rate limiting.

---

## Environment Setup

Leant targets **Linux (`x86_64`)** and requires a C compiler, SQLite3 development headers, Rust (`cargo`), and Lean 4 (`elan`).

### 1. System Dependencies (Ubuntu / Debian)

```bash
sudo apt-get update
sudo apt-get install -y build-essential curl git libsqlite3-dev
```

### 2. Rust Toolchain

Leant automatically compiles the Rust HTTP transport, crypto primitives, and PostgreSQL wire client via Cargo during `lake build`.

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
```

### 3. Lean 4 Toolchain (`elan`)

The repository pins `leanprover/lean4:v4.36.0` in [`lean-toolchain`](lean-toolchain); `elan` downloads and activates the exact version automatically.

```bash
curl https://elan.lean-lang.org/elan-init.sh -sSf | sh -s -- -y --default-toolchain none
export PATH="$HOME/.elan/bin:$PATH"
```

### 4. Clone & Verify Build

```bash
git clone https://github.com/goodyanki/leant.git
cd leant

# Compiles Rust static library, C ABI shims, and Lean 4 framework + all 40 proofs
lake build

# Runs unit, formal proof, negative-compilation, SQLite, security, and HTTP tests
lake test
```

> **Note**: The first `lake build` downloads Lean `v4.36.0` and builds the Rust crates in release mode. Subsequent incremental builds complete in a few seconds.

---

## Quick Start: Run Your First Server

### Option A: Run the Minimal Built-in Server (`examples/hello`)

```bash
lake build hello
./.lake/build/bin/hello
```

The server listens on `http://127.0.0.1:8080`. Test it in another terminal:

```bash
curl http://127.0.0.1:8080/
# Hello from Leant!

curl http://127.0.0.1:8080/ping
# pong

curl http://127.0.0.1:8080/json
# {"message":"Hello, World!"}

curl http://127.0.0.1:8080/api/v1/users/42
# {"id":42,"name":"user-42"}

curl -X POST http://127.0.0.1:8080/api/v1/users -d '{"name":"Ada"}'
# {"created":true,"payload_len":14}
```

Press `Ctrl+C` (`SIGINT`) or send `SIGTERM` for graceful connection draining.

### Option B: Write a Minimal Server from Scratch

Create a new file (e.g. `MyServer.lean`):

```lean
import Leant

open Leant

def main : IO Unit := do
  let app := Leant.default
    |>.get "/" (fun c => c.text "Hello from Leant!")
    |>.get "/users/:id" (fun c => do
      let id ← c.param! "id" (α := Nat)
      c.jsonRaw s!"\{\"id\":{id}}")
  app.run "127.0.0.1:8080"
```

Register it as an executable in `lakefile.lean`:

```lean
lean_exe my_server where
  root := `MyServer
  moreLinkArgs := commonLinkArgs
```

Build and start it:

```bash
lake build my_server
./.lake/build/bin/my_server
```

To use Leant from a separate Lake project, add it as a Git dependency in your project's `lakefile.lean` (with the same `leanprover/lean4:v4.36.0` in `lean-toolchain`):

```lean
require leant from git
  "https://github.com/goodyanki/leant.git" @ "main"
```

---

## Core Usage Examples

### 1. Compile-Time Typed Routes & Refined Binding

```lean
import Leant

open Leant Leant.Binding

def userPostRoute := route! / "users" / (id : Nat) / "posts" / (slug : String)

def app : App := Leant.default
  |>.getTyped userPostRoute (fun c (id : Nat) (slug : String) =>
    c.jsonRaw s!"\{\"user\":{id},\"slug\":\"{slug}\"}")
  |>.getTyped (route! / "items" / (itemId : PositiveNat)) (fun c itemId => do
    -- `itemId.pos : itemId.val > 0` is guaranteed at compile time
    c.text s!"item-{itemId.val}")
```

### 2. Formally Verified ORM, Tenant RLS & Scope-Checked JOINs

```lean
import Leant

open Leant.Data

leant_tenant_table Orders "orders" (tenant_id : ScalarType.text) where
  | id        : SqlType.int  [pk, auto]
  | tenant_id : SqlType.text
  | code      : SqlType.int
  | title     : SqlType.text

leant_tenant_table Invoices "invoices" (tenant_id : ScalarType.text) where
  | id        : SqlType.int  [pk, auto]
  | tenant_id : SqlType.text
  | code      : SqlType.int
  | amount    : SqlType.int

def queryTenantOrders (pool : Pool SqliteConn) (tenantId : String) : IO (Array (Array SqlValue)) := do
  -- Unscoped queries on tenant tables fail to compile!
  let q := SelectQuery.fromTable Orders.table
    |>.filter (Orders.code ==. 100)
    |>.forTenant tenantId
  pool.select q

def queryTenantLeftJoin (pool : Pool SqliteConn) (tenantId : String) : IO (Array (Array SqlValue)) := do
  -- `forBothTenants` scopes the left table in WHERE and the right table in ON,
  -- blocking cross-tenant matches while retaining legitimate unmatched left rows.
  let j := JoinQuery.left Orders.table Invoices.table Orders.code Invoices.code
    |>.forBothTenants tenantId
  pool.selectJoin j
```

Switching to PostgreSQL only changes pool construction:

```lean
let pgPool ← Pool.createPostgres "postgres://user:pass@127.0.0.1:5432/mydb" { maxSize := 8 }
```

### 3. Authentication, Proof-Carrying Authorization & Consistent Reads

```lean
import Leant

open Leant Leant.Authz Leant.Security.Session

def policy : Policy := {
  roleRules    := [("admin", .read, "doc"), ("admin", .delete, "doc")]
  ownerActions := [.read, .update, .delete]
  forbidRules  := [("suspended", .delete, "doc")]
}

-- Only callable with an `Authorized` proof token produced by `requires` / `guard`
def deleteVerified (p : Principal) (r : Resource)
    (_auth : Authorized policy p .delete r) : IO Unit :=
  pure ()

def secureApp (cfg : SessionConfig) : App :=
  Leant.default
    |>.delete "/docs/:id" (authenticate cfg fun ac => do
      let res : Resource := { kind := "doc", owner := ac.principal.id, tenant := ac.principal.tenant }
      requires policy ac.principal .delete on res with auth => do
        deleteVerified ac.principal res auth
        ac.ctx.status Status.noContent)
```

### 4. In-Memory HTTP Testing (No Socket Needed)

```lean
import Leant

open Leant

def testPing : IO Unit := do
  let app := Leant.new |>.get "/ping" (fun c => c.text "pong")
  let resp ← Testing.get app "/ping"
  assert! resp.status == Status.ok
  assert! resp.bodyText == "pong"
```

---

## Running the Built-in Examples

| Example | What It Demonstrates | Build & Run |
| --- | --- | --- |
| [`examples/hello`](examples/hello/Hello.lean) | Minimal server, route groups, `:param` parsing, middleware | `lake build hello && ./.lake/build/bin/hello` |
| [`examples/todo`](examples/todo/Todo.lean) | SQLite-backed CRUD API, refined `NonEmptyBounded 120`, transactions | `lake build todo && TODO_DB_PATH=/tmp/todo.db ./.lake/build/bin/todo` |
| [`examples/saas`](examples/saas/Saas.lean) | Multi-tenant SaaS API, wall-clock signed sessions, RBAC/ownership guards, list/detail policy consistency, RLS | `lake build saas && SAAS_DB_PATH=/tmp/saas.db SAAS_SECRET=my-secret ./.lake/build/bin/saas` |

Quick walkthrough with the **SaaS** example (`examples/saas`):

```bash
# 1. Start the SaaS server
lake build saas
SAAS_SECRET="dev-secret" ./.lake/build/bin/saas

# 2. Log in as demo user "alice" (admin in tenant-a) to receive a signed Bearer token + HttpOnly cookie
TOKEN=$(curl -sS -X POST http://127.0.0.1:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{"user":"alice"}' | jq -r .token)

# 3. Create and list tenant-scoped documents
curl -sS -X POST http://127.0.0.1:8080/api/v1/docs \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Security Policy","content":"Verified by Lean 4"}'

curl -sS http://127.0.0.1:8080/api/v1/docs \
  -H "Authorization: Bearer $TOKEN"
```

---

## Testing & Verification

### 1. Core Suite (Unit, Formal Proofs, Negative Compile, SQLite, Security, HTTP)

```bash
lake test
```

This also compiles [`LeantTest/NegativeCompile.lean`](LeantTest/NegativeCompile.lean), which enforces 12 compile-time rejection tests (unscoped tenant queries, forged constructors, half-scoped JOINs, bypassed `Authorized` proofs).

### 2. Live PostgreSQL 16 Integration Tests

```bash
LEANT_TEST_PG_URL="postgres://leant:leant@127.0.0.1:5432/leant_test" \
LEANT_REQUIRE_PG=1 \
lake test
```

Covers PostgreSQL `BEGIN`/`COMMIT`, rollback-on-error, `BIGSERIAL` + `INSERT ... RETURNING`, `NULL`/`BOOLEAN` roundtrips, versioned migrations (`migrateUp`/`rollbackLast`), and two-tenant overlapping-key `INNER`/`LEFT JOIN` isolation.

### 3. SQLAlchemy + Hypothesis ORM Conformance Tests

```bash
python3 -m venv .venv-orm
.venv-orm/bin/pip install -r tests/orm/requirements.txt
lake build orm_insert_probe
LEANT_TEST_PG_URL="postgres://leant:leant@127.0.0.1:5432/leant_test" \
  .venv-orm/bin/python -m pytest -q tests/orm
```

### 4. Verify Zero `sorry` / `partial` / `unsafe` in Core Library

```bash
grep -rnE '\b(sorry|partial|unsafe)\b' Leant.lean Leant/ || echo "Clean: 0 matches"
```

---

## Performance (Leant vs Gin)

Measured on Linux `x86_64` (2 vCPU, `wrk -t2`, WAL SQLite 4-connection pool) against Go Gin `v1.12.0` (`gin.ReleaseMode`, `mattn/go-sqlite3`):

| Endpoint | Leant RPS | Gin RPS | Leant / Gin | Leant p99 vs Gin p99 |
| --- | ---: | ---: | ---: | --- |
| `/plaintext` | 49.5k – 56.8k | 31.5k – 43.4k | **121% – 158%** | 1.38–27.05 ms vs 5.96–37.52 ms |
| `/json` | 43.0k – 55.9k | 31.5k – 39.2k | **132% – 143%** | 2.00–19.60 ms vs 6.69–52.69 ms |
| `/db` (SQLite) | 18.3k – 22.0k | 16.0k – 18.2k | **106% – 121%** | 2.66–58.16 ms vs 18.90–112.47 ms |
| `/authz/:id` (HMAC + RBAC + RLS) | 12.2k – 13.9k | 8.5k – 14.4k | **94% – 143%** | 4.09–92.53 ms vs 24.96–194.01 ms |

Full methodology, per-concurrency breakdown (`c=16..512`), and raw CSV data are in [docs/benchmarks/BENCHMARKS.md](docs/benchmarks/BENCHMARKS.md).

---

## Architecture & Project Layout

```text
.
├── Leant.lean                  # Top-level library re-exports
├── Leant/
│   ├── Core/                   # Request, Response, Headers, Cookies, Context, Errors, SSE
│   ├── Router/                 # Total segment-trie router, typed route! DSL, 8 routing proofs
│   ├── Binding/                # Proof-carrying refined domain types (Email, PositiveNat, ...)
│   ├── Middleware/             # Logger, recovery, CORS, requestId, bodyLimit, timeout, static
│   ├── Transport/              # Pluggable HTTP backend interface + RustHyper FFI binding
│   ├── Data/                   # Schema, Macros, Expr GADT, Query, Join, Pool, Migration, SQLite/PG, 20 proofs
│   ├── Authz/                  # Policy engine, Authorized tokens, requires macro, filterAuthorized, 11 proofs
│   ├── Security/               # Crypto FFI, wall-clock Session, Argon2id Password, CSRF, RateLimit
│   ├── Testing/                # Zero-socket in-memory HTTP test client
│   └── App/                    # Gin-style App builder and dispatch loop
├── transport/
│   ├── rust-http/              # Rust tokio + hyper HTTP/1.1, crypto, Argon2id, PostgreSQL client
│   └── c/bridge.c              # Thin C ABI bridge between Lean 4 runtime and Rust staticlib
├── data/c/sqlite_bridge.c      # SQLite3 C FFI shim
├── examples/                   # hello, todo, and multi-tenant saas applications
├── LeantTest/                  # Lean test runner, negative compilation suite, ORM probe
├── tests/orm/                  # SQLAlchemy + Hypothesis differential conformance tests
└── docs/                       # Security proofs, ADRs, and benchmark reports
```

---

## Documentation

- [Verified Guarantees, Raw SQL Trust Boundary & TCB (40 Theorems)](docs/SECURITY_PROOFS.md)
- [ADR-001: Rust Hyper HTTP Transport](docs/adr/001-rust-hyper-transport.md)
- [ADR-002: Formally Verified ORM Architecture](docs/adr/002-verified-orm-design.md)
- [Benchmarks: Leant vs Gin](docs/benchmarks/BENCHMARKS.md)
- [HTTP Transport Evaluation](docs/benchmarks/transport-comparison.md)
