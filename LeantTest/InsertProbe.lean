import Leant

open Leant.Data

leant_table GeneratedKeys "leant_generated" where
  | item_key : SqlType.int [pk, auto]
  | marker : SqlType.text

leant_table ManualKeys "leant_manual" where
  | item_key : SqlType.int [pk]
  | marker : SqlType.text

leant_table NoIntKey "leant_no_int_key" where
  | marker : SqlType.text [pk]

/-- Run each insert in a committed transaction on the same physical connection.
    The conformance test observes the committed rows from a separate connection. -/
private def runInserts {δ : Type} [Driver δ] (pool : Pool δ) (operations : List String) : IO Unit := do
  pool.migrateTable GeneratedKeys.table
  pool.migrateTable ManualKeys.table
  pool.migrateTable NoIntKey.table
  for (op, index) in operations.zipIdx do
    let marker := toString index
    let key ← pool.withTransaction fun conn => do
      match op with
      | "auto" =>
        Pool.insertOn conn (InsertQuery.into GeneratedKeys.table |>.set GeneratedKeys.marker marker)
      | "text" =>
        Pool.insertOn conn (InsertQuery.into NoIntKey.table |>.set NoIntKey.marker marker)
      | _ =>
        let some id := op.toInt? | throw (IO.userError "expected an integer key")
        Pool.insertOn conn (InsertQuery.into ManualKeys.table
          |>.set ManualKeys.item_key id |>.set ManualKeys.marker marker)
    IO.println key

def main (args : List String) : IO Unit := do
  let some target ← IO.getEnv "LEANT_PROBE_DATABASE" | throw (IO.userError "missing probe database")
  match args with
  | "sqlite" :: ops => runInserts (← Pool.createSqlite target { maxSize := 1 }) ops
  | "postgres" :: ops => runInserts (← Pool.createPostgres target { maxSize := 1 }) ops
  | _ => throw (IO.userError "expected sqlite or postgres")
