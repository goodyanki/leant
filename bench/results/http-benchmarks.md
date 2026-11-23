# HTTP Framework Benchmarks: Leant vs Gin

- **Date**: 2026-11-22
- **Environment**: Linux x86_64 (2 vCPU, `ulimit -n 1024`)
- **Toolchains**: Lean `v4.36.0` (Release), Go `1.26.11` + Gin `v1.12.0` (`ReleaseMode` + `gin.New()`), Rust `1.100.0` (`tokio 1.54` + `hyper 1.12`), `wrk 4.1.0`
- **Command**: `DURATION=4s ./bench/scripts/run.sh bench/results/http-benchmarks.csv`
- **Targets**:
  - `bench_leant` ([bench/leant/BenchLeant.lean](../leant/BenchLeant.lean)): Full Leant stack (`App`, `TrieNode` router, `Context`, `AppError`, `Headers`, `Lean.ToJson`, `RustHyper` transport with timeouts & graceful drain).
  - `gin_baseline` ([bench/baselines/gin/main.go](../baselines/gin/main.go)): `gin.ReleaseMode` + `gin.New()`.

## Results (Raw CSV: [http-benchmarks.csv](./http-benchmarks.csv))

### `/plaintext`

| Connections | Gin RPS | Gin p99 | **Leant RPS** | **Leant p99** | **Leant / Gin RPS** | **Leant / Gin p99** |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `c=16` | 32,560 | 6.04 ms | **50,942** | **1.52 ms** | **156.5%** | 0.25x |
| `c=64` | 41,044 | 7.64 ms | **53,503** | **3.59 ms** | **130.4%** | 0.47x |
| `c=256` | 46,184 | 18.90 ms | **52,380** | **12.06 ms** | **113.4%** | 0.64x |
| `c=512` | 46,256 | 36.71 ms | **61,394** | **17.41 ms** | **132.7%** | 0.47x |

### `/json`

| Connections | Gin RPS | Gin p99 | **Leant RPS** | **Leant p99** | **Leant / Gin RPS** | **Leant / Gin p99** |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `c=16` | 30,872 | 6.69 ms | **45,277** | **1.65 ms** | **146.7%** | 0.25x |
| `c=64` | 39,121 | 10.27 ms | **53,622** | **3.25 ms** | **137.1%** | 0.32x |
| `c=256` | 42,105 | 20.46 ms | **55,399** | **10.34 ms** | **131.6%** | 0.51x |
| `c=512` | 42,384 | 38.93 ms | **56,316** | **18.95 ms** | **132.9%** | 0.49x |
