import Leant.Data.Pool

namespace Leant.Data

/-- Extracts and decodes the cell corresponding to `col : ColRef s t` from a raw database row. -/
def rowGet {s : Schema} {t : SqlType} (row : Array SqlValue) (col : ColRef s t) :
    Except DbError t.denote :=
  match row[col.index]? with
  | none => .error (.decode s!"missing column '{col.ident.val}' at index {col.index}")
  | some raw =>
    match SqlValue.toSqlType t raw with
    | .ok v => .ok v
    | .error e => .error (.decode s!"column '{col.ident.val}': {e}")

/-- Extracts a column value and re-validates it into a refined Lean type at the DB trust boundary. -/
def rowGetRefined {s : Schema} {t : SqlType} {α : Type}
    (row : Array SqlValue) (col : ColRef s t) (validate : t.denote → Except String α) :
    Except DbError α := do
  let v ← rowGet row col
  match validate v with
  | .ok refined => .ok refined
  | .error e => .error (.decode s!"column '{col.ident.val}' validation failed: {e}")

/-- Decodes an array of raw SQL rows into typed models using `decodeRow`. -/
def decodeRows {α : Type} (rows : Array (Array SqlValue))
    (decodeRow : Array SqlValue → Except DbError α) : Except DbError (Array α) :=
  rows.foldl (init := .ok #[]) fun acc row => do
    let arr ← acc
    let item ← decodeRow row
    pure (arr.push item)

/-- Typeclass associating a Lean domain struct with its verified `Table` and row decoder. -/
class Model (α : Type) where
  mode : TenantMode
  table : Table mode
  fromRow : Array SqlValue → Except DbError α

namespace Pool

/-- Executes a scope-checked `SELECT` and decodes all rows into `Array α` via `Model.fromRow`. -/
def selectModels {δ α : Type} [Driver δ] [m : Model α] {isScoped : Bool}
    (pool : Pool δ) (q : SelectQuery m.table isScoped)
    (hscope : ExecutableScope m.mode isScoped := by trivial) :
    IO (Except DbError (Array α)) := do
  let rows ← pool.select q hscope
  pure (decodeRows rows m.fromRow)

/-- Executes a scope-checked `SELECT` on a borrowed connection and decodes rows into `Array α`. -/
def selectModelsOn {δ α : Type} [Driver δ] [m : Model α] {isScoped : Bool}
    (conn : δ) (q : SelectQuery m.table isScoped)
    (hscope : ExecutableScope m.mode isScoped := by trivial) :
    IO (Except DbError (Array α)) := do
  let rows ← Pool.selectOn conn q hscope
  pure (decodeRows rows m.fromRow)

end Pool

end Leant.Data
