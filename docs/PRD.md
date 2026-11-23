# Leant PRD（产品需求文档）

| 项 | 内容 |
|---|---|
| 项目 | **Leant**：一个用 Lean 4 原生编写、可形式化验证的后端 Web 框架 |
| 版本 | v0.1（草案） |
| 日期 | 2026-11-22 |
| 状态 | Draft，待评审 |

---

## 1. 背景与动机

主流后端框架（Gin、Django、Spring）里的权限与安全，大多靠**约定和测试**来保证：

- 新加的路由忘了挂鉴权中间件，测试不一定能发现。
- 越权漏洞（IDOR，把 `/orders/123` 改成 `/orders/124`）在 OWASP Top 10 里多年排第一（Broken Access Control）。
- 多租户 SaaS 少写一个 `WHERE tenant_id = ?`，就会把别人的数据泄露出去。
- 权限策略一多，就没人说得清"谁能对什么做什么"。

Lean 4 同时是**编程语言和定理证明器**。2026 年起，标准库已经有 `Std.Async`（libuv）、TCP 和 `Std.Http`（HTTP/1.1 服务端），已经能写真实的服务。Leant 的目标是把上面这些"靠人记住"的安全约束，变成**编译器强制检查、可以给出证明**的约束。

## 2. 产品定位

> **Gin 一样轻快的内核，加上可证明的授权和数据访问层。**

- **v0.x**：Gin 风格的 HTTP 内核，包括路由、中间件、上下文、绑定、JSON。
- **v0.x → v1**：类型化 ORM（Lean 目前没有）和可证明的授权层。
- **暂不做**：Django 式 admin 后台、模板引擎全家桶、HTTP/2/TLS 原生实现（交给反向代理）。

## 3. 目标用户

| 用户 | 诉求 |
|---|---|
| P1 安全敏感的 API 开发者（金融、医疗、SaaS 多租户） | 要求访问控制"可以证明"，便于审计和合规 |
| P2 Lean / 函数式爱好者 | 想用 Lean 写真实服务 |
| P3 研究者 / 教学 | 做验证 Web 系统的范例 |

**用户画像假设**：用户会写普通 Lean 代码，但**不一定会写证明**。框架必须做到"大部分用户只写声明，证明由框架和自动化策略完成"。

## 4. 目标与非目标

### 4.1 目标（Goals）
- **G1 开发体验接近 Gin**：几行代码就能起一个服务，API 风格熟悉（`GET`/`POST`/`Group`/`Use`/`c.json`）。
- **G2 编译期安全**：未授权的 handler 不能注册；SQL 注入在 API 层面无法表达。
- **G3 可证明的授权**：策略引擎带核心定理（默认拒绝、deny 优先、租户隔离）。
- **G4 类型化 ORM**：用模型声明生成表结构、查询、迁移；查询是 AST，不是字符串。
- **G5 性能可度量、可比较**：有标准化 benchmark，可以和 Gin、Axum、Django 在同一台机器上对比。

### 4.2 非目标（Non-goals，v1 之前）
- 端到端证明 IO、数据库、网络的正确性（这些属于可信基）。
- 原生 TLS、HTTP/2、HTTP/3。
- 热重载、admin 后台、i18n。
- 支持 Windows（不阻止，但不保证）。

## 5. 功能需求

优先级：**P0** = MVP 必须，**P1** = v1 必须，**P2** = 以后再做。

### 5.1 HTTP 内核（Gin 对标）

| ID | 需求 | 优先级 | Gin 对应 |
|---|---|---|---|
| K1 | 基于 `Std.Http.Server` 的服务启动、优雅停机、连接数上限、超时配置 | P0 | `r.Run()` / `http.Server` |
| K2 | 路由：静态路径、`:param`、`*wildcard`；按方法分发；用 **radix tree** 匹配 | P0 | `httprouter` |
| K3 | 路由分组 `group "/api/v1"`，组级中间件 | P0 | `r.Group` |
| K4 | 中间件链（洋葱模型），可以短路（`abort`） | P0 | `c.Next()` / `c.Abort()` |
| K5 | `Context`：读取 param、query、header、cookie、body，写响应，按请求存取的 KV | P0 | `*gin.Context` |
| K6 | 绑定与校验：`FromJson` 加精化类型，例如 `{s : String // s.length ≤ 64}` | P0 | `ShouldBindJSON` + validator |
| K7 | 响应：`json`、`text`、`html`、`redirect`、`status`、流式 / SSE | P0 / P1(SSE) | `c.JSON` 等 |
| K8 | 内置中间件：Logger、Recovery、RequestID、CORS、BodyLimit、Timeout | P0 | `gin.Default()` |
| K9 | 统一错误模型：`AppError → Response`，handler 用 `ExceptT` | P0 | `c.Error` |
| K10 | 静态文件服务 | P1 | `r.Static` |
| K11 | 测试工具：不走网络，在内存里直接跑 `Request → Response` | P0 | `httptest` |
| K12 | 路由声明 DSL（宏），编译期检查 path 参数和 handler 签名是否一致 | P1 | — |
| K13 | 从路由类型生成 OpenAPI 3 | P2 | swag |
| K14 | WebSocket | P2 | gorilla/websocket |

### 5.2 ORM（Leant.Data）

| ID | 需求 | 优先级 |
|---|---|---|
| O1 | 数据库驱动抽象 `Driver` 类型类；先接 **SQLite**（`leansqlite`），再接 **PostgreSQL**（libpq FFI） | P0 / P1 |
| O2 | 连接池（固定大小、获取超时） | P0 |
| O3 | `model` 宏：从 `structure` 生成表结构、`FromRow`/`ToRow`、主键、索引元数据 | P0 |
| O4 | **类型化查询 AST**：`select`/`where`/`orderBy`/`limit`/`join`；列有类型，比较两端类型必须一致 | P0 |
| O5 | 只渲染成**参数化 SQL**，公共 API 不暴露原始字符串拼接（`raw` 必须显式标记 `unsafe`） | P0 |
| O6 | 插入、更新、删除、事务（`withTransaction`） | P0 |
| O7 | 迁移：根据模型 diff 生成 `CREATE/ALTER`，记录版本号，支持 up/down | P1 |
| O8 | **作用域注入（Row-Level Security）**：带租户的模型，在查询编译时自动加上 `tenant_id = ?` | P1 |
| O9 | 关系：`belongsTo`/`hasMany`，预加载以避免 N+1 | P2 |

### 5.3 授权层（Leant.Authz），核心差异化

| ID | 需求 | 优先级 |
|---|---|---|
| A1 | 认证中间件把请求解析成 `Principal`（Session 或 JWT 二选一起步） | P0 |
| A2 | 策略模型 v1：**RBAC + 资源归属 + 租户**（见附录 A） | P0 |
| A3 | 纯函数 `evaluate : Policy → Principal → Action → Resource → Decision` | P0 |
| A4 | **证明型守卫**：`guard` 在运行时求值；返回 allow 时给出 `Authorized p a r` 证明，handler 的类型要求这个证明 | P0 |
| A5 | 声明式语法 `requires .delete on post` | P1 |
| A6 | 内置定理：默认拒绝、deny 优先、租户隔离、角色授予不越权 | P1 |
| A7 | 策略 diff：比较两版策略，列出新增或减少的授权 | P2 |
| A8 | 扩展到 ABAC 条件和 ReBAC（关系图） | P2 |

### 5.4 安全基础设施

| ID | 需求 | 优先级 |
|---|---|---|
| S1 | Cookie 安全默认值（`HttpOnly`、`Secure`、`SameSite`） | P0 |
| S2 | 签名 Session（HMAC-SHA256，FFI 接 OpenSSL）、常量时间比较 | P1 |
| S3 | CSRF 中间件 | P1 |
| S4 | 限流中间件（令牌桶） | P1 |
| S5 | 类型化 HTML 转义（`Untrusted` → `Html`） | P2 |
| S6 | 密码哈希（argon2 或 bcrypt，FFI） | P1 |

## 6. 非功能需求

| 类别 | 要求 |
|---|---|
| 性能 | 见第 8 节。MVP 目标：plaintext 和 JSON 吞吐 ≥ 同机 Gin 的 **30%**；v1 目标 ≥ **60%** |
| 并发 | 能撑住 10k 并发 keep-alive 连接而不崩，内存线性增长 |
| 稳定性 | 72 小时压测不泄漏（RSS 稳定）、不 panic |
| 正确性 | 框架核心**禁用 `sorry`**；`partial` 和 `unsafe` 需要说明理由并登记 |
| 可移植 | Linux x86_64 / arm64 优先，macOS 次之 |
| 工具链 | 固定 `lean-toolchain`（≥ v4.30，因为依赖 `Std.Http`），每个季度评估一次升级 |
| 文档 | 每个公共 API 都有 docstring；提供 Quick Start、示例项目、"证明了什么"清单 |
| 测试 | 单元测试（`#guard` 加 `lake test`）、内存 HTTP 测试、集成测试（真实 socket） |

## 7. 形式化验证范围

**可信基（TCB，明确声明不验证）**：Lean 内核、编译器、运行时、libuv、`Std.Http` 自身、OpenSSL、SQLite/libpq、操作系统。

| 验证项 | 性质 | 阶段 |
|---|---|---|
| 路由匹配 | 全函数（不会 panic）；静态路由优先级正确；`match (render route params) = some params` | M2 |
| 策略引擎 | 默认拒绝、deny 优先、租户隔离、单调性 | M4 |
| 守卫 | handler 只有在 `evaluate = allow` 时才可调用（由类型保证） | M4 |
| SQL 渲染 | 用户数据只出现在参数位置，不出现在 SQL 文本里 | M3 |
| RLS 注入 | 对租户模型，编译出的每个查询的 WHERE 都蕴含 `tenant_id = ctx.tenant` | M4 |
| JSON 和精化类型 | 解析成功即满足约束（由类型保证） | M1 |

## 8. Benchmark 方案

### 8.1 选型说明
- **TechEmpower Framework Benchmarks（TFB）** 是业界最常引用的 Web 框架基准，Round 23 发布于 2025-03。**该项目已在 2026-03 宣布停止维护、仓库归档**，所以不能再"提交上榜"。
- 但它的**测试规范**（6 种负载）仍然是事实标准，Gin、Axum、Django 都有现成实现，可以直接复用。
- 因此 Leant 的做法是：**沿用 TFB 测试规范，自建可复现的本地 benchmark**，在同一台机器上和基线框架对比。

### 8.2 测试负载（沿用 TFB 规范）

| 测试 | 衡量什么 | 优先级 |
|---|---|---|
| Plaintext `/plaintext` | HTTP 解析、路由、IO 的极限（pipelining 16） | P0 |
| JSON `/json` | 序列化加内存分配 | P0 |
| Single Query `/db` | 驱动加连接池 | P1 |
| Multiple Queries `/queries?q=N` | 并发 DB IO | P1 |
| Fortunes `/fortunes` | ORM、排序、HTML 转义 | P1 |
| Updates `/updates?q=N` | 写入加事务 | P2 |
| **Leant 专属：Authz** `/authz/:id` | 带策略求值和 RLS 查询的真实请求，用来量化安全层开销 | P1 |

### 8.3 工具与指标

| 工具 | 用途 |
|---|---|
| `wrk` | 闭环、最大吞吐（RPS），和 TFB 方法一致 |
| `wrk2` 或 `oha`（开环、固定速率） | **尾延迟** p50/p99/p99.9，避免 coordinated omission 低估延迟 |
| `/usr/bin/time -v`、`pidstat` | CPU、RSS 峰值 |

- 并发梯度：16 / 64 / 256 / 512 / 1024 / 4096 连接
- 指标：RPS、p50/p99/p99.9 延迟、错误率、CPU%、RSS
- **基线框架**：Gin（Go）、Axum（Rust）、Django 加 gunicorn（Python）、Lithe（Lean，可选）
- 规则：服务端和压测端绑定不同 CPU 核（`taskset`），每项跑 3 次取中位数，记录硬件和版本信息
- CI：每个 PR 跑一次 plaintext 和 JSON 冒烟压测，吞吐回退超过 10% 时告警

## 9. 成功指标

| 指标 | MVP（M2 结束） | v1 |
|---|---|---|
| plaintext 和 JSON 吞吐 / 同机 Gin | ≥ 30% | ≥ 60% |
| p99 延迟（固定速率 = Gin 最大吞吐的 50%） | ≤ Gin 的 3 倍 | ≤ Gin 的 1.5 倍 |
| 框架核心里 `sorry` 的数量 | 0 | 0 |
| 已证明的安全定理 | ≥ 3 | ≥ 10 |
| 示例应用 | Hello、Todo API | 多租户 SaaS Demo |

## 10. 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| `Std.Http` API 不稳定或有 bug | 内核要返工 | 在框架内部抽象一层 `Transport`，必要时可以换成 Rust/C shim |
| 性能远低于预期 | 定位受影响 | M0 先测 `Std.Http` 原生基线，再决定架构 |
| 证明成本过高 | 进度延误 | 先用类型保证，定理只针对小而纯的核心；大量使用 `decide` 和 `grind` |
| ORM 范围膨胀 | 延误 | v1 只做 SQLite 加 Postgres，关系和预加载放到 P2 |
| 编译慢 | 开发体验差 | 控制宏展开规模，按模块拆分 |

---

## 附录 A：权限模型入门（选型说明）

| 模型 | 一句话 | 例子 | 优点 | 缺点 |
|---|---|---|---|---|
| **ACL**（访问控制列表） | 每个资源挂一张"谁能做什么"的名单 | 文件权限 | 直观 | 用户和资源一多就没法管 |
| **RBAC**（基于角色） | 用户 → 角色 → 权限 | admin 能删文章，editor 能改 | 简单、主流、好审计 | 表达不了"只能改**自己的**文章" |
| **ABAC**（基于属性） | 根据用户、资源、环境的属性写规则 | `resource.owner == user.id`、`time < 18:00` | 很灵活 | 规则多了难以理解，**正好需要形式化验证** |
| **ReBAC**（基于关系） | 根据对象之间的关系图判断 | "文档所在文件夹的成员可以读"（Google Zanzibar） | 适合协作类产品 | 实现和验证都复杂 |

**Leant v1 的选择：RBAC + 两条 ABAC 规则（资源归属、租户隔离）。** 这能覆盖大多数 SaaS 场景，而且对应的定理都比较好证明。

```lean
-- 示意：v1 的策略语义
def evaluate (pol : Policy) (p : Principal) (a : Action) (r : Resource) : Decision :=
  if r.tenant ≠ p.tenant then .deny                         -- 租户隔离（硬性规则）
  else if pol.forbids p a r then .deny                      -- deny 优先
  else if pol.rolePermits p.roles a r.kind then .allow      -- RBAC
  else if a ∈ pol.ownerActions ∧ r.owner = p.id then .allow -- 归属（ABAC）
  else .deny                                                -- 默认拒绝
```

策略引擎按 Cedar 的结构设计（permit/forbid 规则加条件表达式），以后扩展到完整 ABAC 和 ReBAC 时不需要推翻重来。
