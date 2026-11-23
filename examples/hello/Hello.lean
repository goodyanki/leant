import Leant

open Leant

private def getUser (c : Context) : HandlerM Response := do
  let id ← c.param! "id" (α := Nat)
  c.jsonRaw s!"\{\"id\":{id},\"name\":\"user-{id}\"}"

private def createUser (c : Context) : HandlerM Response := do
  let body := c.request.bodyText
  c.jsonRaw s!"\{\"created\":true,\"payload_len\":{body.length}}" Status.created

def main : IO Unit := do
  let app := Leant.default
    |>.get "/" (fun c => c.text "Hello from Leant!")
    |>.get "/ping" (fun c => c.text "pong")
    |>.get "/json" (fun c => c.jsonRaw "{\"message\":\"Hello, World!\"}")
    |>.group "/api/v1" (·
      |>.use Middleware.requestId
      |>.get "/users/:id" getUser
      |>.post "/users" createUser)
  app.run "127.0.0.1:8080"
