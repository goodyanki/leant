import Leant.Core.Method
import Leant.Core.Context
import Leant.Core.Middleware

namespace Leant

/-- Parsed segment of a route pattern. -/
inductive Segment where
  | literal (text : String)
  | param (name : String)
  | wildcard (name : String)
  deriving Repr, BEq, DecidableEq, Inhabited

/-- Splits an HTTP path into non-empty `/` segments. -/
def splitPath (path : String) : List String :=
  (path.splitOn "/").filter (fun s => !s.isEmpty)

/-- Parses a route pattern string (e.g. `"/users/:id/*rest"`) into `Segment`s. -/
def parsePattern (pattern : String) : List Segment :=
  (splitPath pattern).map fun seg =>
    if seg.startsWith ":" then
      .param (seg.drop 1).toString
    else if seg.startsWith "*" then
      .wildcard (seg.drop 1).toString
    else
      .literal seg

/-- A registered HTTP route entry. -/
structure Route where
  method : Method
  pattern : String
  segments : List Segment
  handler : Handler

/-- Pure total route matcher returning extracted parameters if matched. -/
def matchSegments : List Segment → List String → Array (String × String) → Option (Array (String × String))
  | [], [], acc => some acc
  | [.wildcard name], rest, acc =>
    some (acc.push (name, String.intercalate "/" rest))
  | .wildcard name :: _, rest, acc =>
    some (acc.push (name, String.intercalate "/" rest))
  | .literal lit :: segs, part :: parts, acc =>
    if lit == part then matchSegments segs parts acc else none
  | .param name :: segs, part :: parts, acc =>
    matchSegments segs parts (acc.push (name, part))
  | _, _, _ => none

/-- Specificity score so static literals beat `:param` which beats `*wildcard`. -/
def patternPriority (segs : List Segment) : Nat :=
  segs.foldl (init := 0) fun acc seg =>
    match seg with
    | .literal _  => acc * 4 + 3
    | .param _    => acc * 4 + 2
    | .wildcard _ => acc * 4 + 1

/-- Result of routing a `(method, path)` pair. -/
inductive RouteMatch where
  | matched (handler : Handler) (params : Array (String × String))
  | methodNotAllowed
  | notFound

/-- Pure route table supporting static, `:param`, and `*wildcard` patterns. -/
structure Router where
  routes : Array Route := #[]
  deriving Inhabited

namespace Router

def empty : Router := { routes := #[] }

/-- Joins a group prefix and sub-pattern cleanly. -/
def joinPaths (prefixPath subPath : String) : String :=
  let p := splitPath prefixPath
  let s := splitPath subPath
  "/" ++ String.intercalate "/" (p ++ s)

/-- Registers a new route into the router. -/
def add (r : Router) (method : Method) (pattern : String) (handler : Handler) : Router :=
  let segs := parsePattern pattern
  { routes := r.routes.push { method, pattern, segments := segs, handler } }

/-- Resolves the highest-priority matching route for `(method, path)`.
    Returns `methodNotAllowed` when the path matches another method, or `notFound` otherwise. -/
def lookup (r : Router) (method : Method) (path : String) : RouteMatch :=
  let parts := splitPath path
  let best := r.routes.foldl
    (init := ((none : Option (Nat × Handler × Array (String × String))), false))
    fun (bestMatch, anyPathMatched) route =>
      match matchSegments route.segments parts #[] with
      | none => (bestMatch, anyPathMatched)
      | some params =>
        if route.method == method then
          let prio := patternPriority route.segments
          match bestMatch with
          | none => (some (prio, route.handler, params), true)
          | some (bestPrio, _, _) =>
            if prio > bestPrio then
              (some (prio, route.handler, params), true)
            else
              (bestMatch, true)
        else
          (bestMatch, true)
  match best with
  | (some (_, h, params), _) => .matched h params
  | (none, true) => .methodNotAllowed
  | (none, false) => .notFound

end Router
end Leant
