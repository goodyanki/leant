namespace Leant.Data

/-- Target SQL backend dialect for DDL and transaction syntax. -/
inductive SqlDialect where
  | sqlite
  | postgres
  deriving Repr, DecidableEq, Inhabited

/-- Non-null comparable SQL scalar types (immune to SQL tri-valued NULL equality pitfalls). -/
inductive ScalarType where
  | int
  | text
  | bool
  deriving Repr, DecidableEq, Inhabited

namespace ScalarType

/-- Maps a `ScalarType` to its corresponding Lean type. -/
@[reducible]
def denote : ScalarType → Type
  | .int  => Int
  | .text => String
  | .bool => Bool

/-- Dialect-specific SQL DDL type name for a `ScalarType`. -/
def sqlNameFor (d : SqlDialect) : ScalarType → String
  | .int  => match d with | .sqlite => "INTEGER" | .postgres => "BIGINT"
  | .text => "TEXT"
  | .bool => match d with | .sqlite => "INTEGER" | .postgres => "BOOLEAN"

/-- Default (SQLite) SQL DDL type name for a `ScalarType`. -/
def sqlName : ScalarType → String := sqlNameFor .sqlite

/-- Decidable equality on denoted scalar values. -/
def decEq : (t : ScalarType) → (a b : t.denote) → Decidable (a = b)
  | .int,  a, b => inferInstanceAs (Decidable (a = b))
  | .text, a, b => inferInstanceAs (Decidable (a = b))
  | .bool, a, b => inferInstanceAs (Decidable (a = b))

/-- Boolean equality on denoted scalar values. -/
def beq : (t : ScalarType) → t.denote → t.denote → Bool
  | .int,  a, b => a == b
  | .text, a, b => a == b
  | .bool, a, b => a == b

theorem eq_of_beq {t : ScalarType} {a b : t.denote} (h : t.beq a b = true) : a = b := by
  cases t <;> simpa [beq] using h

end ScalarType

/-- Universe of SQL column types supported by the typed ORM. -/
inductive SqlType where
  | scalar (s : ScalarType)
  | blob
  | nullable (s : ScalarType)
  deriving Repr, DecidableEq, Inhabited

namespace SqlType

abbrev int : SqlType := .scalar .int
abbrev text : SqlType := .scalar .text
abbrev bool : SqlType := .scalar .bool
abbrev nullableInt : SqlType := .nullable .int
abbrev nullableText : SqlType := .nullable .text
abbrev nullableBool : SqlType := .nullable .bool

/-- Maps a `SqlType` to its Lean host type. -/
@[reducible]
def denote : SqlType → Type
  | .scalar s   => s.denote
  | .blob       => ByteArray
  | .nullable s => Option s.denote

/-- Dialect-specific SQL DDL column type string (including `NOT NULL` for non-nullable types). -/
def ddlTypeFor (d : SqlDialect) : SqlType → String
  | .scalar s   => s.sqlNameFor d ++ " NOT NULL"
  | .blob       => match d with | .sqlite => "BLOB NOT NULL" | .postgres => "BYTEA NOT NULL"
  | .nullable s => s.sqlNameFor d

/-- Default (SQLite) SQL DDL column type string. -/
def ddlType : SqlType → String := ddlTypeFor .sqlite

end SqlType

/-- Typed SQL bind parameter (user values travel exclusively as bound parameters). -/
inductive SqlValue where
  | null
  | int (v : Int)
  | text (v : String)
  | bool (v : Bool)
  | blob (v : ByteArray)
  deriving BEq, Inhabited

namespace SqlValue

def ofScalar : (t : ScalarType) → t.denote → SqlValue
  | .int,  v => .int v
  | .text, v => .text v
  | .bool, v => .bool v

def ofSqlType : (t : SqlType) → t.denote → SqlValue
  | .scalar s,   v        => ofScalar s v
  | .blob,       v        => .blob v
  | .nullable _, none     => .null
  | .nullable s, some v   => ofScalar s v

def toScalar : (t : ScalarType) → SqlValue → Except String t.denote
  | .int,  .int v  => .ok v
  | .text, .text v => .ok v
  | .bool, .bool v => .ok v
  | .bool, .int v  => .ok (v != 0)
  | t,     _       => .error s!"SQL type mismatch decoding {repr t}"

def toSqlType : (t : SqlType) → SqlValue → Except String t.denote
  | .scalar s,   v     => toScalar s v
  | .blob,       .blob b => .ok b
  | .blob,       _     => .error "SQL type mismatch decoding BLOB"
  | .nullable _, .null => .ok none
  | .nullable s, v     => some <$> toScalar s v

end SqlValue

/-- Checks whether a character is allowed at the start of an SQL identifier (`[A-Za-z_]`). -/
def isIdentStart (c : Char) : Bool :=
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'

/-- Checks whether a character is allowed inside an SQL identifier (`[A-Za-z0-9_]`). -/
def isIdentChar (c : Char) : Bool :=
  isIdentStart c || (c >= '0' && c <= '9')

/-- Pure validator for safe unquoted SQL identifiers (`[A-Za-z_][A-Za-z0-9_]*`).
    Guarantees absence of quotes, semicolons, whitespace, and `?` bind placeholders. -/
def isValidSqlIdent (s : String) : Bool :=
  match s.toList with
  | [] => false
  | c :: rest => isIdentStart c && rest.all isIdentChar

/-- Proof-carrying valid SQL identifier (table or column name). -/
structure SqlIdent where
  val : String
  valid : isValidSqlIdent val = true

namespace SqlIdent

instance : BEq SqlIdent := ⟨fun a b => a.val == b.val⟩
instance : ToString SqlIdent := ⟨fun x => x.val⟩
instance : Repr SqlIdent := ⟨fun x p => Repr.reprPrec x.val p⟩

def ofString (s : String) : Except String SqlIdent :=
  if h : isValidSqlIdent s = true then
    .ok ⟨s, h⟩
  else
    .error s!"invalid SQL identifier: '{s}'"

end SqlIdent

/-- Joins a list of SQL fragments with `sep` via structural recursion (proof-friendly). -/
def joinSep (sep : String) : List String → String
  | [] => ""
  | [x] => x
  | x :: rest => x ++ sep ++ joinSep sep rest

/-- Parameterized SQL query emitted by the verified query renderer. -/
structure RenderedQuery where
  sql : String
  params : Array SqlValue := #[]
  deriving BEq, Inhabited

/-- Structured database layer error. -/
inductive DbError where
  | driver (msg : String)
  | decode (msg : String)
  | poolTimeout (msg : String := "connection pool acquire timeout")
  | notFound (msg : String := "record not found")
  deriving Repr, BEq, Inhabited

namespace DbError

def message : DbError → String
  | .driver m      => m
  | .decode m      => m
  | .poolTimeout m => m
  | .notFound m    => m

instance : ToString DbError := ⟨DbError.message⟩

end DbError

/-- Low-level database driver interface implemented by SQLite / PostgreSQL backends.
    **Trust Boundary**: Calling `Driver.exec` or `Driver.query` directly with raw `RenderedQuery`
    bypasses compile-time `ExecutableScope` and `ScopeInvariant` enforcement.
    Application code should always use the scope-checked `Pool.select`, `Pool.selectModels`,
    `Pool.selectJoin`, `Pool.update`, and `Pool.delete` APIs instead. -/
class Driver (δ : Type) where
  exec : δ → RenderedQuery → IO Unit
  query : δ → RenderedQuery → IO (Array (Array SqlValue))
  lastInsertRowId : δ → IO Int
  dialect : SqlDialect := .sqlite
  beginTransactionSql : String := "BEGIN"

end Leant.Data
