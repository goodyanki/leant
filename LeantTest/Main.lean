import Std.Sync.Mutex
import Lean.Data.Json
import Leant
import Saas
import LeantTest.NegativeCompile

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

  -- 2. Signed session token: issue, verify, tamper rejection, expiry boundary (nowSec >= expSec)
  let cfg : SessionConfig := { secret := "super-secret-key", ttlSeconds := 60 }
  let alice : Principal := { id := "u1", tenant := "t1", roles := ["admin"] }
  let tok := issueTokenAt cfg alice 1000
  match verifyTokenWithConfig cfg tok 1059 with
  | .ok claims => assertEq "session verify principal before boundary" claims.principal alice
  | .error e => throw <| IO.userError s!"FAIL [session verify]: {e}"

  let tampered := tok ++ "0"
  assertTrue "session rejects tampered signature"
    (match verifyToken cfg.secret tampered 1030 with | .error _ => true | .ok _ => false)
  assertTrue "session rejects wrong secret"
    (match verifyToken "wrong-key" tok 1030 with | .error _ => true | .ok _ => false)
  assertTrue "session rejects token at exact expiry boundary (now == exp)"
    (match verifyTokenWithConfig cfg tok 1060 with | .error _ => true | .ok _ => false)
  assertTrue "session rejects expired token (now > exp)"
    (match verifyTokenWithConfig cfg tok 1061 with | .error _ => true | .ok _ => false)
  let noExpTok := signClaims cfg.secret { principal := alice, expSec := 0 }
  assertTrue "session rejects non-expiring token when ttlSeconds > 0"
    (match verifyTokenWithConfig cfg noExpTok 1030 with | .error _ => true | .ok _ => false)

  -- Default wall-clock issuance produces expSec > 0 and verifies immediately
  let liveTok ← issueToken cfg alice
  let nowWall ← systemClock
  match verifyTokenWithConfig cfg liveTok nowWall with
  | .ok claims => assertTrue "wall-clock issued token records positive expSec" (claims.expSec > 0)
  | .error e => throw <| IO.userError s!"FAIL [wall-clock token]: {e}"

  -- 3. PolicyDiff auditing
  let pol1 : Policy := { roleRules := [("admin", .delete, "doc")], ownerActions := [.update] }
  let pol2 : Policy := { roleRules := [("admin", .delete, "doc"), ("editor", .update, "doc")], ownerActions := [.update], forbidRules := [("suspended", .delete, "doc")] }
  let diff := PolicyDiff.compute pol1 pol2
  assertEq "PolicyDiff addedRoleRules" diff.addedRoleRules [("editor", .update, "doc")]
  assertEq "PolicyDiff addedForbidRules" diff.addedForbidRules [("suspended", .delete, "doc")]
  assertTrue "PolicyDiff non-empty" (!diff.isEmpty)

  -- 4. Auth middleware (with injectable per-request clock) + `requires` macro + CSRF + RateLimit
  let rlMw ← makeRateLimit { capacity := 2, refillPerSec := 1 }
  let docRes : Resource := { kind := "doc", owner := "u2", tenant := "t1" }
  let bob : Principal := { id := "u2", tenant := "t1", roles := ["member"] }
  let outsider : Principal := { id := "u9", tenant := "t2", roles := ["admin"] }

  let clockRef ← IO.mkRef (1000 : Nat)
  let testClock : Clock := clockRef.get
  let bobTok ← issueToken cfg bob testClock
  let aliceTok ← issueToken cfg alice testClock
  let outsiderTok ← issueToken cfg outsider testClock

  let app := Leant.new
    |>.group "/secure" (·
      |>.get "/del" (authenticate cfg (fun ac =>
        requires pol2 ac.principal .delete on docRes with _auth =>
          ac.ctx.text "deleted") testClock)
      |>.get "/whoami" (authenticate cfg (fun ac =>
        ac.ctx.text ac.principal.id) testClock))
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

  -- Same registered route enforces per-request TTL boundary for BOTH Bearer and Cookie
  clockRef.set 1059
  let rBearerOk ← Testing.get app "/secure/whoami" "" #[("Authorization", s!"Bearer {aliceTok}")]
  assertEq "route TTL before expiry (Bearer) -> 200" rBearerOk.status Status.ok
  let rCookieOk ← Testing.get app "/secure/whoami" "" #[("Cookie", s!"leant_session={aliceTok}")]
  assertEq "route TTL before expiry (Cookie) -> 200" rCookieOk.status Status.ok

  clockRef.set 1060 -- exact expiry boundary (issuedAt=1000 + ttl=60)
  let rBearerExp ← Testing.get app "/secure/whoami" "" #[("Authorization", s!"Bearer {aliceTok}")]
  assertEq "route TTL at expiry boundary (Bearer) -> 401" rBearerExp.status Status.unauthorized
  let rCookieExp ← Testing.get app "/secure/whoami" "" #[("Cookie", s!"leant_session={aliceTok}")]
  assertEq "route TTL at expiry boundary (Cookie) -> 401" rCookieExp.status Status.unauthorized

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

private def parseJsonStringField (body : String) (field : String) : IO String := do
  match Lean.Json.parse body with
  | .error e => throw <| IO.userError s!"invalid JSON: {e}"
  | .ok j =>
    match j.getObjValAs? String field with
    | .ok v => pure v
    | .error e => throw <| IO.userError s!"missing string field '{field}': {e}"

private def parseJsonIntField (body : String) (field : String) : IO Int := do
  match Lean.Json.parse body with
  | .error e => throw <| IO.userError s!"invalid JSON: {e}"
  | .ok j =>
    match j.getObjValAs? Int field with
    | .ok v => pure v
    | .error e => throw <| IO.userError s!"missing int field '{field}': {e}"

open Leant.Authz Leant.Security.Session in
private def testSaasSessionAndReadPolicy : IO Unit := do
  -- Tightened read policy: `admin` may read any tenant doc, while `member` may read ONLY owned docs.
  let ownerOnlyReadPolicy : Policy := {
    roleRules := [
      ("admin",  .read,   "document"),
      ("admin",  .create, "document"),
      ("admin",  .update, "document"),
      ("admin",  .delete, "document"),
      ("member", .create, "document")
    ]
    ownerActions := [.read, .update, .delete]
    forbidRules := saasPolicy.forbidRules
  }

  let clockRef ← IO.mkRef (5000 : Nat)
  let app ← buildSaasApp ":memory:" "test-saas-secret" false ownerOnlyReadPolicy 120 clockRef.get

  -- 1. Login as alice (admin, tenant-a) and bob (member, tenant-a)
  let rLoginAlice ← Testing.postJson app "/auth/login" "{\"user\":\"alice\"}"
  assertEq "SaaS login alice -> 200" rLoginAlice.status Status.ok
  let aliceTok ← parseJsonStringField rLoginAlice.bodyText "token"

  let rLoginBob ← Testing.postJson app "/auth/login" "{\"user\":\"bob\"}"
  assertEq "SaaS login bob -> 200" rLoginBob.status Status.ok
  let bobTok ← parseJsonStringField rLoginBob.bodyText "token"

  -- 2. Seed two documents in the SAME tenant (`tenant-a`), one owned by alice and one by bob
  let rDocAlice ← Testing.run app
    (Request.make .post "/api/v1/docs" ""
      #[("Authorization", s!"Bearer {aliceTok}"), ("Content-Type", "application/json")]
      "{\"title\":\"Alice Private\",\"content\":\"top-secret\"}")
  assertEq "SaaS create alice doc -> 201" rDocAlice.status Status.created
  let aliceDocId ← parseJsonIntField rDocAlice.bodyText "id"

  let rDocBob ← Testing.run app
    (Request.make .post "/api/v1/docs" ""
      #[("Authorization", s!"Bearer {bobTok}"), ("Content-Type", "application/json")]
      "{\"title\":\"Bob Owned\",\"content\":\"draft\"}")
  assertEq "SaaS create bob doc -> 201" rDocBob.status Status.created
  let bobDocId ← parseJsonIntField rDocBob.bodyText "id"

  -- 3. Bob's list & detail responses MUST agree under tightened read policy
  let rBobList ← Testing.get app "/api/v1/docs" "" #[("Authorization", s!"Bearer {bobTok}")]
  assertEq "SaaS bob list -> 200" rBobList.status Status.ok
  match Lean.Json.parse rBobList.bodyText with
  | .ok (.arr elems) =>
    assertEq "SaaS bob list contains only 1 permitted doc" elems.size 1
  | _ => throw <| IO.userError s!"FAIL [SaaS bob list]: expected JSON array, got {rBobList.bodyText}"
  assertTrue "SaaS bob list contains Bob Owned"
    ((rBobList.bodyText.splitOn "Bob Owned").length >= 2)
  assertTrue "SaaS bob list excludes Alice Private"
    ((rBobList.bodyText.splitOn "Alice Private").length == 1)

  let rBobOwnDetail ← Testing.get app s!"/api/v1/docs/{bobDocId}" "" #[("Authorization", s!"Bearer {bobTok}")]
  assertEq "SaaS bob detail on owned doc -> 200" rBobOwnDetail.status Status.ok
  let rBobOtherDetail ← Testing.get app s!"/api/v1/docs/{aliceDocId}" "" #[("Authorization", s!"Bearer {bobTok}")]
  assertEq "SaaS bob detail on unpermitted tenant doc -> 403" rBobOtherDetail.status Status.forbidden

  -- 4. Alice (admin) sees both documents in list and detail
  let rAliceList ← Testing.get app "/api/v1/docs" "" #[("Authorization", s!"Bearer {aliceTok}")]
  assertEq "SaaS alice list -> 200" rAliceList.status Status.ok
  match Lean.Json.parse rAliceList.bodyText with
  | .ok (.arr elems) =>
    assertEq "SaaS alice list contains both tenant docs" elems.size 2
  | _ => throw <| IO.userError s!"FAIL [SaaS alice list]: expected JSON array, got {rAliceList.bodyText}"
  let rAliceDetailBob ← Testing.get app s!"/api/v1/docs/{bobDocId}" "" #[("Authorization", s!"Bearer {aliceTok}")]
  assertEq "SaaS alice detail on bob doc -> 200" rAliceDetailBob.status Status.ok

  -- 5. SaaS session TTL boundary through `/auth/login` + `/api/v1/docs` (Bearer & Cookie)
  clockRef.set 5119
  let rSaasBearerOk ← Testing.get app "/api/v1/docs" "" #[("Authorization", s!"Bearer {bobTok}")]
  assertEq "SaaS TTL before expiry (Bearer) -> 200" rSaasBearerOk.status Status.ok
  let rSaasCookieOk ← Testing.get app "/api/v1/docs" "" #[("Cookie", s!"leant_session={bobTok}")]
  assertEq "SaaS TTL before expiry (Cookie) -> 200" rSaasCookieOk.status Status.ok

  clockRef.set 5120 -- exact expiry boundary (5000 + 120)
  let rSaasBearerExp ← Testing.get app "/api/v1/docs" "" #[("Authorization", s!"Bearer {bobTok}")]
  assertEq "SaaS TTL at expiry boundary (Bearer) -> 401" rSaasBearerExp.status Status.unauthorized
  let rSaasCookieExp ← Testing.get app "/api/v1/docs" "" #[("Cookie", s!"leant_session={bobTok}")]
  assertEq "SaaS TTL at expiry boundary (Cookie) -> 401" rSaasCookieExp.status Status.unauthorized

section MacroTests
open Leant.Data

leant_table AuthorsTable "authors" where
  | id   : SqlType.int  [pk, auto]
  | name : SqlType.text [unique]

leant_tenant_table ArticlesTable "articles" (tenant_id : ScalarType.text) where
  | id        : SqlType.int  [pk, auto]
  | tenant_id : SqlType.text
  | author_id : SqlType.int
  | title     : SqlType.text

leant_tenant_table OrdersTable "join_orders" (tenant_id : ScalarType.text) where
  | id        : SqlType.int  [pk, auto]
  | tenant_id : SqlType.text
  | ext_key   : SqlType.int
  | title     : SqlType.text

leant_tenant_table InvoicesTable "join_invoices" (tenant_id : ScalarType.text) where
  | id        : SqlType.int  [pk, auto]
  | tenant_id : SqlType.text
  | ext_key   : SqlType.int
  | amount    : SqlType.int

end MacroTests

open Leant.Data in
private def testTenantJoinIsolation {δ : Type} [Driver δ] (backend : String) (pool : Pool δ) : IO Unit := do
  pool.migrateTable OrdersTable.table
  pool.migrateTable InvoicesTable.table

  -- Tenant t-1 orders:
  --   ext_key=100 -> has matching invoice in t-1 (111) AND overlapping invoice in t-2 (999)
  --   ext_key=200 -> NO invoice in t-1, ONLY overlapping invoice in t-2 (888)
  --   ext_key=300 -> NO invoice in any tenant
  let _ ← pool.insert <| InsertQuery.into OrdersTable.table
    |>.set OrdersTable.tenant_id "t-1"
    |>.set OrdersTable.ext_key 100
    |>.set OrdersTable.title "t1-matched"
  let _ ← pool.insert <| InsertQuery.into OrdersTable.table
    |>.set OrdersTable.tenant_id "t-1"
    |>.set OrdersTable.ext_key 200
    |>.set OrdersTable.title "t1-overlap-foreign"
  let _ ← pool.insert <| InsertQuery.into OrdersTable.table
    |>.set OrdersTable.tenant_id "t-1"
    |>.set OrdersTable.ext_key 300
    |>.set OrdersTable.title "t1-unmatched"

  let _ ← pool.insert <| InsertQuery.into InvoicesTable.table
    |>.set InvoicesTable.tenant_id "t-1"
    |>.set InvoicesTable.ext_key 100
    |>.set InvoicesTable.amount 111

  -- Tenant t-2 data using the EXACT SAME overlapping join keys (100, 200)
  let _ ← pool.insert <| InsertQuery.into OrdersTable.table
    |>.set OrdersTable.tenant_id "t-2"
    |>.set OrdersTable.ext_key 100
    |>.set OrdersTable.title "t2-order-100"
  let _ ← pool.insert <| InsertQuery.into OrdersTable.table
    |>.set OrdersTable.tenant_id "t-2"
    |>.set OrdersTable.ext_key 200
    |>.set OrdersTable.title "t2-order-200"
  let _ ← pool.insert <| InsertQuery.into InvoicesTable.table
    |>.set InvoicesTable.tenant_id "t-2"
    |>.set InvoicesTable.ext_key 100
    |>.set InvoicesTable.amount 999
  let _ ← pool.insert <| InsertQuery.into InvoicesTable.table
    |>.set InvoicesTable.tenant_id "t-2"
    |>.set InvoicesTable.ext_key 200
    |>.set InvoicesTable.amount 888

  -- 1. Scoped INNER JOIN for t-1: must return ONLY (t1-matched, amount=111)
  let innerQ := JoinQuery.inner OrdersTable.table InvoicesTable.table
      OrdersTable.ext_key InvoicesTable.ext_key
    |>.forBothTenants "t-1"
  let innerRows ← pool.selectJoin innerQ
  assertEq s!"{backend} INNER JOIN tenant isolation row count" innerRows.size 1
  -- Projected cols: orders(0:id, 1:tenant_id, 2:ext_key, 3:title), invoices(4:id, 5:tenant_id, 6:ext_key, 7:amount)
  assertTrue s!"{backend} INNER JOIN left title"
    ((innerRows[0]?.bind (·[3]?)) == some (.text "t1-matched"))
  assertTrue s!"{backend} INNER JOIN right tenant"
    ((innerRows[0]?.bind (·[5]?)) == some (.text "t-1"))
  assertTrue s!"{backend} INNER JOIN right amount (no cross-tenant match)"
    ((innerRows[0]?.bind (·[7]?)) == some (.int 111))

  -- 2. Scoped LEFT JOIN for t-1: must isolate BOTH sides AND retain all 3 t-1 orders
  let leftQ := JoinQuery.left OrdersTable.table InvoicesTable.table
      OrdersTable.ext_key InvoicesTable.ext_key
    |>.forBothTenants "t-1"
  let leftRows ← pool.selectJoin leftQ
  assertEq s!"{backend} LEFT JOIN retains all 3 t-1 rows (0 t-2 rows)" leftRows.size 3

  let allLeftT1 := leftRows.all fun r => r[1]? == some (.text "t-1")
  assertTrue s!"{backend} LEFT JOIN all left rows belong to t-1" allLeftT1

  let noForeignRight := leftRows.all fun r =>
    r[5]? == some (.text "t-1") || r[5]? == some .null
  assertTrue s!"{backend} LEFT JOIN right rows are either t-1 or NULL" noForeignRight

  let row100 := leftRows.find? fun r => r[2]? == some (.int 100)
  let row200 := leftRows.find? fun r => r[2]? == some (.int 200)
  let row300 := leftRows.find? fun r => r[2]? == some (.int 300)
  assertTrue s!"{backend} LEFT JOIN key=100 matched t-1 invoice (111)"
    ((row100.bind (·[7]?)) == some (.int 111))
  assertTrue s!"{backend} LEFT JOIN key=200 retained unmatched (foreign t-2 invoice blocked)"
    ((row200.bind (·[7]?)) == some .null)
  assertTrue s!"{backend} LEFT JOIN key=300 retained unmatched"
    ((row300.bind (·[7]?)) == some .null)

open Leant.Data Leant.Data.Migration Leant.Security Leant.Static in
private def testV05Features : IO Unit := do
  -- 1. Declarative table macros + scope-checked multi-table SQL JOIN on SQLite
  let pool ← Pool.createSqlite ":memory:"
  pool.migrateTable AuthorsTable.table
  pool.migrateTable ArticlesTable.table

  let authorId ← pool.insert <| InsertQuery.into AuthorsTable.table
    |>.set AuthorsTable.name "Ada Lovelace"
  let _ ← pool.insert <| InsertQuery.into ArticlesTable.table
    |>.set ArticlesTable.tenant_id "t-1"
    |>.set ArticlesTable.author_id authorId
    |>.set ArticlesTable.title "Verified Web Frameworks"

  let joinQ := JoinQuery.inner ArticlesTable.table AuthorsTable.table
      ArticlesTable.author_id AuthorsTable.id
    |>.forLeftTenant "t-1"
    |>.limit 5
  let joinRows ← pool.selectJoin joinQ
  assertEq "JOIN query row count" joinRows.size 1
  -- Projected columns: articles(id, tenant_id, author_id, title), authors(id, name) -> idx 3 = title, idx 5 = author name
  assertTrue "JOIN projected article title"
    ((joinRows[0]?.bind (·[3]?)) == some (.text "Verified Web Frameworks"))
  assertTrue "JOIN projected author name"
    ((joinRows[0]?.bind (·[5]?)) == some (.text "Ada Lovelace"))

  -- Two-tenant overlapping-key INNER & LEFT JOIN isolation on SQLite
  testTenantJoinIsolation "SQLite" pool

  -- 2. Schema diff & versioned migrations (migrateUp + rollbackLast)
  let sV1 : Schema := {
    tableName := ⟨"widgets", by decide⟩
    cols := [{ name := ⟨"id", by decide⟩, ty := .int, isPrimaryKey := true }]
  }
  let sV2 : Schema := {
    tableName := ⟨"widgets", by decide⟩
    cols := [
      { name := ⟨"id", by decide⟩, ty := .int, isPrimaryKey := true },
      { name := ⟨"label", by decide⟩, ty := .nullableText }
    ]
  }
  let ops := diffSchema sV1 sV2
  assertEq "diffSchema detects 1 added column" ops.length 1

  let migrations : List Migration := [
    { version := 1, name := "create_widgets"
    , up := [.createTable sV1], down := [.dropTable sV1.tableName] },
    { version := 2, name := "add_label"
    , up := ops, down := [] }
  ]
  let applied1 ← migrateUp pool migrations
  assertEq "migrateUp applied [1, 2]" applied1 #[1, 2]
  let applied2 ← migrateUp pool migrations
  assertEq "migrateUp idempotent []" applied2 #[]
  let rolled ← rollbackLast pool migrations
  assertEq "rollbackLast version 2" rolled (some 2)
  let vers ← appliedVersions pool
  assertEq "appliedVersions after rollback" vers #[1]

  -- 3. PostgreSQL placeholder translation & dialect DDL
  assertEq "toPostgresPlaceholders"
    (toPostgresPlaceholders "SELECT id FROM users WHERE tenant_id = ? AND id = ? LIMIT ?")
    "SELECT id FROM users WHERE tenant_id = $1 AND id = $2 LIMIT $3"
  assertEq "SQLite beginTransactionSql" (Driver.beginTransactionSql (δ := SqliteConn)) "BEGIN IMMEDIATE"
  assertEq "Postgres beginTransactionSql" (Driver.beginTransactionSql (δ := PgConn)) "BEGIN"

  -- 4. Argon2id password hashing & constant-time verification
  let phc ← Password.hash "correct-horse-battery-staple"
  assertTrue "Argon2id PHC prefix" (phc.startsWith "$argon2id$")
  assertTrue "Argon2id verify valid" (Password.verify "correct-horse-battery-staple" phc)
  assertTrue "Argon2id verify wrong password" (!Password.verify "wrong-password" phc)
  assertTrue "Argon2id verify malformed hash" (!Password.verify "anything" "not-a-hash")

  -- 5. Static file serving + traversal rejection
  assertEq "static rejects .." (safeRelativePath "../etc/passwd") none
  assertEq "static rejects nested .." (safeRelativePath "css/../../secret") none
  assertEq "static rejects backslash" (safeRelativePath "a\\b") none
  assertEq "static accepts valid path" (safeRelativePath "css/app.css") (some ["css", "app.css"])

  let tmpDir : System.FilePath := "/tmp/leant_static_test"
  IO.FS.createDirAll (tmpDir / "css")
  IO.FS.writeFile (tmpDir / "css" / "app.css") "body { color: black; }"
  let staticApp := Leant.new |>.static "/assets" tmpDir
  let rFile ← Testing.get staticApp "/assets/css/app.css"
  assertEq "static serves file 200" rFile.status Status.ok
  assertEq "static Content-Type CSS" (rFile.headers.get? "content-type") (some "text/css; charset=utf-8")
  assertEq "static X-Content-Type-Options" (rFile.headers.get? "x-content-type-options") (some "nosniff")
  assertEq "static body" rFile.bodyText "body { color: black; }"
  let rEsc ← Testing.get staticApp "/assets/../etc/passwd"
  assertEq "static traversal blocked 404" rEsc.status Status.notFound

open Leant.Data Leant.Data.Migration in
private def testPostgresIntegration : IO Unit := do
  match ← IO.getEnv "LEANT_TEST_PG_URL" with
  | none =>
    if (← IO.getEnv "LEANT_REQUIRE_PG") == some "1" then
      throw <| IO.userError "FAIL [Postgres]: LEANT_REQUIRE_PG=1 but LEANT_TEST_PG_URL is not set"
    IO.println "SKIP [Postgres integration]: LEANT_TEST_PG_URL not set"
  | some pgUrl =>
    let pool ← Pool.createPostgres pgUrl { maxSize := 2 }
    -- Clean slate before integration assertions
    pool.withConn fun conn => do
      for tbl in ["pg_tx_items", "pg_mig_widgets", "_leant_migrations", "join_orders", "join_invoices"] do
        Driver.exec conn { sql := s!"DROP TABLE IF EXISTS {tbl}", params := #[] }

    let pgSchema : Schema := {
      tableName := ⟨"pg_tx_items", by decide⟩
      cols := [
        { name := ⟨"id", by decide⟩, ty := .int, isPrimaryKey := true, isAutoIncrement := true },
        { name := ⟨"tenant_id", by decide⟩, ty := .text },
        { name := ⟨"title", by decide⟩, ty := .text },
        { name := ⟨"active", by decide⟩, ty := .bool },
        { name := ⟨"note", by decide⟩, ty := .nullableText }
      ]
    }
    let colId : ColRef pgSchema .int := ⟨0, _, rfl, rfl⟩
    let colTenant : ColRef pgSchema .text := ⟨1, _, rfl, rfl⟩
    let colTitle : ColRef pgSchema .text := ⟨2, _, rfl, rfl⟩
    let colActive : ColRef pgSchema .bool := ⟨3, _, rfl, rfl⟩
    let colNote : ColRef pgSchema .nullableText := ⟨4, _, rfl, rfl⟩
    let pgTable : Table (.tenantScoped .text) := { schema := pgSchema, tenantCol := colTenant }

    pool.migrateTable pgTable

    -- 1. Transaction COMMIT contract on real PostgreSQL
    let committedId ← pool.withTransaction fun conn => do
      Pool.insertOn conn <| InsertQuery.into pgTable
        |>.set colTenant "pg-t1"
        |>.set colTitle "committed-row"
        |>.set colActive true
        |>.set colNote none
    assertTrue "Postgres tx COMMIT returned positive BIGSERIAL id" (committedId > 0)

    let afterCommit ← pool.select (SelectQuery.fromTable pgTable |>.filter (colId ==. committedId) |>.forTenant "pg-t1")
    assertEq "Postgres tx COMMIT persisted 1 row" afterCommit.size 1
    assertTrue "Postgres Bool roundtrip"
      ((afterCommit[0]?.bind (·[3]?)) == some (.bool true))
    assertTrue "Postgres NULL roundtrip"
      ((afterCommit[0]?.bind (·[4]?)) == some .null)

    -- 2. Transaction ROLLBACK-on-error contract on real PostgreSQL
    let rolledBack ←
      try
        pool.withTransaction fun conn => do
          let _ ← Pool.insertOn conn <| InsertQuery.into pgTable
            |>.set colTenant "pg-t1"
            |>.set colTitle "should-rollback"
            |>.set colActive false
            |>.set colNote (some "ephemeral")
          throw (IO.userError "simulated postgres tx failure")
        pure false
      catch _ =>
        pure true
    assertTrue "Postgres tx ROLLBACK caught error" rolledBack

    let afterRollback ← pool.select (SelectQuery.fromTable pgTable |>.forTenant "pg-t1")
    assertEq "Postgres tx ROLLBACK discarded uncommitted row" afterRollback.size 1

    -- 3. Versioned migrations (migrateUp + idempotency + rollbackLast) on real PostgreSQL
    let mV1 : Schema := {
      tableName := ⟨"pg_mig_widgets", by decide⟩
      cols := [{ name := ⟨"id", by decide⟩, ty := .int, isPrimaryKey := true }]
    }
    let mV2 : Schema := {
      tableName := ⟨"pg_mig_widgets", by decide⟩
      cols := [
        { name := ⟨"id", by decide⟩, ty := .int, isPrimaryKey := true },
        { name := ⟨"label", by decide⟩, ty := .nullableText }
      ]
    }
    let pgMigrations : List Migration := [
      { version := 1, name := "create_pg_widgets"
      , up := [.createTable mV1], down := [.dropTable mV1.tableName] },
      { version := 2, name := "add_pg_label"
      , up := diffSchema mV1 mV2, down := [] }
    ]
    let pgApp1 ← migrateUp pool pgMigrations
    assertEq "Postgres migrateUp applied [1, 2]" pgApp1 #[1, 2]
    let pgApp2 ← migrateUp pool pgMigrations
    assertEq "Postgres migrateUp idempotent []" pgApp2 #[]
    let pgRolled ← rollbackLast pool pgMigrations
    assertEq "Postgres rollbackLast version 2" pgRolled (some 2)
    let pgVers ← appliedVersions pool
    assertEq "Postgres appliedVersions after rollback" pgVers #[1]

    -- 4. Tenant-scoped INNER & LEFT JOIN isolation on real PostgreSQL
    testTenantJoinIsolation "Postgres" pool

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
  testSaasSessionAndReadPolicy
  testV05Features
  testPostgresIntegration
  IO.println "All Leant tests passed!"
