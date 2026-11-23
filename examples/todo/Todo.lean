import Lean.Data.Json
import Leant

open Leant
open Leant.Binding
open Leant.Data

/-- Validated SQL identifiers for the `todos` table. -/
private def todosTableIdent : SqlIdent := ⟨"todos", by decide⟩
private def colIdIdent : SqlIdent := ⟨"id", by decide⟩
private def colTitleIdent : SqlIdent := ⟨"title", by decide⟩
private def colCompletedIdent : SqlIdent := ⟨"completed", by decide⟩

private def todosSchema : Schema := {
  tableName := todosTableIdent
  cols := [
    { name := colIdIdent, ty := .int, isPrimaryKey := true, isAutoIncrement := true },
    { name := colTitleIdent, ty := .text, checkSql := some "length(title) > 0 AND length(title) <= 120" },
    { name := colCompletedIdent, ty := .bool }
  ]
}

/-- Verified global `Table` descriptor for `todos`. -/
def todosTable : Table .global := {
  schema := todosSchema
  tenantCol := ()
}

/-- Proof-carrying column handles for `todos`. -/
def colId : ColRef todosSchema .int := ⟨0, _, rfl, rfl⟩
def colTitle : ColRef todosSchema .text := ⟨1, _, rfl, rfl⟩
def colCompleted : ColRef todosSchema .bool := ⟨2, _, rfl, rfl⟩

/-- A Todo item whose title is proven at the type level to satisfy `0 < length ≤ 120`. -/
structure Todo where
  id : Int
  title : NonEmptyBounded 120
  completed : Bool := false

instance : Lean.ToJson Todo where
  toJson t := Lean.Json.mkObj [
    ("id", Lean.ToJson.toJson t.id),
    ("title", Lean.ToJson.toJson t.title),
    ("completed", Lean.ToJson.toJson t.completed)
  ]

instance : Model Todo where
  mode := .global
  table := todosTable
  fromRow row := do
    let id ← rowGet row colId
    let title ← rowGetRefined row colTitle NonEmptyBounded.ofString
    let completed ← rowGet row colCompleted
    pure { id, title, completed }

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

private def liftDb {α : Type} (res : Except DbError α) : HandlerM α :=
  match res with
  | .ok v => pure v
  | .error e => throw (.internal s!"database decode error: {e}")

def buildTodoApp (dbPath : String := ":memory:") (withLogger : Bool := true) : IO App := do
  let pool ← Pool.createSqlite dbPath { maxSize := 4 }
  pool.migrateTable todosTable
  let reqIdMw ← Middleware.makeRequestId "todo"

  let listTodos : Handler := fun c => do
    let filterDone? ← match c.query? "completed" with
      | none => pure none
      | some raw =>
        match FromParam.parseParam (α := Bool) raw with
        | some b => pure (some b)
        | none => throw (.badRequest s!"invalid completed filter: {raw}")
    let q := SelectQuery.fromTable todosTable |>.orderBy colId .asc
    let q := match filterDone? with
      | none => q
      | some flag => q.filter (colCompleted ==. flag)
    let items ← liftDb (← pool.selectModels (α := Todo) q)
    c.json items

  let createTodo : Handler := fun c => do
    let body ← c.bindJson (α := CreateTodoReq)
    let ins := InsertQuery.into todosTable
      |>.set colTitle body.title.val
      |>.set colCompleted false
    let newId ← pool.insert ins
    let item : Todo := { id := newId, title := body.title, completed := false }
    c.json item Status.created

  let getTodo : Handler := fun c => do
    let id ← c.param! "id" (α := Int)
    let q := SelectQuery.fromTable todosTable |>.filter (colId ==. id) |>.limit 1
    let items ← liftDb (← pool.selectModels (α := Todo) q)
    match items[0]? with
    | some item => c.json item
    | none => throw (.notFound s!"todo {id} not found")

  let updateTodo : Handler := fun c => do
    let id ← c.param! "id" (α := Int)
    let patch ← c.bindJson (α := UpdateTodoReq)
    let updated? : Option Todo ← (pool.withTransaction fun conn => do
      let q := SelectQuery.fromTable todosTable |>.filter (colId ==. id) |>.limit 1
      match ← Pool.selectModelsOn (α := Todo) conn q with
      | .error e => throw (IO.userError s!"decode error: {e}")
      | .ok items =>
        match items[0]? with
        | none => pure (none : Option Todo)
        | some old =>
          let nextItem : Todo := {
            old with
            title := patch.title.getD old.title
            completed := patch.completed.getD old.completed
          }
          let upd := UpdateQuery.table todosTable
            |>.set colTitle nextItem.title.val
            |>.set colCompleted nextItem.completed
            |>.filter (colId ==. id)
          Pool.updateOn conn upd
          pure (some nextItem) : IO (Option Todo))
    match updated? with
    | some item => c.json item
    | none => throw (AppError.notFound s!"todo {id} not found")

  let deleteTodo : Handler := fun c => do
    let id ← c.param! "id" (α := Int)
    let existed : Bool ← (pool.withTransaction fun conn => do
      let q := SelectQuery.fromTable todosTable |>.filter (colId ==. id) |>.limit 1
      let rows ← Pool.selectOn conn q
      if rows.isEmpty then
        pure false
      else
        Pool.deleteOn conn (DeleteQuery.fromTable todosTable |>.filter (colId ==. id))
        pure true : IO Bool)
    if existed then
      c.status Status.noContent
    else
      throw (AppError.notFound s!"todo {id} not found")

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
  let dbPath := (← IO.getEnv "TODO_DB_PATH").getD ":memory:"
  let app ← buildTodoApp dbPath true
  app.run "127.0.0.1:8080"
