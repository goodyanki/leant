# ADR-001: 采用 Rust (`tokio` + `hyper`) 作为默认 HTTP Transport 层

- **状态**：已采纳
- **日期**：2026-11-22
- **关联**：`docs/DEVELOPMENT_PLAN.md` 决策点 D0、`bench/results/M0.md`

## 背景

`DEVELOPMENT_PLAN.md` 的决策点 D0 约定：若 Lean 4 标准库 `Std.Http` 吞吐低于同机 Gin 的 10%，或在高并发下不稳定，则将 HTTP 传输层替换为 Rust (`hyper`) 或 C shim，Lean 仅负责路由、中间件、业务逻辑与形式化验证核心。

## 实测依据

在 Lean `v4.36.0` 上实测（详见 `bench/results/M0.md`）：
- 裸 `Std.Http` 峰值约 **3.2k RPS**，仅为同机 Gin（48k RPS）的 **6.1%–8.5%**；
- 在 `c=512` 下出现 **181–221 次 2s 超时**，p99 达到 **1.33s**；
- 同机验证的 **Rust (`tokio` + `hyper` 1.x) + C ABI shim + Lean 4 FFI** 达到 **94.8k–101.7k RPS**（Gin 的 **2x–2.7x**），`c=512` 下 p99 仅 **13.71ms**，0 错误，RSS 稳定在 14 MB。

## 决策

1. 保留 `Leant.Transport.Backend` 抽象层，便于未来切换或回测新版本 `Std.Http`。
2. 默认传输层实现为 `Leant.Transport.RustHyper`：
   - Rust (`transport/rust-http`) 编译为 `staticlib`，通过 Lake `extern_lib` 集成到单二进制产物。
   - 薄 C shim (`transport/c/bridge.c`) 使用 `<lean/lean.h>` 隔离 Lean 内部对象内存布局。
   - 启动服务前通过 `lean_mark_mt` 标记路由/中间件闭包图；每个 Tokio worker 线程通过 `lean_initialize_thread` / `lean_finalize_thread` 接入 Lean runtime。
3. **TCB 影响**：Rust HTTP 传输层与 C shim 属于网络传输可信基（替代原 `Std.Http` + `libuv` 在 TCB 中的位置），路由、授权策略、ORM 查询 AST 等核心形式化验证范围不受影响。
