import Lean.Data.Json
import Leant.Core.Cookie
import Leant.Authz.Basic
import Leant.Security.Crypto

namespace Leant.Security.Session

open Leant
open Leant.Authz
open Leant.Security.Crypto

/-- Configuration for HMAC-SHA256 signed stateless session / bearer tokens. -/
structure SessionConfig where
  secret : String
  cookieName : String := "leant_session"
  ttlSeconds : Nat := 3600
  secureCookie : Bool := true
  deriving Repr, Inhabited

/-- Signed token claims wrapping an authenticated `Principal` with an optional expiration timestamp. -/
structure Claims where
  principal : Principal
  expSec : Nat := 0
  deriving Repr, BEq

instance : Lean.ToJson Principal where
  toJson p := Lean.Json.mkObj [
    ("id", Lean.ToJson.toJson p.id),
    ("tenant", Lean.ToJson.toJson p.tenant),
    ("roles", Lean.ToJson.toJson p.roles)
  ]

instance : Lean.FromJson Principal where
  fromJson? j := do
    let id ← j.getObjValAs? String "id"
    let tenant ← j.getObjValAs? String "tenant"
    let roles ← j.getObjValAs? (List String) "roles"
    pure { id, tenant, roles }

instance : Lean.ToJson Claims where
  toJson c := Lean.Json.mkObj [
    ("principal", Lean.ToJson.toJson c.principal),
    ("exp", Lean.ToJson.toJson c.expSec)
  ]

instance : Lean.FromJson Claims where
  fromJson? j := do
    let principal ← j.getObjValAs? Principal "principal"
    let expSec ← j.getObjValAs? Nat "exp"
    pure { principal, expSec }

/-- Signs `claims` into `<hex(json_payload)>.<hex(hmac_sha256(secret, hex_payload))>`.
    Hex-encoding the payload guarantees cookie/header-safe ASCII without padding ambiguity. -/
def signClaims (secret : String) (claims : Claims) : String :=
  let payloadHex := toHex (Lean.ToJson.toJson claims).compress.toUTF8
  let mac := hmacSha256 secret.toUTF8 payloadHex.toUTF8
  payloadHex ++ "." ++ toHex mac

/-- Verifies token signature in constant time and checks optional expiry (`expSec > 0`). -/
def verifyToken (secret : String) (token : String) (nowSec : Nat := 0) : Except String Claims :=
  match token.splitOn "." with
  | [payloadHex, sigHex] =>
    let expectedMac := hmacSha256 secret.toUTF8 payloadHex.toUTF8
    match fromHex sigHex with
    | none => .error "malformed token signature"
    | some providedMac =>
      if !ctEq expectedMac providedMac then
        .error "invalid token signature"
      else
        match fromHex payloadHex with
        | none => .error "malformed token payload"
        | some payloadBytes =>
          match Lean.Json.parse (String.fromUTF8! payloadBytes) with
          | .error e => .error s!"invalid token JSON: {e}"
          | .ok j =>
            match Lean.FromJson.fromJson? (α := Claims) j with
            | .error e => .error s!"invalid token claims: {e}"
            | .ok claims =>
              if claims.expSec > 0 && nowSec > claims.expSec then
                .error "token expired"
              else
                .ok claims
  | _ => .error "malformed token format"

/-- Issues a signed token for `principal` using monotonic/configured expiry. -/
def issueToken (cfg : SessionConfig) (principal : Principal) (nowSec : Nat := 0) : String :=
  let exp := if cfg.ttlSeconds > 0 && nowSec > 0 then nowSec + cfg.ttlSeconds else 0
  signClaims cfg.secret { principal, expSec := exp }

/-- Wraps a signed session token into a `Cookie` with secure defaults (`HttpOnly`, `SameSite=Lax`). -/
def makeSessionCookie (cfg : SessionConfig) (token : String) : Cookie :=
  { name := cfg.cookieName
  , value := token
  , maxAge := some cfg.ttlSeconds
  , httpOnly := true
  , secure := cfg.secureCookie
  , sameSite := .lax }

end Leant.Security.Session
