import Leant.Core.Error

namespace Leant.Authz

/-- Authenticated subject (user/service) with tenant and roles. -/
structure Principal where
  id : String
  tenant : String
  roles : List String
  deriving Repr, BEq, DecidableEq, Inhabited

/-- Action performed on a resource. -/
inductive Action where
  | read
  | create
  | update
  | delete
  | custom (name : String)
  deriving Repr, BEq, DecidableEq, Inhabited

/-- Target resource with kind, owner, and tenant. -/
structure Resource where
  kind : String
  owner : String
  tenant : String
  deriving Repr, BEq, DecidableEq, Inhabited

/-- Authorization evaluation result. -/
inductive Decision where
  | allow
  | deny
  deriving Repr, BEq, DecidableEq, Inhabited

/-- Policy v1: RBAC + resource ownership + explicit forbid rules + hard tenant isolation. -/
structure Policy where
  roleRules : List (String × Action × String) := []
  ownerActions : List Action := []
  forbidRules : List (String × Action × String) := []
  deriving Repr, BEq, Inhabited

namespace Policy

/-- Checks whether an explicit forbid rule matches `(principal, action, resource)`. -/
def forbids (pol : Policy) (p : Principal) (a : Action) (r : Resource) : Bool :=
  pol.forbidRules.any fun (role, act, kind) =>
    (role == "*" || p.roles.contains role) && act == a && kind == r.kind

/-- Checks whether an RBAC role rule permits `(principal, action, resource)`. -/
def rolePermits (pol : Policy) (p : Principal) (a : Action) (r : Resource) : Bool :=
  pol.roleRules.any fun (role, act, kind) =>
    p.roles.contains role && act == a && kind == r.kind

end Policy

/-- Pure policy evaluation semantics. -/
def evaluate (pol : Policy) (p : Principal) (a : Action) (r : Resource) : Decision :=
  if r.tenant != p.tenant then .deny
  else if pol.forbids p a r then .deny
  else if pol.rolePermits p a r then .allow
  else if pol.ownerActions.contains a && r.owner == p.id then .allow
  else .deny

/-- Proof-carrying authorization token required by guarded handlers. -/
structure Authorized (pol : Policy) (p : Principal) (a : Action) (r : Resource) : Type where
  proof : evaluate pol p a r = .allow

/-- Evaluates the policy and returns an `Authorized` proof token or `403 Forbidden`. -/
def guard (pol : Policy) (p : Principal) (a : Action) (r : Resource)
    : Except AppError (Authorized pol p a r) :=
  match h : evaluate pol p a r with
  | .allow => .ok ⟨h⟩
  | .deny  => .error (.forbidden "Access denied by policy")

/-! ### Core Security Theorems -/

/-- Theorem 1 (Tenant Isolation): Cross-tenant access is always denied regardless of policy or roles. -/
theorem tenant_isolation (pol : Policy) (p : Principal) (a : Action) (r : Resource)
    (h : r.tenant ≠ p.tenant) :
    evaluate pol p a r = .deny := by
  unfold evaluate
  have hne : (r.tenant != p.tenant) = true := by
    simp [bne, h]
  simp [hne]

/-- Theorem 2 (Deny Overrides): Any matching forbid rule overrides RBAC and ownership grants. -/
theorem deny_overrides (pol : Policy) (p : Principal) (a : Action) (r : Resource)
    (hforbid : pol.forbids p a r = true) :
    evaluate pol p a r = .deny := by
  simp [evaluate, hforbid]

/-- Theorem 3 (Default Deny): An empty policy denies every request. -/
theorem default_deny (p : Principal) (a : Action) (r : Resource) :
    evaluate {} p a r = .deny := by
  unfold evaluate Policy.forbids Policy.rolePermits
  split <;> simp

end Leant.Authz
