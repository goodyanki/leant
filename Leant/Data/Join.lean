import Leant.Data.Query
import Leant.Data.Theorems
import Leant.Data.Pool

namespace Leant.Data

/-- Supported SQL JOIN kinds. -/
inductive JoinKind where
  | inner
  | left
  deriving Repr, DecidableEq, Inhabited

namespace JoinKind

def sql : JoinKind → String
  | .inner => "INNER JOIN"
  | .left  => "LEFT JOIN"

end JoinKind

/-- Table-qualified column reference for multi-table JOIN queries. -/
inductive JoinCol (s₁ s₂ : Schema) : SqlType → Type where
  | left  {t : SqlType} (c : ColRef s₁ t) : JoinCol s₁ s₂ t
  | right {t : SqlType} (c : ColRef s₂ t) : JoinCol s₁ s₂ t

namespace JoinCol

def sql {s₁ s₂ : Schema} {t : SqlType} : JoinCol s₁ s₂ t → String
  | .left c  => s₁.tableName.val ++ "." ++ c.ident.val
  | .right c => s₂.tableName.val ++ "." ++ c.ident.val

end JoinCol

/-- Type-safe qualified filter predicate for two-table JOIN queries. -/
inductive JoinPred (s₁ s₂ : Schema) where
  | eq  {t : ScalarType} (col : JoinCol s₁ s₂ (.scalar t)) (v : t.denote) : JoinPred s₁ s₂
  | neq {t : ScalarType} (col : JoinCol s₁ s₂ (.scalar t)) (v : t.denote) : JoinPred s₁ s₂
  | and (a b : JoinPred s₁ s₂) : JoinPred s₁ s₂
  | or  (a b : JoinPred s₁ s₂) : JoinPred s₁ s₂

namespace JoinPred

/-- Evaluates a `JoinPred` against a left row `env₁` and an optional right row `env₂`.
    When `env₂ = none` (an unmatched row produced by `LEFT JOIN`), SQL `NULL` comparisons
    on right-side columns evaluate to `false` (SQL `UNKNOWN` is falsy in `WHERE`/`ON`). -/
def evalOpt {s₁ s₂ : Schema} (env₁ : RowEnv s₁) (env₂ : Option (RowEnv s₂)) : JoinPred s₁ s₂ → Bool
  | .eq (t := t) (.left c) v  => t.beq (env₁.get c) v
  | .eq (t := t) (.right c) v =>
    match env₂ with
    | none    => false
    | some e₂ => t.beq (e₂.get c) v
  | .neq (t := t) (.left c) v => !t.beq (env₁.get c) v
  | .neq (t := t) (.right c) v =>
    match env₂ with
    | none    => false
    | some e₂ => !t.beq (e₂.get c) v
  | .and a b => evalOpt env₁ env₂ a && evalOpt env₁ env₂ b
  | .or  a b => evalOpt env₁ env₂ a || evalOpt env₁ env₂ b

def render {s₁ s₂ : Schema} : JoinPred s₁ s₂ → RenderedQuery
  | .eq (t := t) col v =>
    { sql := "(" ++ col.sql ++ " = ?)", params := #[SqlValue.ofScalar t v] }
  | .neq (t := t) col v =>
    { sql := "(" ++ col.sql ++ " != ?)", params := #[SqlValue.ofScalar t v] }
  | .and a b =>
    let ra := render a
    let rb := render b
    { sql := "(" ++ ra.sql ++ " AND " ++ rb.sql ++ ")", params := ra.params ++ rb.params }
  | .or a b =>
    let ra := render a
    let rb := render b
    { sql := "(" ++ ra.sql ++ " OR " ++ rb.sql ++ ")", params := ra.params ++ rb.params }

end JoinPred

/-- Combines an optional existing `JoinPred` with a new predicate via SQL `AND`. -/
def combineJoinPred {s₁ s₂ : Schema} (existing : Option (JoinPred s₁ s₂)) (cond : JoinPred s₁ s₂) :
    JoinPred s₁ s₂ :=
  match existing with
  | none   => cond
  | some p => .and p cond

/-- Evaluates an optional `WHERE` clause of a `JOIN` against `(env₁, env₂)` (including unmatched `env₂ = none`). -/
def evalJoinWhere {s₁ s₂ : Schema} (env₁ : RowEnv s₁) (env₂ : Option (RowEnv s₂)) :
    Option (JoinPred s₁ s₂) → Bool
  | none   => true
  | some p => p.evalOpt env₁ env₂

/-- Evaluates an optional extra `ON` clause of a `JOIN` against a candidate matched pair `(env₁, env₂)`. -/
def evalJoinOn {s₁ s₂ : Schema} (env₁ : RowEnv s₁) (env₂ : RowEnv s₂) :
    Option (JoinPred s₁ s₂) → Bool
  | none   => true
  | some p => p.evalOpt env₁ (some env₂)

/-- Left-side semantic tenant-isolation invariant carried by `JoinQuery`.
    Covers both matched pairs (`some env₂`) and unmatched `LEFT JOIN` rows (`none`). -/
def JoinLeftScopeInvariant {m₁ m₂ : TenantMode} (tbl₁ : Table m₁) (tbl₂ : Table m₂)
    (leftScoped : Bool) (whereClause : Option (JoinPred tbl₁.schema tbl₂.schema)) : Prop :=
  match m₁, leftScoped with
  | .tenantScoped ty₁, true =>
    ∃ tid₁ : ty₁.denote, ∀ (env₁ : RowEnv tbl₁.schema) (env₂ : Option (RowEnv tbl₂.schema)),
      evalJoinWhere env₁ env₂ whereClause = true → env₁.get tbl₁.tenantCol = tid₁
  | _, _ => True

/-- Right-side semantic tenant-isolation invariant carried by `JoinQuery`.
    Enforced in the `ON` clause so that both `INNER JOIN` and `LEFT JOIN` block cross-tenant
    right rows while `LEFT JOIN` still retains legitimate unmatched left rows. -/
def JoinRightScopeInvariant {m₁ m₂ : TenantMode} (tbl₁ : Table m₁) (tbl₂ : Table m₂)
    (rightScoped : Bool) (onClause : Option (JoinPred tbl₁.schema tbl₂.schema)) : Prop :=
  match m₂, rightScoped with
  | .tenantScoped ty₂, true =>
    ∃ tid₂ : ty₂.denote, ∀ (env₁ : RowEnv tbl₁.schema) (env₂ : RowEnv tbl₂.schema),
      evalJoinOn env₁ env₂ onClause = true → env₂.get tbl₂.tenantCol = tid₂
  | _, _ => True

private theorem joinLeftScope_false {m₁ m₂ : TenantMode} (tbl₁ : Table m₁) (tbl₂ : Table m₂)
    (w : Option (JoinPred tbl₁.schema tbl₂.schema)) :
    JoinLeftScopeInvariant tbl₁ tbl₂ false w := by
  cases m₁ <;> trivial

private theorem joinRightScope_false {m₁ m₂ : TenantMode} (tbl₁ : Table m₁) (tbl₂ : Table m₂)
    (o : Option (JoinPred tbl₁.schema tbl₂.schema)) :
    JoinRightScopeInvariant tbl₁ tbl₂ false o := by
  cases m₂ <;> trivial

private theorem joinLeftScope_combine {m₁ m₂ : TenantMode} {tbl₁ : Table m₁} {tbl₂ : Table m₂}
    {ls : Bool} {w : Option (JoinPred tbl₁.schema tbl₂.schema)}
    (cond : JoinPred tbl₁.schema tbl₂.schema)
    (h : JoinLeftScopeInvariant tbl₁ tbl₂ ls w) :
    JoinLeftScopeInvariant tbl₁ tbl₂ ls (some (combineJoinPred w cond)) := by
  cases m₁ with
  | global => trivial
  | tenantScoped ty₁ =>
    cases ls with
    | false => trivial
    | true =>
      rcases h with ⟨tid₁, htid₁⟩
      refine ⟨tid₁, fun env₁ env₂ heval => ?_⟩
      cases w with
      | none => exact htid₁ env₁ env₂ rfl
      | some p =>
        simp only [combineJoinPred, evalJoinWhere, JoinPred.evalOpt, Bool.and_eq_true] at heval
        exact htid₁ env₁ env₂ heval.1

private theorem joinRightScope_combine {m₁ m₂ : TenantMode} {tbl₁ : Table m₁} {tbl₂ : Table m₂}
    {rs : Bool} {o : Option (JoinPred tbl₁.schema tbl₂.schema)}
    (cond : JoinPred tbl₁.schema tbl₂.schema)
    (h : JoinRightScopeInvariant tbl₁ tbl₂ rs o) :
    JoinRightScopeInvariant tbl₁ tbl₂ rs (some (combineJoinPred o cond)) := by
  cases m₂ with
  | global => trivial
  | tenantScoped ty₂ =>
    cases rs with
    | false => trivial
    | true =>
      rcases h with ⟨tid₂, htid₂⟩
      refine ⟨tid₂, fun env₁ env₂ heval => ?_⟩
      cases o with
      | none => exact htid₂ env₁ env₂ rfl
      | some p =>
        simp only [combineJoinPred, evalJoinOn, JoinPred.evalOpt, Bool.and_eq_true] at heval
        exact htid₂ env₁ env₂ heval.1

private theorem joinLeftScope_forTenant {ty₁ : ScalarType} {m₂ : TenantMode}
    {tbl₁ : Table (.tenantScoped ty₁)} {tbl₂ : Table m₂}
    (w : Option (JoinPred tbl₁.schema tbl₂.schema)) (tid₁ : ty₁.denote) :
    JoinLeftScopeInvariant tbl₁ tbl₂ true (some (match w with
      | none => .eq (.left tbl₁.tenantCol) tid₁
      | some p => .and (.eq (.left tbl₁.tenantCol) tid₁) p)) := by
  refine ⟨tid₁, fun env₁ env₂ heval => ?_⟩
  cases w with
  | none =>
    simp only [evalJoinWhere, JoinPred.evalOpt] at heval
    exact ScalarType.eq_of_beq heval
  | some p =>
    simp only [evalJoinWhere, JoinPred.evalOpt, Bool.and_eq_true] at heval
    exact ScalarType.eq_of_beq heval.1

private theorem joinRightScope_forTenant {m₁ : TenantMode} {ty₂ : ScalarType}
    {tbl₁ : Table m₁} {tbl₂ : Table (.tenantScoped ty₂)}
    (o : Option (JoinPred tbl₁.schema tbl₂.schema)) (tid₂ : ty₂.denote) :
    JoinRightScopeInvariant tbl₁ tbl₂ true (some (match o with
      | none => .eq (.right tbl₂.tenantCol) tid₂
      | some p => .and (.eq (.right tbl₂.tenantCol) tid₂) p)) := by
  refine ⟨tid₂, fun env₁ env₂ heval => ?_⟩
  cases o with
  | none =>
    simp only [evalJoinOn, JoinPred.evalOpt] at heval
    exact ScalarType.eq_of_beq heval
  | some p =>
    simp only [evalJoinOn, JoinPred.evalOpt, Bool.and_eq_true] at heval
    exact ScalarType.eq_of_beq heval.1

/-- Type-safe two-table SQL `JOIN` query AST enforcing matching scalar join key types and
    proof-carrying tenant isolation (`leftScoped`, `rightScoped`) by construction. -/
structure JoinQuery {m₁ m₂ : TenantMode} (tbl₁ : Table m₁) (tbl₂ : Table m₂)
    (joinTy : ScalarType) (leftScoped rightScoped : Bool) where
  private mk ::
  kind : JoinKind := .inner
  leftKey : ColRef tbl₁.schema (.scalar joinTy)
  rightKey : ColRef tbl₂.schema (.scalar joinTy)
  onClause : Option (JoinPred tbl₁.schema tbl₂.schema) := none
  whereClause : Option (JoinPred tbl₁.schema tbl₂.schema) := none
  limitVal : Option Nat := none
  leftScopeProof : JoinLeftScopeInvariant tbl₁ tbl₂ leftScoped whereClause
  rightScopeProof : JoinRightScopeInvariant tbl₁ tbl₂ rightScoped onClause

namespace JoinQuery

def inner {m₁ m₂ : TenantMode} {joinTy : ScalarType}
    (tbl₁ : Table m₁) (tbl₂ : Table m₂)
    (leftKey : ColRef tbl₁.schema (.scalar joinTy))
    (rightKey : ColRef tbl₂.schema (.scalar joinTy)) : JoinQuery tbl₁ tbl₂ joinTy false false :=
  { kind := .inner
  , leftKey
  , rightKey
  , leftScopeProof := joinLeftScope_false tbl₁ tbl₂ none
  , rightScopeProof := joinRightScope_false tbl₁ tbl₂ none }

def left {m₁ m₂ : TenantMode} {joinTy : ScalarType}
    (tbl₁ : Table m₁) (tbl₂ : Table m₂)
    (leftKey : ColRef tbl₁.schema (.scalar joinTy))
    (rightKey : ColRef tbl₂.schema (.scalar joinTy)) : JoinQuery tbl₁ tbl₂ joinTy false false :=
  { kind := .left
  , leftKey
  , rightKey
  , leftScopeProof := joinLeftScope_false tbl₁ tbl₂ none
  , rightScopeProof := joinRightScope_false tbl₁ tbl₂ none }

/-- Injects a top-level `tbl₁.tenant_col = ?` conjunct into `WHERE`, transitioning `leftScoped` to `true`. -/
def forLeftTenant {ty₁ : ScalarType} {m₂ : TenantMode}
    {tbl₁ : Table (.tenantScoped ty₁)} {tbl₂ : Table m₂}
    {joinTy : ScalarType} {rs : Bool}
    (q : JoinQuery tbl₁ tbl₂ joinTy false rs) (tid₁ : ty₁.denote) :
    JoinQuery tbl₁ tbl₂ joinTy true rs :=
  let tenantPred : JoinPred tbl₁.schema tbl₂.schema := .eq (.left tbl₁.tenantCol) tid₁
  let wrapped := match q.whereClause with
    | none   => tenantPred
    | some p => .and tenantPred p
  { kind := q.kind
  , leftKey := q.leftKey
  , rightKey := q.rightKey
  , onClause := q.onClause
  , whereClause := some wrapped
  , limitVal := q.limitVal
  , leftScopeProof := joinLeftScope_forTenant q.whereClause tid₁
  , rightScopeProof := q.rightScopeProof }

/-- Injects a top-level `tbl₂.tenant_col = ?` conjunct into the `ON` clause, transitioning `rightScoped`
    to `true`. Placing the right-side tenant predicate in `ON` isolates both `INNER JOIN` and `LEFT JOIN`
    while preserving legitimate unmatched left rows in a `LEFT JOIN`. -/
def forRightTenant {m₁ : TenantMode} {ty₂ : ScalarType}
    {tbl₁ : Table m₁} {tbl₂ : Table (.tenantScoped ty₂)}
    {joinTy : ScalarType} {ls : Bool}
    (q : JoinQuery tbl₁ tbl₂ joinTy ls false) (tid₂ : ty₂.denote) :
    JoinQuery tbl₁ tbl₂ joinTy ls true :=
  let tenantPred : JoinPred tbl₁.schema tbl₂.schema := .eq (.right tbl₂.tenantCol) tid₂
  let wrapped := match q.onClause with
    | none   => tenantPred
    | some p => .and tenantPred p
  { kind := q.kind
  , leftKey := q.leftKey
  , rightKey := q.rightKey
  , onClause := some wrapped
  , whereClause := q.whereClause
  , limitVal := q.limitVal
  , leftScopeProof := q.leftScopeProof
  , rightScopeProof := joinRightScope_forTenant q.onClause tid₂ }

/-- Scopes both sides of a two-table join to the same tenant ID `tid`. -/
def forBothTenants {ty : ScalarType}
    {tbl₁ : Table (.tenantScoped ty)} {tbl₂ : Table (.tenantScoped ty)}
    {joinTy : ScalarType}
    (q : JoinQuery tbl₁ tbl₂ joinTy false false) (tid : ty.denote) :
    JoinQuery tbl₁ tbl₂ joinTy true true :=
  (q.forLeftTenant tid).forRightTenant tid

/-- Adds a conjunctive `WHERE` predicate while preserving `leftScopeProof` and `rightScopeProof`. -/
def filter {m₁ m₂ : TenantMode} {tbl₁ : Table m₁} {tbl₂ : Table m₂}
    {joinTy : ScalarType} {ls rs : Bool}
    (q : JoinQuery tbl₁ tbl₂ joinTy ls rs) (p : JoinPred tbl₁.schema tbl₂.schema) :
    JoinQuery tbl₁ tbl₂ joinTy ls rs :=
  { q with
    whereClause := some (combineJoinPred q.whereClause p)
    leftScopeProof := joinLeftScope_combine p q.leftScopeProof }

/-- Adds a conjunctive `ON` predicate while preserving `leftScopeProof` and `rightScopeProof`. -/
def onFilter {m₁ m₂ : TenantMode} {tbl₁ : Table m₁} {tbl₂ : Table m₂}
    {joinTy : ScalarType} {ls rs : Bool}
    (q : JoinQuery tbl₁ tbl₂ joinTy ls rs) (p : JoinPred tbl₁.schema tbl₂.schema) :
    JoinQuery tbl₁ tbl₂ joinTy ls rs :=
  { q with
    onClause := some (combineJoinPred q.onClause p)
    rightScopeProof := joinRightScope_combine p q.rightScopeProof }

def limit {m₁ m₂ : TenantMode} {tbl₁ : Table m₁} {tbl₂ : Table m₂}
    {joinTy : ScalarType} {ls rs : Bool}
    (q : JoinQuery tbl₁ tbl₂ joinTy ls rs) (n : Nat) : JoinQuery tbl₁ tbl₂ joinTy ls rs :=
  { q with limitVal := some n }

private def qualifiedCols (s : Schema) : List String :=
  s.cols.map fun c => s.tableName.val ++ "." ++ c.name.val

/-- Renders the `JOIN` query into parameterized SQL with fully qualified column projections
    and exact left-to-right bind parameter ordering (`ON`, `WHERE`, `LIMIT`). -/
def render {m₁ m₂ : TenantMode} {tbl₁ : Table m₁} {tbl₂ : Table m₂}
    {joinTy : ScalarType} {ls rs : Bool}
    (q : JoinQuery tbl₁ tbl₂ joinTy ls rs) : RenderedQuery :=
  let proj := joinSep ", " (qualifiedCols tbl₁.schema ++ qualifiedCols tbl₂.schema)
  let baseSql := "SELECT " ++ proj ++
    " FROM " ++ tbl₁.schema.tableName.val ++
    " " ++ q.kind.sql ++ " " ++ tbl₂.schema.tableName.val ++
    " ON " ++ tbl₁.schema.tableName.val ++ "." ++ q.leftKey.ident.val ++
    " = " ++ tbl₂.schema.tableName.val ++ "." ++ q.rightKey.ident.val
  let onPart : RenderedQuery := match q.onClause with
    | none => { sql := "", params := #[] }
    | some p =>
      let rp := p.render
      { sql := " AND " ++ rp.sql, params := rp.params }
  let wherePart : RenderedQuery := match q.whereClause with
    | none => { sql := "", params := #[] }
    | some p =>
      let rp := p.render
      { sql := " WHERE " ++ rp.sql, params := rp.params }
  let limitPart : RenderedQuery := match q.limitVal with
    | none => { sql := "", params := #[] }
    | some n => { sql := " LIMIT ?", params := #[.int n] }
  { sql := baseSql ++ onPart.sql ++ wherePart.sql ++ limitPart.sql
  , params := onPart.params ++ wherePart.params ++ limitPart.params }

end JoinQuery

namespace Pool

/-- Executes a scope-checked two-table `JOIN` query on a borrowed connection.
    Compile-time proof obligations `ExecutableScope m₁ ls` and `ExecutableScope m₂ rs`
    reject any join missing tenant scope on either tenant-scoped input table. -/
def selectJoinOn {δ : Type} [Driver δ] {m₁ m₂ : TenantMode}
    {tbl₁ : Table m₁} {tbl₂ : Table m₂} {joinTy : ScalarType} {ls rs : Bool}
    (conn : δ) (q : JoinQuery tbl₁ tbl₂ joinTy ls rs)
    (_hl : ExecutableScope m₁ ls := by trivial)
    (_hr : ExecutableScope m₂ rs := by trivial) :
    IO (Array (Array SqlValue)) :=
  Driver.query conn q.render

/-- Executes a scope-checked two-table `JOIN` query using a pooled connection. -/
def selectJoin {δ : Type} [Driver δ] {m₁ m₂ : TenantMode}
    {tbl₁ : Table m₁} {tbl₂ : Table m₂} {joinTy : ScalarType} {ls rs : Bool}
    (pool : Pool δ) (q : JoinQuery tbl₁ tbl₂ joinTy ls rs)
    (hl : ExecutableScope m₁ ls := by trivial)
    (hr : ExecutableScope m₂ rs := by trivial) :
    IO (Array (Array SqlValue)) :=
  pool.withConn fun conn => selectJoinOn conn q hl hr

end Pool

namespace Theorems

theorem joinCol_no_question_mark {s₁ s₂ : Schema} {t : SqlType} (c : JoinCol s₁ s₂ t) :
    countPlaceholders c.sql = 0 := by
  cases c with
  | left col =>
    simp [JoinCol.sql, countPlaceholders_append,
          sqlIdent_no_question_mark s₁.tableName,
          sqlIdent_no_question_mark col.ident,
          show countPlaceholders "." = 0 by decide]
  | right col =>
    simp [JoinCol.sql, countPlaceholders_append,
          sqlIdent_no_question_mark s₂.tableName,
          sqlIdent_no_question_mark col.ident,
          show countPlaceholders "." = 0 by decide]

theorem joinPred_render_arity_sound {s₁ s₂ : Schema} (p : JoinPred s₁ s₂) :
    countPlaceholders (p.render).sql = (p.render).params.size := by
  induction p with
  | eq col _ =>
    simp [JoinPred.render, countPlaceholders_append, joinCol_no_question_mark col,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " = ?)" = 1 by decide]
  | neq col _ =>
    simp [JoinPred.render, countPlaceholders_append, joinCol_no_question_mark col,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " != ?)" = 1 by decide]
  | and _ _ iha ihb =>
    simp [JoinPred.render, countPlaceholders_append, iha, ihb,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " AND " = 0 by decide,
          show countPlaceholders ")" = 0 by decide]
  | or _ _ iha ihb =>
    simp [JoinPred.render, countPlaceholders_append, iha, ihb,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " OR " = 0 by decide,
          show countPlaceholders ")" = 0 by decide]

private theorem countPlaceholders_joinSep_zero' (sep : String) (xs : List String)
    (hsep : countPlaceholders sep = 0)
    (hxs : ∀ x ∈ xs, countPlaceholders x = 0) :
    countPlaceholders (joinSep sep xs) = 0 := by
  induction xs with
  | nil => simp [joinSep, countPlaceholders, countCharList]
  | cons hd tl ih =>
    cases tl with
    | nil => simpa [joinSep] using hxs hd (by simp)
    | cons hd2 tl2 =>
      have hhd : countPlaceholders hd = 0 := hxs hd (by simp)
      have hrest : ∀ x ∈ (hd2 :: tl2), countPlaceholders x = 0 :=
        fun x hx => hxs x (by simp [hx])
      have hrec := ih hrest
      simp only [joinSep, countPlaceholders_append, hhd, hsep, hrec]

/-- Theorem (Full JoinQuery Placeholder Arity Soundness):
    Every rendered `JoinQuery` has exact `?` / parameter arity parity across `ON`, `WHERE`, and `LIMIT`. -/
theorem joinQuery_render_arity_sound {m₁ m₂ : TenantMode}
    {tbl₁ : Table m₁} {tbl₂ : Table m₂} {joinTy : ScalarType} {ls rs : Bool}
    (q : JoinQuery tbl₁ tbl₂ joinTy ls rs) :
    countPlaceholders (q.render).sql = (q.render).params.size := by
  unfold JoinQuery.render
  have hproj : countPlaceholders (joinSep ", " (JoinQuery.qualifiedCols tbl₁.schema ++ JoinQuery.qualifiedCols tbl₂.schema)) = 0 := by
    apply countPlaceholders_joinSep_zero' ", " _ (by decide)
    intro x hx
    simp only [List.mem_append, JoinQuery.qualifiedCols, List.mem_map] at hx
    rcases hx with ⟨c, _, rfl⟩ | ⟨c, _, rfl⟩
    · simp [countPlaceholders_append, sqlIdent_no_question_mark tbl₁.schema.tableName,
            sqlIdent_no_question_mark c.name, show countPlaceholders "." = 0 by decide]
    · simp [countPlaceholders_append, sqlIdent_no_question_mark tbl₂.schema.tableName,
            sqlIdent_no_question_mark c.name, show countPlaceholders "." = 0 by decide]
  have hkind : countPlaceholders q.kind.sql = 0 := by
    cases q.kind <;> decide
  have hbase : countPlaceholders (
      "SELECT " ++ joinSep ", " (JoinQuery.qualifiedCols tbl₁.schema ++ JoinQuery.qualifiedCols tbl₂.schema) ++
      " FROM " ++ tbl₁.schema.tableName.val ++
      " " ++ q.kind.sql ++ " " ++ tbl₂.schema.tableName.val ++
      " ON " ++ tbl₁.schema.tableName.val ++ "." ++ q.leftKey.ident.val ++
      " = " ++ tbl₂.schema.tableName.val ++ "." ++ q.rightKey.ident.val) = 0 := by
    simp [countPlaceholders_append, hproj, hkind,
          sqlIdent_no_question_mark tbl₁.schema.tableName,
          sqlIdent_no_question_mark tbl₂.schema.tableName,
          sqlIdent_no_question_mark q.leftKey.ident,
          sqlIdent_no_question_mark q.rightKey.ident,
          show countPlaceholders "SELECT " = 0 by decide,
          show countPlaceholders " FROM " = 0 by decide,
          show countPlaceholders " " = 0 by decide,
          show countPlaceholders " ON " = 0 by decide,
          show countPlaceholders "." = 0 by decide,
          show countPlaceholders " = " = 0 by decide]
  cases hon : q.onClause <;> cases hwh : q.whereClause <;> cases hlim : q.limitVal <;>
    simp only [countPlaceholders_append, hbase, joinPred_render_arity_sound,
               Array.size_append, Array.size_empty, Array.size_singleton,
               show countPlaceholders "" = 0 by decide,
               show countPlaceholders " AND " = 0 by decide,
               show countPlaceholders " WHERE " = 0 by decide,
               show countPlaceholders " LIMIT ?" = 1 by decide,
               Nat.zero_add, Nat.add_zero]

/-- Theorem (By-Construction Left-Side JOIN Tenant Isolation):
    Every left-scoped `JoinQuery` isolates left rows to a single fixed tenant ID across both
    matched pairs and unmatched `LEFT JOIN` rows. -/
theorem rls_join_left_soundness {ty₁ : ScalarType} {m₂ : TenantMode}
    {tbl₁ : Table (.tenantScoped ty₁)} {tbl₂ : Table m₂}
    {joinTy : ScalarType} {rs : Bool}
    (q : JoinQuery tbl₁ tbl₂ joinTy true rs) :
    ∃ tid₁ : ty₁.denote, ∀ (env₁ : RowEnv tbl₁.schema) (env₂ : Option (RowEnv tbl₂.schema)),
      evalJoinWhere env₁ env₂ q.whereClause = true → env₁.get tbl₁.tenantCol = tid₁ :=
  q.leftScopeProof

/-- Theorem (By-Construction Right-Side JOIN Tenant Isolation):
    Every right-scoped `JoinQuery` restricts matched right rows in `ON` to a single fixed tenant ID. -/
theorem rls_join_right_soundness {m₁ : TenantMode} {ty₂ : ScalarType}
    {tbl₁ : Table m₁} {tbl₂ : Table (.tenantScoped ty₂)}
    {joinTy : ScalarType} {ls : Bool}
    (q : JoinQuery tbl₁ tbl₂ joinTy ls true) :
    ∃ tid₂ : ty₂.denote, ∀ (env₁ : RowEnv tbl₁.schema) (env₂ : RowEnv tbl₂.schema),
      evalJoinOn env₁ env₂ q.onClause = true → env₂.get tbl₂.tenantCol = tid₂ :=
  q.rightScopeProof

private theorem scalarType_beq_self {t : ScalarType} (v : t.denote) : t.beq v v = true := by
  cases t <;> simp [ScalarType.beq]

/-- Theorem (LEFT JOIN Unmatched Left-Row Preservation):
    Scoping a `LEFT JOIN` via `forBothTenants tid` places the right-side tenant check in `ON`,
    so any legitimate unmatched left row belonging to `tid` still satisfies `whereClause` (`env₂ = none`). -/
theorem rls_join_left_preserves_unmatched {ty : ScalarType}
    {tbl₁ : Table (.tenantScoped ty)} {tbl₂ : Table (.tenantScoped ty)}
    {joinTy : ScalarType}
    (lk : ColRef tbl₁.schema (.scalar joinTy))
    (rk : ColRef tbl₂.schema (.scalar joinTy))
    (tid : ty.denote) (env₁ : RowEnv tbl₁.schema)
    (hown : env₁.get tbl₁.tenantCol = tid) :
    evalJoinWhere env₁ none
      (((JoinQuery.left tbl₁ tbl₂ lk rk).forBothTenants tid).whereClause) = true := by
  simp [JoinQuery.left, JoinQuery.forBothTenants, JoinQuery.forLeftTenant, JoinQuery.forRightTenant,
        evalJoinWhere, JoinPred.evalOpt, hown, scalarType_beq_self]

end Theorems
end Leant.Data
