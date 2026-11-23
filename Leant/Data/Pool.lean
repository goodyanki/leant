import Std.Sync.Mutex
import Leant.Data.Query
import Leant.Data.Sqlite

namespace Leant.Data

/-- Fixed-size connection pool configuration. -/
structure PoolConfig where
  maxSize : Nat := 8
  acquireTimeoutMs : Nat := 5000
  deriving Repr, Inhabited

private structure PoolState (δ : Type) where
  idle : Array δ

/-- Thread-safe fixed-size connection pool backed by `Std.Mutex` and `Std.Condvar`. -/
structure Pool (δ : Type) where
  private state : Std.Mutex (PoolState δ)
  private available : Std.Condvar
  config : PoolConfig

namespace Pool

/-- Creates a fixed-size pool by invoking `connect` `cfg.maxSize` times (minimum 1). -/
def create {δ : Type} (connect : IO δ) (cfg : PoolConfig := {}) : IO (Pool δ) := do
  let count := if cfg.maxSize == 0 then 1 else cfg.maxSize
  let mut conns : Array δ := Array.mkEmpty count
  for _ in [0:count] do
    conns := conns.push (← connect)
  let state ← Std.Mutex.new ({ idle := conns } : PoolState δ)
  let available ← Std.Condvar.new
  pure { state, available, config := cfg }

/-- Convenience constructor opening a SQLite connection pool.
    Note: `":memory:"` automatically uses a single shared connection (`maxSize := 1`)
    so all queries observe the same in-memory database. -/
def createSqlite (path : String) (cfg : PoolConfig := {}) : IO (Pool SqliteConn) :=
  let effectiveCfg := if path == ":memory:" then { cfg with maxSize := 1 } else cfg
  create (SqliteConn.openPath path) effectiveCfg

private def acquire {δ : Type} (pool : Pool δ) : IO δ := do
  let deadline ← IO.monoMsNow
  let deadline := deadline + pool.config.acquireTimeoutMs
  let rec loop (fuel : Nat) : IO δ := do
    match fuel with
    | 0 => throw (IO.userError "connection pool acquire timeout")
    | fuel' + 1 =>
      let conn? ← pool.state.atomically do
        let st ← get
        match st.idle.back? with
        | some c =>
          set ({ idle := st.idle.pop } : PoolState δ)
          pure (some c)
        | none => pure none
      match conn? with
      | some c => pure c
      | none =>
        let now ← IO.monoMsNow
        if now >= deadline then
          throw (IO.userError "connection pool acquire timeout")
        IO.sleep 2
        loop fuel'
  -- Bound iterations by timeout window (2ms step) + margin so acquisition is total.
  loop (pool.config.acquireTimeoutMs + 10)

private def release {δ : Type} (pool : Pool δ) (conn : δ) : IO Unit := do
  pool.state.atomically do
    let st ← get
    set ({ idle := st.idle.push conn } : PoolState δ)
  pool.available.notifyOne

/-- Borrows a connection from the pool and guarantees return via `try ... finally`. -/
def withConn {δ α : Type} (pool : Pool δ) (action : δ → IO α) : IO α := do
  let conn ← pool.acquire
  try
    action conn
  finally
    pool.release conn

/-- Executes `action` inside an atomic database transaction (`BEGIN IMMEDIATE` / `COMMIT`).
    Automatically executes `ROLLBACK` if `action` throws an exception. -/
def withTransaction {δ α : Type} [Driver δ] (pool : Pool δ) (action : δ → IO α) : IO α :=
  pool.withConn fun conn => do
    Driver.exec conn { sql := "BEGIN IMMEDIATE", params := #[] }
    try
      let res ← action conn
      Driver.exec conn { sql := "COMMIT", params := #[] }
      pure res
    catch e =>
      try
        Driver.exec conn { sql := "ROLLBACK", params := #[] }
      catch _ =>
        pure ()
      throw e

/-! ### Compile-Time Scope-Checked Query Execution API -/

/-- Executes a `SELECT` query on a borrowed connection.
    For `.tenantScoped` tables, `ExecutableScope mode isScoped` statically requires `isScoped = true`
    (obtained via `SelectQuery.forTenant`), rejecting unscoped queries at compile time. -/
def selectOn {δ : Type} [Driver δ] {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (conn : δ) (q : SelectQuery tbl isScoped)
    (_hscope : ExecutableScope mode isScoped := by trivial) :
    IO (Array (Array SqlValue)) :=
  Driver.query conn q.render

/-- Executes a typed `INSERT` on a borrowed connection and returns `lastInsertRowId`. -/
def insertOn {δ : Type} [Driver δ] {mode : TenantMode} {tbl : Table mode}
    (conn : δ) (q : InsertQuery tbl) : IO Int := do
  Driver.exec conn q.render
  Driver.lastInsertRowId conn

/-- Executes a scope-checked `UPDATE` on a borrowed connection. -/
def updateOn {δ : Type} [Driver δ] {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (conn : δ) (q : UpdateQuery tbl isScoped)
    (_hscope : ExecutableScope mode isScoped := by trivial) : IO Unit :=
  Driver.exec conn q.render

/-- Executes a scope-checked `DELETE` on a borrowed connection. -/
def deleteOn {δ : Type} [Driver δ] {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (conn : δ) (q : DeleteQuery tbl isScoped)
    (_hscope : ExecutableScope mode isScoped := by trivial) : IO Unit :=
  Driver.exec conn q.render

/-- Executes a `SELECT` query using a pooled connection. -/
def select {δ : Type} [Driver δ] {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (pool : Pool δ) (q : SelectQuery tbl isScoped)
    (hscope : ExecutableScope mode isScoped := by trivial) :
    IO (Array (Array SqlValue)) :=
  pool.withConn fun conn => selectOn conn q hscope

/-- Executes an `INSERT` query using a pooled connection and returns `lastInsertRowId`. -/
def insert {δ : Type} [Driver δ] {mode : TenantMode} {tbl : Table mode}
    (pool : Pool δ) (q : InsertQuery tbl) : IO Int :=
  pool.withConn fun conn => insertOn conn q

/-- Executes a scope-checked `UPDATE` query using a pooled connection. -/
def update {δ : Type} [Driver δ] {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (pool : Pool δ) (q : UpdateQuery tbl isScoped)
    (hscope : ExecutableScope mode isScoped := by trivial) : IO Unit :=
  pool.withConn fun conn => updateOn conn q hscope

/-- Executes a scope-checked `DELETE` query using a pooled connection. -/
def delete {δ : Type} [Driver δ] {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (pool : Pool δ) (q : DeleteQuery tbl isScoped)
    (hscope : ExecutableScope mode isScoped := by trivial) : IO Unit :=
  pool.withConn fun conn => deleteOn conn q hscope

/-- Runs `CREATE TABLE IF NOT EXISTS` for a table's schema on the pool. -/
def migrateTable {δ : Type} [Driver δ] {mode : TenantMode}
    (pool : Pool δ) (tbl : Table mode) : IO Unit :=
  pool.withConn fun conn =>
    Driver.exec conn { sql := tbl.schema.createTableSql, params := #[] }

end Pool
end Leant.Data
