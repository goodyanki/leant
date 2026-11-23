import Leant.Core.Method
import Leant.Core.Status

namespace Leant

/-- Key-value list for HTTP headers (case-insensitive lookups). -/
abbrev Headers := Array (String × String)

namespace Headers

def empty : Headers := #[]

/-- Returns the first header value matching `name` (ASCII case-insensitive). -/
def get? (hs : Headers) (name : String) : Option String :=
  let target := name.toLower
  (hs.find? fun (k, _) => k.toLower == target).map Prod.snd

/-- Sets or appends a header `(name, value)`. -/
def set (hs : Headers) (name value : String) : Headers :=
  let target := name.toLower
  let filtered := hs.filter fun (k, _) => k.toLower != target
  filtered.push (name, value)

/-- Appends a header without removing existing headers of the same name. -/
def add (hs : Headers) (name value : String) : Headers :=
  hs.push (name, value)

/-- Parses `"Name: Value\n"` lines into `Headers`. -/
def parseRaw (raw : String) : Headers :=
  if raw.isEmpty then #[]
  else
    raw.splitOn "\n" |>.foldl (init := #[]) fun acc line =>
      let line := line.trimAscii.toString
      if line.isEmpty then acc
      else
        match line.splitOn ":" with
        | [] => acc
        | [k] => acc.push (k.trimAscii.toString, "")
        | k :: rest =>
          let v := (String.intercalate ":" rest).trimAscii.toString
          acc.push (k.trimAscii.toString, v)

/-- Serializes `Headers` to `"Name: Value\n"` lines for transport. -/
def toRaw (hs : Headers) : String :=
  hs.foldl (init := "") fun acc (k, v) => acc ++ k ++ ": " ++ v ++ "\n"

end Headers

/-- HTTP Request passed into the router and middleware chain. -/
structure Request where
  method : Method := .get
  path : String := "/"
  query : String := ""
  headers : Headers := #[]
  body : ByteArray := ByteArray.empty
  deriving Inhabited

namespace Request

/-- Convenience constructor for building requests in tests. -/
def make
    (method : Method := .get)
    (path : String := "/")
    (query : String := "")
    (headers : Headers := #[])
    (body : String := "") : Request :=
  { method, path, query, headers, body := body.toUTF8 }

/-- Decodes the request body as UTF-8 text. -/
def bodyText (req : Request) : String :=
  String.fromUTF8! req.body

/-- Parses simple `k=v&k2=v2` query parameters. -/
def queryParams (req : Request) : Array (String × String) :=
  if req.query.isEmpty then #[]
  else
    req.query.splitOn "&" |>.foldl (init := #[]) fun acc pair =>
      if pair.isEmpty then acc
      else
        match pair.splitOn "=" with
        | [] => acc
        | [k] => acc.push (k, "")
        | k :: rest => acc.push (k, String.intercalate "=" rest)

/-- Looks up a single query parameter by name. -/
def queryParam? (req : Request) (key : String) : Option String :=
  (req.queryParams.find? fun (k, _) => k == key).map Prod.snd

end Request

/-- HTTP Response returned by handlers and middleware. -/
structure Response where
  status : Status := Status.ok
  headers : Headers := #[]
  body : ByteArray := ByteArray.empty
  deriving Inhabited

namespace Response

/-- Returns a plain text response (`text/plain; charset=utf-8`). -/
def text (body : String) (status : Status := Status.ok) : Response :=
  { status
  , headers := Headers.empty.set "Content-Type" "text/plain; charset=utf-8"
  , body := body.toUTF8 }

/-- Returns a JSON response (`application/json; charset=utf-8`). -/
def json (body : String) (status : Status := Status.ok) : Response :=
  { status
  , headers := Headers.empty.set "Content-Type" "application/json; charset=utf-8"
  , body := body.toUTF8 }

/-- Returns an HTML response (`text/html; charset=utf-8`). -/
def html (body : String) (status : Status := Status.ok) : Response :=
  { status
  , headers := Headers.empty.set "Content-Type" "text/html; charset=utf-8"
  , body := body.toUTF8 }

/-- Returns an empty response with the given status code. -/
def empty (status : Status := Status.noContent) : Response :=
  { status, headers := #[], body := ByteArray.empty }

/-- Returns an HTTP redirect response. -/
def redirect (location : String) (status : Status := Status.found) : Response :=
  { status
  , headers := Headers.empty.set "Location" location
  , body := ByteArray.empty }

/-- Sets a response header. -/
def withHeader (resp : Response) (name value : String) : Response :=
  { resp with headers := resp.headers.set name value }

/-- Decodes the response body as UTF-8 text (useful in tests). -/
def bodyText (resp : Response) : String :=
  String.fromUTF8! resp.body

end Response
end Leant
