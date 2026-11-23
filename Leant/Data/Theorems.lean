import Leant.Data.Query

namespace Leant.Data.Theorems

open Leant.Data

/-! ### Character & Placeholder Counting Helpers -/

/-- Counts occurrences of a character `ch` in a `List Char`. -/
def countCharList (ch : Char) : List Char → Nat
  | [] => 0
  | c :: rest => (if c == ch then 1 else 0) + countCharList ch rest

/-- Counts SQL `?` bind placeholders in a rendered SQL string. -/
def countPlaceholders (s : String) : Nat :=
  countCharList '?' s.toList

theorem countCharList_append (ch : Char) (xs ys : List Char) :
    countCharList ch (xs ++ ys) = countCharList ch xs + countCharList ch ys := by
  induction xs with
  | nil => simp [countCharList]
  | cons c rest ih =>
    simp [countCharList, ih, Nat.add_assoc]

theorem countPlaceholders_append (a b : String) :
    countPlaceholders (a ++ b) = countPlaceholders a + countPlaceholders b := by
  simp [countPlaceholders, String.toList_append, countCharList_append]

theorem countCharList_zero_of_all_ne (ch : Char) (xs : List Char)
    (h : ∀ c ∈ xs, c ≠ ch) : countCharList ch xs = 0 := by
  induction xs with
  | nil => rfl
  | cons c rest ih =>
    have hc : c ≠ ch := h c (by simp)
    have hbeq : (c == ch) = false := beq_false_of_ne hc
    have hrest : ∀ x ∈ rest, x ≠ ch := fun x hx => h x (by simp [hx])
    simp [countCharList, hbeq, ih hrest]

/-! ### Theorem 1: SQL Identifier Safety -/

private theorem isIdentStart_ne_forbidden (c : Char) (h : isIdentStart c = true) :
    c ≠ '?' ∧ c ≠ '\'' ∧ c ≠ '"' ∧ c ≠ ';' := by
  unfold isIdentStart at h
  refine ⟨?_, ?_, ?_, ?_⟩ <;> (intro heq; subst heq; simp at h)

private theorem isIdentChar_ne_forbidden (c : Char) (h : isIdentChar c = true) :
    c ≠ '?' ∧ c ≠ '\'' ∧ c ≠ '"' ∧ c ≠ ';' := by
  unfold isIdentChar isIdentStart at h
  refine ⟨?_, ?_, ?_, ?_⟩ <;> (intro heq; subst heq; simp at h)

/-- Theorem 1a (Identifier Safety — No Placeholders):
    Every validated `SqlIdent` contains zero `?` characters. -/
theorem sqlIdent_no_question_mark (ident : SqlIdent) :
    countPlaceholders ident.val = 0 := by
  unfold countPlaceholders
  apply countCharList_zero_of_all_ne
  have hv := ident.valid
  unfold isValidSqlIdent at hv
  cases hlist : ident.val.toList with
  | nil => simp [hlist] at hv
  | cons hd tl =>
    simp only [hlist, Bool.and_eq_true, List.all_eq_true] at hv
    intro c hc
    simp only [List.mem_cons] at hc
    rcases hc with rfl | htl
    · exact (isIdentStart_ne_forbidden c hv.1).1
    · exact (isIdentChar_ne_forbidden c (hv.2 c htl)).1

/-- Theorem 1b (Identifier Safety — No Injection Delimiters):
    Every character of a `SqlIdent` is distinct from `?`, `'`, `"`, and `;`. -/
theorem sqlIdent_no_injection_chars (ident : SqlIdent) (c : Char) (hc : c ∈ ident.val.toList) :
    c ≠ '?' ∧ c ≠ '\'' ∧ c ≠ '"' ∧ c ≠ ';' := by
  have hv := ident.valid
  unfold isValidSqlIdent at hv
  cases hlist : ident.val.toList with
  | nil => simp [hlist] at hv
  | cons hd tl =>
    simp only [hlist, Bool.and_eq_true, List.all_eq_true] at hv
    rw [hlist] at hc
    simp only [List.mem_cons] at hc
    rcases hc with rfl | htl
    · exact isIdentStart_ne_forbidden c hv.1
    · exact isIdentChar_ne_forbidden c (hv.2 c htl)

/-! ### Theorems 2 & 3: SQL Injection Non-Interference -/

/-- Theorem 2 (Expression SQL Injection Non-Interference):
    Replacing any runtime parameter values (`Expr.val`, `Expr.like` patterns) with arbitrary
    attacker-controlled inputs leaves the rendered SQL string bit-for-bit identical. -/
theorem expr_render_value_invariant {s : Schema} {t : SqlType} {e₁ e₂ : Expr s t}
    (hsame : Expr.SameShape e₁ e₂) :
    (e₁.render).sql = (e₂.render).sql := by
  induction hsame with
  | col _ => rfl
  | val _ _ => rfl
  | eq _ _ iha ihb => simp [Expr.render, iha, ihb]
  | neq _ _ iha ihb => simp [Expr.render, iha, ihb]
  | lt _ _ iha ihb => simp [Expr.render, iha, ihb]
  | le _ _ iha ihb => simp [Expr.render, iha, ihb]
  | gt _ _ iha ihb => simp [Expr.render, iha, ihb]
  | ge _ _ iha ihb => simp [Expr.render, iha, ihb]
  | like _ _ _ iha => simp [Expr.render, iha]
  | and _ _ iha ihb => simp [Expr.render, iha, ihb]
  | or _ _ iha ihb => simp [Expr.render, iha, ihb]
  | not _ iha => simp [Expr.render, iha]
  | isNull _ iha => simp [Expr.render, iha]
  | isNotNull _ iha => simp [Expr.render, iha]

/-- Theorem 3 (SelectQuery SQL Injection Non-Interference):
    Any two `SelectQuery` ASTs with the same shape render to the exact same SQL string
    regardless of runtime user values (including `WHERE`, `LIKE`, `LIMIT`, and `OFFSET`). -/
theorem select_render_value_invariant {mode : TenantMode} {tbl : Table mode} {s₁ s₂ : Bool}
    {q₁ : SelectQuery tbl s₁} {q₂ : SelectQuery tbl s₂}
    (hsame : SelectQuery.SameShape q₁ q₂) :
    (q₁.render).sql = (q₂.render).sql := by
  rcases hsame with ⟨hwhere, hord, hlim, hoff⟩
  unfold SelectQuery.render
  have hwSql : (renderWhere q₁.whereClause).sql = (renderWhere q₂.whereClause).sql := by
    cases h1 : q₁.whereClause <;> cases h2 : q₂.whereClause
    · rfl
    · simp [h1, h2] at hwhere
    · simp [h1, h2] at hwhere
    · simp [h1, h2] at hwhere
      simp [renderWhere, expr_render_value_invariant hwhere]
  cases hlim1 : q₁.limitVal <;> cases hlim2 : q₂.limitVal <;>
    cases hoff1 : q₁.offsetVal <;> cases hoff2 : q₂.offsetVal <;>
    simp_all

/-! ### Theorems 4 & 5: Placeholder Arity Soundness -/

private theorem countPlaceholders_joinSep_zero (sep : String) (xs : List String)
    (hsep : countPlaceholders sep = 0)
    (hxs : ∀ x ∈ xs, countPlaceholders x = 0) :
    countPlaceholders (joinSep sep xs) = 0 := by
  induction xs with
  | nil => simp [joinSep, countPlaceholders, countCharList]
  | cons hd tl ih =>
    cases tl with
    | nil =>
      simpa [joinSep] using hxs hd (by simp)
    | cons hd2 tl2 =>
      have hhd : countPlaceholders hd = 0 := hxs hd (by simp)
      have hrest : ∀ x ∈ (hd2 :: tl2), countPlaceholders x = 0 :=
        fun x hx => hxs x (by simp [hx])
      have hrec := ih hrest
      simp only [joinSep, countPlaceholders_append, hhd, hsep, hrec]

private theorem countPlaceholders_joinSep_one (sep : String) (xs : List String)
    (hsep : countPlaceholders sep = 0)
    (hxs : ∀ x ∈ xs, countPlaceholders x = 1) :
    countPlaceholders (joinSep sep xs) = xs.length := by
  induction xs with
  | nil => simp [joinSep, countPlaceholders, countCharList]
  | cons hd tl ih =>
    cases tl with
    | nil =>
      simpa [joinSep] using hxs hd (by simp)
    | cons hd2 tl2 =>
      have hhd : countPlaceholders hd = 1 := hxs hd (by simp)
      have hrest : ∀ x ∈ (hd2 :: tl2), countPlaceholders x = 1 :=
        fun x hx => hxs x (by simp [hx])
      have hrec := ih hrest
      simp only [joinSep, countPlaceholders_append, hhd, hsep, hrec, List.length_cons]
      omega

/-- Theorem 4 (Expression Placeholder Arity Soundness):
    Every rendered expression has exactly as many `?` placeholders as bound parameters. -/
theorem expr_render_arity_sound {s : Schema} {t : SqlType} (e : Expr s t) :
    countPlaceholders (e.render).sql = (e.render).params.size := by
  induction e with
  | col c =>
    simpa [Expr.render] using sqlIdent_no_question_mark c.ident
  | val _ =>
    simp [Expr.render, countPlaceholders, countCharList]
  | eq _ _ iha ihb =>
    simp [Expr.render, countPlaceholders_append, iha, ihb,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " = " = 0 by decide,
          show countPlaceholders ")" = 0 by decide]
  | neq _ _ iha ihb =>
    simp [Expr.render, countPlaceholders_append, iha, ihb,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " != " = 0 by decide,
          show countPlaceholders ")" = 0 by decide]
  | lt _ _ iha ihb =>
    simp [Expr.render, countPlaceholders_append, iha, ihb,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " < " = 0 by decide,
          show countPlaceholders ")" = 0 by decide]
  | le _ _ iha ihb =>
    simp [Expr.render, countPlaceholders_append, iha, ihb,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " <= " = 0 by decide,
          show countPlaceholders ")" = 0 by decide]
  | gt _ _ iha ihb =>
    simp [Expr.render, countPlaceholders_append, iha, ihb,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " > " = 0 by decide,
          show countPlaceholders ")" = 0 by decide]
  | ge _ _ iha ihb =>
    simp [Expr.render, countPlaceholders_append, iha, ihb,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " >= " = 0 by decide,
          show countPlaceholders ")" = 0 by decide]
  | like _ _ iha =>
    simp [Expr.render, countPlaceholders_append, iha,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " LIKE ?)" = 1 by decide]
  | and _ _ iha ihb =>
    simp [Expr.render, countPlaceholders_append, iha, ihb,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " AND " = 0 by decide,
          show countPlaceholders ")" = 0 by decide]
  | or _ _ iha ihb =>
    simp [Expr.render, countPlaceholders_append, iha, ihb,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " OR " = 0 by decide,
          show countPlaceholders ")" = 0 by decide]
  | not _ iha =>
    simp [Expr.render, countPlaceholders_append, iha,
          show countPlaceholders "(NOT " = 0 by decide,
          show countPlaceholders ")" = 0 by decide]
  | isNull _ iha =>
    simp [Expr.render, countPlaceholders_append, iha,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " IS NULL)" = 0 by decide]
  | isNotNull _ iha =>
    simp [Expr.render, countPlaceholders_append, iha,
          show countPlaceholders "(" = 0 by decide,
          show countPlaceholders " IS NOT NULL)" = 0 by decide]

theorem renderWhere_arity_sound {s : Schema} (w : Option (Expr s .bool)) :
    countPlaceholders (renderWhere w).sql = (renderWhere w).params.size := by
  cases w with
  | none => simp [renderWhere, countPlaceholders, countCharList]
  | some e =>
    simp [renderWhere, countPlaceholders_append, expr_render_arity_sound e,
          show countPlaceholders " WHERE " = 0 by decide]

/-- Theorem 5a (SelectQuery Placeholder Arity Soundness):
    Every rendered `SELECT` statement has `countPlaceholders sql = params.size`. -/
theorem select_render_arity_sound {mode : TenantMode} {tbl : Table mode} {isScoped : Bool}
    (q : SelectQuery tbl isScoped) :
    countPlaceholders (q.render).sql = (q.render).params.size := by
  unfold SelectQuery.render
  have hcols : countPlaceholders tbl.schema.allColumnsSql = 0 := by
    unfold Schema.allColumnsSql
    apply countPlaceholders_joinSep_zero ", " _ (by decide)
    intro x hx
    simp only [List.mem_map] at hx
    rcases hx with ⟨c, _, rfl⟩
    exact sqlIdent_no_question_mark c.name
  have htbl : countPlaceholders tbl.schema.tableName.val = 0 :=
    sqlIdent_no_question_mark tbl.schema.tableName
  have hbase : countPlaceholders ("SELECT " ++ tbl.schema.allColumnsSql ++ " FROM " ++ tbl.schema.tableName.val) = 0 := by
    simp [countPlaceholders_append, hcols, htbl,
          show countPlaceholders "SELECT " = 0 by decide,
          show countPlaceholders " FROM " = 0 by decide]
  have hord : countPlaceholders (
      if q.orderByList.isEmpty then ""
      else " ORDER BY " ++ joinSep ", "
        (q.orderByList.map fun (ident, dir) => ident.val ++ " " ++ dir.sql)) = 0 := by
    split
    · decide
    · rw [countPlaceholders_append, show countPlaceholders " ORDER BY " = 0 by decide]
      simp only [Nat.zero_add]
      apply countPlaceholders_joinSep_zero ", " _ (by decide)
      intro x hx
      simp only [List.mem_map] at hx
      rcases hx with ⟨⟨ident, dir⟩, _, rfl⟩
      have hdir : countPlaceholders dir.sql = 0 := by cases dir <;> decide
      simp [countPlaceholders_append, sqlIdent_no_question_mark ident, hdir,
            show countPlaceholders " " = 0 by decide]
  cases hlim : q.limitVal <;> cases hoff : q.offsetVal <;>
    simp only [countPlaceholders_append, hbase, hord, renderWhere_arity_sound q.whereClause,
               Array.size_append, Array.size_empty, Array.size_singleton,
               show countPlaceholders "" = 0 by decide,
               show countPlaceholders " LIMIT ?" = 1 by decide,
               show countPlaceholders " OFFSET ?" = 1 by decide,
               Nat.zero_add, Nat.add_zero]

/-- Theorem 5b (InsertQuery Placeholder Arity Soundness):
    Every rendered `INSERT` statement has `countPlaceholders sql = params.size`. -/
theorem insert_render_arity_sound {mode : TenantMode} {tbl : Table mode}
    (q : InsertQuery tbl) :
    countPlaceholders (q.render).sql = (q.render).params.size := by
  unfold InsertQuery.render
  have htbl : countPlaceholders tbl.schema.tableName.val = 0 :=
    sqlIdent_no_question_mark tbl.schema.tableName
  have hcols : countPlaceholders (joinSep ", " (q.assignments.map fun a => a.col.ident.val)) = 0 := by
    apply countPlaceholders_joinSep_zero ", " _ (by decide)
    intro x hx
    simp only [List.mem_map] at hx
    rcases hx with ⟨a, _, rfl⟩
    exact sqlIdent_no_question_mark a.col.ident
  have hph : countPlaceholders (joinSep ", " (q.assignments.map fun _ => "?")) =
      q.assignments.length := by
    have h := countPlaceholders_joinSep_one ", " (q.assignments.map fun _ => "?") (by decide) (by
      intro x hx
      simp only [List.mem_map] at hx
      rcases hx with ⟨_, _, rfl⟩
      decide)
    simpa [List.length_map] using h
  simp [countPlaceholders_append, htbl, hcols, hph,
        show countPlaceholders "INSERT INTO " = 0 by decide,
        show countPlaceholders " (" = 0 by decide,
        show countPlaceholders ") VALUES (" = 0 by decide,
        show countPlaceholders ")" = 0 by decide]

/-! ### Theorems 6, 7 & 8: Semantic Row-Level Tenant Isolation (RLS) -/

/-- Theorem 6 (Semantic RLS Soundness for `SELECT`):
    For ANY tenant-isScoped table, ANY user `WHERE` clause (even containing arbitrary `OR`, `NOT`,
    or tautologies), and ANY row `env`, if `(q.forTenant tid).evalFilter env = true`,
    then `env.get tbl.tenantCol = tid`. -/
theorem rls_select_soundness {ty : ScalarType} {tbl : Table (.tenantScoped ty)}
    (q : SelectQuery tbl false) (tid : ty.denote) (env : RowEnv tbl.schema)
    (hmatch : (q.forTenant tid).evalFilter env = true) :
    env.get tbl.tenantCol = tid := by
  unfold SelectQuery.evalFilter SelectQuery.forTenant evalWhere at hmatch
  cases h : q.whereClause with
  | none =>
    simp [h, Expr.eval] at hmatch
    exact ScalarType.eq_of_beq hmatch
  | some p =>
    simp [h, Expr.eval, Bool.and_eq_true] at hmatch
    exact ScalarType.eq_of_beq hmatch.1

/-- Theorem 7 (Semantic RLS Soundness for `UPDATE`):
    A tenant-isScoped `UPDATE` can never match a row belonging to another tenant. -/
theorem rls_update_soundness {ty : ScalarType} {tbl : Table (.tenantScoped ty)}
    (q : UpdateQuery tbl false) (tid : ty.denote) (env : RowEnv tbl.schema)
    (hmatch : (q.forTenant tid).evalFilter env = true) :
    env.get tbl.tenantCol = tid := by
  unfold UpdateQuery.evalFilter UpdateQuery.forTenant evalWhere at hmatch
  cases h : q.whereClause with
  | none =>
    simp [h, Expr.eval] at hmatch
    exact ScalarType.eq_of_beq hmatch
  | some p =>
    simp [h, Expr.eval, Bool.and_eq_true] at hmatch
    exact ScalarType.eq_of_beq hmatch.1

/-- Theorem 8 (Semantic RLS Soundness for `DELETE`):
    A tenant-isScoped `DELETE` can never match a row belonging to another tenant. -/
theorem rls_delete_soundness {ty : ScalarType} {tbl : Table (.tenantScoped ty)}
    (q : DeleteQuery tbl false) (tid : ty.denote) (env : RowEnv tbl.schema)
    (hmatch : (q.forTenant tid).evalFilter env = true) :
    env.get tbl.tenantCol = tid := by
  unfold DeleteQuery.evalFilter DeleteQuery.forTenant evalWhere at hmatch
  cases h : q.whereClause with
  | none =>
    simp [h, Expr.eval] at hmatch
    exact ScalarType.eq_of_beq hmatch
  | some p =>
    simp [h, Expr.eval, Bool.and_eq_true] at hmatch
    exact ScalarType.eq_of_beq hmatch.1

end Leant.Data.Theorems
