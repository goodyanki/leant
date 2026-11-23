import Leant.Authz.Basic

namespace Leant.Authz

/-- Structured diff between two `Policy` revisions for security auditing and compliance review. -/
structure PolicyDiff where
  addedRoleRules : List (String × Action × String) := []
  removedRoleRules : List (String × Action × String) := []
  addedOwnerActions : List Action := []
  removedOwnerActions : List Action := []
  addedForbidRules : List (String × Action × String) := []
  removedForbidRules : List (String × Action × String) := []
  deriving Repr, BEq, Inhabited

namespace PolicyDiff

def isEmpty (d : PolicyDiff) : Bool :=
  d.addedRoleRules.isEmpty &&
  d.removedRoleRules.isEmpty &&
  d.addedOwnerActions.isEmpty &&
  d.removedOwnerActions.isEmpty &&
  d.addedForbidRules.isEmpty &&
  d.removedForbidRules.isEmpty

/-- Computes the added and removed grants/forbids between `oldPol` and `newPol`. -/
def compute (oldPol newPol : Policy) : PolicyDiff :=
  { addedRoleRules := newPol.roleRules.filter fun r => !oldPol.roleRules.contains r
  , removedRoleRules := oldPol.roleRules.filter fun r => !newPol.roleRules.contains r
  , addedOwnerActions := newPol.ownerActions.filter fun a => !oldPol.ownerActions.contains a
  , removedOwnerActions := oldPol.ownerActions.filter fun a => !newPol.ownerActions.contains a
  , addedForbidRules := newPol.forbidRules.filter fun r => !oldPol.forbidRules.contains r
  , removedForbidRules := oldPol.forbidRules.filter fun r => !newPol.forbidRules.contains r }

end PolicyDiff
end Leant.Authz
