import Leant.Data.Expr

namespace Leant.Data

/-- Sort order direction for `ORDER BY`. -/
inductive SortDir where
  | asc
  | desc
  deriving Repr, DecidableEq, Inhabited

namespace SortDir

def sql : SortDir → String
  | .asc  => "ASC"
  | .desc => "DESC"

end SortDir

/-- Combines an optional existing predicate with a new predicate using SQL `AND`. -/
def combineWhere {s : Schema} (existing : Option (Expr s .bool)) (cond : Expr s .bool) : Expr s .bool :=
  match existing with
  | none   => cond
  | some p => .and p cond

/-- Evaluates an optional `WHERE` clause over a row (`none` matches all rows). -/
def evalWhere {s : Schema} (env : RowEnv s) : Option (Expr s .bool) → Bool
  | none   => true
  | some e => e.eval env

/-- Renders an optional `WHERE` clause (`""` when absent, `" WHERE <expr>"` when present). -/
def renderWhere {s : Schema} : Option (Expr s .bool) → RenderedQuery
  | none => { sql := "", params := #[] }
  | some e =>
    let r := e.render
    { sql := " WHERE " ++ r.sql, params := r.params }

/-- Semantic tenant-isolation invariant carried inside query ASTs by construction.
    For `.tenantScoped` tables with `isScoped = true`, proves there exists a fixed tenant ID `tid`
    such that every row satisfying `whereClause` belongs to `tid`. -/
def ScopeInvariant {mode : TenantMode} (tbl : Table mode) (isScoped : Bool)
    (whereClause : Option (Expr tbl.schema .bool)) : Prop :=
  match mode, isScoped with
  | .tenantScoped ty, true =>
    ∃ tid : ty.denote, ∀ env : RowEnv tbl.schema,
      evalWhere env whereClause = true → env.get tbl.tenantCol = tid
  | _, _ => True

private theorem scopeInvariant_false {mode : TenantMode} (tbl : Table mode)
    (w : Option (Expr tbl.schema .bool)) : ScopeInvariant tbl false w := by
  cases mode <;> trivial

private theorem scopeInvariant_combineWhere {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    {w : Option (Expr tbl.schema .bool)} (cond : Expr tbl.schema .bool)
    (h : ScopeInvariant tbl isScoped w) :
    ScopeInvariant tbl isScoped (some (combineWhere w cond)) := by
  cases mode with
  | global => trivial
  | tenantScoped ty =>
    cases isScoped with
    | false => trivial
    | true =>
      rcases h with ⟨tid, htid⟩
      refine ⟨tid, fun env heval => ?_⟩
      cases w with
      | none => exact htid env rfl
      | some p =>
        simp only [combineWhere, evalWhere, Expr.eval, Bool.and_eq_true] at heval
        exact htid env heval.1

private theorem scopeInvariant_forTenant {ty : ScalarType} {tbl : Table (.tenantScoped ty)}
    (w : Option (Expr tbl.schema .bool)) (tid : ty.denote) :
    ScopeInvariant tbl true (some (match w with
      | none => .eq (.col tbl.tenantCol) (.val tid)
      | some p => .and (.eq (.col tbl.tenantCol) (.val tid)) p)) := by
  refine ⟨tid, fun env heval => ?_⟩
  cases w with
  | none =>
    simp only [evalWhere, Expr.eval] at heval
    exact ScalarType.eq_of_beq heval
  | some p =>
    simp only [evalWhere, Expr.eval, Bool.and_eq_true] at heval
    exact ScalarType.eq_of_beq heval.1

/-- Type-safe `SELECT` query AST indexed by `Table mode` and tenant-scope state `isScoped : Bool`.
    The private constructor and `scopedProof` ensure `isScoped = true` cannot be forged and is
    preserved across all builder combinators. -/
structure SelectQuery {mode : TenantMode} (tbl : Table mode) (isScoped : Bool) where
  private mk ::
  whereClause : Option (Expr tbl.schema .bool) := none
  orderByList : List (SqlIdent × SortDir) := []
  limitVal : Option Nat := none
  offsetVal : Option Nat := none
  scopedProof : ScopeInvariant tbl isScoped whereClause

namespace SelectQuery

/-- Starts a `SELECT` query for `tbl` (initially unscoped). -/
def fromTable {mode : TenantMode} (tbl : Table mode) : SelectQuery tbl false :=
  { scopedProof := scopeInvariant_false tbl none }

/-- Adds a conjunctive `WHERE` predicate to the query while preserving `scopedProof`. -/
def filter {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : SelectQuery tbl isScoped) (cond : Expr tbl.schema .bool) : SelectQuery tbl isScoped :=
  { q with
    whereClause := some (combineWhere q.whereClause cond)
    scopedProof := scopeInvariant_combineWhere cond q.scopedProof }

/-- Appends a validated `ORDER BY` column clause. -/
def orderBy {mode : TenantMode} {tbl : Table mode} {isScoped : Bool} {t : SqlType}
    (q : SelectQuery tbl isScoped) (col : ColRef tbl.schema t) (dir : SortDir := .asc) : SelectQuery tbl isScoped :=
  { q with orderByList := q.orderByList ++ [(col.ident, dir)] }

/-- Sets `LIMIT n`. -/
def limit {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : SelectQuery tbl isScoped) (n : Nat) : SelectQuery tbl isScoped :=
  { q with limitVal := some n }

/-- Sets `OFFSET n`. -/
def offset {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : SelectQuery tbl isScoped) (n : Nat) : SelectQuery tbl isScoped :=
  { q with offsetVal := some n }

/-- Injects a top-level `tenant_col = ?` conjunct, transitioning a tenant-scoped query to `isScoped = true`
    with an embedded semantic isolation proof. -/
def forTenant {ty : ScalarType} {tbl : Table (.tenantScoped ty)}
    (q : SelectQuery tbl false) (tid : ty.denote) : SelectQuery tbl true :=
  let tenantPred : Expr tbl.schema .bool := .eq (.col tbl.tenantCol) (.val tid)
  let wrapped := match q.whereClause with
    | none   => tenantPred
    | some p => .and tenantPred p
  { whereClause := some wrapped
  , orderByList := q.orderByList
  , limitVal := q.limitVal
  , offsetVal := q.offsetVal
  , scopedProof := scopeInvariant_forTenant q.whereClause tid }

/-- Evaluates the query's `WHERE` predicate against a denotational row `env`. -/
def evalFilter {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : SelectQuery tbl isScoped) (env : RowEnv tbl.schema) : Bool :=
  evalWhere env q.whereClause

/-- Renders the `SELECT` query into parameterized SQL (all user values bound via `?`). -/
def render {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : SelectQuery tbl isScoped) : RenderedQuery :=
  let baseSql := "SELECT " ++ tbl.schema.allColumnsSql ++ " FROM " ++ tbl.schema.tableName.val
  let wr := renderWhere q.whereClause
  let orderSql :=
    if q.orderByList.isEmpty then ""
    else
      " ORDER BY " ++ joinSep ", "
        (q.orderByList.map fun (ident, dir) => ident.val ++ " " ++ dir.sql)
  let limitPart : RenderedQuery := match q.limitVal with
    | none => { sql := "", params := #[] }
    | some n => { sql := " LIMIT ?", params := #[.int n] }
  let offsetPart : RenderedQuery := match q.offsetVal with
    | none => { sql := "", params := #[] }
    | some n => { sql := " OFFSET ?", params := #[.int n] }
  { sql := baseSql ++ wr.sql ++ orderSql ++ limitPart.sql ++ offsetPart.sql
  , params := wr.params ++ limitPart.params ++ offsetPart.params }

/-- Structural equivalence of two `SelectQuery` values ignoring runtime parameter values. -/
def SameShape {mode : TenantMode} {tbl : Table mode} {s₁ s₂ : Bool}
    (q₁ : SelectQuery tbl s₁) (q₂ : SelectQuery tbl s₂) : Prop :=
  (match q₁.whereClause, q₂.whereClause with
    | none, none => True
    | some e₁, some e₂ => Expr.SameShape e₁ e₂
    | _, _ => False) ∧
  q₁.orderByList = q₂.orderByList ∧
  q₁.limitVal.isSome = q₂.limitVal.isSome ∧
  q₁.offsetVal.isSome = q₂.offsetVal.isSome

end SelectQuery

/-- A single typed column assignment (`col = val`) for `INSERT` or `UPDATE`. -/
structure Assignment (s : Schema) where
  ty : SqlType
  col : ColRef s ty
  value : ty.denote

namespace Assignment

def mk' {s : Schema} {t : SqlType} (col : ColRef s t) (value : t.denote) : Assignment s :=
  ⟨t, col, value⟩

def sqlValue {s : Schema} (a : Assignment s) : SqlValue :=
  SqlValue.ofSqlType a.ty a.value

end Assignment

/-- Type-safe `INSERT INTO` query AST. -/
structure InsertQuery {mode : TenantMode} (tbl : Table mode) where
  assignments : List (Assignment tbl.schema) := []

namespace InsertQuery

def into {mode : TenantMode} (tbl : Table mode) : InsertQuery tbl := {}

def set {mode : TenantMode} {tbl : Table mode} {t : SqlType}
    (q : InsertQuery tbl) (col : ColRef tbl.schema t) (v : t.denote) : InsertQuery tbl :=
  { assignments := q.assignments ++ [Assignment.mk' col v] }

/-- Renders `INSERT INTO tbl (c1, c2) VALUES (?, ?)` with matching bound parameter array. -/
def render {mode : TenantMode} {tbl : Table mode} (q : InsertQuery tbl) : RenderedQuery :=
  let colNames := joinSep ", " (q.assignments.map fun a => a.col.ident.val)
  let placeholders := joinSep ", " (q.assignments.map fun _ => "?")
  let params := (q.assignments.map Assignment.sqlValue).toArray
  { sql := "INSERT INTO " ++ tbl.schema.tableName.val ++
      " (" ++ colNames ++ ") VALUES (" ++ placeholders ++ ")"
  , params := params }

end InsertQuery

/-- Type-safe `UPDATE` query AST with proof-carrying tenant-scope type-state. -/
structure UpdateQuery {mode : TenantMode} (tbl : Table mode) (isScoped : Bool) where
  private mk ::
  assignments : List (Assignment tbl.schema) := []
  whereClause : Option (Expr tbl.schema .bool) := none
  scopedProof : ScopeInvariant tbl isScoped whereClause

namespace UpdateQuery

def table {mode : TenantMode} (tbl : Table mode) : UpdateQuery tbl false :=
  { scopedProof := scopeInvariant_false tbl none }

def set {mode : TenantMode} {tbl : Table mode} {isScoped : Bool} {t : SqlType}
    (q : UpdateQuery tbl isScoped) (col : ColRef tbl.schema t) (v : t.denote) : UpdateQuery tbl isScoped :=
  { q with assignments := q.assignments ++ [Assignment.mk' col v] }

def filter {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : UpdateQuery tbl isScoped) (cond : Expr tbl.schema .bool) : UpdateQuery tbl isScoped :=
  { q with
    whereClause := some (combineWhere q.whereClause cond)
    scopedProof := scopeInvariant_combineWhere cond q.scopedProof }

/-- Injects a top-level `tenant_col = ?` conjunct, transitioning an update query to `isScoped = true`
    with an embedded semantic isolation proof. -/
def forTenant {ty : ScalarType} {tbl : Table (.tenantScoped ty)}
    (q : UpdateQuery tbl false) (tid : ty.denote) : UpdateQuery tbl true :=
  let tenantPred : Expr tbl.schema .bool := .eq (.col tbl.tenantCol) (.val tid)
  let wrapped := match q.whereClause with
    | none   => tenantPred
    | some p => .and tenantPred p
  { assignments := q.assignments
  , whereClause := some wrapped
  , scopedProof := scopeInvariant_forTenant q.whereClause tid }

def evalFilter {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : UpdateQuery tbl isScoped) (env : RowEnv tbl.schema) : Bool :=
  evalWhere env q.whereClause

def render {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : UpdateQuery tbl isScoped) : RenderedQuery :=
  let setSql := joinSep ", " (q.assignments.map fun a => a.col.ident.val ++ " = ?")
  let setParams := (q.assignments.map Assignment.sqlValue).toArray
  let wr := renderWhere q.whereClause
  { sql := "UPDATE " ++ tbl.schema.tableName.val ++ " SET " ++ setSql ++ wr.sql
  , params := setParams ++ wr.params }

end UpdateQuery

/-- Type-safe `DELETE FROM` query AST with proof-carrying tenant-scope type-state. -/
structure DeleteQuery {mode : TenantMode} (tbl : Table mode) (isScoped : Bool) where
  private mk ::
  whereClause : Option (Expr tbl.schema .bool) := none
  scopedProof : ScopeInvariant tbl isScoped whereClause

namespace DeleteQuery

def fromTable {mode : TenantMode} (tbl : Table mode) : DeleteQuery tbl false :=
  { scopedProof := scopeInvariant_false tbl none }

def filter {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : DeleteQuery tbl isScoped) (cond : Expr tbl.schema .bool) : DeleteQuery tbl isScoped :=
  { whereClause := some (combineWhere q.whereClause cond)
  , scopedProof := scopeInvariant_combineWhere cond q.scopedProof }

/-- Injects a top-level `tenant_col = ?` conjunct, transitioning a delete query to `isScoped = true`
    with an embedded semantic isolation proof. -/
def forTenant {ty : ScalarType} {tbl : Table (.tenantScoped ty)}
    (q : DeleteQuery tbl false) (tid : ty.denote) : DeleteQuery tbl true :=
  let tenantPred : Expr tbl.schema .bool := .eq (.col tbl.tenantCol) (.val tid)
  let wrapped := match q.whereClause with
    | none   => tenantPred
    | some p => .and tenantPred p
  { whereClause := some wrapped
  , scopedProof := scopeInvariant_forTenant q.whereClause tid }

def evalFilter {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : DeleteQuery tbl isScoped) (env : RowEnv tbl.schema) : Bool :=
  evalWhere env q.whereClause

def render {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : DeleteQuery tbl isScoped) : RenderedQuery :=
  let wr := renderWhere q.whereClause
  { sql := "DELETE FROM " ++ tbl.schema.tableName.val ++ wr.sql
  , params := wr.params }

end DeleteQuery

/-- Helper predicate defining which queries may execute on a table given its `TenantMode`.
    Global tables allow any query; tenant-scoped tables strictly require `isScoped = true`. -/
abbrev ExecutableScope : TenantMode → Bool → Prop
  | .global,         _     => True
  | .tenantScoped _, true  => True
  | .tenantScoped _, false => False

end Leant.Data
