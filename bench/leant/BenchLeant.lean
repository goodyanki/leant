import Lean.Data.Json
import Leant

open Leant
open Leant.Data
open Leant.Authz
open Leant.Security.Session

/-- JSON response payload for `/json`. -/
private structure Message where
  message : String

private instance : Lean.ToJson Message where
  toJson m := Lean.Json.mkObj [("message", Lean.Json.str m.message)]

leant_table BenchItems "bench_items" where
  | id    : SqlType.int  [pk, auto]
  | label : SqlType.text

leant_tenant_table BenchDocs "bench_docs" (tenant_id : ScalarType.text) where
  | id        : SqlType.int  [pk, auto]
  | tenant_id : SqlType.text
  | owner_id  : SqlType.text
  | title     : SqlType.text

private structure BenchItem where
  id : Int
  label : String

private instance : Lean.ToJson BenchItem where
  toJson x := Lean.Json.mkObj [("id", Lean.ToJson.toJson x.id), ("label", Lean.ToJson.toJson x.label)]

private instance : Model BenchItem where
  mode := .global
  table := BenchItems.table
  fromRow row := do
    let id ← rowGet row BenchItems.id
    let label ← rowGet row BenchItems.label
    pure { id, label }

private structure BenchDoc where
  id : Int
  tenantId : String
  ownerId : String
  title : String

private instance : Lean.ToJson BenchDoc where
  toJson d := Lean.Json.mkObj [
    ("id", Lean.ToJson.toJson d.id),
    ("tenant_id", Lean.ToJson.toJson d.tenantId),
    ("owner_id", Lean.ToJson.toJson d.ownerId),
    ("title", Lean.ToJson.toJson d.title)
  ]

private instance : Model BenchDoc where
  mode := .tenantScoped .text
  table := BenchDocs.table
  fromRow row := do
    let id ← rowGet row BenchDocs.id
    let tenantId ← rowGet row BenchDocs.tenant_id
    let ownerId ← rowGet row BenchDocs.owner_id
    let title ← rowGet row BenchDocs.title
    pure { id, tenantId, ownerId, title }

private def benchPolicy : Policy := {
  roleRules := [("admin", .read, "doc"), ("member", .read, "doc")]
  ownerActions := [.read, .update, .delete]
  forbidRules := [("suspended", .read, "doc")]
}

private def seedDatabase (pool : Pool SqliteConn) : IO Unit := do
  pool.migrateTable BenchItems.table
  pool.migrateTable BenchDocs.table
  let existing ← pool.select (SelectQuery.fromTable BenchItems.table |>.limit 1)
  if existing.isEmpty then
    pool.withTransaction fun conn => do
      for i in [1:101] do
        let _ ← Pool.insertOn conn <| InsertQuery.into BenchItems.table
          |>.set BenchItems.label s!"item-{i}"
        let _ ← Pool.insertOn conn <| InsertQuery.into BenchDocs.table
          |>.set BenchDocs.tenant_id "tenant-a"
          |>.set BenchDocs.owner_id "u-alice"
          |>.set BenchDocs.title s!"doc-{i}"

def main : IO Unit := do
  let addr := (← IO.getEnv "ADDR").getD "127.0.0.1:18082"
  let dbPath := (← IO.getEnv "BENCH_DB").getD "/tmp/leant_bench.db"
  let secret := (← IO.getEnv "BENCH_SECRET").getD "bench-secret-key"
  let (host, port) := Transport.parseAddr addr

  let pool ← Pool.createSqlite dbPath { maxSize := 4 }
  seedDatabase pool

  let sessionCfg : SessionConfig := { secret, secureCookie := false }
  let benchPrincipal : Principal := { id := "u-alice", tenant := "tenant-a", roles := ["admin"] }
  let sampleToken ← issueToken sessionCfg benchPrincipal
  if let some tokenFile := ← IO.getEnv "TOKEN_OUT" then
    IO.FS.writeFile tokenFile sampleToken

  let dbHandler : Handler := fun c => do
    let q := SelectQuery.fromTable BenchItems.table |>.filter (BenchItems.id ==. 42) |>.limit 1
    match ← pool.selectModels (α := BenchItem) q with
    | .ok items =>
      match items[0]? with
      | some item => c.json item
      | none => throw (AppError.notFound "item not found")
    | .error e => throw (.internal s!"db error: {e}")

  let authzHandler : AuthHandler := fun ac => do
    let id ← ac.ctx.param! "id" (α := Int)
    let q := scopeSelect (SelectQuery.fromTable BenchDocs.table |>.filter (BenchDocs.id ==. id) |>.limit 1) ac.principal
    match ← pool.selectModels (α := BenchDoc) q with
    | .error e => throw (.internal s!"db error: {e}")
    | .ok docs =>
      match docs[0]? with
      | none => throw (AppError.notFound "doc not found")
      | some doc =>
        let res : Resource := { kind := "doc", owner := doc.ownerId, tenant := doc.tenantId }
        requires benchPolicy ac.principal .read on res with _auth =>
          ac.ctx.json doc

  let app := Leant.new
    |>.get "/plaintext" (fun c => c.text "Hello, World!")
    |>.get "/json" (fun c => c.json ({ message := "Hello, World!" } : Message))
    |>.get "/db" dbHandler
    |>.get "/authz/:id" (authenticate sessionCfg authzHandler)

  let cfg : Transport.Config := {
    host := host
    port := port
    maxConnections := 16384
    keepAlive := true
    headerTimeoutMs := 5000
    requestTimeoutMs := 0
    shutdownTimeoutMs := 2000
  }
  app.runWith Transport.RustHyper.backend cfg
