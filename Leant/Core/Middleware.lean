import Leant.Core.Context

namespace Leant

/-- Onion-model middleware transforming the downstream `Handler`. -/
abbrev Middleware := Handler → Handler

namespace Middleware

/-- Identity middleware that delegates directly to `next`. -/
def id : Middleware := fun next => next

/-- Composes a list of middlewares in registration order (first registered runs outermost). -/
def chain (mws : Array Middleware) (h : Handler) : Handler :=
  mws.foldr (init := h) fun mw acc => mw acc

end Middleware
end Leant
