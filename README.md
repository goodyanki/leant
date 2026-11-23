# Leant

一个用 **Lean 4** 编写、面向后端服务与形式化验证的 Web 框架。

> **Gin 一样轻快的开发体验 + Rust (`tokio` + `hyper`) 高性能 HTTP 传输层 + Lean 4 可证明的路由、数据访问与授权核心。**

## 架构概览

基于 M0 压测基线（见 [bench/results/M0.md](bench/results/M0.md) 与 [ADR-001](docs/adr/001-rust-hyper-transport.md)）：
- **HTTP 传输层**（`transport/rust-http` + `transport/c/bridge.c`）：Rust `tokio` + `hyper` 1.x 多线程 HTTP/1.1 引擎，通过薄 C ABI shim 与 Lean 4 runtime 线程安全集成。
- **Web 内核**（`Leant/Core`, `Leant/Router`, `Leant/Binding`, `Leant/Middleware`, `Leant/App`）：
  - 全函数段级前缀/基数 Trie 路由（静态 > `:param` > `*wildcard`，支持回溯与 404/405 区分）
  - 路由分组 `group`、洋葱中间件链与 `abort` 短路
  - `Context`（param / query / form / header / cookie / body / JSON 绑定 / 请求级 KV）与安全默认值 Cookie（`HttpOnly; Secure; SameSite=Lax`）
  - 携带编译期证明的精化绑定类型（`NonEmpty`、`Bounded n`、`NonEmptyBounded n`、`Email`、`PositiveNat`）
  - 内置中间件：`logger`、`recovery`、`makeRequestId`/`requestId`、`cors`/`corsWith`、`bodyLimit`、`timeout`
  - 内存 HTTP 测试工具：`Leant.Testing`
- **可证明安全核心**（`Leant/Authz`, `Leant/Data`）：零 `sorry` 的策略求值引擎与核心定理（租户隔离、Deny 优先、默认拒绝）及参数化 SQL 抽象。

## 快速开始

```bash
# 构建框架库（自动编译 Rust HTTP 传输层 + C ABI shim）
lake build

# 运行单元测试与内存 HTTP 测试
lake test

# 构建并运行示例服务
lake build hello
./.lake/build/bin/hello

# 或运行 Todo CRUD API 示例（含线程安全 Std.Mutex 状态 + 精化类型校验）
lake build todo
./.lake/build/bin/todo
```

测试 Todo API：

```bash
curl -X POST http://127.0.0.1:8080/api/v1/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"Write formal proofs"}'
curl http://127.0.0.1:8080/api/v1/todos
curl -X PATCH http://127.0.0.1:8080/api/v1/todos/1 \
  -H "Content-Type: application/json" \
  -d '{"completed":true}'
curl -X DELETE http://127.0.0.1:8080/api/v1/todos/1
```

## 文档

- [PRD](docs/PRD.md)
- [开发计划](docs/DEVELOPMENT_PLAN.md)
- [M0 性能基线报告](bench/results/M0.md)
- [ADR-001: Rust Hyper Transport](docs/adr/001-rust-hyper-transport.md)
