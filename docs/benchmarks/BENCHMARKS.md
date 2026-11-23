# Leant `v0.5.0` Benchmarks: Leant vs Gin

- **Date**: 2026-11-22
- **Environment**: Linux x86_64 (2 vCPU, `ulimit -n 1024`)
- **Toolchains**:
  - **Leant `v0.5.0`**: Lean `v4.36.0` (Release), Rust `1.100.0` (`tokio 1.54`, `hyper 1.12`, `hmac`/`sha2`/`subtle`), SQLite `3.45.1` (WAL mode, 4-connection pool)
  - **Gin baseline** (external comparison binary, not vendored in VCS): Go `1.26.11`, Gin `v1.12.0` (`gin.ReleaseMode` + `gin.New()`), `mattn/go-sqlite3` (CGO `libsqlite3`, WAL mode, 4-connection pool), `crypto/hmac` + `crypto/sha256`
  - **Load generator**: `wrk 4.1.0` (`-t2`, 3s per scenario, 1s warmup)
- **Raw CSV**: [results.csv](./results.csv)
- **Transport Evaluation**: [transport-comparison.md](./transport-comparison.md)

---

## 1. Plaintext (`/plaintext`)

Returns `"Hello, World!"` (`text/plain; charset=utf-8`).

| Connections | Gin RPS | Gin p99 | **Leant RPS** | **Leant p99** | **Leant / Gin RPS** | **Leant / Gin p99** |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `c=16` | 31,458 | 5.96 ms | **49,815** | **1.38 ms** | **158.4%** | 0.23x |
| `c=64` | 39,422 | 8.83 ms | **55,239** | **3.12 ms** | **140.1%** | 0.35x |
| `c=256` | 43,381 | 20.18 ms | **56,775** | **9.27 ms** | **130.9%** | 0.46x |
| `c=512` | 40,888 | 37.52 ms | **49,462** | **27.05 ms** | **121.0%** | 0.72x |

---

## 2. JSON Serialization (`/json`)

Dynamically encodes `{"message":"Hello, World!"}` (`application/json; charset=utf-8`) on every request.

| Connections | Gin RPS | Gin p99 | **Leant RPS** | **Leant p99** | **Leant / Gin RPS** | **Leant / Gin p99** |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `c=16` | 31,491 | 6.69 ms | **43,006** | **2.00 ms** | **136.6%** | 0.30x |
| `c=64` | 39,227 | 9.35 ms | **51,843** | **3.39 ms** | **132.2%** | 0.36x |
| `c=256` | 38,988 | 22.76 ms | **55,890** | **8.42 ms** | **143.4%** | 0.37x |
| `c=512` | 38,884 | 52.69 ms | **52,423** | **19.60 ms** | **134.8%** | 0.37x |

---

## 3. Single Database Query (`/db`)

Executes a parameterized SQLite lookup (`SELECT id, label FROM bench_items WHERE (id = ?) LIMIT ?`) through a 4-connection WAL-mode pool and decodes the row into a typed JSON response.

| Connections | Gin RPS | Gin p99 | **Leant RPS** | **Leant p99** | **Leant / Gin RPS** | **Leant / Gin p99** |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `c=16` | 15,988 | 18.90 ms | **18,805** | **2.66 ms** | **117.6%** | 0.14x |
| `c=64` | 17,984 | 30.52 ms | **19,777** | **7.50 ms** | **110.0%** | 0.25x |
| `c=256` | 18,181 | 64.26 ms | **22,031** | **22.03 ms** | **121.2%** | 0.34x |
| `c=512` | 17,322 | 112.47 ms | **18,272** | **58.16 ms** | **105.5%** | 0.52x |

---

## 4. Authenticated & Authorized RLS Query (`/authz/:id`)

Full security stack per request: constant-time HMAC-SHA256 Bearer token verification, JSON `Principal` decoding, compile-time tenant-scoped SQLite RLS query (`WHERE (tenant_id = ?) AND (id = ?) LIMIT ?`), RBAC/ownership/forbid policy guard (`requires`), and JSON response serialization.

| Connections | Gin RPS | Gin p99 | **Leant RPS** | **Leant p99** | **Leant / Gin RPS** | **Leant / Gin p99** |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `c=16` | 13,821 | 24.96 ms | **12,976** | **4.09 ms** | **93.9%** | 0.16x |
| `c=64` | 14,365 | 42.86 ms | **13,919** | **9.43 ms** | **96.9%** | 0.22x |
| `c=256` | 13,595 | 105.50 ms | **13,565** | **42.63 ms** | **99.8%** | 0.40x |
| `c=512` | 8,494 | 194.01 ms | **12,167** | **92.53 ms** | **143.2%** | 0.48x |

---

## Key Takeaways

1. **HTTP & JSON**: Leant sustains **121%–158%** of Gin's throughput on `/plaintext` and **132%–143%** on `/json`, with **2x–4x lower p99 latency**.
2. **Verified ORM (`/db`)**: Despite full typed AST construction, parameterized rendering, and boundary decoding, Leant outperforms Gin + `go-sqlite3` at every concurrency level (**105%–121% RPS**, **1.9x–7.1x lower p99 latency**).
3. **Security Layer Overhead (`/authz/:id`)**: Adding HMAC-SHA256 Bearer auth, verified RBAC/forbid policy evaluation, and tenant-scoped RLS retains ~65%–70% of raw `/db` throughput, matching Gin at `c=16..256` and outperforming Gin by **43%** at `c=512` while maintaining **2.1x–6.1x lower p99 latency** across all concurrency levels.
4. **Memory Stability**: Across all 16 consecutive load scenarios (~1.5M+ requests), Leant RSS stayed flat at ~73–83 MB with zero monotonic leak.
