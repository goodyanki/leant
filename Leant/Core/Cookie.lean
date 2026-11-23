namespace Leant

/-- `SameSite` cookie attribute controlling cross-site transmission. -/
inductive SameSite where
  | strict
  | lax
  | none
  deriving Repr, BEq, DecidableEq, Inhabited

namespace SameSite

def toString : SameSite → String
  | .strict => "Strict"
  | .lax    => "Lax"
  | .none   => "None"

instance : ToString SameSite := ⟨SameSite.toString⟩

end SameSite

/-- HTTP `Set-Cookie` builder with secure defaults (`HttpOnly`, `Secure`, `SameSite=Lax`, PRD S1). -/
structure Cookie where
  name : String
  value : String
  path : Option String := some "/"
  domain : Option String := none
  maxAge : Option Int := none
  httpOnly : Bool := true
  secure : Bool := true
  sameSite : SameSite := .lax
  deriving Repr, BEq, Inhabited

namespace Cookie

/-- Formats a `Cookie` into a `Set-Cookie` HTTP header value. -/
def toSetCookieHeader (c : Cookie) : String :=
  let parts : Array String := #[s!"{c.name}={c.value}"]
  let parts := match c.path with
    | some p => parts.push s!"Path={p}"
    | none => parts
  let parts := match c.domain with
    | some d => parts.push s!"Domain={d}"
    | none => parts
  let parts := match c.maxAge with
    | some age => parts.push s!"Max-Age={age}"
    | none => parts
  let parts := if c.httpOnly then parts.push "HttpOnly" else parts
  let parts := if c.secure then parts.push "Secure" else parts
  let parts := parts.push s!"SameSite={c.sameSite}"
  String.intercalate "; " parts.toList

/-- Parses an incoming `Cookie` request header (`"a=1; b=2"`) into `(name, value)` pairs. -/
def parseRequestHeader (raw : String) : Array (String × String) :=
  if raw.isEmpty then #[]
  else
    raw.splitOn ";" |>.foldl (init := #[]) fun acc part =>
      let trimmed := part.trimAscii.toString
      if trimmed.isEmpty then acc
      else
        match trimmed.splitOn "=" with
        | [] => acc
        | [k] => acc.push (k.trimAscii.toString, "")
        | k :: rest =>
          acc.push (k.trimAscii.toString, (String.intercalate "=" rest).trimAscii.toString)

end Cookie
end Leant
