import Leant.Data.Basic

namespace Leant.Data

private opaque SqliteConnImpl : NonemptyType.{0}

/-- Managed SQLite3 connection handle (automatically closed by Lean runtime finalizer). -/
def SqliteConn : Type := SqliteConnImpl.type

instance : Nonempty SqliteConn := SqliteConnImpl.property

namespace SqliteConn

/-- Opens (or creates) a SQLite database at `path` (supports `":memory:"`).
    Configures `PRAGMA foreign_keys = ON`, `busy_timeout = 5000ms`, and WAL mode for file DBs. -/
@[extern "leant_sqlite_open"]
opaque openPath (path : @& String) : IO SqliteConn

@[extern "leant_sqlite_exec"]
private opaque execRaw (conn : @& SqliteConn) (sql : @& String) (params : @& Array SqlValue) : IO Unit

@[extern "leant_sqlite_query"]
private opaque queryRaw (conn : @& SqliteConn) (sql : @& String) (params : @& Array SqlValue) :
    IO (Array (Array SqlValue))

@[extern "leant_sqlite_last_insert_rowid"]
opaque lastInsertRowId (conn : @& SqliteConn) : IO Int

/-- Executes a parameterized statement returning no rows. -/
def exec (conn : SqliteConn) (q : RenderedQuery) : IO Unit :=
  execRaw conn q.sql q.params

/-- Executes a parameterized query returning all result rows. -/
def query (conn : SqliteConn) (q : RenderedQuery) : IO (Array (Array SqlValue)) :=
  queryRaw conn q.sql q.params

/-- Executes a DDL statement (e.g., `Schema.createTableSql`). -/
def execDdl (conn : SqliteConn) (ddlSql : String) : IO Unit :=
  execRaw conn ddlSql #[]

end SqliteConn

instance : Driver SqliteConn where
  exec := SqliteConn.exec
  query := SqliteConn.query
  lastInsertRowId := SqliteConn.lastInsertRowId

end Leant.Data
