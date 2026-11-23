import Leant.Core.Context
import Leant.Data.Query
import Leant.Authz.Basic
import Leant.Security.Session

namespace Leant.Authz

open Leant
open Leant.Data
open Leant.Security.Session

/-- Request context enriched with a cryptographically verified `Principal`. -/
structure AuthContext where
  ctx : Context
  principal : Principal

/-- Handler that can only be invoked after authentication has succeeded. -/
abbrev AuthHandler := AuthContext → HandlerM Response

/-- Extracts a signed token from `Authorization: Bearer <token>` or the configured session cookie. -/
def extractToken (cfg : SessionConfig) (c : Context) : Option String :=
  match c.header? "authorization" with
  | some auth =>
    if auth.startsWith "Bearer " then
      some (auth.drop 7).toString
    else
      c.cookie? cfg.cookieName
  | none =>
    c.cookie? cfg.cookieName

/-- Wraps an `AuthHandler` into a standard `Handler` by verifying the signed Bearer token
    or session cookie (returns `401 Unauthorized` if missing, tampered, or expired). -/
def authenticate (cfg : SessionConfig) (h : AuthHandler) (nowSec : Nat := 0) : Handler := fun c => do
  match extractToken cfg c with
  | none => throw (.unauthorized "missing authentication credentials")
  | some tok =>
    match verifyToken cfg.secret tok nowSec with
    | .error msg => throw (.unauthorized msg)
    | .ok claims => h { ctx := c, principal := claims.principal }

/-- Evaluates `guard` inside `HandlerM`, returning `Authorized pol p a r` or throwing `403 Forbidden`. -/
def guardM (pol : Policy) (p : Principal) (a : Action) (r : Resource) :
    HandlerM (Authorized pol p a r) :=
  match guard pol p a r with
  | .ok proof => pure proof
  | .error err => throw err

/-- Evaluates `guardM` and passes the resulting `Authorized` proof token directly to `k`. -/
def withGuard (pol : Policy) (p : Principal) (a : Action) (r : Resource)
    (k : Authorized pol p a r → HandlerM Response) : HandlerM Response := do
  let auth ← guardM pol p a r
  k auth

/-- Declarative authorization guard macro:
    `requires pol principal .delete on resource with auth => body`
    evaluates the policy and binds `auth : Authorized pol principal .delete resource` in `body`. -/
syntax "requires " term:arg term:arg term:arg " on " term:arg " with " ident " => " term : term

macro_rules
  | `(requires $pol $p $a on $r with $auth => $body) =>
    `(Leant.Authz.withGuard $pol $p $a $r (fun $auth => $body))

/-! ### Authz ↔ ORM Row-Level Security (RLS) Bridges -/

/-- Scopes a `SelectQuery` on a text-tenant table to `principal.tenant` (`scoped = true`). -/
def scopeSelect {tbl : Table (.tenantScoped .text)}
    (q : SelectQuery tbl false) (p : Principal) : SelectQuery tbl true :=
  q.forTenant p.tenant

/-- Scopes an `UpdateQuery` on a text-tenant table to `principal.tenant` (`scoped = true`). -/
def scopeUpdate {tbl : Table (.tenantScoped .text)}
    (q : UpdateQuery tbl false) (p : Principal) : UpdateQuery tbl true :=
  q.forTenant p.tenant

/-- Scopes a `DeleteQuery` on a text-tenant table to `principal.tenant` (`scoped = true`). -/
def scopeDelete {tbl : Table (.tenantScoped .text)}
    (q : DeleteQuery tbl false) (p : Principal) : DeleteQuery tbl true :=
  q.forTenant p.tenant

end Leant.Authz
