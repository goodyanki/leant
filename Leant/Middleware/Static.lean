import Leant.App

namespace Leant.Static

open Leant

/-- Checks whether a single relative path segment is safe (not empty, `.`, `..`, and free of
    backslashes, NUL bytes, or drive-letter colons). -/
def isSafeSegment (seg : String) : Bool :=
  !seg.isEmpty &&
  seg != "." &&
  seg != ".." &&
  !seg.toList.any (fun (c : Char) => c == '\\' || c == '\x00' || c == ':')

/-- Parses and validates a relative URL path into safe path segments, returning `none`
    if any segment attempts directory traversal or contains forbidden characters. -/
def safeRelativePath (rawPath : String) : Option (List String) :=
  let rawSegs := (rawPath.splitOn "/").filter fun s => !s.isEmpty
  if rawSegs.isEmpty then
    none
  else if rawSegs.all isSafeSegment then
    some rawSegs
  else
    none

/-- Machine-checked path traversal prevention theorem:
    Every segment returned by `safeRelativePath` is guaranteed to be non-empty,
    distinct from `.` and `..`, and free of `\`, NUL, and `:`. -/
theorem safeRelativePath_no_traversal (raw : String) (segs : List String)
    (h : safeRelativePath raw = some segs) :
    ∀ s ∈ segs, s ≠ "" ∧ s ≠ "." ∧ s ≠ ".." ∧
      '\\' ∉ s.toList ∧ '\x00' ∉ s.toList ∧ ':' ∉ s.toList := by
  unfold safeRelativePath at h
  dsimp only at h
  split at h
  · cases h
  · split at h
    · rename_i hall
      cases h
      intro s hs
      rw [List.all_eq_true] at hall
      have hsafe := hall s hs
      unfold isSafeSegment at hsafe
      simp only [Bool.and_eq_true, Bool.not_eq_true', List.any_eq_false] at hsafe
      rcases hsafe with ⟨⟨⟨hneEmpty, hneDot⟩, hneDotDot⟩, hchars⟩
      refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
      · intro hempty
        subst hempty
        simp at hneEmpty
      · intro hdot
        subst hdot
        simp at hneDot
      · intro hdd
        subst hdd
        simp at hneDotDot
      · intro hmem
        have hc := hchars '\\' hmem
        simp at hc
      · intro hmem
        have hc := hchars '\x00' hmem
        simp at hc
      · intro hmem
        have hc := hchars ':' hmem
        simp at hc
    · cases h

/-- Infers a standard MIME `Content-Type` from a file extension. -/
def contentTypeFor (fileName : String) : String :=
  match fileName.splitOn "." |>.reverse with
  | ext :: _ :: _ =>
    match ext.toLower with
    | "html" | "htm" => "text/html; charset=utf-8"
    | "css"          => "text/css; charset=utf-8"
    | "js" | "mjs"   => "application/javascript; charset=utf-8"
    | "json"         => "application/json; charset=utf-8"
    | "svg"          => "image/svg+xml"
    | "png"          => "image/png"
    | "jpg" | "jpeg" => "image/jpeg"
    | "gif"          => "image/gif"
    | "webp"         => "image/webp"
    | "ico"          => "image/x-icon"
    | "txt" | "md"   => "text/plain; charset=utf-8"
    | "wasm"         => "application/wasm"
    | _              => "application/octet-stream"
  | _ => "application/octet-stream"

/-- Resolves a validated segment list underneath `rootDir`. -/
def resolveFilePath (rootDir : System.FilePath) (segs : List String) : System.FilePath :=
  segs.foldl (init := rootDir) fun acc seg => acc / System.FilePath.mk seg

/-- Builds a static-file serving `Handler` anchored strictly inside `rootDir`. -/
def handler (rootDir : System.FilePath) (paramName : String := "filepath") : Handler := fun c => do
  let rawPath := (c.param? paramName).getD ""
  match safeRelativePath rawPath with
  | none => throw (AppError.notFound "File not found")
  | some segs =>
    let target := resolveFilePath rootDir segs
    if !(← target.pathExists) || (← target.isDir) then
      throw (AppError.notFound "File not found")
    let bytes ← IO.FS.readBinFile target
    let lastName := segs.getLast?.getD ""
    pure {
      status := Status.ok
      headers := Headers.empty
        |>.set "Content-Type" (contentTypeFor lastName)
        |>.set "X-Content-Type-Options" "nosniff"
      body := bytes
    }

end Leant.Static

namespace Leant.App

/-- Mounts a static file directory under `urlPrefix` (e.g., `app.static "/assets" "./public"`). -/
def static (app : App) (urlPrefix : String) (rootDir : System.FilePath) : App :=
  let pattern := Router.joinPaths urlPrefix "*filepath"
  app.get pattern (Leant.Static.handler rootDir "filepath")

end Leant.App
