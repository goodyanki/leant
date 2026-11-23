import Std.Sync.Mutex
import Lean.Data.Json
import Leant

open Leant
open Leant.Binding

private def assertEq {α : Type} [BEq α] [Repr α] (label : String) (actual expected : α) : IO Unit := do
  if actual != expected then
    throw <| IO.userError s!"FAIL [{label}]: expected {repr expected}, got {repr actual}"
  else
    IO.println s!"PASS [{label}]"

private def assertTrue (label : String) (cond : Bool) : IO Unit := do
  if !cond then
    throw <| IO.userError s!"FAIL [{label}]: condition was false"
  else
    IO.println s!"PASS [{label}]"

private structure SignupPayload where
  name : NonEmptyBounded 32
  email : Email
  age : PositiveNat

private instance : Lean.FromJson SignupPayload where
  fromJson? j := do
    let name ← j.getObjValAs? (NonEmptyBounded 32) "name"
    let email ← j.getObjValAs? Email "email"
    let age ← j.getObjValAs? PositiveNat "age"
    pure { name, email, age }

private def testTrieRouting : IO Unit := do
  let app := Leant.new
    |>.get "/" (fun c => c.text "root")
    |>.get "/ping" (fun c => c.text "pong")
    |>.get "/users/me" (fun c => c.text "static-me")
    |>.get "/users/settings/profile" (fun c => c.text "static-profile")
    |>.get "/users/:id" (fun c => do
      let id ← c.param! "id" (α := Nat)
      c.jsonRaw s!"\{\"id\":{id}}")
    |>.get "/users/:id/posts" (fun c => do
      let id ← c.param! "id" (α := String)
      c.text s!"posts-of-{id}")
    |>.get "/files/*path" (fun c => do
      let p ← c.param! "path" (α := String)
      c.text p)

  let r0 ← Testing.get app "/"
  assertEq "trie GET /" r0.bodyText "root"

  -- Static beats :param
  let r1 ← Testing.get app "/users/me"
  assertEq "trie static beats :param" r1.bodyText "static-me"

  -- Backtracking: /users/settings/posts misses static /users/settings/profile, falls back to /users/:id/posts
  let r2 ← Testing.get app "/users/settings/profile"
  assertEq "trie deep static match" r2.bodyText "static-profile"
  let r3 ← Testing.get app "/users/settings/posts"
  assertEq "trie backtrack static -> :param" r3.bodyText "posts-of-settings"

  -- Typed :param + 400 validation error
  let r4 ← Testing.get app "/users/42"
  assertEq "trie :id Nat" r4.bodyText "{\"id\":42}"
  let r5 ← Testing.get app "/users/abc"
  assertEq "trie :id invalid Nat -> 400" r5.status Status.badRequest

  -- Wildcard
  let r6 ← Testing.get app "/files/a/b/c.txt"
  assertEq "trie *wildcard" r6.bodyText "a/b/c.txt"

  -- 405 vs 404
  let r7 ← Testing.post app "/ping" ""
  assertEq "trie 405 Method Not Allowed" r7.status Status.methodNotAllowed
  let r8 ← Testing.get app "/nope"
  assertEq "trie 404 Not Found" r8.status Status.notFound

private def testCookiesQueryForm : IO Unit := do
  let app := Leant.new
    |>.get "/search" (fun c => do
      let q ← c.query! "q" (α := String)
      let page ← c.queryOr "page" (α := Nat) 1
      c.text s!"{q}#{page}")
    |>.post "/form" (fun c => do
      let title ← c.form! "title" (α := NonEmpty)
      let done ← c.form! "done" (α := Bool)
      c.text s!"{title}:{done}")
    |>.get "/session" (fun c => do
      let sid := (c.cookie? "sid").getD "none"
      let resp ← c.text sid
      pure <| resp.withCookie { name := "sid", value := "tok-99", maxAge := some 3600 })

  -- URL-decoded query + default page
  let rq ← Testing.get app "/search" "q=lean+4%20web"
  assertEq "query decode + default" rq.bodyText "lean 4 web#1"
  let rq2 ← Testing.get app "/search" "q=ok&page=3"
  assertEq "query typed page" rq2.bodyText "ok#3"

  -- Form parsing + refined NonEmpty
  let rf ← Testing.post app "/form" "title=Buy+milk%21&done=true"
  assertEq "form decode" rf.bodyText "Buy milk!:true"
  let rfBad ← Testing.post app "/form" "title=&done=true"
  assertEq "form empty NonEmpty -> 400" rfBad.status Status.badRequest

  -- Cookie parsing & secure defaults
  let rc ← Testing.get app "/session" "" #[("Cookie", "theme=dark; sid=abc-1")]
  assertEq "cookie read" rc.bodyText "abc-1"
  let setCookie := (rc.headers.get? "set-cookie").getD ""
  assertEq "Set-Cookie secure defaults"
    setCookie "sid=tok-99; Path=/; Max-Age=3600; HttpOnly; Secure; SameSite=Lax"

private def testBindingRefinedTypes : IO Unit := do
  let app := Leant.new
    |>.post "/signup" (fun c => do
      let p ← c.bindJson (α := SignupPayload)
      -- Compile-time proofs are directly accessible on parsed fields:
      let _ : p.name.val.length > 0 := p.name.nonEmpty
      let _ : p.name.val.length ≤ 32 := p.name.bounded
      let _ : isValidEmail p.email.val = true := p.email.valid
      let _ : p.age.val > 0 := p.age.pos
      c.text s!"{p.name.val}<{p.email.val}>:{p.age.val}" Status.created)

  let okResp ← Testing.postJson app "/signup"
    "{\"name\":\"Alice\",\"email\":\"alice@example.com\",\"age\":30}"
  assertEq "bindJson valid status" okResp.status Status.created
  assertEq "bindJson valid body" okResp.bodyText "Alice<alice@example.com>:30"

  let badEmpty ← Testing.postJson app "/signup"
    "{\"name\":\"\",\"email\":\"alice@example.com\",\"age\":30}"
  assertEq "bindJson rejects empty name" badEmpty.status Status.badRequest

  let badEmail ← Testing.postJson app "/signup"
    "{\"name\":\"Alice\",\"email\":\"not-an-email\",\"age\":30}"
  assertEq "bindJson rejects bad email" badEmail.status Status.badRequest

  let badAge ← Testing.postJson app "/signup"
    "{\"name\":\"Alice\",\"email\":\"alice@example.com\",\"age\":0}"
  assertEq "bindJson rejects zero PositiveNat" badAge.status Status.badRequest

private def testMiddlewares : IO Unit := do
  let traceRef ← IO.mkRef (#[] : Array String)
  let reqIdMw ← Middleware.makeRequestId "t"

  let outer : Middleware := fun next c => do
    traceRef.modify (·.push "outer-before")
    let r ← next c
    traceRef.modify (·.push "outer-after")
    pure r

  let inner : Middleware := fun next c => do
    traceRef.modify (·.push "inner-before")
    let r ← next c
    traceRef.modify (·.push "inner-after")
    pure r

  let blocker : Middleware := fun _next c =>
    c.abort (.unauthorized "blocked")

  let app := Leant.new
    |>.use Middleware.recovery
    |>.use (Middleware.cors "https://example.com")
    |>.use (Middleware.bodyLimit 16)
    |>.group "/onion" (·
      |>.use outer
      |>.use inner
      |>.get "/go" (fun c => do
        traceRef.modify (·.push "handler")
        c.text "ok"))
    |>.group "/blocked" (·
      |>.use blocker
      |>.get "/secret" (fun c => c.text "never"))
    |>.group "/ids" (·
      |>.use reqIdMw
      |>.get "/next" (fun c => c.text ((c.get? "request_id").getD "")))
    |>.post "/small" (fun c => c.text c.request.bodyText)
    |>.get "/boom" (fun _c => do
      let _ : Unit ← (throw (IO.userError "boom!") : IO Unit)
      pure (Response.text "unreachable"))
    |>.group "/timed" (·
      |>.use (Middleware.timeout 40)
      |>.get "/fast" (fun c => c.text "fast")
      |>.get "/slow" (fun c => do
        IO.sleep 150
        c.text "slow"))

  -- Onion ordering
  let r1 ← Testing.get app "/onion/go"
  assertEq "onion response" r1.bodyText "ok"
  let trace ← traceRef.get
  assertEq "onion trace order" trace #["outer-before", "inner-before", "handler", "inner-after", "outer-after"]

  -- Abort short-circuit
  let r2 ← Testing.get app "/blocked/secret"
  assertEq "abort 401" r2.status Status.unauthorized

  -- CORS preflight + header
  let rCors ← Testing.run app (Request.make .options "/onion/go")
  assertEq "CORS preflight 204" rCors.status Status.noContent
  assertEq "CORS origin header" (rCors.headers.get? "access-control-allow-origin") (some "https://example.com")

  -- Monotonic RequestID
  let rid1 ← Testing.get app "/ids/next"
  let rid2 ← Testing.get app "/ids/next"
  assertEq "makeRequestId #1" rid1.bodyText "t-1"
  assertEq "makeRequestId #2" rid2.bodyText "t-2"
  let ridPass ← Testing.get app "/ids/next" "" #[("X-Request-Id", "custom-7")]
  assertEq "makeRequestId passthrough" ridPass.bodyText "custom-7"

  -- BodyLimit 413
  let rOkBody ← Testing.post app "/small" "1234567890"
  assertEq "bodyLimit within cap" rOkBody.status Status.ok
  let rBigBody ← Testing.post app "/small" "12345678901234567890"
  assertEq "bodyLimit exceeds cap -> 413" rBigBody.status Status.payloadTooLarge

  -- Recovery catches unexpected IO.userError -> 500
  let rBoom ← Testing.get app "/boom"
  assertEq "recovery -> 500" rBoom.status Status.internalServerError

  -- Timeout middleware
  let rFast ← Testing.get app "/timed/fast"
  assertEq "timeout fast -> 200" rFast.status Status.ok
  let rSlow ← Testing.get app "/timed/slow"
  assertEq "timeout slow -> 408" rSlow.status Status.requestTimeout

private def testAuthz : IO Unit := do
  let pol : Authz.Policy := {
    roleRules := [("admin", .delete, "post")]
    ownerActions := [.update, .delete]
    forbidRules := [("suspended", .delete, "post")]
  }
  let admin : Authz.Principal := { id := "u1", tenant := "t1", roles := ["admin"] }
  let otherTenant : Authz.Principal := { id := "u2", tenant := "t2", roles := ["admin"] }
  let suspendedAdmin : Authz.Principal := { id := "u3", tenant := "t1", roles := ["admin", "suspended"] }
  let owner : Authz.Principal := { id := "u4", tenant := "t1", roles := ["member"] }
  let post : Authz.Resource := { kind := "post", owner := "u4", tenant := "t1" }

  assertEq "authz admin allowed" (Authz.evaluate pol admin .delete post) .allow
  assertEq "authz cross-tenant denied" (Authz.evaluate pol otherTenant .delete post) .deny
  assertEq "authz forbid overrides allow" (Authz.evaluate pol suspendedAdmin .delete post) .deny
  assertEq "authz owner allowed" (Authz.evaluate pol owner .update post) .allow

  match Authz.guard pol admin .delete post with
  | .ok _ => assertTrue "authz guard returns Authorized proof" true
  | .error e => throw <| IO.userError s!"FAIL [guard]: unexpected error {repr e}"

private def testTypedRouteDsl : IO Unit := do
  let userPostRoute := route! / "users" / (id : Nat) / "posts" / (slug : String)
  assertEq "DSL toPattern" userPostRoute.toPattern "/users/:id/posts/:slug"
  assertEq "DSL typed render" (userPostRoute.render 42 "lean-web") "/users/42/posts/lean-web"

  let app := Leant.new
    |>.getTyped userPostRoute (fun c (id : Nat) (slug : String) =>
      c.jsonRaw s!"\{\"user\":{id},\"slug\":\"{slug}\"}")
    |>.group "/api" (·
      |>.getTyped (route! / "items" / (itemId : PositiveNat)) (fun c itemId => do
        -- Proof witness `itemId.pos : itemId.val > 0` is guaranteed at compile time!
        let _ : itemId.val > 0 := itemId.pos
        c.text s!"item-{itemId.val}"))

  let r1 ← Testing.get app (userPostRoute.render 7 "formal-routing")
  assertEq "DSL typed dispatch 200" r1.status Status.ok
  assertEq "DSL typed dispatch body" r1.bodyText "{\"user\":7,\"slug\":\"formal-routing\"}"

  let rBad ← Testing.get app "/users/not-nat/posts/abc"
  assertEq "DSL invalid Nat param -> 400" rBad.status Status.badRequest

  let rPos ← Testing.get app "/api/items/5"
  assertEq "DSL refined PositiveNat param" rPos.bodyText "item-5"
  let rZero ← Testing.get app "/api/items/0"
  assertEq "DSL PositiveNat rejects 0 -> 400" rZero.status Status.badRequest

private def testSseAndStream : IO Unit := do
  let app := Leant.new
    |>.get "/events" (fun c =>
      c.sse #[
        { id := some "1", event := some "tick", data := "hello\nworld", retryMs := some 3000 },
        { data := "done" }
      ])
    |>.get "/chunks" (fun c =>
      c.stream "text/plain; charset=utf-8" fun emit => do
        emit "part1-".toUTF8
        emit "part2".toUTF8)

  let rSse ← Testing.get app "/events"
  assertEq "SSE status" rSse.status Status.ok
  assertEq "SSE Content-Type" (rSse.headers.get? "content-type") (some "text/event-stream; charset=utf-8")
  assertEq "SSE Cache-Control" (rSse.headers.get? "cache-control") (some "no-cache")
  assertEq "SSE wire encoding" rSse.bodyText
    "id: 1\nevent: tick\nretry: 3000\ndata: hello\ndata: world\n\ndata: done\n\n"

  let rStream ← Testing.get app "/chunks"
  assertEq "stream chunks body" rStream.bodyText "part1-part2"

open Leant.Data in
private def testVerifiedOrmAndSqlite : IO Unit := do
    -- Define a tenant-scoped `notes` table: (id, tenant_id, title, note_body)
    let notesSchema : Schema := {
      tableName := ⟨"notes", by decide⟩
      cols := [
        { name := ⟨"id", by decide⟩, ty := .int, isPrimaryKey := true, isAutoIncrement := true },
        { name := ⟨"tenant_id", by decide⟩, ty := .int },
        { name := ⟨"title", by decide⟩, ty := .text },
        { name := ⟨"body", by decide⟩, ty := .nullableText }
      ]
    }
    let colId : ColRef notesSchema .int := ⟨0, _, rfl, rfl⟩
    let colTenant : ColRef notesSchema .int := ⟨1, _, rfl, rfl⟩
    let colTitle : ColRef notesSchema .text := ⟨2, _, rfl, rfl⟩
    let colBody : ColRef notesSchema .nullableText := ⟨3, _, rfl, rfl⟩
    let notesTable : Table (.tenantScoped .int) := {
      schema := notesSchema
      tenantCol := colTenant
    }

    -- 1. SQL injection non-interference at runtime + arity check
    let malicious := "'; DROP TABLE notes; --"
    let qBenign := SelectQuery.fromTable notesTable
      |>.filter (colTitle ==. "hello" ||. colTitle.like "%safe%")
      |>.orderBy colId .asc
      |>.limit 10
      |>.forTenant 1
    let qEvil := SelectQuery.fromTable notesTable
      |>.filter (colTitle ==. malicious ||. colTitle.like malicious)
      |>.orderBy colId .asc
      |>.limit 5
      |>.forTenant 1
    assertEq "ORM SQL injection non-interference" qBenign.render.sql qEvil.render.sql
    assertEq "ORM placeholder arity"
      (Theorems.countPlaceholders qEvil.render.sql) qEvil.render.params.size

    -- 2. Real SQLite connection pool + DDL + CRUD + Multi-tenant RLS isolation
    let pool ← Pool.createSqlite ":memory:"
    pool.migrateTable notesTable

    let id1 ← pool.insert <| InsertQuery.into notesTable
      |>.set colTenant 1
      |>.set colTitle "tenant1-secret"
      |>.set colBody (some "private")
    let _id2 ← pool.insert <| InsertQuery.into notesTable
      |>.set colTenant 2
      |>.set colTitle "tenant2-secret"
      |>.set colBody none
    let _id3 ← pool.insert <| InsertQuery.into notesTable
      |>.set colTenant 1
      |>.set colTitle malicious
      |>.set colBody (some "stored literally")
    assertTrue "ORM SQLite insert returned positive rowid" (id1 > 0)

    -- Even with an adversarial tautology `OR title != ""`, tenant 1 CANNOT see tenant 2's rows!
    let rlsQuery := SelectQuery.fromTable notesTable
      |>.filter (colTitle ==. "nope" ||. colTitle !=. "")
      |>.orderBy colId .asc
      |>.forTenant 1
    let t1Rows ← pool.select rlsQuery
    assertEq "ORM RLS isolates tenant 1 row count" t1Rows.size 2

    -- Malicious SQL payload was stored literally as data and table survived intact
    let evilLookup := SelectQuery.fromTable notesTable
      |>.filter (colTitle ==. malicious)
      |>.forTenant 1
    let evilRows ← pool.select evilLookup
    assertEq "ORM malicious payload matched safely as bound value" evilRows.size 1

    -- Nullable column IS NULL query
    let nullBodyQuery := SelectQuery.fromTable notesTable
      |>.filter colBody.isNull
      |>.forTenant 2
    let nullRows ← pool.select nullBodyQuery
    assertEq "ORM nullable IS NULL scoped to tenant 2" nullRows.size 1

    -- 3. Scoped UPDATE and DELETE cannot mutate another tenant's rows
    pool.update <| UpdateQuery.table notesTable
      |>.set colTitle "hacked"
      |>.filter (colId ==. id1)
      |>.forTenant 2 -- wrong tenant!
    let checkT1 ← pool.select (SelectQuery.fromTable notesTable |>.filter (colId ==. id1) |>.forTenant 1)
    let titleAfterWrongUpdate := match checkT1[0]? with
      | some row => (rowGet row colTitle).toOption
      | none => none
    assertEq "ORM cross-tenant UPDATE blocked by RLS" titleAfterWrongUpdate (some "tenant1-secret")

    -- 4. Transaction automatic ROLLBACK on failure
    let rolledBack ←
      try
        pool.withTransaction fun conn => do
          let _ ← Pool.insertOn conn <| InsertQuery.into notesTable
            |>.set colTenant 2
            |>.set colTitle "should-rollback"
            |>.set colBody none
          throw (IO.userError "simulated failure")
        pure false
      catch _ =>
        pure true
    assertTrue "ORM transaction caught error" rolledBack
    let t2AfterRollback ← pool.select (SelectQuery.fromTable notesTable |>.forTenant 2)
    assertEq "ORM transaction rolled back cleanly" t2AfterRollback.size 1

    -- 5. Refined type validation rejects corrupted data at DB boundary
    let emptyCheck := rowGetRefined #[.int 1, .int 1, .text "", .null] colTitle (NonEmptyBounded.ofString (maxLen := 120))
    assertTrue "ORM rowGetRefined rejects empty DB value" (match emptyCheck with | .error _ => true | .ok _ => false)

open Leant.Authz Leant.Security Leant.Security.Crypto Leant.Security.Session in
private def testSecurityAndAuthzIntegration : IO Unit := do
  -- 1. HMAC-SHA256 RFC 4231 Test Case 2: key = "Jefe", data = "what do ya want for nothing?"
  let mac := hmacSha256 "Jefe".toUTF8 "what do ya want for nothing?".toUTF8
  assertEq "HMAC-SHA256 RFC 4231 vector"
    (toHex mac)
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
  assertTrue "ctEq equal bytes" (ctEq mac mac)
  assertTrue "ctEq unequal bytes" (!ctEq "abc".toUTF8 "abd".toUTF8)
  let rnd ← randomHex 16
  assertEq "CSPRNG randomHex length" rnd.length 32

  -- 2. Signed session token: issue, verify, tamper rejection, expiry rejection
  let cfg : SessionConfig := { secret := "super-secret-key", ttlSeconds := 60 }
  let alice : Principal := { id := "u1", tenant := "t1", roles := ["admin"] }
  let tok := issueToken cfg alice (nowSec := 1000)
  match verifyToken cfg.secret tok (nowSec := 1030) with
  | .ok claims => assertEq "session verify principal" claims.principal alice
  | .error e => throw <| IO.userError s!"FAIL [session verify]: {e}"

  let tampered := tok ++ "0"
  assertTrue "session rejects tampered signature"
    (match verifyToken cfg.secret tampered (nowSec := 1030) with | .error _ => true | .ok _ => false)
  assertTrue "session rejects wrong secret"
    (match verifyToken "wrong-key" tok (nowSec := 1030) with | .error _ => true | .ok _ => false)
  assertTrue "session rejects expired token"
    (match verifyToken cfg.secret tok (nowSec := 1061) with | .error _ => true | .ok _ => false)

  -- 3. PolicyDiff auditing
  let pol1 : Policy := { roleRules := [("admin", .delete, "doc")], ownerActions := [.update] }
  let pol2 : Policy := { roleRules := [("admin", .delete, "doc"), ("editor", .update, "doc")], ownerActions := [.update], forbidRules := [("suspended", .delete, "doc")] }
  let diff := PolicyDiff.compute pol1 pol2
  assertEq "PolicyDiff addedRoleRules" diff.addedRoleRules [("editor", .update, "doc")]
  assertEq "PolicyDiff addedForbidRules" diff.addedForbidRules [("suspended", .delete, "doc")]
  assertTrue "PolicyDiff non-empty" (!diff.isEmpty)

  -- 4. Auth middleware + declarative `requires` macro + CSRF + RateLimit
  let rlMw ← makeRateLimit { capacity := 2, refillPerSec := 1 }
  let docRes : Resource := { kind := "doc", owner := "u2", tenant := "t1" }
  let bob : Principal := { id := "u2", tenant := "t1", roles := ["member"] }
  let bobTok := issueToken cfg bob
  let aliceTok := issueToken cfg alice
  let outsider : Principal := { id := "u9", tenant := "t2", roles := ["admin"] }
  let outsiderTok := issueToken cfg outsider

  let app := Leant.new
    |>.group "/secure" (·
      |>.get "/del" (authenticate cfg fun ac =>
        requires pol2 ac.principal .delete on docRes with _auth =>
          ac.ctx.text "deleted"))
    |>.group "/csrf" (·
      |>.use (csrf {})
      |>.get "/open" (fun c => c.text "ok")
      |>.post "/mutate" (fun c => c.text "mutated"))
    |>.group "/limited" (·
      |>.use rlMw
      |>.get "/ping" (fun c => c.text "pong"))

  -- Missing auth -> 401
  let rNoAuth ← Testing.get app "/secure/del"
  assertEq "auth missing -> 401" rNoAuth.status Status.unauthorized
  -- Admin same tenant (Bearer) -> 200
  let rAdmin ← Testing.get app "/secure/del" "" #[("Authorization", s!"Bearer {aliceTok}")]
  assertEq "requires admin allowed -> 200" rAdmin.status Status.ok
  -- Member without delete grant (Cookie) -> 403
  let rBob ← Testing.get app "/secure/del" "" #[("Cookie", s!"leant_session={bobTok}")]
  assertEq "requires member denied -> 403" rBob.status Status.forbidden
  -- Cross-tenant admin -> 403
  let rOutsider ← Testing.get app "/secure/del" "" #[("Authorization", s!"Bearer {outsiderTok}")]
  assertEq "requires cross-tenant admin denied -> 403" rOutsider.status Status.forbidden

  -- CSRF middleware
  let rCsrfGet ← Testing.get app "/csrf/open"
  assertEq "CSRF safe GET -> 200" rCsrfGet.status Status.ok
  let rCsrfNoTok ← Testing.post app "/csrf/mutate" ""
  assertEq "CSRF missing token -> 403" rCsrfNoTok.status Status.forbidden
  let rCsrfBad ← Testing.post app "/csrf/mutate" "" #[("Cookie", "leant_csrf=aaa"), ("X-CSRF-Token", "bbb")]
  assertEq "CSRF mismatch -> 403" rCsrfBad.status Status.forbidden
  let rCsrfOk ← Testing.post app "/csrf/mutate" "" #[("Cookie", "leant_csrf=tok123"), ("X-CSRF-Token", "tok123")]
  assertEq "CSRF matching token -> 200" rCsrfOk.status Status.ok

  -- Token-bucket rate limiter (capacity = 2)
  let rRl1 ← Testing.get app "/limited/ping" "" #[("X-Client-Id", "c1")]
  let rRl2 ← Testing.get app "/limited/ping" "" #[("X-Client-Id", "c1")]
  let rRl3 ← Testing.get app "/limited/ping" "" #[("X-Client-Id", "c1")]
  assertEq "rateLimit #1 -> 200" rRl1.status Status.ok
  assertEq "rateLimit #2 -> 200" rRl2.status Status.ok
  assertEq "rateLimit #3 -> 429" rRl3.status Status.tooManyRequests

def main : IO Unit := do
  testTrieRouting
  testCookiesQueryForm
  testBindingRefinedTypes
  testMiddlewares
  testAuthz
  testTypedRouteDsl
  testSseAndStream
  testVerifiedOrmAndSqlite
  testSecurityAndAuthzIntegration
  IO.println "All Leant tests passed!"
