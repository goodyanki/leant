import Lean.Data.Json
import Leant.App

namespace Leant.Testing

/-- Executes a `Request` directly against an `App` in memory without opening a socket (PRD K11). -/
def run (app : App) (req : Request) : IO Response :=
  app.handle req

/-- Sends an in-memory `GET` request. -/
def get (app : App) (path : String) (query : String := "") (headers : Headers := #[]) : IO Response :=
  app.handle (Request.make .get path query headers)

/-- Sends an in-memory `POST` request with a UTF-8 body. -/
def post (app : App) (path : String) (body : String := "") (headers : Headers := #[]) : IO Response :=
  app.handle (Request.make .post path "" headers body)

/-- Sends an in-memory `PUT` request with a UTF-8 body. -/
def put (app : App) (path : String) (body : String := "") (headers : Headers := #[]) : IO Response :=
  app.handle (Request.make .put path "" headers body)

/-- Sends an in-memory `PATCH` request with a UTF-8 body. -/
def patch (app : App) (path : String) (body : String := "") (headers : Headers := #[]) : IO Response :=
  app.handle (Request.make .patch path "" headers body)

/-- Sends an in-memory `DELETE` request. -/
def delete (app : App) (path : String) (headers : Headers := #[]) : IO Response :=
  app.handle (Request.make .delete path "" headers)

/-- Sends an in-memory `POST` request with JSON payload and `Content-Type: application/json`. -/
def postJson (app : App) (path : String) (rawJson : String) (headers : Headers := #[]) : IO Response :=
  app.handle (Request.make .post path "" (headers.set "Content-Type" "application/json") rawJson)

/-- Sends an in-memory `PATCH` request with JSON payload and `Content-Type: application/json`. -/
def patchJson (app : App) (path : String) (rawJson : String) (headers : Headers := #[]) : IO Response :=
  app.handle (Request.make .patch path "" (headers.set "Content-Type" "application/json") rawJson)

/-- Sends an in-memory `PUT` request with JSON payload and `Content-Type: application/json`. -/
def putJson (app : App) (path : String) (rawJson : String) (headers : Headers := #[]) : IO Response :=
  app.handle (Request.make .put path "" (headers.set "Content-Type" "application/json") rawJson)

end Leant.Testing
