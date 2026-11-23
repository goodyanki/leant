import Lake
open Lake DSL

package leant where
  version := v!"0.1.0"

/-- Compiles the thin C ABI bridge (`transport/c/bridge.c`) against `<lean/lean.h>`. -/
target bridge.o pkg : System.FilePath := do
  let oFile := pkg.buildDir / "c" / "bridge.o"
  let srcJob ← inputTextFile <| pkg.dir / "transport" / "c" / "bridge.c"
  let weakArgs := #["-I", (← getLeanIncludeDir).toString]
  buildO oFile srcJob weakArgs #["-fPIC", "-O3"] "cc" getLeanTrace

/-- Compiles the SQLite3 C FFI shim (`data/c/sqlite_bridge.c`) against `<lean/lean.h>`. -/
target sqlite_bridge.o pkg : System.FilePath := do
  let oFile := pkg.buildDir / "c" / "sqlite_bridge.o"
  let srcJob ← inputTextFile <| pkg.dir / "data" / "c" / "sqlite_bridge.c"
  let weakArgs := #["-I", (← getLeanIncludeDir).toString]
  buildO oFile srcJob weakArgs #["-fPIC", "-O3"] "cc" getLeanTrace

extern_lib libleant_bridge pkg := do
  let ffiO ← bridge.o.fetch
  let sqliteO ← sqlite_bridge.o.fetch
  let name := nameToStaticLib "leant_bridge"
  buildStaticLib (pkg.staticLibDir / name) #[ffiO, sqliteO]

/-- Builds the Rust Tokio + Hyper HTTP/1.1 transport static library via Cargo. -/
extern_lib libleant_rust_http pkg := do
  let rustDir := pkg.dir / "transport" / "rust-http"
  let libName := nameToStaticLib "leant_rust_http"
  let libFile := rustDir / "target" / "release" / libName
  let cargoToml ← inputTextFile <| rustDir / "Cargo.toml"
  let libRs ← inputTextFile <| rustDir / "src" / "lib.rs"
  let depJob := Job.mix cargoToml libRs
  depJob.mapM fun _ => do
    proc {
      cmd := "cargo"
      args := #["build", "--release"]
      cwd := some rustDir
    }
    return libFile

def commonLinkArgs : Array String := #[
  "-Wl,--allow-shlib-undefined",
  "/usr/lib/x86_64-linux-gnu/libsqlite3.so",
  "-lpthread", "-ldl", "-lm"
]

@[default_target]
lean_lib Leant where
  moreLinkArgs := commonLinkArgs

@[test_driver]
lean_exe LeantTest where
  root := `LeantTest.Main
  moreLinkArgs := commonLinkArgs

lean_exe hello where
  srcDir := "examples/hello"
  root := `Hello
  moreLinkArgs := commonLinkArgs

lean_exe todo where
  srcDir := "examples/todo"
  root := `Todo
  moreLinkArgs := commonLinkArgs

lean_exe bench_leant where
  srcDir := "bench/leant"
  root := `BenchLeant
  moreLinkArgs := commonLinkArgs
