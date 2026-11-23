import Leant.Core.Status
import Leant.Core.Types

namespace Leant

/-- Structured application error automatically rendered into an HTTP response. -/
inductive AppError where
  | badRequest (msg : String)
  | unauthorized (msg : String := "Unauthorized")
  | forbidden (msg : String := "Forbidden")
  | notFound (msg : String := "Not Found")
  | methodNotAllowed (msg : String := "Method Not Allowed")
  | requestTimeout (msg : String := "Request Timeout")
  | conflict (msg : String)
  | payloadTooLarge (msg : String := "Payload Too Large")
  | unprocessableEntity (msg : String)
  | internal (msg : String := "Internal Server Error")
  | custom (status : Status) (msg : String)
  deriving Repr, BEq, Inhabited

namespace AppError

private def escapeJsonString (s : String) : String :=
  s.foldl (init := "") fun acc c =>
    match c with
    | '"'  => acc ++ "\\\""
    | '\\' => acc ++ "\\\\"
    | '\n' => acc ++ "\\n"
    | '\r' => acc ++ "\\r"
    | '\t' => acc ++ "\\t"
    | _    => acc.push c

/-- HTTP status corresponding to an `AppError`. -/
def status : AppError → Status
  | .badRequest _          => Status.badRequest
  | .unauthorized _        => Status.unauthorized
  | .forbidden _           => Status.forbidden
  | .notFound _            => Status.notFound
  | .methodNotAllowed _    => Status.methodNotAllowed
  | .requestTimeout _      => Status.requestTimeout
  | .conflict _            => Status.conflict
  | .payloadTooLarge _     => Status.payloadTooLarge
  | .unprocessableEntity _ => Status.unprocessableEntity
  | .internal _            => Status.internalServerError
  | .custom s _            => s

/-- Human-readable error message. -/
def message : AppError → String
  | .badRequest m          => m
  | .unauthorized m        => m
  | .forbidden m           => m
  | .notFound m            => m
  | .methodNotAllowed m    => m
  | .requestTimeout m      => m
  | .conflict m            => m
  | .payloadTooLarge m     => m
  | .unprocessableEntity m => m
  | .internal m            => m
  | .custom _ m            => m

/-- Renders an `AppError` into a standard JSON error response. -/
def toResponse (err : AppError) : Response :=
  let payload := "{\"error\":\"" ++ escapeJsonString err.message ++ "\"}"
  Response.json payload err.status

end AppError
end Leant
