import Leant.Core.Types

namespace Leant.Transport

/-- Server transport configuration (host, port, limits). -/
structure Config where
  host : String := "127.0.0.1"
  port : UInt16 := 8080
  maxConnections : UInt32 := 10000
  maxBodyBytes : USize := 16 * 1024 * 1024
  keepAlive : Bool := true
  deriving Repr, Inhabited

/-- Parses `":8080"` or `"0.0.0.0:8080"` into `(host, port)`. -/
def parseAddr (addr : String) : String × UInt16 :=
  match addr.splitOn ":" with
  | [host, portStr] =>
    let h := if host.isEmpty then "0.0.0.0" else host
    let p := (portStr.toNat?.getD 8080).toUInt16
    (h, p)
  | _ => ("127.0.0.1", 8080)

/-- Transport backend abstraction: takes a `Config` and a total `Request → IO Response` handler. -/
class Backend (τ : Type) where
  serve : τ → Config → (Request → IO Response) → IO Unit

end Leant.Transport
