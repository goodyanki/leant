namespace Leant.Data

/-- Typed SQL bind parameter (user values only travel as bound parameters, never raw SQL text). -/
inductive SqlValue where
  | null
  | int (v : Int)
  | text (v : String)
  | bool (v : Bool)
  | blob (v : ByteArray)
  deriving BEq, Inhabited

/-- Parameterized SQL query produced by the typed query AST renderer (M3). -/
structure RenderedQuery where
  sql : String
  params : Array SqlValue := #[]
  deriving BEq, Inhabited

/-- Abstract database driver typeclass to be implemented by SQLite / Postgres backends in M3. -/
class Driver (δ : Type) where
  exec : δ → RenderedQuery → IO Unit
  query : δ → RenderedQuery → IO (Array (Array SqlValue))

end Leant.Data
