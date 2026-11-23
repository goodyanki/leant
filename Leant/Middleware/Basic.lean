import Leant.Core.Middleware

namespace Leant.Middleware

/-- Logs request method, path, and response status to stdout. -/
def logger : Middleware := fun next c => do
  let res ← next c
  IO.println s!"[leant] {c.request.method} {c.request.path} -> {res.status}"
  pure res

/-- Catches unexpected IO exceptions and converts them to `500 Internal Server Error`. -/
def recovery : Middleware := fun next c =>
  ExceptT.mk do
    try
      (next c).run
    catch e =>
      IO.eprintln s!"[leant] recovered error: {e}"
      pure (.error (.internal "Internal Server Error"))

/-- Propagates or assigns an `X-Request-Id` header on the response and context store. -/
def requestId : Middleware := fun next c => do
  let reqId := (c.header? "x-request-id").getD "req-0"
  let c' := c.set "request_id" reqId
  let resp ← next c'
  pure (resp.withHeader "X-Request-Id" reqId)

/-- Adds permissive CORS headers and handles `OPTIONS` preflight requests. -/
def cors (allowOrigin : String := "*") : Middleware := fun next c => do
  if c.request.method == .options then
    pure <| Response.empty Status.noContent
      |>.withHeader "Access-Control-Allow-Origin" allowOrigin
      |>.withHeader "Access-Control-Allow-Methods" "GET, POST, PUT, PATCH, DELETE, OPTIONS"
      |>.withHeader "Access-Control-Allow-Headers" "Content-Type, Authorization, X-Request-Id"
  else
    let resp ← next c
    pure (resp.withHeader "Access-Control-Allow-Origin" allowOrigin)

end Leant.Middleware
