import Std.Sync.Mutex
import Leant.Core.Middleware

namespace Leant.Security

open Leant

/-- Configuration for the token-bucket rate limiter middleware. -/
structure RateLimitConfig where
  /-- Maximum burst capacity (tokens). -/
  capacity : Nat := 60
  /-- Refill rate in tokens per second. -/
  refillPerSec : Nat := 10
  /-- Function extracting the rate-limit bucket key from a request context. -/
  keyFn : Context → String := fun c =>
    (c.header? "x-forwarded-for").getD ((c.header? "x-client-id").getD "global")

private structure Bucket where
  tokens : Nat
  lastMs : Nat

/-- Creates a thread-safe token-bucket rate-limiting middleware backed by `Std.Mutex`.
    Rejects requests exceeding the bucket capacity with `429 Too Many Requests`. -/
def makeRateLimit (cfg : RateLimitConfig := {}) : IO Middleware := do
  let buckets ← Std.Mutex.new (#[] : Array (String × Bucket))
  pure fun next c => do
    let key := cfg.keyFn c
    let nowMs ← IO.monoMsNow
    let allowed : Bool ← buckets.atomically do
      let arr ← get
      match arr.findIdx? (fun (k, _) => k == key) with
      | none =>
        let cap := if cfg.capacity == 0 then 1 else cfg.capacity
        let nextArr := arr.push (key, { tokens := cap - 1, lastMs := nowMs })
        set nextArr
        pure true
      | some idx =>
        if h : idx < arr.size then
          let (_, b) := arr[idx]
          let elapsedMs := if nowMs >= b.lastMs then nowMs - b.lastMs else 0
          let added := (elapsedMs * cfg.refillPerSec) / 1000
          let refilled := Nat.min cfg.capacity (b.tokens + added)
          let newLastMs := if added > 0 then nowMs else b.lastMs
          if refilled > 0 then
            set (arr.set idx (key, { tokens := refilled - 1, lastMs := newLastMs }) h)
            pure true
          else
            set (arr.set idx (key, { tokens := 0, lastMs := newLastMs }) h)
            pure false
        else
          pure false
    if allowed then
      next c
    else
      throw (.custom Status.tooManyRequests "Too Many Requests")

end Leant.Security
