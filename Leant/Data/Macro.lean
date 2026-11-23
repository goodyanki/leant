import Leant.Data.Schema

namespace Leant.Data

/-! ### Declarative `leant_table` and `leant_tenant_table` Macros
    Generates a verified `Schema`, a global or tenant-scoped `Table`, and proof-carrying `ColRef`
    handles with zero manual index/proof boilerplate. -/

/-- Convenience helper to build a `ColDef` with compile-time identifier verification. -/
def mkColDef (name : String) (h : isValidSqlIdent name = true := by decide)
    (ty : SqlType) (isPrimaryKey : Bool := false) (isAutoIncrement : Bool := false)
    (isUnique : Bool := false) (checkSql : Option String := none) : ColDef :=
  { name := ⟨name, h⟩, ty, isPrimaryKey, isAutoIncrement, isUnique, checkSql }

declare_syntax_cat leant_col_decl
syntax "| " ident " : " term:max ("[" ident,* "]")? : leant_col_decl

/-- Declares a verified global `Table .global` namespace with `schema`, `table`, and typed `ColRef`s. -/
syntax "leant_table " ident str " where " leant_col_decl+ : command

/-- Declares a verified multi-tenant `Table (.tenantScoped ty)` namespace with `schema`,
    typed `ColRef`s, and compile-time enforced `tenantCol`. -/
syntax "leant_tenant_table " ident str " (" ident " : " term ")" " where " leant_col_decl+ : command

private def parseFlagIdents (flags : Array Lean.Ident) : Bool × Bool × Bool :=
  flags.foldl (init := (false, false, false)) fun (isPk, isAuto, isUniq) f =>
    match f.getId.toString with
    | "pk"     => (true, isAuto, isUniq)
    | "auto"   => (isPk, true, isUniq)
    | "unique" => (isPk, isAuto, true)
    | _        => (isPk, isAuto, isUniq)

private def expandColDecls (colDecls : Array (Lean.TSyntax `leant_col_decl)) :
    Lean.MacroM (Array (Lean.Ident × Lean.Term × Bool × Bool × Bool)) := do
  colDecls.mapM fun d =>
    match d with
    | `(leant_col_decl| | $name:ident : $ty:term [$flags:ident,*]) =>
      let (isPk, isAuto, isUniq) := parseFlagIdents flags.getElems
      pure (name, ty, isPk, isAuto, isUniq)
    | `(leant_col_decl| | $name:ident : $ty:term) =>
      pure (name, ty, false, false, false)
    | _ => Lean.Macro.throwUnsupported

macro_rules
  | `(leant_table $ns:ident $tableName:str where $cols:leant_col_decl*) => do
    let parsed ← expandColDecls cols
    let colDefTerms ← parsed.mapM fun (name, ty, isPk, isAuto, isUniq) => do
      let nameStr := Lean.Syntax.mkStrLit name.getId.toString
      let pkTerm := if isPk then Lean.mkIdent `true else Lean.mkIdent `false
      let autoTerm := if isAuto then Lean.mkIdent `true else Lean.mkIdent `false
      let uniqTerm := if isUniq then Lean.mkIdent `true else Lean.mkIdent `false
      `(Leant.Data.mkColDef $nameStr (by decide) $ty $pkTerm $autoTerm $uniqTerm)
    let schemaId := Lean.mkIdent `schema
    let tableId := Lean.mkIdent `table
    let mut cmds : Array (Lean.TSyntax `command) := #[]
    cmds := cmds.push (← `(namespace $ns))
    cmds := cmds.push (← `(def $schemaId : Leant.Data.Schema := {
      tableName := ⟨$tableName, by decide⟩
      cols := [$colDefTerms,*]
    }))
    cmds := cmds.push (← `(def $tableId : Leant.Data.Table .global := {
      schema := $schemaId
      tenantCol := ()
    }))
    for h : i in [0:parsed.size] do
      let (name, ty, _, _, _) := parsed[i]
      let idxLit := Lean.Syntax.mkNumLit (toString i)
      cmds := cmds.push (← `(def $name : Leant.Data.ColRef $schemaId $ty := ⟨$idxLit, _, rfl, rfl⟩))
    cmds := cmds.push (← `(end $ns))
    pure (Lean.mkNullNode (cmds.map (·.raw)))

  | `(leant_tenant_table $ns:ident $tableName:str ($tenantIdent:ident : $tenantTy:term) where $cols:leant_col_decl*) => do
    let parsed ← expandColDecls cols
    let colDefTerms ← parsed.mapM fun (name, ty, isPk, isAuto, isUniq) => do
      let nameStr := Lean.Syntax.mkStrLit name.getId.toString
      let pkTerm := if isPk then Lean.mkIdent `true else Lean.mkIdent `false
      let autoTerm := if isAuto then Lean.mkIdent `true else Lean.mkIdent `false
      let uniqTerm := if isUniq then Lean.mkIdent `true else Lean.mkIdent `false
      `(Leant.Data.mkColDef $nameStr (by decide) $ty $pkTerm $autoTerm $uniqTerm)
    let schemaId := Lean.mkIdent `schema
    let tableId := Lean.mkIdent `table
    let mut cmds : Array (Lean.TSyntax `command) := #[]
    cmds := cmds.push (← `(namespace $ns))
    cmds := cmds.push (← `(def $schemaId : Leant.Data.Schema := {
      tableName := ⟨$tableName, by decide⟩
      cols := [$colDefTerms,*]
    }))
    for h : i in [0:parsed.size] do
      let (name, ty, _, _, _) := parsed[i]
      let idxLit := Lean.Syntax.mkNumLit (toString i)
      cmds := cmds.push (← `(def $name : Leant.Data.ColRef $schemaId $ty := ⟨$idxLit, _, rfl, rfl⟩))
    cmds := cmds.push (← `(def $tableId : Leant.Data.Table (.tenantScoped $tenantTy) := {
      schema := $schemaId
      tenantCol := $tenantIdent
    }))
    cmds := cmds.push (← `(end $ns))
    pure (Lean.mkNullNode (cmds.map (·.raw)))

end Leant.Data
