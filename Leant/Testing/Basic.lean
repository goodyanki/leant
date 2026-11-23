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

end Leant.Testing
