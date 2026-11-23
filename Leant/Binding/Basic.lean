import Lean.Data.Json
import Leant.Core.Context

namespace Leant.Binding

/-- A `String` proven to be non-empty (`val.length > 0`). -/
structure NonEmpty where
  val : String
  proof : val.length > 0

namespace NonEmpty

def ofString (s : String) : Except String NonEmpty :=
  if h : s.length > 0 then
    .ok ⟨s, h⟩
  else
    .error "string must be non-empty"

instance : BEq NonEmpty := ⟨fun a b => a.val == b.val⟩
instance : ToString NonEmpty := ⟨fun x => x.val⟩
instance : Repr NonEmpty := ⟨fun x p => Repr.reprPrec x.val p⟩
instance : Lean.ToJson NonEmpty := ⟨fun x => Lean.Json.str x.val⟩

instance : Lean.FromJson NonEmpty where
  fromJson? j := do
    let s ← Lean.FromJson.fromJson? (α := String) j
    ofString s

instance : FromParam NonEmpty where
  parseParam s := (ofString s).toOption

end NonEmpty

/-- A `String` proven to have length at most `maxLen` (`val.length ≤ maxLen`). -/
structure Bounded (maxLen : Nat) where
  val : String
  proof : val.length ≤ maxLen

namespace Bounded

def ofString {maxLen : Nat} (s : String) : Except String (Bounded maxLen) :=
  if h : s.length ≤ maxLen then
    .ok ⟨s, h⟩
  else
    .error s!"string length {s.length} exceeds maximum {maxLen}"

instance {n : Nat} : BEq (Bounded n) := ⟨fun a b => a.val == b.val⟩
instance {n : Nat} : ToString (Bounded n) := ⟨fun x => x.val⟩
instance {n : Nat} : Repr (Bounded n) := ⟨fun x p => Repr.reprPrec x.val p⟩
instance {n : Nat} : Lean.ToJson (Bounded n) := ⟨fun x => Lean.Json.str x.val⟩

instance {n : Nat} : Lean.FromJson (Bounded n) where
  fromJson? j := do
    let s ← Lean.FromJson.fromJson? (α := String) j
    ofString s

instance {n : Nat} : FromParam (Bounded n) where
  parseParam s := (ofString s).toOption

end Bounded

/-- A `String` proven to satisfy `0 < val.length ≤ maxLen`. -/
structure NonEmptyBounded (maxLen : Nat) where
  val : String
  nonEmpty : val.length > 0
  bounded : val.length ≤ maxLen

namespace NonEmptyBounded

def ofString {maxLen : Nat} (s : String) : Except String (NonEmptyBounded maxLen) :=
  if h1 : s.length > 0 then
    if h2 : s.length ≤ maxLen then
      .ok ⟨s, h1, h2⟩
    else
      .error s!"string length {s.length} exceeds maximum {maxLen}"
  else
    .error "string must be non-empty"

instance {n : Nat} : BEq (NonEmptyBounded n) := ⟨fun a b => a.val == b.val⟩
instance {n : Nat} : ToString (NonEmptyBounded n) := ⟨fun x => x.val⟩
instance {n : Nat} : Repr (NonEmptyBounded n) := ⟨fun x p => Repr.reprPrec x.val p⟩
instance {n : Nat} : Lean.ToJson (NonEmptyBounded n) := ⟨fun x => Lean.Json.str x.val⟩

instance {n : Nat} : Lean.FromJson (NonEmptyBounded n) where
  fromJson? j := do
    let s ← Lean.FromJson.fromJson? (α := String) j
    ofString s

instance {n : Nat} : FromParam (NonEmptyBounded n) where
  parseParam s := (ofString s).toOption

end NonEmptyBounded

/-- Pure structural validator for RFC-lite email addresses (no whitespace, single `@`, dotted domain). -/
def isValidEmail (s : String) : Bool :=
  if s.isEmpty || s.length > 254 then
    false
  else if s.toList.any (fun (c : Char) => c.isWhitespace || c.toNat < 32) then
    false
  else
    match s.splitOn "@" with
    | [localPart, domain] =>
      !localPart.isEmpty &&
      !domain.isEmpty &&
      !domain.startsWith "." &&
      !domain.endsWith "." &&
      (domain.splitOn ".").length >= 2 &&
      (domain.splitOn ".").all (fun label => !label.isEmpty)
    | _ => false

/-- A `String` proven to satisfy `isValidEmail val = true`. -/
structure Email where
  val : String
  valid : isValidEmail val = true

namespace Email

def ofString (s : String) : Except String Email :=
  if h : isValidEmail s = true then
    .ok ⟨s, h⟩
  else
    .error s!"invalid email address: {s}"

instance : BEq Email := ⟨fun a b => a.val == b.val⟩
instance : ToString Email := ⟨fun x => x.val⟩
instance : Repr Email := ⟨fun x p => Repr.reprPrec x.val p⟩
instance : Lean.ToJson Email := ⟨fun x => Lean.Json.str x.val⟩

instance : Lean.FromJson Email where
  fromJson? j := do
    let s ← Lean.FromJson.fromJson? (α := String) j
    ofString s

instance : FromParam Email where
  parseParam s := (ofString s).toOption

end Email

/-- A `Nat` proven to be strictly positive (`val > 0`). -/
structure PositiveNat where
  val : Nat
  pos : val > 0

namespace PositiveNat

def ofNat (n : Nat) : Except String PositiveNat :=
  if h : n > 0 then
    .ok ⟨n, h⟩
  else
    .error "value must be > 0"

instance : BEq PositiveNat := ⟨fun a b => a.val == b.val⟩
instance : ToString PositiveNat := ⟨fun x => toString x.val⟩
instance : Repr PositiveNat := ⟨fun x p => Repr.reprPrec x.val p⟩
instance : Lean.ToJson PositiveNat := ⟨fun x => Lean.ToJson.toJson x.val⟩

instance : Lean.FromJson PositiveNat where
  fromJson? j := do
    let n ← Lean.FromJson.fromJson? (α := Nat) j
    ofNat n

instance : FromParam PositiveNat where
  parseParam s := s.toNat?.bind fun n => (ofNat n).toOption

end PositiveNat

end Leant.Binding
