import Leant.Data.Basic
import Leant.Data.Pool

namespace Leant.Data

/-- Translates `?` bind placeholders into PostgreSQL positional placeholders (`$1`, `$2`, ...).
    Because `Leant.Data` never interpolates user strings into SQL text, every `?` in a rendered
    query is guaranteed to be a genuine bind slot. -/
def toPostgresPlaceholders (sql : String) : String :=
  let rec go (chars : List Char) (idx : Nat) (acc : String) : String :=
    match chars with
    | [] => acc
    | '?' :: rest => go rest (idx + 1) (acc ++ "$" ++ toString idx)
    | c :: rest => go rest idx (acc.push c)
  go sql.toList 1 ""

private opaque PgConnImpl : NonemptyType.{0}

/-- Managed PostgreSQL connection backed by a pure-Rust wire-protocol client. -/
def PgConn : Type := PgConnImpl.type

instance : Nonempty PgConn := PgConnImpl.property

namespace PgConn

/-- Connects to a PostgreSQL database using a standard libpq URI or key-value connection string
    (e.g. `"postgres://user:pass@127.0.0.1:5432/mydb"`). -/
@[extern "leant_c_pg_connect"]
opaque connect (connStr : @& String) : IO PgConn

@[extern "leant_c_pg_exec"]
private opaque execRaw (conn : @& PgConn) (sql : @& String) (params : @& Array SqlValue) : IO Unit

@[extern "leant_c_pg_query"]
private opaque queryRaw (conn : @& PgConn) (sql : @& String) (params : @& Array SqlValue) :
    IO (Array (Array SqlValue))

/-- Executes a parameterized statement, automatically translating `?` to `$1, $2, ...`. -/
def exec (conn : PgConn) (q : RenderedQuery) : IO Unit :=
  execRaw conn (toPostgresPlaceholders q.sql) q.params

/-- Executes a parameterized query, automatically translating `?` to `$1, $2, ...`. -/
def query (conn : PgConn) (q : RenderedQuery) : IO (Array (Array SqlValue)) :=
  queryRaw conn (toPostgresPlaceholders q.sql) q.params

/-- Retrieves the last generated sequence ID (`SELECT LASTVAL()`). -/
def lastInsertRowId (conn : PgConn) : IO Int := do
  let rows ← queryRaw conn "SELECT LASTVAL()" #[]
  match rows[0]? with
  | some row =>
    match row[0]? with
    | some (SqlValue.int id) => pure id
    | _ => pure 0
  | none => pure 0

end PgConn

instance : Driver PgConn where
  exec := PgConn.exec
  query := PgConn.query
  lastInsertRowId := PgConn.lastInsertRowId

namespace Pool

/-- Creates a fixed-size PostgreSQL connection pool. -/
def createPostgres (connStr : String) (cfg : PoolConfig := {}) : IO (Pool PgConn) :=
  create (PgConn.connect connStr) cfg

end Pool

end Leant.Data
