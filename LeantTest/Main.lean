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

  -- Cookie parsing & secure defaults (PRD S1)
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

def main : IO Unit := do
  testTrieRouting
  testCookiesQueryForm
  testBindingRefinedTypes
  testMiddlewares
  testAuthz
  IO.println "All Leant M1 tests passed!"
