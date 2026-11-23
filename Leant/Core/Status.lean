namespace Leant

/-- HTTP status code wrapper with common named constants. -/
structure Status where
  code : UInt16
  deriving Repr, BEq, DecidableEq, Inhabited

namespace Status

def ok : Status := ⟨200⟩
def created : Status := ⟨201⟩
def accepted : Status := ⟨202⟩
def noContent : Status := ⟨204⟩
def movedPermanently : Status := ⟨301⟩
def found : Status := ⟨302⟩
def badRequest : Status := ⟨400⟩
def unauthorized : Status := ⟨401⟩
def forbidden : Status := ⟨403⟩
def notFound : Status := ⟨404⟩
def methodNotAllowed : Status := ⟨405⟩
def conflict : Status := ⟨409⟩
def payloadTooLarge : Status := ⟨413⟩
def tooManyRequests : Status := ⟨429⟩
def internalServerError : Status := ⟨500⟩
def serviceUnavailable : Status := ⟨503⟩

instance : ToString Status := ⟨fun s => toString s.code⟩

end Status
end Leant
