import Leant.Transport.Basic

namespace Leant.Transport.RustHyper

/-- C-ABI response struct returned across the FFI boundary.
    Field order MUST match `transport/c/bridge.c`:
    - obj 0: `headersRaw : String`
    - obj 1: `body : ByteArray`
    - scalar at `sizeof(void*) * 2`: `status : UInt16` -/
structure RawResponse where
  headersRaw : String
  body : ByteArray
  status : UInt16

/-- Raw request handler stored across the Tokio runtime. -/
abbrev RawHandler := Request → IO Response

/-- Internal FFI entrypoint invoked by `transport/c/bridge.c` on Tokio worker threads. -/
@[export leant_internal_dispatch]
def dispatch
    (handler : RawHandler)
    (method path query headersRaw : String)
    (body : ByteArray) : IO RawResponse := do
  let req : Request := {
    method := Method.ofString method
    path := path
    query := query
    headers := Headers.parseRaw headersRaw
    body := body
  }
  let resp ← handler req
  pure {
    headersRaw := resp.headers.toRaw
    body := resp.body
    status := resp.status.code
  }

@[extern "leant_c_serve"]
private opaque serveRaw
    (host : @& String)
    (port : UInt16)
    (maxConnections : UInt32)
    (maxBodyBytes : USize)
    (keepAlive : Bool)
    (handler : RawHandler) : IO Unit

/-- Marker type for the Rust Tokio + Hyper HTTP/1.1 transport backend. -/
structure RustHyperTransport where
  deriving Inhabited

/-- Default Rust Hyper transport instance. -/
def backend : RustHyperTransport := {}

instance : Backend RustHyperTransport where
  serve _ cfg handler :=
    serveRaw cfg.host cfg.port cfg.maxConnections cfg.maxBodyBytes cfg.keepAlive handler

end Leant.Transport.RustHyper
