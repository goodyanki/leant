# Verified Guarantees & Trusted Computing Base (TCB)

Leant separates security-critical logic into pure, total Lean 4 modules verified with **zero `sorry`, zero `partial`, and zero `unsafe`**, while clearly bounding external systems inside the Trusted Computing Base.

## Trusted Computing Base (TCB) & Raw SQL Trust Boundary

The following components are verified through automated integration suites (including live SQLite and PostgreSQL 16 tests) rather than formally proved inside Lean:

- Lean 4 kernel, compiler, and runtime
- Rust `tokio` + `hyper` HTTP/1.1 transport (`transport/rust-http`) and C ABI shim (`transport/c/bridge.c`)
- Pure-Rust cryptographic primitives (`hmac`, `sha2`, `subtle`, `getrandom`, `argon2`)
- SQLite C library (`libsqlite3`), SQLite FFI shim (`data/c/sqlite_bridge.c`), and pure-Rust PostgreSQL wire client (`postgres`)
- Operating system, system wall clock (`Std.Time.Timestamp.now`), kernel networking, and storage

### Separate Trust Boundary of Raw SQL (`Driver.exec` / `Driver.query`)

`Leant.Data.Driver` exposes low-level `Driver.exec` and `Driver.query` primitives for schema DDL, migrations, and driver internals. Calling `Driver.exec` or `Driver.query` directly with a raw `RenderedQuery` sits **outside** the compile-time tenant-scoping boundary and bypasses `ExecutableScope` and `ScopeInvariant`.

Application code MUST execute queries exclusively through the verified, scope-checked `Pool` APIs:
- `Pool.select` / `Pool.selectOn` / `Pool.selectModels` / `Pool.selectModelsOn`
- `Pool.selectJoin` / `Pool.selectJoinOn`
- `Pool.update` / `Pool.updateOn` / `Pool.delete` / `Pool.deleteOn`

All query ASTs (`SelectQuery`, `UpdateQuery`, `DeleteQuery`, `JoinQuery`) hide their constructors (`private mk ::`) and embed semantic tenant-isolation proofs (`ScopeInvariant`, `JoinLeftScopeInvariant`, `JoinRightScopeInvariant`) that are preserved across `.filter`, `.onFilter`, `.orderBy`, `.limit`, and `.offset`.

### Session Expiration Boundary

When `SessionConfig.ttlSeconds > 0`, `issueToken` reads wall-clock time (`systemClock` by default, injectable `Clock` for tests) and records `expSec = issuedAt + ttlSeconds`. The `authenticate` middleware reads the clock on every request and validates both Bearer tokens and session cookies via `verifyTokenWithConfig`:
- Valid strictly before expiry: `nowSec < expSec`
- Rejected with `401 Unauthorized` at and after expiry: `nowSec >= expSec`
- Non-expiring tokens (`expSec = 0`) are also rejected whenever `cfg.ttlSeconds > 0`.

## Machine-Checked Theorems (40 Total, Zero `sorry`)

### 1. Routing (`Leant/Router/Theorems.lean`) — 8 Theorems

| Theorem | Property Proved |
| --- | --- |
| `lookup_empty_notFound` | An empty router always returns `404 Not Found`. |
| `static_precedes_param_first` / `_second` | Static routes strictly beat `:param` routes regardless of registration order. |
| `param_precedes_wildcard_first` / `_second` | `:param` routes strictly beat `*wildcard` routes regardless of registration order. |
| `lookupMethod_insert_render` | Roundtrip invertibility: looking up any rendered route recovers the exact handler and extracted parameters. |
| `lookupMethod_insert_diff_method` & `pathExists_insert_render` | Matching a registered path with an unregistered HTTP method yields `405 Method Not Allowed`. |

### 2. Typed ORM, JOINs, Migrations & Row-Level Security (`Leant/Data/Theorems.lean`, `Leant/Data/Join.lean`, `Leant/Data/Migration.lean`) — 20 Theorems

| Theorem | Property Proved |
| --- | --- |
| `sqlIdent_no_question_mark` & `sqlIdent_no_injection_chars` | Validated SQL identifiers contain no `?`, `'`, `"`, or `;`. |
| `expr_render_value_invariant` | SQL injection non-interference on expressions: replacing runtime values leaves rendered SQL bit-for-bit identical. |
| `select_render_value_invariant` | SQL injection non-interference on full `SELECT` queries (including `WHERE`, `LIKE`, `LIMIT`, `OFFSET`). |
| `expr_render_arity_sound` | Rendered expression `?` placeholder count equals bound parameter count. |
| `select_render_arity_sound` & `insert_render_arity_sound` | Rendered `SELECT` and `INSERT` statements have exact `?` / parameter arity parity. |
| `joinCol_no_question_mark`, `joinPred_render_arity_sound`, `joinQuery_render_arity_sound` | Qualified `JOIN` columns contain no `?`, and full `JOIN` queries (across `ON`, `WHERE`, `LIMIT`) preserve exact placeholder arity. |
| `diffSchema_self_empty` | Diffing any schema against itself produces an empty migration list. |
| `rls_select_soundness` / `rls_update_soundness` / `rls_delete_soundness` | Semantic RLS across `SELECT`, `UPDATE`, and `DELETE`: regardless of arbitrary `OR`/`NOT`/tautologies in user `WHERE` clauses, no cross-tenant row can satisfy a tenant-scoped query. |
| `rls_select_scoped_invariant` / `rls_update_scoped_invariant` / `rls_delete_scoped_invariant` | By-construction RLS: every `isScoped = true` query AST preserves tenant isolation across all builder combinators. |
| `rls_join_left_soundness` / `rls_join_right_soundness` | By-construction two-table `JOIN` RLS: left-scoped joins isolate left rows (matched and unmatched) and right-scoped joins isolate matched right rows in `ON`. |
| `rls_join_left_preserves_unmatched` | Scoping a `LEFT JOIN` via `forBothTenants` places right-side scoping in `ON`, preserving legitimate unmatched left rows for the active tenant. |

### 3. Authorization & Multi-Tenant Alignment (`Leant/Authz/Basic.lean`, `Leant/Authz/Theorems.lean`) — 11 Theorems

| Theorem | Property Proved |
| --- | --- |
| `tenant_isolation` | Cross-tenant access is unconditionally denied regardless of policy or roles. |
| `deny_overrides` | Any matching forbid rule overrides all RBAC and ownership grants. |
| `default_deny` | An empty policy denies every request. |
| `authorized_implies_same_tenant` | Every `Authorized pol p a r` proof token statically guarantees `r.tenant = p.tenant`. |
| `guard_sound` | Successful `guard` evaluation entails both `evaluate = .allow` and `r.tenant = p.tenant`. |
| `role_monotonicity` | Adding a `roleRule` never revokes an existing `.allow` decision. |
| `forbid_monotonicity` | Adding a `forbidRule` never converts `.deny` into `.allow`. |
| `role_grant_no_cross_tenant_escalation` | Granting arbitrary roles never escalates privileges across tenants. |
| `role_grant_no_forbid_bypass` | Granting additional roles never bypasses an existing forbid rule. |
| `rls_principal_alignment` | Database RLS (`forTenant p.tenant`) aligns with `Authorized` tenant isolation. |
| `filterAuthorized_sound` | Every item emitted by `filterAuthorized` satisfies the exact same `evaluate = .allow` and tenant-isolation guarantees as single-item `guard`/`requires`. |

### 4. Static File Path Safety (`Leant/Middleware/Static.lean`) — 1 Theorem

| Theorem | Property Proved |
| --- | --- |
| `safeRelativePath_no_traversal` | Every segment emitted by `safeRelativePath` is non-empty, distinct from `.` and `..`, and free of `\`, NUL, and `:`. |

## Type-Level Compile-Time Guarantees & Negative Compilation Tests

- **Compile-time route signatures (`Leant/Router/Dsl.lean`)**: `route! / "users" / (id : Nat)` fails to compile if the handler expects a mismatched parameter type.
- **Declarative table macros (`Leant/Data/Macro.lean`)**: `leant_table` and `leant_tenant_table` generate verified `Schema`, `Table`, and `ColRef` handles with automatic proof discharge.
- **Proof-carrying request binding (`Leant/Binding/Basic.lean`)**: Parsed `NonEmpty`, `Bounded n`, `NonEmptyBounded n`, `Email`, and `PositiveNat` values carry proofs of their invariants.
- **Compile-time RLS enforcement (`Leant/Data/Query.lean`, `Leant/Data/Join.lean`, `Leant/Data/Pool.lean`)**: Unscoped single-table queries, unscoped left/right `JOIN` inputs, and forged query constructors are statically rejected at compile time (verified by 12 automated negative compilation tests in `LeantTest/NegativeCompile.lean`).
- **Proof-carrying handlers (`Leant/Authz/Guard.lean`)**: Guarded operations requiring `Authorized pol p a r` cannot be called without passing through `guard` / `requires`.
