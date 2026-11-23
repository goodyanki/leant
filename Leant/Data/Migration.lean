import Leant.Data.Schema
import Leant.Data.Pool

namespace Leant.Data.Migration

open Leant.Data

/-- Structured DDL operation emitted by schema diffing or explicit migrations. -/
inductive MigrationOp where
  | createTable (schema : Schema)
  | dropTable (tableName : SqlIdent)
  | addColumn (tableName : SqlIdent) (col : ColDef)

namespace MigrationOp

/-- Renders a `MigrationOp` into deterministic SQL DDL. -/
def toSql : MigrationOp → String
  | .createTable s => s.createTableSql
  | .dropTable name => "DROP TABLE IF EXISTS " ++ name.val
  | .addColumn tbl col => "ALTER TABLE " ++ tbl.val ++ " ADD COLUMN " ++ col.ddlColumn

end MigrationOp

/-- Computes additive schema migrations (`ALTER TABLE ... ADD COLUMN`) from `oldSchema` to `newSchema`. -/
def diffSchema (oldSchema newSchema : Schema) : List MigrationOp :=
  let oldNames := oldSchema.cols.map fun c => c.name.val
  let added := newSchema.cols.filter fun c => !oldNames.contains c.name.val
  added.map fun col => .addColumn newSchema.tableName col

/-- Machine-checked theorem: diffing a schema against itself always yields zero migration ops. -/
theorem diffSchema_self_empty (s : Schema) :
    diffSchema s s = [] := by
  simp only [diffSchema, List.map_eq_nil_iff, List.filter_eq_nil_iff]
  intro c hc
  simp only [Bool.not_eq_true']
  rw [Bool.eq_false_iff]
  intro hfalse
  have hmem : c.name.val ∈ s.cols.map (fun x => x.name.val) :=
    List.mem_map_of_mem hc
  have hcont : (s.cols.map fun x => x.name.val).contains c.name.val = true :=
    List.contains_iff_mem.mpr hmem
  exact hfalse hcont

/-- A versioned database migration with explicit `up` and `down` DDL steps. -/
structure Migration where
  version : Nat
  name : String
  up : List MigrationOp
  down : List MigrationOp

private def ensureVersionTable {δ : Type} [Driver δ] (conn : δ) : IO Unit :=
  Driver.exec conn {
    sql := "CREATE TABLE IF NOT EXISTS _leant_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL)"
    params := #[]
  }

/-- Returns all currently applied migration version numbers in ascending order. -/
def appliedVersions {δ : Type} [Driver δ] (pool : Pool δ) : IO (Array Nat) :=
  pool.withConn fun conn => do
    ensureVersionTable conn
    let rows ← Driver.query conn {
      sql := "SELECT version FROM _leant_migrations ORDER BY version ASC"
      params := #[]
    }
    pure <| rows.foldl (init := #[]) fun acc row =>
      match row[0]? with
      | some (SqlValue.int v) => if v >= 0 then acc.push v.toNat else acc
      | _ => acc

/-- Applies all pending migrations whose `version` has not yet been recorded.
    Each migration runs atomically inside a transaction. Returns newly applied version numbers. -/
def migrateUp {δ : Type} [Driver δ] (pool : Pool δ) (migrations : List Migration) : IO (Array Nat) := do
  let applied ← appliedVersions pool
  let mut ran : Array Nat := #[]
  for m in migrations do
    if !applied.contains m.version then
      pool.withTransaction fun conn => do
        ensureVersionTable conn
        for op in m.up do
          Driver.exec conn { sql := op.toSql, params := #[] }
        Driver.exec conn {
          sql := "INSERT INTO _leant_migrations (version, name) VALUES (?, ?)"
          params := #[.int m.version, .text m.name]
        }
      ran := ran.push m.version
  pure ran

/-- Rolls back the most recently applied migration matching `migrations`.
    Returns `some version` if rolled back, or `none` if no applied migrations exist. -/
def rollbackLast {δ : Type} [Driver δ] (pool : Pool δ) (migrations : List Migration) : IO (Option Nat) := do
  let applied ← appliedVersions pool
  match applied.back? with
  | none => pure none
  | some lastVer =>
    match migrations.find? (fun m => m.version == lastVer) with
    | none => throw (IO.userError s!"migration definition for version {lastVer} not found")
    | some m =>
      pool.withTransaction fun conn => do
        for op in m.down do
          Driver.exec conn { sql := op.toSql, params := #[] }
        Driver.exec conn {
          sql := "DELETE FROM _leant_migrations WHERE version = ?"
          params := #[.int m.version]
        }
      pure (some m.version)

end Leant.Data.Migration
