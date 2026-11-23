import Lean.Data.Json
import Leant.Core.Types
import Leant.Core.Error

namespace Leant

/-- Typeclass for parsing path/query/form parameter strings into typed values. -/
class FromParam (α : Type) where
  parseParam : String → Option α

instance : FromParam String where
  parseParam s := some s

instance : FromParam Nat where
  parseParam s := s.toNat?

instance : FromParam Int where
  parseParam s := s.toInt?

instance : FromParam Bool where
  parseParam s :=
    match s.toLower with
    | "true" | "1" => some true
    | "false" | "0" => some false
    | _ => none

/-- Request-scoped context passed to Gin-style handlers and middleware. -/
structure Context where
  request : Request
  params : Array (String × String) := #[]
  store : Array (String × String) := #[]
  deriving Inhabited

/-- Handler monad combining `IO` with typed `AppError` short-circuiting. -/
abbrev HandlerM := ExceptT AppError IO

/-- Core request handler type. -/
abbrev Handler := Context → HandlerM Response

namespace Context

/-- Looks up a route path parameter (e.g. `:id`). -/
def param? (c : Context) (name : String) : Option String :=
  (c.params.find? fun (k, _) => k == name).map Prod.snd

/-- Parses a required route path parameter into `α`, returning `400 Bad Request` on failure. -/
def param! (c : Context) (name : String) {α : Type} [FromParam α] : HandlerM α :=
  match c.param? name with
  | none => throw (.badRequest s!"missing path parameter: {name}")
  | some raw =>
    match FromParam.parseParam (α := α) raw with
    | some v => pure v
    | none => throw (.badRequest s!"invalid path parameter '{name}': {raw}")

/-- Looks up a URL-decoded query parameter by key. -/
def query? (c : Context) (key : String) : Option String :=
  c.request.queryParam? key

/-- Parses a required query parameter into `α`, returning `400 Bad Request` on failure. -/
def query! (c : Context) (key : String) {α : Type} [FromParam α] : HandlerM α :=
  match c.query? key with
  | none => throw (.badRequest s!"missing query parameter: {key}")
  | some raw =>
    match FromParam.parseParam (α := α) raw with
    | some v => pure v
    | none => throw (.badRequest s!"invalid query parameter '{key}': {raw}")

/-- Parses an optional query parameter into `α`, falling back to `defaultVal` when absent. -/
def queryOr (c : Context) (key : String) {α : Type} [FromParam α] (defaultVal : α) : HandlerM α :=
  match c.query? key with
  | none => pure defaultVal
  | some raw =>
    match FromParam.parseParam (α := α) raw with
    | some v => pure v
    | none => throw (.badRequest s!"invalid query parameter '{key}': {raw}")

/-- Looks up a request header (case-insensitive). -/
def header? (c : Context) (name : String) : Option String :=
  c.request.headers.get? name

/-- Looks up an incoming cookie value by name. -/
def cookie? (c : Context) (name : String) : Option String :=
  c.request.cookie? name

/-- Returns raw request body bytes. -/
def bodyBytes (c : Context) : ByteArray :=
  c.request.body

/-- Parses `application/x-www-form-urlencoded` body fields. -/
def formParams (c : Context) : Array (String × String) :=
  parseFormEncoded c.request.bodyText

/-- Looks up a single form field by key. -/
def form? (c : Context) (key : String) : Option String :=
  (c.formParams.find? fun (k, _) => k == key).map Prod.snd

/-- Parses a required form field into `α`, returning `400 Bad Request` on failure. -/
def form! (c : Context) (key : String) {α : Type} [FromParam α] : HandlerM α :=
  match c.form? key with
  | none => throw (.badRequest s!"missing form field: {key}")
  | some raw =>
    match FromParam.parseParam (α := α) raw with
    | some v => pure v
    | none => throw (.badRequest s!"invalid form field '{key}': {raw}")

/-- Reads a value from the per-request key-value store. -/
def get? (c : Context) (key : String) : Option String :=
  (c.store.find? fun (k, _) => k == key).map Prod.snd

/-- Stores a key-value entry in the per-request store. -/
def set (c : Context) (key value : String) : Context :=
  let filtered := c.store.filter fun (k, _) => k != key
  { c with store := filtered.push (key, value) }

/-- Parses the request body as JSON and decodes it via `Lean.FromJson`. -/
def bindJson (c : Context) {α : Type} [Lean.FromJson α] : HandlerM α :=
  match Lean.Json.parse c.request.bodyText with
  | .error e => throw (.badRequest s!"invalid JSON: {e}")
  | .ok j =>
    match Lean.FromJson.fromJson? (α := α) j with
    | .error e => throw (.badRequest s!"JSON validation failed: {e}")
    | .ok v => pure v

/-- Returns a plain text response. -/
def text (_c : Context) (body : String) (status : Status := Status.ok) : HandlerM Response :=
  pure (Response.text body status)

/-- Returns a JSON response serialized with `Lean.ToJson`. -/
def json (_c : Context) {α : Type} [Lean.ToJson α] (value : α) (status : Status := Status.ok) : HandlerM Response :=
  pure (Response.json (Lean.ToJson.toJson value).compress status)

/-- Returns a raw pre-encoded JSON string response. -/
def jsonRaw (_c : Context) (raw : String) (status : Status := Status.ok) : HandlerM Response :=
  pure (Response.json raw status)

/-- Returns an HTML response. -/
def html (_c : Context) (body : String) (status : Status := Status.ok) : HandlerM Response :=
  pure (Response.html body status)

/-- Returns a status-only empty response. -/
def status (_c : Context) (s : Status) : HandlerM Response :=
  pure (Response.empty s)

/-- Returns a redirect response. -/
def redirect (_c : Context) (location : String) (s : Status := Status.found) : HandlerM Response :=
  pure (Response.redirect location s)

/-- Short-circuits request handling with an `AppError`. -/
def abort (_c : Context) (err : AppError) : HandlerM Response :=
  throw err

end Context
end Leant
