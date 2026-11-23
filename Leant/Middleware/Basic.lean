import Std.Sync.Mutex
import Leant.Core.Middleware

namespace Leant.Middleware

/-- Logs request method, path, response status, and elapsed duration in milliseconds. -/
def logger : Middleware := fun next c => do
  let startMs ← IO.monoMsNow
  let res ← next c
  let elapsedMs := (← IO.monoMsNow) - startMs
  IO.println s!"[leant] {c.request.method} {c.request.path} -> {res.status} ({elapsedMs}ms)"
  pure res

/-- Catches unexpected IO exceptions and converts them to `500 Internal Server Error`. -/
def recovery : Middleware := fun next c =>
  ExceptT.mk do
    try
      (next c).run
    catch e =>
      IO.eprintln s!"[leant] recovered error: {e}"
      pure (.error (.internal "Internal Server Error"))

/-- Creates a thread-safe `RequestID` middleware with a monotonic counter fallback. -/
def makeRequestId (prefixStr : String := "req") : IO Middleware := do
  let counter ← Std.Mutex.new (0 : Nat)
  pure fun next c => do
    let reqId ← match c.header? "x-request-id" with
      | some existing =>
        if existing.isEmpty then
          counter.atomically do
            let n := (← get) + 1
            set n
            pure s!"{prefixStr}-{n}"
        else
          pure existing
      | none =>
        counter.atomically do
          let n := (← get) + 1
          set n
          pure s!"{prefixStr}-{n}"
    let c' := c.set "request_id" reqId
    let resp ← next c'
    pure (resp.withHeader "X-Request-Id" reqId)

/-- Stateless `RequestID` middleware propagating `X-Request-Id` or defaulting to `"req-0"`. -/
def requestId : Middleware := fun next c => do
  let reqId := match c.header? "x-request-id" with
    | some v => if v.isEmpty then "req-0" else v
    | none => "req-0"
  let c' := c.set "request_id" reqId
  let resp ← next c'
  pure (resp.withHeader "X-Request-Id" reqId)

/-- Configuration for the CORS middleware. -/
structure CorsConfig where
  allowOrigin : String := "*"
  allowMethods : String := "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  allowHeaders : String := "Content-Type, Authorization, X-Request-Id"
  allowCredentials : Bool := false
  maxAgeSeconds : Option Nat := none
  deriving Repr, Inhabited

/-- Configurable CORS middleware handling preflight `OPTIONS` requests. -/
def corsWith (cfg : CorsConfig := {}) : Middleware := fun next c => do
  let applyHeaders (resp : Response) : Response :=
    let r := resp.withHeader "Access-Control-Allow-Origin" cfg.allowOrigin
    let r := if cfg.allowCredentials then
      r.withHeader "Access-Control-Allow-Credentials" "true"
    else r
    r
  if c.request.method == .options then
    let r := Response.empty Status.noContent
      |> applyHeaders
      |>.withHeader "Access-Control-Allow-Methods" cfg.allowMethods
      |>.withHeader "Access-Control-Allow-Headers" cfg.allowHeaders
    let r := match cfg.maxAgeSeconds with
      | some secs => r.withHeader "Access-Control-Max-Age" (toString secs)
      | none => r
    pure r
  else
    let resp ← next c
    pure (applyHeaders resp)

/-- Convenience CORS middleware allowing the given origin. -/
def cors (allowOrigin : String := "*") : Middleware :=
  corsWith { allowOrigin }

/-- Rejects requests whose body exceeds `maxBytes` with `413 Payload Too Large`. -/
def bodyLimit (maxBytes : Nat) : Middleware := fun next c => do
  if c.request.body.size > maxBytes then
    throw (.payloadTooLarge s!"request body exceeds limit of {maxBytes} bytes")
  else
    next c

/-- Enforces a wall-clock timeout in milliseconds on downstream handler execution.
    Returns `408 Request Timeout` if the handler does not complete within `timeoutMs`. -/
def timeout (timeoutMs : UInt32) : Middleware := fun next c =>
  ExceptT.mk do
    let done ← IO.Promise.new (α := Option (Except AppError Response))
    let worker ← IO.asTask (prio := .dedicated) do
      let res ←
        try
          (next c).run
        catch e =>
          pure (.error (.internal s!"handler exception: {e}"))
      done.resolve (some res)
    let _ ← IO.asTask (prio := .dedicated) do
      IO.sleep timeoutMs
      done.resolve none
    match done.result?.get with
    | some (some res) => pure res
    | _ =>
      IO.cancel worker
      pure (.error (.requestTimeout s!"request timed out after {timeoutMs}ms"))

end Leant.Middleware
