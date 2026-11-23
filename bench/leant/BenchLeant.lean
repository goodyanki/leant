import Lean.Data.Json
import Leant

open Leant

/-- TechEmpower Framework Benchmarks (TFB) JSON response payload. -/
private structure Message where
  message : String

private instance : Lean.ToJson Message where
  toJson m := Lean.Json.mkObj [("message", Lean.Json.str m.message)]

def main : IO Unit := do
  let addr := (← IO.getEnv "ADDR").getD "127.0.0.1:18082"
  let (host, port) := Transport.parseAddr addr
  let app := Leant.new
    |>.get "/plaintext" (fun c => c.text "Hello, World!")
    |>.get "/json" (fun c => c.json ({ message := "Hello, World!" } : Message))
  let cfg : Transport.Config := {
    host := host
    port := port
    maxConnections := 16384
    keepAlive := true
    headerTimeoutMs := 5000
    requestTimeoutMs := 0
    shutdownTimeoutMs := 2000
  }
  app.runWith Transport.RustHyper.backend cfg
