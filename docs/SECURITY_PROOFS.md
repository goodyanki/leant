# Verified Guarantees & Trusted Computing Base (TCB)

Leant separates security-critical logic into pure, total Lean 4 modules verified with **zero `sorry`, zero `partial`, and zero `unsafe`**, while clearly bounding external systems inside the Trusted Computing Base.

## Trusted Computing Base (TCB)

The following components are tested via automated integration suites rather than formally proved:

- Lean 4 kernel, compiler, and runtime
- Rust `tokio` + `hyper` HTTP/1.1 transport (`transport/rust-http`) and C ABI shim (`transport/c/bridge.c`)
- Pure-Rust cryptographic primitives (`hmac`, `sha2`, `subtle`, `getrandom`, `argon2`)
- SQLite C library (`libsqlite3`), SQLite FFI shim (`data/c/sqlite_bridge.c`), and pure-Rust PostgreSQL wire client (`postgres`)
- Operating system, kernel networking, and storage

## Machine-Checked Theorems (30 Total, Zero `sorry`)

### 1. Routing (`Leant/Router/Theorems.lean`) — 8 Theorems

| Theorem | Property Proved |
| --- | --- |
| `lookup_empty_notFound` | An empty router always returns `404 Not Found`. |
| `static_precedes_param_first` / `_second` | Static routes strictly beat `:param` routes regardless of registration order. |
| `param_precedes_wildcard_first` / `_second` | `:param` routes strictly beat `*wildcard` routes regardless of registration order. |
| `lookupMethod_insert_render` | Roundtrip invertibility: looking up any rendered route recovers the exact handler and extracted parameters. |
| `lookupMethod_insert_diff_method` & `pathExists_insert_render` | Matching a registered path with an unregistered HTTP method yields `405 Method Not Allowed`. |

### 2. Typed ORM, JOINs, Migrations & Row-Level Security (`Leant/Data/Theorems.lean`, `Leant/Data/Join.lean`, `Leant/Data/Migration.lean`) — 11 Theorems

| Theorem | Property Proved |
| --- | --- |
| `sqlIdent_no_question_mark` & `sqlIdent_no_injection_chars` | Validated SQL identifiers contain no `?`, `'`, `"`, or `;`. |
| `expr_render_value_invariant` | SQL injection non-interference on expressions: replacing runtime values leaves rendered SQL bit-for-bit identical. |
| `select_render_value_invariant` | SQL injection non-interference on full `SELECT` queries (including `WHERE`, `LIKE`, `LIMIT`, `OFFSET`). |
| `expr_render_arity_sound` | Rendered expression `?` placeholder count equals bound parameter count. |
| `select_render_arity_sound` & `insert_render_arity_sound` | Rendered `SELECT` and `INSERT` statements have exact `?` / parameter arity parity. |
| `joinCol_no_question_mark` & `joinPred_render_arity_sound` | Qualified `JOIN` columns contain no `?` and `JOIN` predicates preserve exact placeholder arity. |
| `diffSchema_self_empty` | Diffing any schema against itself produces an empty migration list. |
| `rls_select_soundness` / `rls_update_soundness` / `rls_delete_soundness` | Semantic RLS across `SELECT`, `UPDATE`, and `DELETE`: regardless of arbitrary `OR`/`NOT`/tautologies in user `WHERE` clauses, no cross-tenant row can satisfy a tenant-scoped query. |

### 3. Authorization & Multi-Tenant Alignment (`Leant/Authz/Basic.lean`, `Leant/Authz/Theorems.lean`) — 10 Theorems

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

### 4. Static File Path Safety (`Leant/Middleware/Static.lean`) — 1 Theorem

| Theorem | Property Proved |
| --- | --- |
| `safeRelativePath_no_traversal` | Every segment emitted by `safeRelativePath` is non-empty, distinct from `.` and `..`, and free of `\`, NUL, and `:`. |

## Type-Level Compile-Time Guarantees

- **Compile-time route signatures (`Leant/Router/Dsl.lean`)**: `route! / "users" / (id : Nat)` fails to compile if the handler expects a mismatched parameter type.
- **Declarative table macros (`Leant/Data/Macro.lean`)**: `leant_table` and `leant_tenant_table` generate verified `Schema`, `Table`, and `ColRef` handles with automatic proof discharge.
- **Proof-carrying request binding (`Leant/Binding/Basic.lean`)**: Parsed `NonEmpty`, `Bounded n`, `NonEmptyBounded n`, `Email`, and `PositiveNat` values carry proofs of their invariants.
- **Compile-time RLS enforcement (`Leant/Data/Query.lean`, `Leant/Data/Pool.lean`)**: Unscoped queries on `.tenantScoped` tables fail to compile unless scoped via `.forTenant` / `scopeSelect` / `scopeUpdate` / `scopeDelete`.
- **Proof-carrying handlers (`Leant/Authz/Guard.lean`)**: Guarded operations requiring `Authorized pol p a r` cannot be called without passing through `guard` / `requires`.
