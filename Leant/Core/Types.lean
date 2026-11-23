import Leant.Core.Method
import Leant.Core.Status
import Leant.Core.Cookie

namespace Leant

private def hexVal (b : UInt8) : Option UInt8 :=
  if b >= 48 && b <= 57 then some (b - 48)          -- '0'..'9'
  else if b >= 65 && b <= 70 then some (b - 65 + 10) -- 'A'..'F'
  else if b >= 97 && b <= 102 then some (b - 97 + 10) -- 'a'..'f'
  else none

/-- Decodes `application/x-www-form-urlencoded` / query percent-encoding (`+` -> space, `%XX` -> byte). -/
def urlDecode (s : String) : String :=
  let bytes := s.toUTF8
  let rec go (i : Nat) (out : ByteArray) : ByteArray :=
    if h : i < bytes.size then
      let b := bytes[i]
      if b == 43 then -- '+'
        go (i + 1) (out.push 32)
      else if b == 37 && i + 2 < bytes.size then -- '%'
        match hexVal (bytes.get! (i + 1)), hexVal (bytes.get! (i + 2)) with
        | some hi, some lo => go (i + 3) (out.push (hi * 16 + lo))
        | _, _ => go (i + 1) (out.push b)
      else
        go (i + 1) (out.push b)
    else
      out
  termination_by bytes.size - i
  String.fromUTF8! (go 0 ByteArray.empty)

/-- Parses `k=v&k2=v2` form or query strings with percent-decoding. -/
def parseFormEncoded (raw : String) : Array (String × String) :=
  if raw.isEmpty then #[]
  else
    raw.splitOn "&" |>.foldl (init := #[]) fun acc pair =>
      if pair.isEmpty then acc
      else
        match pair.splitOn "=" with
        | [] => acc
        | [k] => acc.push (urlDecode k, "")
        | k :: rest => acc.push (urlDecode k, urlDecode (String.intercalate "=" rest))

/-- Key-value list for HTTP headers (case-insensitive lookups). -/
abbrev Headers := Array (String × String)

namespace Headers

def empty : Headers := #[]

/-- Returns the first header value matching `name` (ASCII case-insensitive). -/
def get? (hs : Headers) (name : String) : Option String :=
  let target := name.toLower
  (hs.find? fun (k, _) => k.toLower == target).map Prod.snd

/-- Returns all header values matching `name` (ASCII case-insensitive). -/
def getAll (hs : Headers) (name : String) : Array String :=
  let target := name.toLower
  hs.foldl (init := #[]) fun acc (k, v) =>
    if k.toLower == target then acc.push v else acc

/-- Sets or replaces a header `(name, value)`. -/
def set (hs : Headers) (name value : String) : Headers :=
  let target := name.toLower
  let filtered := hs.filter fun (k, _) => k.toLower != target
  filtered.push (name, value)

/-- Appends a header without removing existing headers of the same name (e.g. `Set-Cookie`). -/
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

/-- Parses URL-decoded query parameters (`k=v&k2=v2`). -/
def queryParams (req : Request) : Array (String × String) :=
  parseFormEncoded req.query

/-- Looks up a single URL-decoded query parameter by name. -/
def queryParam? (req : Request) (key : String) : Option String :=
  (req.queryParams.find? fun (k, _) => k == key).map Prod.snd

/-- Parses all incoming cookies from `Cookie` request headers. -/
def cookies (req : Request) : Array (String × String) :=
  (req.headers.getAll "cookie").foldl (init := #[]) fun acc raw =>
    acc ++ Cookie.parseRequestHeader raw

/-- Looks up a single cookie value by name. -/
def cookie? (req : Request) (name : String) : Option String :=
  (req.cookies.find? fun (k, _) => k == name).map Prod.snd

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

/-- Sets or replaces a response header. -/
def withHeader (resp : Response) (name value : String) : Response :=
  { resp with headers := resp.headers.set name value }

/-- Appends a response header without removing existing headers of the same name. -/
def addHeader (resp : Response) (name value : String) : Response :=
  { resp with headers := resp.headers.add name value }

/-- Appends a `Set-Cookie` header using `Cookie` (secure defaults enabled). -/
def withCookie (resp : Response) (cookie : Cookie) : Response :=
  resp.addHeader "Set-Cookie" cookie.toSetCookieHeader

/-- Decodes the response body as UTF-8 text (useful in tests). -/
def bodyText (resp : Response) : String :=
  String.fromUTF8! resp.body

end Response
end Leant
