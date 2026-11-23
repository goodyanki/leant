import Leant.Core.Method
import Leant.Core.Status
import Leant.Core.Types
import Leant.Core.Error
import Leant.Core.Context
import Leant.Core.Middleware
import Leant.Router.Router
import Leant.Middleware.Basic
import Leant.Transport.Basic
import Leant.Transport.RustHyper

namespace Leant

/-- Route group builder carrying a shared path prefix and group-level middlewares. -/
structure Group where
  pathPrefix : String := ""
  middlewares : Array Middleware := #[]
  routes : Array (Method × String × Handler) := #[]
  deriving Inhabited

namespace Group

/-- Attaches a middleware to all routes in this group. -/
def use (g : Group) (mw : Middleware) : Group :=
  { g with middlewares := g.middlewares.push mw }

/-- Registers a route for an arbitrary `Method` inside the group. -/
def route (g : Group) (method : Method) (path : String) (handler : Handler) : Group :=
  let fullPath := Router.joinPaths g.pathPrefix path
  { g with routes := g.routes.push (method, fullPath, handler) }

def get (g : Group) (path : String) (handler : Handler) : Group := g.route .get path handler
def post (g : Group) (path : String) (handler : Handler) : Group := g.route .post path handler
def put (g : Group) (path : String) (handler : Handler) : Group := g.route .put path handler
def patch (g : Group) (path : String) (handler : Handler) : Group := g.route .patch path handler
def delete (g : Group) (path : String) (handler : Handler) : Group := g.route .delete path handler

/-- Nests a child group under this group's prefix and middlewares. -/
def group (g : Group) (subPrefix : String) (configure : Group → Group) : Group :=
  let child : Group := {
    pathPrefix := Router.joinPaths g.pathPrefix subPrefix
    middlewares := g.middlewares
    routes := #[]
  }
  let configured := configure child
  let wrapped := configured.routes.map fun (m, p, h) =>
    (m, p, Middleware.chain configured.middlewares h)
  { g with routes := g.routes ++ wrapped }

end Group

/-- Gin-style web application holding a router and global middlewares. -/
structure App where
  router : Router := Router.empty
  middlewares : Array Middleware := #[]
  deriving Inhabited

/-- Creates a bare application with no middlewares (analogous to `gin.New()`). -/
def new : App := {}

/-- Creates an application preloaded with `recovery` and `logger` (analogous to `gin.Default()`). -/
def default : App :=
  { middlewares := #[Middleware.recovery, Middleware.logger] }

namespace App

/-- Registers a global middleware (runs around all matched and unmatched requests). -/
def use (app : App) (mw : Middleware) : App :=
  { app with middlewares := app.middlewares.push mw }

/-- Registers a route for any HTTP method. -/
def route (app : App) (method : Method) (path : String) (handler : Handler) : App :=
  { app with router := app.router.add method path handler }

def get (app : App) (path : String) (handler : Handler) : App := app.route .get path handler
def post (app : App) (path : String) (handler : Handler) : App := app.route .post path handler
def put (app : App) (path : String) (handler : Handler) : App := app.route .put path handler
def patch (app : App) (path : String) (handler : Handler) : App := app.route .patch path handler
def delete (app : App) (path : String) (handler : Handler) : App := app.route .delete path handler

/-- Mounts a route group with a shared path prefix and group-scoped middlewares. -/
def group (app : App) (pathPrefix : String) (configure : Group → Group) : App :=
  let g := configure { pathPrefix }
  let router' := g.routes.foldl (init := app.router) fun r (m, p, h) =>
    r.add m p (Middleware.chain g.middlewares h)
  { app with router := router' }

/-- Dispatches a single `Request` through global middlewares and the router. -/
def handle (app : App) (req : Request) : IO Response := do
  let dispatch : Handler := fun c =>
    match app.router.lookup c.request.method c.request.path with
    | .matched h params => h { c with params }
    | .methodNotAllowed => throw (.methodNotAllowed)
    | .notFound => throw (.notFound)
  let pipeline := Middleware.chain app.middlewares dispatch
  let res ← (pipeline { request := req }).run
  match res with
  | .ok resp => pure resp
  | .error err => pure err.toResponse

/-- Starts the HTTP server on `addr` (e.g. `":8080"` or `"127.0.0.1:8080"`) using the default Rust Hyper transport. -/
def run (app : App) (addr : String := "127.0.0.1:8080") : IO Unit := do
  let (host, port) := Transport.parseAddr addr
  let cfg : Transport.Config := { host, port }
  IO.println s!"[leant] listening on http://{host}:{port}"
  Transport.Backend.serve Transport.RustHyper.backend cfg app.handle

/-- Starts the HTTP server with an explicit `Transport.Config` and pluggable `Backend`. -/
def runWith {τ : Type} [Transport.Backend τ] (app : App) (backend : τ) (cfg : Transport.Config) : IO Unit :=
  Transport.Backend.serve backend cfg app.handle

end App
end Leant
