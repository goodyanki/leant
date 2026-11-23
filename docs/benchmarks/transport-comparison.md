# HTTP Transport Evaluation: `Std.Http` vs `Gin` vs `Rust (Hyper) + Lean 4 FFI`

- **Date**: 2026-11-22
- **Environment**: Linux x86_64 (2 vCPU, `ulimit -n 1024`)
- **Toolchains**: Lean `v4.36.0` (Release), Go `1.26.11` + Gin `v1.12.0` (`ReleaseMode` + `gin.New()`), Rust `1.100.0` (`tokio 1.54` + `hyper 1.12`), `wrk 4.1.0`
- **Protocol**: 2s warmup followed by 5s load per scenario.

## Results

| Scenario | Gin (`ReleaseMode`) | Raw `Std.Http` | `Std.Http / Gin` | **Rust (`hyper`) + Lean 4 FFI** | Hybrid / Gin |
| --- | ---: | ---: | ---: | ---: | ---: |
| `GET /` `c=1` | 8,691 RPS (p99 0.67ms) | 894 RPS (p99 1.80ms) | 10.3% | **14,191 RPS** (p99 0.81ms) | **1.63x** |
| `GET /` `c=16` | 31,917 RPS (p99 7.57ms) | 2,728 RPS (p99 9.20ms) | 8.5% | **86,821 RPS** (p99 4.63ms) | **2.72x** |
| `GET /` `c=64` | 39,812 RPS (p99 8.65ms) | 3,193 RPS (p99 29.81ms) | 8.0% | **92,349 RPS** (p99 4.33ms) | **2.32x** |
| `GET /` `c=256` | 44,728 RPS (p99 20.30ms) | 3,122 RPS (p99 762.00ms) | 7.0% | **93,173 RPS** (p99 7.23ms) | **2.08x** |
| `GET /` `c=512` | 47,992 RPS (p99 35.10ms, 0 err) | 2,934 RPS (p99 1.33s, 181 timeout) | 6.1% | **94,823 RPS** (p99 13.71ms, 0 err) | **1.98x** |
| `GET /json` `c=64` | 38,293 RPS (p99 10.20ms) | 2,993 RPS (p99 97.25ms) | 7.8% | **101,695 RPS** (p99 4.35ms) | **2.66x** |
| Short conn `c=32` | 13,832 RPS (p99 6.62ms) | 1,586 RPS (p99 27.73ms) | 11.5% | **19,717 RPS** (p99 4.59ms) | **1.43x** |
| Peak RSS | 28.9 MB | 15.7 MB | — | **14.0 MB** | 0.48x |

> Note: Disabling `generateDate` and `serverName` in `Std.Http` yielded 3,221 RPS at `c=64` and 2,711 RPS with 221 timeouts at `c=512`.

## Conclusion

Leant adopts the Rust (`tokio` + `hyper`) transport behind the pluggable `Leant.Transport.Backend` interface (see [ADR-001](../adr/001-rust-hyper-transport.md)).
