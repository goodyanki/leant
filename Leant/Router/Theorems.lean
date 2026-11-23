import Leant.Router.Router

namespace Leant.Router.Theorems

open Leant

/-! ### Helper Lemmas on Method & Static Child Tables -/

theorem findMethodHandler_upsert_self (hs : List (Method × Handler)) (m : Method) (h : Handler) :
    findMethodHandler (upsertMethodHandler hs m h) m = some h := by
  induction hs with
  | nil =>
    simp [upsertMethodHandler, findMethodHandler]
  | cons hd tl ih =>
    rcases hd with ⟨m', h'⟩
    unfold upsertMethodHandler
    by_cases heq : (m' == m) = true
    · simp [heq, findMethodHandler]
    · simp [heq, findMethodHandler, ih]

theorem findMethodHandler_upsert_ne (hs : List (Method × Handler)) (m1 m2 : Method) (h : Handler)
    (hne : m1 ≠ m2) :
    findMethodHandler (upsertMethodHandler hs m1 h) m2 = findMethodHandler hs m2 := by
  induction hs with
  | nil =>
    have hbeq : (m1 == m2) = false := beq_false_of_ne hne
    simp [upsertMethodHandler, findMethodHandler, hbeq]
  | cons hd tl ih =>
    rcases hd with ⟨m', h'⟩
    unfold upsertMethodHandler
    by_cases h1 : (m' == m1) = true
    · have hm' : m' = m1 := eq_of_beq h1
      subst hm'
      have hbeq : (m' == m2) = false := beq_false_of_ne hne
      simp [findMethodHandler, hbeq]
    · by_cases h2 : (m' == m2) = true
      · simp [h1, findMethodHandler, h2]
      · simp [h1, findMethodHandler, h2, ih]

theorem findStatic_upsert_empty (key : String) (f : TrieNode → TrieNode) :
    TrieNode.findStatic (TrieNode.upsertStatic [] key f) key = some (f TrieNode.empty) := by
  simp [TrieNode.upsertStatic, TrieNode.findStatic]

/-! ### Empty Router & Total Lookup Properties -/

theorem lookupMethod_empty (parts : List String) (m : Method) (acc : Array (String × String)) :
    TrieNode.lookupMethod TrieNode.empty parts m acc = none := by
  cases parts <;> simp [TrieNode.empty, TrieNode.lookupMethod, findMethodHandler, TrieNode.findStatic]

theorem pathExists_empty (parts : List String) :
    TrieNode.pathExists TrieNode.empty parts = false := by
  cases parts <;> simp [TrieNode.empty, TrieNode.pathExists, TrieNode.findStatic]

/-- Theorem 1 (Empty Router): An empty router always yields `notFound` for every method and path. -/
theorem lookup_empty_notFound (m : Method) (path : String) :
    Router.empty.lookup m path = .notFound := by
  simp [Router.empty, Router.lookup, lookupMethod_empty, pathExists_empty]

/-! ### Precedence Theorems (Static > `:param` > `*wildcard`) -/

/-- Theorem 2a (Static Precedence, Static-then-Param):
    Registering a static route and then a `:param` route on the same segment always resolves to the static handler. -/
theorem static_precedes_param_first (seg pname : String) (m : Method) (hStatic hParam : Handler)
    (acc : Array (String × String)) :
    let t := (TrieNode.empty.insert [.literal seg] m hStatic).insert [.param pname] m hParam
    TrieNode.lookupMethod t [seg] m acc = some (hStatic, acc) := by
  simp [TrieNode.empty, TrieNode.insert, TrieNode.upsertStatic, upsertMethodHandler,
        TrieNode.lookupMethod, TrieNode.findStatic, findMethodHandler]

/-- Theorem 2b (Static Precedence, Param-then-Static):
    Registering a `:param` route first and a static route second STILL resolves to the static handler. -/
theorem static_precedes_param_second (seg pname : String) (m : Method) (hStatic hParam : Handler)
    (acc : Array (String × String)) :
    let t := (TrieNode.empty.insert [.param pname] m hParam).insert [.literal seg] m hStatic
    TrieNode.lookupMethod t [seg] m acc = some (hStatic, acc) := by
  simp [TrieNode.empty, TrieNode.insert, TrieNode.upsertStatic, upsertMethodHandler,
        TrieNode.lookupMethod, TrieNode.findStatic, findMethodHandler]

/-- Theorem 3a (Param Precedence over Wildcard, Param-then-Wildcard):
    A `:param` route beats a `*wildcard` route on single-segment paths. -/
theorem param_precedes_wildcard_first (seg pname wname : String) (m : Method) (hParam hWild : Handler)
    (acc : Array (String × String)) :
    let t := (TrieNode.empty.insert [.param pname] m hParam).insert [.wildcard wname] m hWild
    TrieNode.lookupMethod t [seg] m acc = some (hParam, acc.push (pname, seg)) := by
  simp [TrieNode.empty, TrieNode.insert, upsertMethodHandler,
        TrieNode.lookupMethod, TrieNode.findStatic, findMethodHandler]

/-- Theorem 3b (Param Precedence over Wildcard, Wildcard-then-Param):
    Regardless of registration order, `:param` beats `*wildcard` on single-segment paths. -/
theorem param_precedes_wildcard_second (seg pname wname : String) (m : Method) (hParam hWild : Handler)
    (acc : Array (String × String)) :
    let t := (TrieNode.empty.insert [.wildcard wname] m hWild).insert [.param pname] m hParam
    TrieNode.lookupMethod t [seg] m acc = some (hParam, acc.push (pname, seg)) := by
  simp [TrieNode.empty, TrieNode.insert, upsertMethodHandler,
        TrieNode.lookupMethod, TrieNode.findStatic, findMethodHandler]

/-! ### Roundtrip Theorem: `lookup (render r ps) = some (h, ps)` (PRD M2.1) -/

/-- Well-formedness predicate for static/param route patterns (no wildcard segment). -/
def NoWildcard : List Segment → Prop
  | [] => True
  | .literal _ :: rest => NoWildcard rest
  | .param _ :: rest => NoWildcard rest
  | .wildcard _ :: _ => False

/-- Number of `:param` placeholders in a route pattern. -/
def paramCount : List Segment → Nat
  | [] => 0
  | .literal _ :: rest => paramCount rest
  | .param _ :: rest => paramCount rest + 1
  | .wildcard _ :: _ => 0

/-- Renders a route segment list by substituting parameter values in order. -/
def renderSegments : List Segment → List String → List String
  | [], _ => []
  | .literal lit :: rest, vals => lit :: renderSegments rest vals
  | .param _ :: rest, v :: vals => v :: renderSegments rest vals
  | .param _ :: rest, [] => "" :: renderSegments rest []
  | .wildcard _ :: _, vals => vals

/-- Computes the expected `(name, value)` pairs extracted when matching `renderSegments`. -/
def expectedParams : List Segment → List String → Array (String × String) → Array (String × String)
  | [], _, acc => acc
  | .literal _ :: rest, vals, acc => expectedParams rest vals acc
  | .param name :: rest, v :: vals, acc => expectedParams rest vals (acc.push (name, v))
  | .param name :: rest, [], acc => expectedParams rest [] (acc.push (name, ""))
  | .wildcard _ :: _, _, acc => acc

/-- Theorem 4 (Roundtrip Invertibility, PRD M2.1):
    For any route `segs` without wildcards and matching parameter list `vals`,
    inserting `(segs, m, h)` into an empty trie and looking up `renderSegments segs vals`
    ALWAYS recovers `(h, expectedParams segs vals acc)`. -/
theorem lookupMethod_insert_render
    (segs : List Segment) (vals : List String) (m : Method) (h : Handler)
    (acc : Array (String × String))
    (hwf : NoWildcard segs)
    (hlen : vals.length = paramCount segs) :
    TrieNode.lookupMethod (TrieNode.empty.insert segs m h) (renderSegments segs vals) m acc
      = some (h, expectedParams segs vals acc) := by
  induction segs generalizing vals acc with
  | nil =>
    simp [TrieNode.empty, TrieNode.insert, upsertMethodHandler,
          renderSegments, expectedParams, TrieNode.lookupMethod, findMethodHandler]
  | cons seg rest ih =>
    cases seg with
    | literal lit =>
      simp only [NoWildcard, paramCount] at hwf hlen
      have hrec := ih vals acc hwf hlen
      unfold TrieNode.empty at hrec
      simp [TrieNode.empty, TrieNode.insert, TrieNode.upsertStatic, renderSegments, expectedParams,
            TrieNode.lookupMethod, TrieNode.findStatic, hrec]
    | param name =>
      simp only [NoWildcard, paramCount] at hwf hlen
      cases vals with
      | nil =>
        simp at hlen
      | cons v vs =>
        simp only [List.length_cons, Nat.add_right_cancel_iff] at hlen
        have hrec := ih vs (acc.push (name, v)) hwf hlen
        unfold TrieNode.empty at hrec
        simp [TrieNode.empty, TrieNode.insert, renderSegments, expectedParams,
              TrieNode.lookupMethod, TrieNode.findStatic, hrec]
    | wildcard _ =>
      simp [NoWildcard] at hwf

/-! ### 405 Method Not Allowed Theorems -/

/-- Theorem 5a (Method Mismatch):
    Looking up a registered route with a different HTTP method yields `none` from `lookupMethod`. -/
theorem lookupMethod_insert_diff_method
    (segs : List Segment) (vals : List String) (m1 m2 : Method) (h : Handler)
    (acc : Array (String × String))
    (hwf : NoWildcard segs)
    (hlen : vals.length = paramCount segs)
    (hne : m1 ≠ m2) :
    TrieNode.lookupMethod (TrieNode.empty.insert segs m1 h) (renderSegments segs vals) m2 acc = none := by
  induction segs generalizing vals acc with
  | nil =>
    have hbeq : (m1 == m2) = false := beq_false_of_ne hne
    simp [TrieNode.empty, TrieNode.insert, upsertMethodHandler,
          renderSegments, TrieNode.lookupMethod, findMethodHandler, hbeq]
  | cons seg rest ih =>
    cases seg with
    | literal lit =>
      simp only [NoWildcard, paramCount] at hwf hlen
      have hrec := ih vals acc hwf hlen
      unfold TrieNode.empty at hrec
      simp [TrieNode.empty, TrieNode.insert, TrieNode.upsertStatic, renderSegments,
            TrieNode.lookupMethod, TrieNode.findStatic, hrec]
    | param name =>
      simp only [NoWildcard, paramCount] at hwf hlen
      cases vals with
      | nil => simp at hlen
      | cons v vs =>
        simp only [List.length_cons, Nat.add_right_cancel_iff] at hlen
        have hrec := ih vs (acc.push (name, v)) hwf hlen
        unfold TrieNode.empty at hrec
        simp [TrieNode.empty, TrieNode.insert, renderSegments,
              TrieNode.lookupMethod, TrieNode.findStatic, hrec]
    | wildcard _ =>
      simp [NoWildcard] at hwf

/-- Theorem 5b (Path Existence):
    `pathExists` returns `true` for any rendered route inserted into the trie, ensuring 405 vs 404. -/
theorem pathExists_insert_render
    (segs : List Segment) (vals : List String) (m : Method) (h : Handler)
    (hwf : NoWildcard segs)
    (hlen : vals.length = paramCount segs) :
    TrieNode.pathExists (TrieNode.empty.insert segs m h) (renderSegments segs vals) = true := by
  induction segs generalizing vals with
  | nil =>
    simp [TrieNode.empty, TrieNode.insert, upsertMethodHandler, renderSegments, TrieNode.pathExists]
  | cons seg rest ih =>
    cases seg with
    | literal lit =>
      simp only [NoWildcard, paramCount] at hwf hlen
      have hrec := ih vals hwf hlen
      unfold TrieNode.empty at hrec
      simp [TrieNode.empty, TrieNode.insert, TrieNode.upsertStatic, renderSegments,
            TrieNode.pathExists, TrieNode.findStatic, hrec]
    | param name =>
      simp only [NoWildcard, paramCount] at hwf hlen
      cases vals with
      | nil => simp at hlen
      | cons v vs =>
        simp only [List.length_cons, Nat.add_right_cancel_iff] at hlen
        have hrec := ih vs hwf hlen
        unfold TrieNode.empty at hrec
        simp [TrieNode.empty, TrieNode.insert, renderSegments,
              TrieNode.pathExists, TrieNode.findStatic, hrec]
    | wildcard _ =>
      simp [NoWildcard] at hwf

end Leant.Router.Theorems
