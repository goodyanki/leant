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

/-- Result of routing a `(method, path)` pair. -/
inductive RouteMatch where
  | matched (handler : Handler) (params : Array (String × String))
  | methodNotAllowed
  | notFound

def upsertMethodHandler (hs : List (Method × Handler)) (m : Method) (h : Handler)
    : List (Method × Handler) :=
  match hs with
  | [] => [(m, h)]
  | (m', h') :: rest =>
    if m' == m then (m, h) :: rest
    else (m', h') :: upsertMethodHandler rest m h

def findMethodHandler (hs : List (Method × Handler)) (m : Method) : Option Handler :=
  match hs with
  | [] => none
  | (m', h) :: rest =>
    if m' == m then some h else findMethodHandler rest m

/-- Segment prefix/radix trie node supporting static, `:param`, and `*wildcard` routes.
    Lookup strictly prioritizes static literals > `:param` > `*wildcard`, with backtracking. -/
inductive TrieNode where
  | mk
      (handlers : List (Method × Handler))
      (statics  : List (String × TrieNode))
      (param    : Option (String × TrieNode))
      (wildcard : Option (String × List (Method × Handler)))

namespace TrieNode

def empty : TrieNode := .mk [] [] none none

instance : Inhabited TrieNode := ⟨empty⟩

def upsertStatic
    (statics : List (String × TrieNode))
    (key : String)
    (update : TrieNode → TrieNode) : List (String × TrieNode) :=
  match statics with
  | [] => [(key, update empty)]
  | (k, child) :: rest =>
    if k == key then (k, update child) :: rest
    else (k, child) :: upsertStatic rest key update

def findStatic (statics : List (String × TrieNode)) (key : String) : Option TrieNode :=
  match statics with
  | [] => none
  | (k, child) :: rest =>
    if k == key then some child else findStatic rest key

/-- Total structural insertion of a route segment list into the trie. -/
def insert (node : TrieNode) (segs : List Segment) (method : Method) (handler : Handler) : TrieNode :=
  match node, segs with
  | .mk hs statics param wild, [] =>
    .mk (upsertMethodHandler hs method handler) statics param wild
  | .mk hs statics param wild, .literal lit :: rest =>
    let statics' := upsertStatic statics lit (fun child => insert child rest method handler)
    .mk hs statics' param wild
  | .mk hs statics param wild, .param name :: rest =>
    let child := match param with
      | some (_, existing) => existing
      | none => empty
    .mk hs statics (some (name, insert child rest method handler)) wild
  | .mk hs statics param wild, .wildcard name :: _ =>
    let whs := match wild with
      | some (_, existing) => upsertMethodHandler existing method handler
      | none => [(method, handler)]
    .mk hs statics param (some (name, whs))

/-- Total lookup matching a specific `method`, with static > `:param` > `*wildcard` priority and backtracking. -/
def lookupMethod
    (node : TrieNode)
    (parts : List String)
    (method : Method)
    (acc : Array (String × String)) : Option (Handler × Array (String × String)) :=
  match node, parts with
  | .mk hs _ _ wild, [] =>
    match findMethodHandler hs method with
    | some h => some (h, acc)
    | none =>
      match wild with
      | some (wname, whs) =>
        (findMethodHandler whs method).map fun h => (h, acc.push (wname, ""))
      | none => none
  | .mk _ statics param wild, part :: rest =>
    let fromStatic :=
      match findStatic statics part with
      | some child => lookupMethod child rest method acc
      | none => none
    match fromStatic with
    | some res => some res
    | none =>
      let fromParam :=
        match param with
        | some (pname, child) => lookupMethod child rest method (acc.push (pname, part))
        | none => none
      match fromParam with
      | some res => some res
      | none =>
        match wild with
        | some (wname, whs) =>
          (findMethodHandler whs method).map fun h =>
            (h, acc.push (wname, String.intercalate "/" (part :: rest)))
        | none => none

/-- Returns `true` if any HTTP method is registered for `parts` (used to distinguish 405 from 404). -/
def pathExists (node : TrieNode) (parts : List String) : Bool :=
  match node, parts with
  | .mk hs _ _ wild, [] =>
    !hs.isEmpty || (match wild with | some (_, whs) => !whs.isEmpty | none => false)
  | .mk _ statics param wild, part :: rest =>
    let staticHit :=
      match findStatic statics part with
      | some child => pathExists child rest
      | none => false
    if staticHit then true
    else
      let paramHit :=
        match param with
        | some (_, child) => pathExists child rest
        | none => false
      if paramHit then true
      else
        match wild with
        | some (_, whs) => !whs.isEmpty
        | none => false

end TrieNode

/-- Segment-trie router supporting static, `:param`, and `*wildcard` patterns with 404/405 dispatch. -/
structure Router where
  root : TrieNode := TrieNode.empty
  deriving Inhabited

namespace Router

def empty : Router := { root := TrieNode.empty }

/-- Joins a group prefix and sub-pattern cleanly. -/
def joinPaths (prefixPath subPath : String) : String :=
  let p := splitPath prefixPath
  let s := splitPath subPath
  "/" ++ String.intercalate "/" (p ++ s)

/-- Registers a new route into the segment trie. -/
def add (r : Router) (method : Method) (pattern : String) (handler : Handler) : Router :=
  { root := r.root.insert (parsePattern pattern) method handler }

/-- Resolves the highest-priority matching route for `(method, path)`.
    Returns `methodNotAllowed` when the path matches another method, or `notFound` otherwise. -/
def lookup (r : Router) (method : Method) (path : String) : RouteMatch :=
  let parts := splitPath path
  match r.root.lookupMethod parts method #[] with
  | some (h, params) => .matched h params
  | none =>
    if r.root.pathExists parts then .methodNotAllowed
    else .notFound

end Router
end Leant
