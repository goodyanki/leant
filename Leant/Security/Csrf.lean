import Leant.Core.Middleware
import Leant.Security.Crypto

namespace Leant.Security

open Leant
open Leant.Security.Crypto

/-- Configuration for double-submit cookie CSRF protection. -/
structure CsrfConfig where
  cookieName : String := "leant_csrf"
  headerName : String := "x-csrf-token"
  deriving Repr, Inhabited

private def isSafeMethod : Method → Bool
  | .get | .head | .options => true
  | _ => false

/-- Double-submit cookie CSRF middleware using constant-time token comparison.
    Safe methods (`GET`, `HEAD`, `OPTIONS`) pass through; state-changing methods must present
    a matching non-empty CSRF token in both cookie and request header. -/
def csrf (cfg : CsrfConfig := {}) : Middleware := fun next c => do
  if isSafeMethod c.request.method then
    next c
  else
    match c.cookie? cfg.cookieName, c.header? cfg.headerName with
    | some cookieTok, some headerTok =>
      if !cookieTok.isEmpty && ctEqString cookieTok headerTok then
        next c
      else
        throw (.forbidden "CSRF token mismatch")
    | _, _ =>
      throw (.forbidden "missing CSRF token")

end Leant.Security
