import Leant.App

namespace Leant

/-- Computes the curried handler return type for a typed list of path parameter types. -/
@[reducible]
def CurriedHandler : List Type → Type
  | []      => HandlerM Response
  | α :: ts => α → CurriedHandler ts

/-- A handler whose arguments match the route's declared path parameter types at compile time. -/
abbrev TypedHandler (ts : List Type) : Type :=
  Context → CurriedHandler ts

/-- Computes the curried URL renderer function type for a typed route. -/
@[reducible]
def RenderFn : List Type → Type
  | []      => String
  | α :: ts => α → RenderFn ts

/-- Compile-time typed route specification.
    Guarantees at compile time that handler parameter types match the route's path parameters. -/
inductive TypedPath : List Type → Type 1 where
  | nil : TypedPath []
  | lit (seg : String) (rest : TypedPath ts) : TypedPath ts
  | param (name : String) (α : Type) [FromParam α] [ToString α] (rest : TypedPath ts) :
      TypedPath (α :: ts)

namespace TypedPath

/-- Converts a `TypedPath` into a list of route segments (e.g. `["users", ":id", "posts", ":slug"]`). -/
def toSegments : {ts : List Type} → TypedPath ts → List String
  | _, .nil => []
  | _, .lit seg rest => seg :: rest.toSegments
  | _, @TypedPath.param _ name _ _ _ rest => (":" ++ name) :: rest.toSegments

/-- Converts a `TypedPath` into a pattern string (e.g. `"/users/:id/posts/:slug"`). -/
def toPattern {ts : List Type} (p : TypedPath ts) : String :=
  "/" ++ String.intercalate "/" p.toSegments

private def renderAux : {ts : List Type} → TypedPath ts → List String → RenderFn ts
  | _, .nil, acc => "/" ++ String.intercalate "/" acc.reverse
  | _, .lit seg rest, acc => renderAux rest (seg :: acc)
  | _, @TypedPath.param _ _ _ _ _ rest, acc => fun v => renderAux rest (toString v :: acc)

/-- Type-safe URL builder whose arguments match the route's path parameter types. -/
def render {ts : List Type} (p : TypedPath ts) : RenderFn ts :=
  renderAux p []

private def applyParams : {ts : List Type} → TypedPath ts → Context → CurriedHandler ts → HandlerM Response
  | _, .nil, _, action => action
  | _, .lit _ rest, c, action => applyParams rest c action
  | _, @TypedPath.param _ name α _ _ rest, c, fn => do
    let v ← c.param! name (α := α)
    applyParams rest c (fn v)

/-- Wraps a `TypedHandler ts` into a standard `Handler` that parses and feeds all path parameters. -/
def toHandler {ts : List Type} (p : TypedPath ts) (h : TypedHandler ts) : Handler :=
  fun c => applyParams p c (h c)

end TypedPath

/-! ### Declarative `route!` Macro DSL -/

declare_syntax_cat leant_route_seg
syntax str : leant_route_seg
syntax "(" ident ":" term ")" : leant_route_seg

/-- Compile-time checked route path DSL:
    `route! / "users" / (id : Nat) / "posts" / (slug : String)`
    produces a `TypedPath [Nat, String]`. -/
syntax "route!" ("/" leant_route_seg)* : term

macro_rules
  | `(route!) => `(TypedPath.nil)
  | `(route! / $s:str $[/ $rest:leant_route_seg]*) =>
    `(TypedPath.lit $s (route! $[/ $rest]*))
  | `(route! / ($id:ident : $ty:term) $[/ $rest:leant_route_seg]*) =>
    let nameStr := Lean.Syntax.mkStrLit id.getId.toString
    `(TypedPath.param $nameStr $ty (route! $[/ $rest]*))

namespace App

/-- Registers a compile-time typed route on an `App`. -/
def routeTyped {ts : List Type} (app : App) (method : Method) (p : TypedPath ts) (h : TypedHandler ts) : App :=
  app.route method p.toPattern (p.toHandler h)

def getTyped {ts : List Type} (app : App) (p : TypedPath ts) (h : TypedHandler ts) : App :=
  app.routeTyped .get p h

def postTyped {ts : List Type} (app : App) (p : TypedPath ts) (h : TypedHandler ts) : App :=
  app.routeTyped .post p h

def putTyped {ts : List Type} (app : App) (p : TypedPath ts) (h : TypedHandler ts) : App :=
  app.routeTyped .put p h

def patchTyped {ts : List Type} (app : App) (p : TypedPath ts) (h : TypedHandler ts) : App :=
  app.routeTyped .patch p h

def deleteTyped {ts : List Type} (app : App) (p : TypedPath ts) (h : TypedHandler ts) : App :=
  app.routeTyped .delete p h

end App

namespace Group

/-- Registers a compile-time typed route inside a `Group`. -/
def routeTyped {ts : List Type} (g : Group) (method : Method) (p : TypedPath ts) (h : TypedHandler ts) : Group :=
  g.route method p.toPattern (p.toHandler h)

def getTyped {ts : List Type} (g : Group) (p : TypedPath ts) (h : TypedHandler ts) : Group :=
  g.routeTyped .get p h

def postTyped {ts : List Type} (g : Group) (p : TypedPath ts) (h : TypedHandler ts) : Group :=
  g.routeTyped .post p h

def putTyped {ts : List Type} (g : Group) (p : TypedPath ts) (h : TypedHandler ts) : Group :=
  g.routeTyped .put p h

def patchTyped {ts : List Type} (g : Group) (p : TypedPath ts) (h : TypedHandler ts) : Group :=
  g.routeTyped .patch p h

def deleteTyped {ts : List Type} (g : Group) (p : TypedPath ts) (h : TypedHandler ts) : Group :=
  g.routeTyped .delete p h

end Group

end Leant
