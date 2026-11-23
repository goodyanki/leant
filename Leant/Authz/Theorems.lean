import Leant.Authz.Basic
import Leant.Data.Query
import Leant.Data.Theorems

namespace Leant.Authz.Theorems

open Leant.Authz
open Leant.Data

/-- Theorem 4 (Authorized Implies Same Tenant):
    Every `Authorized pol p a r` proof token statically guarantees `r.tenant = p.tenant`. -/
theorem authorized_implies_same_tenant (pol : Policy) (p : Principal) (a : Action) (r : Resource)
    (auth : Authorized pol p a r) :
    r.tenant = p.tenant := by
  match decEq r.tenant p.tenant with
  | isTrue h => exact h
  | isFalse hne =>
    have hdeny := tenant_isolation pol p a r hne
    have hallow := auth.proof
    rw [hdeny] at hallow
    cases hallow

/-- Theorem 5 (Guard Soundness):
    If `guard pol p a r` succeeds with `auth`, then both `evaluate pol p a r = .allow`
    and `r.tenant = p.tenant` hold. -/
theorem guard_sound (pol : Policy) (p : Principal) (a : Action) (r : Resource)
    (auth : Authorized pol p a r)
    (_h : guard pol p a r = .ok auth) :
    evaluate pol p a r = .allow ∧ r.tenant = p.tenant :=
  ⟨auth.proof, authorized_implies_same_tenant pol p a r auth⟩

/-- Theorem 6 (Role Rule Monotonicity):
    Adding a new `roleRule` without changing forbid rules never revokes an existing `.allow` decision. -/
theorem role_monotonicity (pol : Policy) (rule : String × Action × String)
    (p : Principal) (a : Action) (r : Resource)
    (hallow : evaluate pol p a r = .allow) :
    evaluate { pol with roleRules := rule :: pol.roleRules } p a r = .allow := by
  unfold evaluate at hallow ⊢
  cases ht : (r.tenant != p.tenant)
  · simp only [ht, Bool.false_eq_true, ↓reduceIte] at hallow ⊢
    cases hf : pol.forbids p a r
    · have hf' : ({ pol with roleRules := rule :: pol.roleRules } : Policy).forbids p a r = false := hf
      simp only [hf, hf', Bool.false_eq_true, ↓reduceIte] at hallow ⊢
      cases hr : pol.rolePermits p a r
      · simp only [hr, Bool.false_eq_true, ↓reduceIte] at hallow
        cases hr' : ({ pol with roleRules := rule :: pol.roleRules } : Policy).rolePermits p a r
        · simp only [Bool.false_eq_true, ↓reduceIte]
          exact hallow
        · simp
      · have hr' : ({ pol with roleRules := rule :: pol.roleRules } : Policy).rolePermits p a r = true := by
          unfold Policy.rolePermits at hr ⊢
          simp only [List.any_cons, hr, Bool.or_true]
        simp [hr']
    · simp [hf] at hallow
  · simp [ht] at hallow

/-- Theorem 7 (Forbid Rule Monotonicity):
    Adding a new `forbidRule` never turns a `.deny` decision into `.allow`. -/
theorem forbid_monotonicity (pol : Policy) (rule : String × Action × String)
    (p : Principal) (a : Action) (r : Resource)
    (hdeny : evaluate pol p a r = .deny) :
    evaluate { pol with forbidRules := rule :: pol.forbidRules } p a r = .deny := by
  unfold evaluate at hdeny ⊢
  cases ht : (r.tenant != p.tenant)
  · simp only [ht, Bool.false_eq_true, ↓reduceIte] at hdeny ⊢
    cases hf' : ({ pol with forbidRules := rule :: pol.forbidRules } : Policy).forbids p a r
    · have hf : pol.forbids p a r = false := by
        cases h : pol.forbids p a r with
        | false => rfl
        | true =>
          unfold Policy.forbids at h hf'
          simp only [List.any_cons, h, Bool.or_true] at hf'
          exact hf'
      simp only [hf, Bool.false_eq_true, ↓reduceIte] at hdeny
      simp only [Bool.false_eq_true, ↓reduceIte]
      have hrEq : ({ pol with forbidRules := rule :: pol.forbidRules } : Policy).rolePermits p a r =
          pol.rolePermits p a r := rfl
      rw [hrEq]
      exact hdeny
    · simp
  · simp

/-- Theorem 8 (Role Grant Cannot Escalate Across Tenants):
    Granting arbitrary additional roles to a principal can never authorize cross-tenant access. -/
theorem role_grant_no_cross_tenant_escalation (pol : Policy) (p : Principal)
    (extraRoles : List String) (a : Action) (r : Resource)
    (hne : r.tenant ≠ p.tenant) :
    evaluate pol { p with roles := extraRoles ++ p.roles } a r = .deny :=
  tenant_isolation pol { p with roles := extraRoles ++ p.roles } a r hne

/-- Theorem 9 (Role Grant Cannot Bypass Existing Forbids):
    If a principal is currently forbidden by policy, granting additional roles cannot bypass the forbid. -/
theorem role_grant_no_forbid_bypass (pol : Policy) (p : Principal)
    (extraRoles : List String) (a : Action) (r : Resource)
    (hforbid : pol.forbids p a r = true) :
    evaluate pol { p with roles := p.roles ++ extraRoles } a r = .deny := by
  apply deny_overrides
  unfold Policy.forbids at hforbid ⊢
  simp only [List.any_eq_true, Bool.and_eq_true, Bool.or_eq_true] at hforbid ⊢
  rcases hforbid with ⟨⟨role, act, kind⟩, hmem, ⟨hrole, hact⟩, hkind⟩
  refine ⟨(role, act, kind), hmem, ⟨?_, hact⟩, hkind⟩
  rcases hrole with hw | hcont
  · exact Or.inl hw
  · apply Or.inr
    rw [List.contains_iff_mem] at hcont ⊢
    exact List.mem_append_left extraRoles hcont

/-- Theorem 10 (End-to-End Authz + ORM RLS Tenant Alignment):
    Any row matching a principal-scoped `SelectQuery` (`q.forTenant p.tenant`) is guaranteed to
    belong to `p.tenant`, aligning database RLS with `authorized_implies_same_tenant`. -/
theorem rls_principal_alignment {tbl : Table (.tenantScoped .text)}
    (q : SelectQuery tbl false) (p : Principal) (row : RowEnv tbl.schema)
    (hmatch : (q.forTenant p.tenant).evalFilter row = true) :
    row.get tbl.tenantCol = p.tenant :=
  Leant.Data.Theorems.rls_select_soundness q p.tenant row hmatch

end Leant.Authz.Theorems
