import Lean
import Leant

/-! ### Negative Compilation Tests (Compile-Time Security Guarantees)
    Each `must_fail_with` block verifies at compile time during `lake build` / `lake test`
    that bypassing tenant scoping, forging scoped query constructors, omitting either side
    of a tenant-scoped JOIN, or skipping `Authorized` proofs is statically rejected by Lean. -/

namespace LeantTest.NegativeCompile

open Lean Elab Command in
elab "must_fail_with " expected:str cmd:command : command => do
  let saved ← get
  let expectedSub := expected.getString
  let mut errText : String := ""
  let mut failed := false
  try
    elabCommand cmd
    let msgs := (← get).messages.toList.filter (·.severity == .error)
    if !msgs.isEmpty then
      failed := true
      for m in msgs do
        errText := errText ++ (← m.data.toString) ++ "\n"
  catch e =>
    failed := true
    errText ← e.toMessageData.toString
  set saved
  if !failed then
    throwError s!"Expected compilation failure containing '{expectedSub}', but command succeeded!"
  if !expectedSub.isEmpty && (errText.splitOn expectedSub).length < 2 then
    throwError s!"Compilation failed as expected, but error did not contain '{expectedSub}'.\nActual error:\n{errText}"

open Leant.Data
open Leant.Authz

leant_table GlobalCatalog "global_catalog" where
  | id   : SqlType.int [pk, auto]
  | code : SqlType.int

leant_tenant_table TenantOrders "tenant_orders" (tenant_id : ScalarType.text) where
  | id        : SqlType.int [pk, auto]
  | tenant_id : SqlType.text
  | code      : SqlType.int

leant_tenant_table TenantInvoices "tenant_invoices" (tenant_id : ScalarType.text) where
  | id        : SqlType.int [pk, auto]
  | tenant_id : SqlType.text
  | code      : SqlType.int

/-! #### 1. Positive controls: properly scoped queries MUST compile -/

def okSelect (pool : Pool SqliteConn) : IO (Array (Array SqlValue)) :=
  pool.select (SelectQuery.fromTable TenantOrders.table |>.forTenant "t1")

def okSelectAfterFilter (pool : Pool SqliteConn) : IO (Array (Array SqlValue)) :=
  pool.select (SelectQuery.fromTable TenantOrders.table |>.forTenant "t1" |>.filter (TenantOrders.code ==. 100))

def okJoinBothScoped (pool : Pool SqliteConn) : IO (Array (Array SqlValue)) :=
  pool.selectJoin <|
    JoinQuery.left TenantOrders.table TenantInvoices.table TenantOrders.code TenantInvoices.code
      |>.forBothTenants "t1"

def okJoinLeftScopedGlobalRight (pool : Pool SqliteConn) : IO (Array (Array SqlValue)) :=
  pool.selectJoin <|
    JoinQuery.inner TenantOrders.table GlobalCatalog.table TenantOrders.code GlobalCatalog.code
      |>.forLeftTenant "t1"

def okJoinGlobalLeftRightScoped (pool : Pool SqliteConn) : IO (Array (Array SqlValue)) :=
  pool.selectJoin <|
    JoinQuery.left GlobalCatalog.table TenantInvoices.table GlobalCatalog.code TenantInvoices.code
      |>.forRightTenant "t1"

/-! #### 2. Negative tests: unscoped single-table queries MUST NOT compile -/

must_fail_with "ExecutableScope"
def badUnscopedSelect (pool : Pool SqliteConn) : IO (Array (Array SqlValue)) :=
  pool.select (SelectQuery.fromTable TenantOrders.table)

must_fail_with "ExecutableScope"
def badUnscopedUpdate (pool : Pool SqliteConn) : IO Unit :=
  pool.update (UpdateQuery.table TenantOrders.table |>.set TenantOrders.code 999)

must_fail_with "ExecutableScope"
def badUnscopedDelete (pool : Pool SqliteConn) : IO Unit :=
  pool.delete (DeleteQuery.fromTable TenantOrders.table)

/-! #### 3. Negative tests: forging `isScoped = true` via raw constructors MUST NOT compile -/

must_fail_with "private"
def badForgedSelect : SelectQuery TenantOrders.table true :=
  { whereClause := none, scopedProof := by trivial }

must_fail_with "private"
def badForgedUpdate : UpdateQuery TenantOrders.table true :=
  { whereClause := none, scopedProof := by trivial }

must_fail_with "private"
def badForgedDelete : DeleteQuery TenantOrders.table true :=
  { whereClause := none, scopedProof := by trivial }

/-! #### 4. Negative tests: missing tenant scope on either side of a JOIN MUST NOT compile -/

must_fail_with "ExecutableScope"
def badJoinUnscopedLeft (pool : Pool SqliteConn) : IO (Array (Array SqlValue)) :=
  pool.selectJoin <|
    JoinQuery.inner TenantOrders.table GlobalCatalog.table TenantOrders.code GlobalCatalog.code

must_fail_with "ExecutableScope"
def badJoinUnscopedRight (pool : Pool SqliteConn) : IO (Array (Array SqlValue)) :=
  pool.selectJoin <|
    JoinQuery.left GlobalCatalog.table TenantInvoices.table GlobalCatalog.code TenantInvoices.code

must_fail_with "ExecutableScope"
def badJoinMissingRightScope (pool : Pool SqliteConn) : IO (Array (Array SqlValue)) :=
  pool.selectJoin <|
    JoinQuery.left TenantOrders.table TenantInvoices.table TenantOrders.code TenantInvoices.code
      |>.forLeftTenant "t1"

must_fail_with "ExecutableScope"
def badJoinMissingLeftScope (pool : Pool SqliteConn) : IO (Array (Array SqlValue)) :=
  pool.selectJoin <|
    JoinQuery.inner TenantOrders.table TenantInvoices.table TenantOrders.code TenantInvoices.code
      |>.forRightTenant "t1"

must_fail_with "private"
def badForgedJoin : JoinQuery TenantOrders.table TenantInvoices.table .int true true :=
  { leftKey := TenantOrders.code, rightKey := TenantInvoices.code
  , leftScopeProof := by trivial, rightScopeProof := by trivial }

/-! #### 5. Negative test: skipping `Authorized` proof MUST NOT compile -/

private def guardedOp (pol : Policy) (p : Principal) (r : Resource)
    (_auth : Authorized pol p .delete r) : IO Unit := pure ()

must_fail_with "Authorized"
def badSkipAuthz (pol : Policy) (p : Principal) (r : Resource) : IO Unit :=
  guardedOp pol p r ()

end LeantTest.NegativeCompile
