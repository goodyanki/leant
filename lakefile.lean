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

extern_lib libleant_bridge pkg := do
  let ffiO ← bridge.o.fetch
  let name := nameToStaticLib "leant_bridge"
  buildStaticLib (pkg.staticLibDir / name) #[ffiO]

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

@[default_target]
lean_lib Leant where
  moreLinkArgs := #["-lpthread", "-ldl", "-lm"]

@[test_driver]
lean_exe LeantTest where
  root := `LeantTest.Main
  moreLinkArgs := #["-lpthread", "-ldl", "-lm"]

lean_exe hello where
  srcDir := "examples/hello"
  root := `Main
  moreLinkArgs := #["-lpthread", "-ldl", "-lm"]
