import Leant.Core.Types
import Leant.Core.Context

namespace Leant

/-- A single Server-Sent Events (SSE) frame following the WHATWG EventSource specification. -/
structure SseEvent where
  data : String
  event : Option String := none
  id : Option String := none
  retryMs : Option Nat := none
  deriving Repr, BEq, Inhabited

namespace SseEvent

/-- Encodes one `SseEvent` into wire format terminated by a blank line (`\n\n`).
    Multi-line `data` fields emit one `data:` line per line as required by the SSE spec. -/
def encode (ev : SseEvent) : String :=
  let out := match ev.id with
    | some v => s!"id: {v}\n"
    | none => ""
  let out := match ev.event with
    | some v => out ++ s!"event: {v}\n"
    | none => out
  let out := match ev.retryMs with
    | some ms => out ++ s!"retry: {ms}\n"
    | none => out
  let dataLines := ev.data.splitOn "\n"
  let out := dataLines.foldl (init := out) fun acc line =>
    acc ++ "data: " ++ line ++ "\n"
  out ++ "\n"

/-- Encodes a sequence of `SseEvent`s into a single SSE stream payload. -/
def encodeAll (events : Array SseEvent) : String :=
  events.foldl (init := "") fun acc ev => acc ++ ev.encode

end SseEvent

namespace Response

/-- Builds a Server-Sent Events (`text/event-stream`) response from an array of `SseEvent`s (PRD K7). -/
def sse (events : Array SseEvent) (status : Status := Status.ok) : Response :=
  { status
  , headers := Headers.empty
      |>.set "Content-Type" "text/event-stream; charset=utf-8"
      |>.set "Cache-Control" "no-cache"
      |>.set "Connection" "keep-alive"
  , body := (SseEvent.encodeAll events).toUTF8 }

/-- Builds a chunked/streamed response by concatenating an array of byte chunks (PRD K7). -/
def streamChunks
    (chunks : Array ByteArray)
    (contentType : String := "application/octet-stream")
    (status : Status := Status.ok) : Response :=
  let total := chunks.foldl (init := ByteArray.empty) fun acc c => acc ++ c
  { status
  , headers := Headers.empty.set "Content-Type" contentType
  , body := total }

end Response

namespace Context

/-- Returns an SSE response (`text/event-stream`) containing `events`. -/
def sse (_c : Context) (events : Array SseEvent) : HandlerM Response :=
  pure (Response.sse events)

/-- Returns a streamed response assembled from chunks produced in `HandlerM`. -/
def stream (_c : Context) (contentType : String := "application/octet-stream")
    (produce : (ByteArray → IO Unit) → HandlerM Unit) : HandlerM Response := do
  let bufRef ← IO.mkRef (#[] : Array ByteArray)
  let emit : ByteArray → IO Unit := fun chunk => bufRef.modify (·.push chunk)
  produce emit
  let chunks ← bufRef.get
  pure (Response.streamChunks chunks contentType)

end Context
end Leant
