namespace Leant

/-- HTTP request methods. -/
inductive Method where
  | get
  | post
  | put
  | patch
  | delete
  | head
  | options
  | other (name : String)
  deriving Repr, DecidableEq, Inhabited

namespace Method

/-- Parses an HTTP method string into a `Method`. -/
def ofString (s : String) : Method :=
  match s.toUpper with
  | "GET" => .get
  | "POST" => .post
  | "PUT" => .put
  | "PATCH" => .patch
  | "DELETE" => .delete
  | "HEAD" => .head
  | "OPTIONS" => .options
  | v => .other v

/-- Renders a `Method` as an uppercase HTTP verb. -/
def toString : Method → String
  | .get => "GET"
  | .post => "POST"
  | .put => "PUT"
  | .patch => "PATCH"
  | .delete => "DELETE"
  | .head => "HEAD"
  | .options => "OPTIONS"
  | .other name => name

instance : ToString Method := ⟨Method.toString⟩

end Method
end Leant
