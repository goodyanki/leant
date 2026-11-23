import Leant.Data.Query
import Leant.Data.Theorems

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

/-- Type-safe two-table SQL `JOIN` query AST enforcing matching scalar join key types at compile time. -/
structure JoinQuery {m₁ m₂ : TenantMode} (tbl₁ : Table m₁) (tbl₂ : Table m₂) (joinTy : ScalarType) where
  kind : JoinKind := .inner
  leftKey : ColRef tbl₁.schema (.scalar joinTy)
  rightKey : ColRef tbl₂.schema (.scalar joinTy)
  whereClause : Option (JoinPred tbl₁.schema tbl₂.schema) := none
  limitVal : Option Nat := none

namespace JoinQuery

def inner {m₁ m₂ : TenantMode} {joinTy : ScalarType}
    (tbl₁ : Table m₁) (tbl₂ : Table m₂)
    (leftKey : ColRef tbl₁.schema (.scalar joinTy))
    (rightKey : ColRef tbl₂.schema (.scalar joinTy)) : JoinQuery tbl₁ tbl₂ joinTy :=
  { kind := .inner, leftKey, rightKey }

def left {m₁ m₂ : TenantMode} {joinTy : ScalarType}
    (tbl₁ : Table m₁) (tbl₂ : Table m₂)
    (leftKey : ColRef tbl₁.schema (.scalar joinTy))
    (rightKey : ColRef tbl₂.schema (.scalar joinTy)) : JoinQuery tbl₁ tbl₂ joinTy :=
  { kind := .left, leftKey, rightKey }

def filter {m₁ m₂ : TenantMode} {tbl₁ : Table m₁} {tbl₂ : Table m₂} {joinTy : ScalarType}
    (q : JoinQuery tbl₁ tbl₂ joinTy) (p : JoinPred tbl₁.schema tbl₂.schema) :
    JoinQuery tbl₁ tbl₂ joinTy :=
  let next := match q.whereClause with
    | none => p
    | some prev => .and prev p
  { q with whereClause := some next }

def limit {m₁ m₂ : TenantMode} {tbl₁ : Table m₁} {tbl₂ : Table m₂} {joinTy : ScalarType}
    (q : JoinQuery tbl₁ tbl₂ joinTy) (n : Nat) : JoinQuery tbl₁ tbl₂ joinTy :=
  { q with limitVal := some n }

private def qualifiedCols (s : Schema) : List String :=
  s.cols.map fun c => s.tableName.val ++ "." ++ c.name.val

/-- Renders the `JOIN` query into parameterized SQL with fully qualified column projections. -/
def render {m₁ m₂ : TenantMode} {tbl₁ : Table m₁} {tbl₂ : Table m₂} {joinTy : ScalarType}
    (q : JoinQuery tbl₁ tbl₂ joinTy) : RenderedQuery :=
  let proj := joinSep ", " (qualifiedCols tbl₁.schema ++ qualifiedCols tbl₂.schema)
  let baseSql := "SELECT " ++ proj ++
    " FROM " ++ tbl₁.schema.tableName.val ++
    " " ++ q.kind.sql ++ " " ++ tbl₂.schema.tableName.val ++
    " ON " ++ tbl₁.schema.tableName.val ++ "." ++ q.leftKey.ident.val ++
    " = " ++ tbl₂.schema.tableName.val ++ "." ++ q.rightKey.ident.val
  let wherePart : RenderedQuery := match q.whereClause with
    | none => { sql := "", params := #[] }
    | some p =>
      let rp := p.render
      { sql := " WHERE " ++ rp.sql, params := rp.params }
  let limitPart : RenderedQuery := match q.limitVal with
    | none => { sql := "", params := #[] }
    | some n => { sql := " LIMIT ?", params := #[.int n] }
  { sql := baseSql ++ wherePart.sql ++ limitPart.sql
  , params := wherePart.params ++ limitPart.params }

end JoinQuery

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

end Theorems
end Leant.Data
