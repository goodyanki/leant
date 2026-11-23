import Lean.Data.Json
import Leant

open Leant
open Leant.Binding
open Leant.Data
open Leant.Authz
open Leant.Security
open Leant.Security.Session

/-! ### Multi-Tenant SaaS Document Service Example
    Demonstrates signed authentication, proof-carrying RBAC + ownership guards,
    and compile-time enforced SQLite row-level tenant isolation (RLS). -/

private def docsSchema : Schema := {
  tableName := ⟨"documents", by decide⟩
  cols := [
    { name := ⟨"id", by decide⟩, ty := .int, isPrimaryKey := true, isAutoIncrement := true },
    { name := ⟨"tenant_id", by decide⟩, ty := .text },
    { name := ⟨"owner_id", by decide⟩, ty := .text },
    { name := ⟨"title", by decide⟩, ty := .text, checkSql := some "length(title) > 0 AND length(title) <= 120" },
    { name := ⟨"content", by decide⟩, ty := .text }
  ]
}

private def colDocId : ColRef docsSchema .int := ⟨0, _, rfl, rfl⟩
private def colDocTenant : ColRef docsSchema .text := ⟨1, _, rfl, rfl⟩
private def colDocOwner : ColRef docsSchema .text := ⟨2, _, rfl, rfl⟩
private def colDocTitle : ColRef docsSchema .text := ⟨3, _, rfl, rfl⟩
private def colDocContent : ColRef docsSchema .text := ⟨4, _, rfl, rfl⟩

/-- Tenant-scoped table: unscoped queries on `docsTable` are rejected at compile time. -/
def docsTable : Table (.tenantScoped .text) := {
  schema := docsSchema
  tenantCol := colDocTenant
}

/-- Authorization policy for the SaaS document service. -/
def saasPolicy : Policy := {
  roleRules := [
    ("admin",  .read,   "document"),
    ("admin",  .create, "document"),
    ("admin",  .update, "document"),
    ("admin",  .delete, "document"),
    ("editor", .read,   "document"),
    ("editor", .create, "document"),
    ("editor", .update, "document"),
    ("member", .read,   "document"),
    ("member", .create, "document")
  ]
  ownerActions := [.read, .update, .delete]
  forbidRules := [
    ("suspended", .create, "document"),
    ("suspended", .update, "document"),
    ("suspended", .delete, "document")
  ]
}

structure Document where
  id : Int
  tenantId : String
  ownerId : String
  title : NonEmptyBounded 120
  content : String

namespace Document

def toResource (d : Document) : Resource :=
  { kind := "document", owner := d.ownerId, tenant := d.tenantId }

end Document

instance : Lean.ToJson Document where
  toJson d := Lean.Json.mkObj [
    ("id", Lean.ToJson.toJson d.id),
    ("tenant_id", Lean.ToJson.toJson d.tenantId),
    ("owner_id", Lean.ToJson.toJson d.ownerId),
    ("title", Lean.ToJson.toJson d.title),
    ("content", Lean.ToJson.toJson d.content)
  ]

instance : Model Document where
  mode := .tenantScoped .text
  table := docsTable
  fromRow row := do
    let id ← rowGet row colDocId
    let tenantId ← rowGet row colDocTenant
    let ownerId ← rowGet row colDocOwner
    let title ← rowGetRefined row colDocTitle NonEmptyBounded.ofString
    let content ← rowGet row colDocContent
    pure { id, tenantId, ownerId, title, content }

structure LoginReq where
  user : String

instance : Lean.FromJson LoginReq where
  fromJson? j := do
    let user ← j.getObjValAs? String "user"
    pure { user }

structure CreateDocReq where
  title : NonEmptyBounded 120
  content : String := ""

instance : Lean.FromJson CreateDocReq where
  fromJson? j := do
    let title ← j.getObjValAs? (NonEmptyBounded 120) "title"
    let content := match j.getObjValAs? String "content" with
      | .ok s => s
      | .error _ => ""
    pure { title, content }

structure UpdateDocReq where
  title : Option (NonEmptyBounded 120) := none
  content : Option String := none

instance : Lean.FromJson UpdateDocReq where
  fromJson? j := do
    let title ← match j.getObjVal? "title" with
      | .ok v =>
        if v.isNull then pure none
        else some <$> Lean.FromJson.fromJson? (α := NonEmptyBounded 120) v
      | .error _ => pure none
    let content ← match j.getObjVal? "content" with
      | .ok v =>
        if v.isNull then pure none
        else some <$> Lean.FromJson.fromJson? (α := String) v
      | .error _ => pure none
    pure { title, content }

private def demoUsers : List (String × Principal) := [
  ("alice",   { id := "u-alice",   tenant := "tenant-a", roles := ["admin"] }),
  ("bob",     { id := "u-bob",     tenant := "tenant-a", roles := ["member"] }),
  ("charlie", { id := "u-charlie", tenant := "tenant-a", roles := ["admin", "suspended"] }),
  ("diana",   { id := "u-diana",   tenant := "tenant-b", roles := ["admin"] })
]

private def liftDb {α : Type} (res : Except DbError α) : HandlerM α :=
  match res with
  | .ok v => pure v
  | .error e => throw (.internal s!"database error: {e}")

/-- Guarded business function: Lean's type system requires an `Authorized` proof token to call it. -/
private def deleteDocumentVerified
    (pool : Pool SqliteConn)
    (p : Principal)
    (doc : Document)
    (_auth : Authorized saasPolicy p .delete doc.toResource) : IO Unit :=
  pool.delete <|
    scopeDelete (DeleteQuery.fromTable docsTable |>.filter (colDocId ==. doc.id)) p

/-- Guarded business function requiring an `Authorized` proof token for document updates. -/
private def updateDocumentVerified
    (pool : Pool SqliteConn)
    (p : Principal)
    (doc : Document)
    (nextTitle : NonEmptyBounded 120)
    (nextContent : String)
    (_auth : Authorized saasPolicy p .update doc.toResource) : IO Document := do
  pool.update <|
    scopeUpdate
      (UpdateQuery.table docsTable
        |>.set colDocTitle nextTitle.val
        |>.set colDocContent nextContent
        |>.filter (colDocId ==. doc.id))
      p
  pure { doc with title := nextTitle, content := nextContent }

def buildSaasApp (dbPath : String := ":memory:") (secret : String := "dev-secret-change-me")
    (withLogger : Bool := true) : IO App := do
  let pool ← Pool.createSqlite dbPath { maxSize := 4 }
  pool.migrateTable docsTable
  let sessionCfg : SessionConfig := { secret, secureCookie := false }
  let rateLimitMw ← makeRateLimit { capacity := 1000, refillPerSec := 500 }

  let loginHandler : Handler := fun c => do
    let req ← c.bindJson (α := LoginReq)
    match demoUsers.find? (fun (u, _) => u == req.user) with
    | none => throw (.unauthorized s!"unknown demo user: {req.user}")
    | some (_, principal) =>
      let tok := issueToken sessionCfg principal
      let resp ← c.jsonRaw s!"\{\"token\":\"{tok}\",\"tenant\":\"{principal.tenant}\"}"
      pure (resp.withCookie (makeSessionCookie sessionCfg tok))

  let listDocs : AuthHandler := fun ac => do
    let q := scopeSelect (SelectQuery.fromTable docsTable |>.orderBy colDocId .asc) ac.principal
    let docs ← liftDb (← pool.selectModels (α := Document) q)
    ac.ctx.json docs

  let createDoc : AuthHandler := fun ac => do
    let body ← ac.ctx.bindJson (α := CreateDocReq)
    let target : Resource := { kind := "document", owner := ac.principal.id, tenant := ac.principal.tenant }
    requires saasPolicy ac.principal .create on target with _auth => do
      let ins := InsertQuery.into docsTable
        |>.set colDocTenant ac.principal.tenant
        |>.set colDocOwner ac.principal.id
        |>.set colDocTitle body.title.val
        |>.set colDocContent body.content
      let newId ← pool.insert ins
      let doc : Document := {
        id := newId
        tenantId := ac.principal.tenant
        ownerId := ac.principal.id
        title := body.title
        content := body.content
      }
      ac.ctx.json doc Status.created

  let getDoc : AuthHandler := fun ac => do
    let id ← ac.ctx.param! "id" (α := Int)
    let q := scopeSelect (SelectQuery.fromTable docsTable |>.filter (colDocId ==. id) |>.limit 1) ac.principal
    let docs ← liftDb (← pool.selectModels (α := Document) q)
    match docs[0]? with
    | none => throw (AppError.notFound s!"document {id} not found")
    | some doc =>
      requires saasPolicy ac.principal .read on doc.toResource with _auth =>
        ac.ctx.json doc

  let updateDoc : AuthHandler := fun ac => do
    let id ← ac.ctx.param! "id" (α := Int)
    let patch ← ac.ctx.bindJson (α := UpdateDocReq)
    let q := scopeSelect (SelectQuery.fromTable docsTable |>.filter (colDocId ==. id) |>.limit 1) ac.principal
    let docs ← liftDb (← pool.selectModels (α := Document) q)
    match docs[0]? with
    | none => throw (AppError.notFound s!"document {id} not found")
    | some doc =>
      requires saasPolicy ac.principal .update on doc.toResource with auth => do
        let nextTitle := patch.title.getD doc.title
        let nextContent := patch.content.getD doc.content
        let updated ← updateDocumentVerified pool ac.principal doc nextTitle nextContent auth
        ac.ctx.json updated

  let deleteDoc : AuthHandler := fun ac => do
    let id ← ac.ctx.param! "id" (α := Int)
    let q := scopeSelect (SelectQuery.fromTable docsTable |>.filter (colDocId ==. id) |>.limit 1) ac.principal
    let docs ← liftDb (← pool.selectModels (α := Document) q)
    match docs[0]? with
    | none => throw (AppError.notFound s!"document {id} not found")
    | some doc =>
      requires saasPolicy ac.principal .delete on doc.toResource with auth => do
        deleteDocumentVerified pool ac.principal doc auth
        ac.ctx.status Status.noContent

  let base := if withLogger then Leant.default else Leant.new |>.use Middleware.recovery
  pure <| base
    |>.use rateLimitMw
    |>.use (Middleware.bodyLimit (64 * 1024))
    |>.get "/health" (fun c => c.jsonRaw "{\"status\":\"ok\"}")
    |>.post "/auth/login" loginHandler
    |>.group "/api/v1" (·
      |>.get    "/docs"     (authenticate sessionCfg listDocs)
      |>.post   "/docs"     (authenticate sessionCfg createDoc)
      |>.get    "/docs/:id" (authenticate sessionCfg getDoc)
      |>.patch  "/docs/:id" (authenticate sessionCfg updateDoc)
      |>.delete "/docs/:id" (authenticate sessionCfg deleteDoc))

def main : IO Unit := do
  let dbPath := (← IO.getEnv "SAAS_DB_PATH").getD ":memory:"
  let secret := (← IO.getEnv "SAAS_SECRET").getD "dev-secret-change-me"
  let app ← buildSaasApp dbPath secret true
  app.run "127.0.0.1:8080"
