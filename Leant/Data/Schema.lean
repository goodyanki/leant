import Leant.Data.Basic

namespace Leant.Data

/-- Metadata for a single column in a database table schema. -/
structure ColDef where
  name : SqlIdent
  ty : SqlType
  isPrimaryKey : Bool := false
  isAutoIncrement : Bool := false
  isUnique : Bool := false
  checkSql : Option String := none

namespace ColDef

/-- Renders a column definition for `CREATE TABLE` DDL. -/
def ddlColumn (c : ColDef) : String :=
  let base := c.name.val ++ " " ++ c.ty.ddlType
  let base := if c.isPrimaryKey then
    if c.isAutoIncrement then base ++ " PRIMARY KEY AUTOINCREMENT"
    else base ++ " PRIMARY KEY"
  else base
  let base := if c.isUnique && !c.isPrimaryKey then base ++ " UNIQUE" else base
  match c.checkSql with
  | some chk => base ++ " CHECK (" ++ chk ++ ")"
  | none => base

end ColDef

/-- Pure first-class database table schema. -/
structure Schema where
  tableName : SqlIdent
  cols : List ColDef

namespace Schema

/-- Generates a `CREATE TABLE IF NOT EXISTS` DDL statement from `Schema`. -/
def createTableSql (s : Schema) : String :=
  let colDdls := s.cols.map ColDef.ddlColumn
  "CREATE TABLE IF NOT EXISTS " ++ s.tableName.val ++
    " (" ++ String.intercalate ", " colDdls ++ ")"

/-- Comma-separated projection list of all column names in schema order. -/
def allColumnsSql (s : Schema) : String :=
  joinSep ", " (s.cols.map fun c => c.name.val)

end Schema

/-- Proof-carrying reference to a column of exact type `t` inside schema `s`.
    Prevents cross-table column misuse and column/type mismatches at compile time. -/
structure ColRef (s : Schema) (t : SqlType) where
  index : Nat
  col : ColDef
  mem : s.cols[index]? = some col
  tyEq : col.ty = t

namespace ColRef

/-- Validated SQL identifier name of the referenced column. -/
def ident {s : Schema} {t : SqlType} (c : ColRef s t) : SqlIdent :=
  c.col.name

end ColRef

/-- Multi-tenancy isolation mode for a table. -/
inductive TenantMode where
  | global
  | tenantScoped (ty : ScalarType)
  deriving Repr, DecidableEq, Inhabited

/-- Typed table descriptor bundling `Schema` and (for tenant-scoped tables) a verified `tenantCol`. -/
structure Table (mode : TenantMode) where
  schema : Schema
  tenantCol : match mode with
    | .global          => Unit
    | .tenantScoped ty => ColRef schema (.scalar ty)

/-- Denotational model of a database row for schema `s`, mapping every `ColRef s t` to a value of `t.denote`. -/
structure RowEnv (s : Schema) where
  get : {t : SqlType} → ColRef s t → t.denote

end Leant.Data
