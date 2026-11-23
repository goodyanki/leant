import Leant.Data.Schema

namespace Leant.Data

/-- Deeply embedded, type-safe SQL expression GADT indexed by `Schema` and `SqlType`. -/
inductive Expr (s : Schema) : SqlType → Type where
  | col       {t : SqlType}    (c : ColRef s t) : Expr s t
  | val       {t : SqlType}    (v : t.denote) : Expr s t
  | eq        {t : ScalarType} (lhs rhs : Expr s (.scalar t)) : Expr s .bool
  | neq       {t : ScalarType} (lhs rhs : Expr s (.scalar t)) : Expr s .bool
  | lt        (lhs rhs : Expr s .int) : Expr s .bool
  | le        (lhs rhs : Expr s .int) : Expr s .bool
  | gt        (lhs rhs : Expr s .int) : Expr s .bool
  | ge        (lhs rhs : Expr s .int) : Expr s .bool
  | like      (lhs : Expr s .text) (pattern : String) : Expr s .bool
  | and       (lhs rhs : Expr s .bool) : Expr s .bool
  | or        (lhs rhs : Expr s .bool) : Expr s .bool
  | not       (e : Expr s .bool) : Expr s .bool
  | isNull    {t : ScalarType} (e : Expr s (.nullable t)) : Expr s .bool
  | isNotNull {t : ScalarType} (e : Expr s (.nullable t)) : Expr s .bool

namespace Expr

/-- Pure denotational semantics of an expression evaluated over a row `env`. -/
def eval {s : Schema} (env : RowEnv s) : {t : SqlType} → Expr s t → t.denote
  | _, .col c          => env.get c
  | _, .val v          => v
  | _, .eq (t := t) a b  => t.beq (eval env a) (eval env b)
  | _, .neq (t := t) a b => !(t.beq (eval env a) (eval env b))
  | _, .lt a b         => decide (eval env a < eval env b)
  | _, .le a b         => decide (eval env a ≤ eval env b)
  | _, .gt a b         => decide (eval env a > eval env b)
  | _, .ge a b         => decide (eval env a ≥ eval env b)
  | _, .like _ _       => true -- abstract over-approximation for SQL LIKE semantics
  | _, .and a b        => eval env a && eval env b
  | _, .or a b         => eval env a || eval env b
  | _, .not a          => !(eval env a)
  | _, .isNull a       => (eval env a).isNone
  | _, .isNotNull a    => (eval env a).isSome

/-- Total parameterized SQL renderer for expressions.
    Every runtime value (including `LIKE` patterns) is emitted as a `?` placeholder + bound parameter. -/
def render {s : Schema} : {t : SqlType} → Expr s t → RenderedQuery
  | _, .col c =>
    { sql := c.ident.val, params := #[] }
  | t, .val v =>
    { sql := "?", params := #[SqlValue.ofSqlType t v] }
  | _, .eq a b =>
    let ra := render a
    let rb := render b
    { sql := "(" ++ ra.sql ++ " = " ++ rb.sql ++ ")", params := ra.params ++ rb.params }
  | _, .neq a b =>
    let ra := render a
    let rb := render b
    { sql := "(" ++ ra.sql ++ " != " ++ rb.sql ++ ")", params := ra.params ++ rb.params }
  | _, .lt a b =>
    let ra := render a
    let rb := render b
    { sql := "(" ++ ra.sql ++ " < " ++ rb.sql ++ ")", params := ra.params ++ rb.params }
  | _, .le a b =>
    let ra := render a
    let rb := render b
    { sql := "(" ++ ra.sql ++ " <= " ++ rb.sql ++ ")", params := ra.params ++ rb.params }
  | _, .gt a b =>
    let ra := render a
    let rb := render b
    { sql := "(" ++ ra.sql ++ " > " ++ rb.sql ++ ")", params := ra.params ++ rb.params }
  | _, .ge a b =>
    let ra := render a
    let rb := render b
    { sql := "(" ++ ra.sql ++ " >= " ++ rb.sql ++ ")", params := ra.params ++ rb.params }
  | _, .like a pat =>
    let ra := render a
    { sql := "(" ++ ra.sql ++ " LIKE ?)", params := ra.params.push (.text pat) }
  | _, .and a b =>
    let ra := render a
    let rb := render b
    { sql := "(" ++ ra.sql ++ " AND " ++ rb.sql ++ ")", params := ra.params ++ rb.params }
  | _, .or a b =>
    let ra := render a
    let rb := render b
    { sql := "(" ++ ra.sql ++ " OR " ++ rb.sql ++ ")", params := ra.params ++ rb.params }
  | _, .not a =>
    let ra := render a
    { sql := "(NOT " ++ ra.sql ++ ")", params := ra.params }
  | _, .isNull a =>
    let ra := render a
    { sql := "(" ++ ra.sql ++ " IS NULL)", params := ra.params }
  | _, .isNotNull a =>
    let ra := render a
    { sql := "(" ++ ra.sql ++ " IS NOT NULL)", params := ra.params }

/-- Structural equivalence of two expressions ignoring runtime values in `val` and `like` leaves. -/
inductive SameShape {s : Schema} : {t : SqlType} → Expr s t → Expr s t → Prop where
  | col {t : SqlType} (c : ColRef s t) : SameShape (.col c) (.col c)
  | val {t : SqlType} (v₁ v₂ : t.denote) : SameShape (.val v₁) (.val v₂)
  | eq {t : ScalarType} {a₁ a₂ b₁ b₂ : Expr s (.scalar t)} :
      SameShape a₁ a₂ → SameShape b₁ b₂ → SameShape (.eq a₁ b₁) (.eq a₂ b₂)
  | neq {t : ScalarType} {a₁ a₂ b₁ b₂ : Expr s (.scalar t)} :
      SameShape a₁ a₂ → SameShape b₁ b₂ → SameShape (.neq a₁ b₁) (.neq a₂ b₂)
  | lt : SameShape a₁ a₂ → SameShape b₁ b₂ → SameShape (.lt a₁ b₁) (.lt a₂ b₂)
  | le : SameShape a₁ a₂ → SameShape b₁ b₂ → SameShape (.le a₁ b₁) (.le a₂ b₂)
  | gt : SameShape a₁ a₂ → SameShape b₁ b₂ → SameShape (.gt a₁ b₁) (.gt a₂ b₂)
  | ge : SameShape a₁ a₂ → SameShape b₁ b₂ → SameShape (.ge a₁ b₁) (.ge a₂ b₂)
  | like (p₁ p₂ : String) : SameShape a₁ a₂ → SameShape (.like a₁ p₁) (.like a₂ p₂)
  | and : SameShape a₁ a₂ → SameShape b₁ b₂ → SameShape (.and a₁ b₁) (.and a₂ b₂)
  | or : SameShape a₁ a₂ → SameShape b₁ b₂ → SameShape (.or a₁ b₁) (.or a₂ b₂)
  | not : SameShape a₁ a₂ → SameShape (.not a₁) (.not a₂)
  | isNull {t : ScalarType} {a₁ a₂ : Expr s (.nullable t)} :
      SameShape a₁ a₂ → SameShape (.isNull a₁) (.isNull a₂)
  | isNotNull {t : ScalarType} {a₁ a₂ : Expr s (.nullable t)} :
      SameShape a₁ a₂ → SameShape (.isNotNull a₁) (.isNotNull a₂)

end Expr

/-! ### Ergonomic DSL Helpers & Operators -/

namespace ColRef

/-- Compares a scalar column with a literal value for equality (`col ==. v`). -/
def eqVal {s : Schema} {t : ScalarType} (c : ColRef s (.scalar t)) (v : t.denote) : Expr s .bool :=
  .eq (.col c) (.val v)

/-- Compares a scalar column with a literal value for inequality (`col !=. v`). -/
def neqVal {s : Schema} {t : ScalarType} (c : ColRef s (.scalar t)) (v : t.denote) : Expr s .bool :=
  .neq (.col c) (.val v)

def ltVal {s : Schema} (c : ColRef s .int) (v : Int) : Expr s .bool :=
  .lt (.col c) (.val v)

def leVal {s : Schema} (c : ColRef s .int) (v : Int) : Expr s .bool :=
  .le (.col c) (.val v)

def gtVal {s : Schema} (c : ColRef s .int) (v : Int) : Expr s .bool :=
  .gt (.col c) (.val v)

def geVal {s : Schema} (c : ColRef s .int) (v : Int) : Expr s .bool :=
  .ge (.col c) (.val v)

def like {s : Schema} (c : ColRef s .text) (pat : String) : Expr s .bool :=
  .like (.col c) pat

def isNull {s : Schema} {t : ScalarType} (c : ColRef s (.nullable t)) : Expr s .bool :=
  .isNull (.col c)

def isNotNull {s : Schema} {t : ScalarType} (c : ColRef s (.nullable t)) : Expr s .bool :=
  .isNotNull (.col c)

end ColRef

infixl:50 " ==. " => ColRef.eqVal
infixl:50 " !=. " => ColRef.neqVal
infixl:50 " <. "  => ColRef.ltVal
infixl:50 " <=. " => ColRef.leVal
infixl:50 " >. "  => ColRef.gtVal
infixl:50 " >=. " => ColRef.geVal
infixr:35 " &&. " => Expr.and
infixr:30 " ||. " => Expr.or
prefix:75 "!. "   => Expr.not

end Leant.Data
