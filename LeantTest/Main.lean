import Leant

open Leant

private def assertEq {α : Type} [BEq α] [Repr α] (label : String) (actual expected : α) : IO Unit := do
  if actual != expected then
    throw <| IO.userError s!"FAIL [{label}]: expected {repr expected}, got {repr actual}"
  else
    IO.println s!"PASS [{label}]"

private def testApp : App :=
  Leant.new
    |>.use Middleware.recovery
    |>.get "/ping" (fun c => c.text "pong")
    |>.get "/users/me" (fun c => c.text "current-user")
    |>.get "/users/:id" (fun c => do
      let id ← c.param! "id" (α := Nat)
      c.jsonRaw s!"\{\"id\":{id}}")
    |>.get "/files/*path" (fun c => do
      let p ← c.param! "path" (α := String)
      c.text p)
    |>.group "/api/v1" (·
      |>.use Middleware.requestId
      |>.post "/echo" (fun c => do
        let reqId := (c.get? "request_id").getD ""
        let resp ← c.text (c.request.bodyText ++ ":" ++ reqId) Status.created
        pure resp))

private def testRoutingAndMiddleware : IO Unit := do
  let r1 ← Testing.get testApp "/ping"
  assertEq "GET /ping status" r1.status Status.ok
  assertEq "GET /ping body" r1.bodyText "pong"

  -- Static route beats :param route
  let r2 ← Testing.get testApp "/users/me"
  assertEq "GET /users/me static priority" r2.bodyText "current-user"

  -- Typed :param parsing
  let r3 ← Testing.get testApp "/users/42"
  assertEq "GET /users/42 status" r3.status Status.ok
  assertEq "GET /users/42 body" r3.bodyText "{\"id\":42}"

  -- Invalid Nat param -> 400
  let r4 ← Testing.get testApp "/users/not-a-num"
  assertEq "GET /users/not-a-num status" r4.status Status.badRequest

  -- Wildcard route
  let r5 ← Testing.get testApp "/files/a/b/c.txt"
  assertEq "GET /files/*path body" r5.bodyText "a/b/c.txt"

  -- 405 Method Not Allowed vs 404 Not Found
  let r6 ← Testing.post testApp "/ping" ""
  assertEq "POST /ping 405" r6.status Status.methodNotAllowed
  let r7 ← Testing.get testApp "/does-not-exist"
  assertEq "GET /does-not-exist 404" r7.status Status.notFound

  -- Group prefix + group middleware
  let r8 ← Testing.post testApp "/api/v1/echo" "hello" #[("X-Request-Id", "abc-123")]
  assertEq "POST /api/v1/echo status" r8.status Status.created
  assertEq "POST /api/v1/echo body" r8.bodyText "hello:abc-123"
  assertEq "POST /api/v1/echo header" (r8.headers.get? "x-request-id") (some "abc-123")

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

  assertEq "admin allowed" (Authz.evaluate pol admin .delete post) .allow
  assertEq "cross-tenant denied" (Authz.evaluate pol otherTenant .delete post) .deny
  assertEq "forbid overrides allow" (Authz.evaluate pol suspendedAdmin .delete post) .deny
  assertEq "owner allowed" (Authz.evaluate pol owner .update post) .allow

  match Authz.guard pol admin .delete post with
  | .ok _ => IO.println "PASS [guard returns Authorized proof]"
  | .error e => throw <| IO.userError s!"FAIL [guard]: unexpected error {repr e}"

def main : IO Unit := do
  testRoutingAndMiddleware
  testAuthz
  IO.println "All Leant tests passed!"
