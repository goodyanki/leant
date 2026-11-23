# ADR-002: Formally Verified ORM Architecture (`Leant.Data`)

- **Status**: Accepted
- **Date**: 2026-11-22

## Context

Conventional ORMs rely on runtime discipline and testing to prevent SQL injection, column/type mismatches, and cross-tenant data leaks. Leant aims to enforce these guarantees statically via Lean 4's type system and machine-checked proofs, without requiring application developers to write proofs manually.

## Trusted Computing Base (TCB)

- **Inside TCB (tested, not proved)**: `libsqlite3` / `libpq` C libraries, database engine query execution, OS storage, and the minimal C FFI binding shim.
- **Formally verified in Lean 4 (zero `sorry`, `partial`, or `unsafe`)**:
  1. SQL identifier validity (`SqlIdent`).
  2. Type-safe query AST (`Expr`, `SelectQuery`, `InsertQuery`, `UpdateQuery`, `DeleteQuery`).
  3. SQL injection non-interference and placeholder arity soundness.
  4. Semantic row-level tenant isolation (RLS) across `SELECT`, `UPDATE`, and `DELETE`.

## Key Design Decisions

1. **Deeply Embedded Typed Schema & Expression GADT**:
   - SQL types are represented as an inductive universe (`SqlType`: `int`, `text`, `bool`, `blob`, `nullable t`) denoted into Lean types via `SqlType.denote`.
   - Column references (`ColRef s t`) carry proofs of schema membership and exact type equality.
   - Expressions (`Expr s t`) form a GADT supporting both a total denotational evaluator (`Expr.eval`) and a total parameterized SQL renderer (`Expr.render`).
2. **SQL Injection Non-Interference**:
   - Rather than brittle string-pattern checks, we prove value non-interference: replacing any runtime parameter values in an expression or query produces the exact same SQL template string, and the number of `?` bind placeholders always equals `params.size`.
3. **Compile-Time Enforced Semantic RLS**:
   - Tables carry a `TenantMode` (`global` vs `tenantScoped ty`).
   - Queries on `tenantScoped` tables are type-state indexed by `scoped : Bool`; database execution APIs only accept `scoped = true`, which is constructed exclusively via `.forTenant tid` (conjoining `tenant_col = ?` at the top level of the `WHERE` predicate).
   - We prove semantically via `Expr.eval` that regardless of arbitrary `OR`/`NOT`/tautologies in user filters, no row belonging to a different tenant can satisfy a scoped query.
4. **Refined Type Boundary**:
   - Outbound writes unwrap validated refined types (`NonEmptyBounded`, `Email`, etc.).
   - Inbound reads treat external database storage as untrusted and re-validate into `Except DbError α` rather than forging proofs.
5. **SQLite FFI & Connection Pool**:
   - A thin C shim (`data/c/sqlite_bridge.c`) links system `libsqlite3` directly with prepared statements, WAL mode, foreign keys, and busy timeouts.
   - `ConnectionPool` uses `Std.Mutex` + `Std.Condvar` for bounded concurrent access, acquire timeouts, and `withTransaction` automatic rollback on failure.
