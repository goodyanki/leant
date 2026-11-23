import Std.Sync.Mutex
import Lean.Data.Json
import Leant

open Leant
open Leant.Binding

/-- A Todo item whose title is proven at the type level to satisfy `0 < length ≤ 120`. -/
structure Todo where
  id : Nat
  title : NonEmptyBounded 120
  completed : Bool := false

instance : Lean.ToJson Todo where
  toJson t := Lean.Json.mkObj [
    ("id", Lean.ToJson.toJson t.id),
    ("title", Lean.ToJson.toJson t.title),
    ("completed", Lean.ToJson.toJson t.completed)
  ]

/-- Request payload for `POST /api/v1/todos`. -/
structure CreateTodoReq where
  title : NonEmptyBounded 120

instance : Lean.FromJson CreateTodoReq where
  fromJson? j := do
    let title ← j.getObjValAs? (NonEmptyBounded 120) "title"
    pure { title }

/-- Request payload for `PATCH /api/v1/todos/:id`. -/
structure UpdateTodoReq where
  title : Option (NonEmptyBounded 120) := none
  completed : Option Bool := none

instance : Lean.FromJson UpdateTodoReq where
  fromJson? j := do
    let title ← match j.getObjVal? "title" with
      | .ok v =>
        if v.isNull then pure none
        else some <$> Lean.FromJson.fromJson? (α := NonEmptyBounded 120) v
      | .error _ => pure none
    let completed ← match j.getObjVal? "completed" with
      | .ok v =>
        if v.isNull then pure none
        else some <$> Lean.FromJson.fromJson? (α := Bool) v
      | .error _ => pure none
    pure { title, completed }

/-- Thread-safe in-memory store for Todo items. -/
structure TodoState where
  nextId : Nat := 1
  items : Array Todo := #[]

def buildTodoApp (withLogger : Bool := true) : IO App := do
  let store ← Std.Mutex.new ({} : TodoState)
  let reqIdMw ← Middleware.makeRequestId "todo"

  let listTodos : Handler := fun c => do
    let filterDone? ← match c.query? "completed" with
      | none => pure none
      | some raw =>
        match FromParam.parseParam (α := Bool) raw with
        | some b => pure (some b)
        | none => throw (.badRequest s!"invalid completed filter: {raw}")
    let items ← store.atomically do
      let st ← get
      pure <| match filterDone? with
        | none => st.items
        | some flag => st.items.filter (·.completed == flag)
    c.json items

  let createTodo : Handler := fun c => do
    let body ← c.bindJson (α := CreateTodoReq)
    let created ← store.atomically do
      let st ← get
      let item : Todo := { id := st.nextId, title := body.title, completed := false }
      set ({ nextId := st.nextId + 1, items := st.items.push item } : TodoState)
      pure item
    c.json created Status.created

  let getTodo : Handler := fun c => do
    let id ← c.param! "id" (α := Nat)
    let found? ← store.atomically do
      let st ← get
      pure (st.items.find? (·.id == id))
    match found? with
    | some item => c.json item
    | none => throw (.notFound s!"todo {id} not found")

  let updateTodo : Handler := fun c => do
    let id ← c.param! "id" (α := Nat)
    let patch ← c.bindJson (α := UpdateTodoReq)
    let updated? ← store.atomically do
      let st ← get
      match st.items.findIdx? (·.id == id) with
      | none => pure none
      | some idx =>
        if h : idx < st.items.size then
          let old := st.items[idx]
          let nextItem : Todo := {
            old with
            title := patch.title.getD old.title
            completed := patch.completed.getD old.completed
          }
          set ({ st with items := st.items.set idx nextItem h } : TodoState)
          pure (some nextItem)
        else
          pure none
    match updated? with
    | some item => c.json item
    | none => throw (.notFound s!"todo {id} not found")

  let deleteTodo : Handler := fun c => do
    let id ← c.param! "id" (α := Nat)
    let deleted : Bool ← store.atomically do
      let st ← get
      let before := st.items.size
      let remaining := st.items.filter (·.id != id)
      set ({ st with items := remaining } : TodoState)
      pure (remaining.size != before)
    if deleted then
      c.status Status.noContent
    else
      throw (.notFound s!"todo {id} not found")

  let base := if withLogger then Leant.default else Leant.new |>.use Middleware.recovery
  pure <| base
    |>.use (Middleware.cors "*")
    |>.use (Middleware.bodyLimit (64 * 1024))
    |>.get "/health" (fun c => c.jsonRaw "{\"status\":\"ok\"}")
    |>.group "/api/v1" (·
      |>.use reqIdMw
      |>.get "/todos" listTodos
      |>.post "/todos" createTodo
      |>.get "/todos/:id" getTodo
      |>.patch "/todos/:id" updateTodo
      |>.delete "/todos/:id" deleteTodo)

def main : IO Unit := do
  let app ← buildTodoApp true
  app.run "127.0.0.1:8080"
