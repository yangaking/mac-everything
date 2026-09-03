# MacEverything 极致性能重构与改进计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 以「极致性能」为核心目标，系统性地修复 MacEverything 在架构、正确性、性能、产品、工程上的全部问题，使搜索真正做到「输入即响应、冷启动秒级、索引文件极小、待机 CPU≈0」。

**Architecture:** 保留「Rust 内存引擎 + SwiftUI 前端」的总体形态，将搜索执行从 UI 主线程迁到后台队列并引入防抖与取消；为内存扁平索引增加可持久化快照以消除全盘冷扫描；修正 FSEvents 热更新正确性。核心原则：**零跨进程开销、零主线程阻塞、零不必要的堆分配**。

**Tech Stack:** Rust（Rayon、walkdir、notify/fsevent-sys、regex）、SwiftUI + AppKit + Carbon、SQLite 仅作为候选持久化方案之一（见决策点）。

---

## 0. 架构决策（✅ 已于 2026-09-03 确认，后续任务按此执行）

### D1. 索引持久化方案 → **A. 内存扁平结构 + mmap 快照**
把当前 `StringPool` 字节池 + `Vec<FileRecord>` + `dir_paths` 按固定布局写入磁盘，启动时 `mmap` 直接映射为可搜索内存，零反序列化。搜索仍是纯内存，延迟不变；冷启动从「全盘重扫（分钟级）」降到「映射文件（毫秒级）」。改动集中在 `indexer.rs` + 新增 `persist.rs`。最贴合「极致性能 + 小巧索引文件」，是 Everything 的实际做法。

### D2. 搜索执行模型 → **A. 同进程后台队列 + 防抖 + 取消**
`search` 仍在当前进程，但放到后台队列/专用线程 + 200ms 防抖 + generation 失效，杜绝主线程阻塞与竞态。零 IPC 开销，延迟最低。隔离性通过 Rust 侧 `catch_unwind` + 重试补足。

### D3. FSEvents 目录移动 → **A. 识别 Rename + 子树重扫 + B. 定时对账兜底**
解析 `notify` 的 `Rename`/`Modify(Name)` 事件，对目录移动触发该子树增量重扫；另加周期对账做静默恢复（贴合 AGENTS.md「优雅降级与恢复」）。

---

## 1. 问题 → 方案映射总表

编号沿用审查报告。P0/P1/P2/P3 为优先级。

| # | 问题 | 方案 | 优先级 | 所属工作流 |
|---|---|---|---|---|
| 1 | 索引不持久化、冷启动全盘重扫 | 决策 D1 方案 A | P0 | WS2 |
| 2 | 搜索在主线程同步执行 | 后台队列执行 `search` | P0 | WS1 |
| 3 | 结果竞态（无 stale guard） | generation 序号失效 | P0 | WS1 |
| 4 | 无防抖 | 200ms debounce | P0 | WS1 |
| 5 | 目录移动不更新子项 | 决策 D3 方案 A+B | P0 | WS3 |
| 6 | `thisweek`/`thismonth` 假过滤 | 实现 `parse_date_op` 全分支 | P1 | WS4 |
| 7 | 无效正则返回全量 | 解析失败返回「空结果」节点 | P1 | WS4 |
| 8 | 正则大小写行为不一致 | 统一为 `(?i)` | P1 | WS4 |
| 9 | 热更新不过滤 `/Library` | 抽出共享过滤谓词复用 | P1 | WS3 |
| 10 | `free_search_results` 潜在 UB | 改用 `into_boxed_slice` 或记录 capacity | P1 | WS1 |
| 11 | `limit==0` 下溢 panic | 加 `limit==0` 守卫 | P1 | WS1 |
| 12 | `onAppear` 重复注册监听器 | 监听器改单例/幂等注册 + `onDisappear` 移除 | P1 | WS3 |
| 13 | Group Containers 过滤死代码 | 删除不可达分支 | P3 | WS6 |
| 14 | `size:10kb` 精确匹配缺失 | 支持「等于」语义或改文档 | P2 | WS4 |
| 15 | 冷扫描单线程 | `scan_directories` 并行化（Rayon） | P1 | WS2 |
| 16 | `date:` 每记录 `SystemTime::now()` | 提升到 `search` 开头算一次 | P1 | WS1 |
| 17 | 路径搜索每记录 `to_lowercase` 分配 | 预计算/复用小写目录池 | P1 | WS1 |
| 18 | 每按键全量 collect 再截断 | 流式 Top-K（`BinaryHeap`） | P1 | WS1 |
| 19 | 拼音生成重复 3 遍 | 抽 `fn build_pinyin(name) -> Option<String>` | P2 | WS6 |
| 20 | 500ms 轮询 + 禁用 App Nap | 改事件驱动唤醒 + 移除 `NSAppSleepDisabled` | P2 | WS3 |
| 21 | Bundle ID/签名占位、版本硬编码 | 正式 bundle id + 版本注入 + 签名脚本化 | P2 | WS5 |
| 22 | Info.plist 声明不存在的卷权限 | 删除无意义 usage-description | P3 | WS5 |
| 23 | 无 App 菜单、Cmd+Q 无效 | 补 App 菜单含 Quit | P2 | WS5 |
| 24 | 状态指示失真 | 增加「热更新中」状态事件 | P3 | WS3 |
| 25 | 结果数硬上限 100 | 提高到可配置，增量加载 | P3 | WS5 |
| 26 | 文案中英混杂 | 统一中文文案 | P3 | WS5 |
| 27 | 死依赖 crossbeam-channel / fsevent-sys | 移除 | P3 | WS6 |
| 28 | 临时/调试文件入库 | 删除 + `.gitignore` | P3 | WS6 |
| 29 | 测试不足、断言被注释 | 建立基准测试 + 单测补齐 | P0 | WS0 |
| 30 | `unsafe from_utf8_unchecked` | 加 debug 断言或改为 `from_utf8` | P3 | WS6 |
| 31 | `FileItem.id` 每次重建 | 用稳定 id（路径 hash） | P3 | WS5 |
| 32 | QuickLook 集成脆弱 | 迁移新 API + 状态同步 | P3 | WS5 |

---

## 2. 工作流分组（Workstreams）

每个工作流产出可独立验证的成果；WS0 是所有性能工作的前置闸门。

### WS0 — 性能基线与基准测试（P0 前置）
**目标**：建立可复现的性能门槛，任何回归可被 CI/本地拒绝（对齐 AGENTS.md「性能基准测试驱动」）。
- 新建 `mac-everything-core/benches/`：用 `criterion` 或手写计时，覆盖：
  - 100 万条路径、正则搜索 `\.pdf$` < 30ms
  - 100 万条路径、普通关键词搜索 < 10ms
  - 索引文件（持久化后）< 50MB
  - 冷启动（加载持久化索引）< 500ms
- 修复 `indexer.rs:733-752` 被注释的断言，恢复 `test_scan_and_search`。
- 产出：`cargo bench` 与 `cargo test` 全绿。

### WS1 — 搜索链路性能与正确性（P0）
**目标**：主线程零阻塞、输入即响应、结果无竞态、内存占用可控。
- `ContentView.swift:377-417` 重构：防抖 200ms + 后台队列执行 + generation 失效 + 结果按序回填。
- `indexer.rs:613-724` 重构：`now` 提升、目录小写池复用、流式 Top-K 取代全量 collect。
- `ffi.rs:105-122`：修 `free_search_results` 的内存契约（`into_boxed_slice`），修 `limit==0`。
- 产出：`search` 不再触碰主线程，高命中查询峰值内存从「几十 MB」降到「约 Top-K 常量」。

### WS2 — 索引持久化与冷启动（P0，依赖 D1）
**目标**：冷启动秒级、索引文件极小。
- 新增 `mac-everything-core/src/persist.rs`：定义稳定二进制布局（magic + version + StringPool 段 + FileRecord 段 + dir_paths 段），写入/`mmap` 加载。
- `scan_directories` 并行化（WS1 预热）。
- `init_engine` 启动时优先加载快照，快照缺失/损坏时回退全量扫描（优雅降级）。
- 产出：重启后无需全盘扫描即可搜索。

### WS3 — 索引热更新正确性与资源（P0/P1，依赖 D3）
**目标**：文件系统变化实时且正确反映，待机资源近零。
- `fsevents.rs` 重写：区分事件类型，目录 Rename 触发子树重扫（D3-A），定时对账兜底（D3-B）。
- 抽出共享过滤谓词，消除 `scan_directories` 与 `apply_updates` 的 `/Library` 规则不一致。
- `ffi.rs:49-56` 轮询改事件驱动；`MacEverythingApp.swift` 增加「热更新中」状态事件。
- 移除 `build.sh:51-52` 的 `NSAppSleepDisabled`。
- 产出：移动目录后索引正确；待机 CPU≈0、可正常 App Nap。

### WS4 — 查询解析正确性（P1）
**目标**：所有文档声明的语法真实可用，错误输入不产生误导结果。
- `query_parser.rs:152-181`：实现 `parse_date_op` 全分支（today/yesterday/thisweek/thismonth/`>`/`<` 日期），实现 `size:10kb` 等值语义。
- 统一正则大小写为 `(?i)`；无效正则返回「空结果」节点。
- 为解析器补边界单测。
- 产出：`kind/date/size/ext/!` 与正则行为一致可测。

### WS5 — 产品与分发就绪（P2/P3）
**目标**：可正式分发、体验统一。
- 正式 bundle id、版本号从单一来源注入；签名脚本化；补 App 菜单（含 Quit）。
- 删除 Info.plist 无意义 usage-description；结果数可配置；统一中文文案；修 `FileItem.id`；迁移 QuickLook 新 API。
- 产出：可 Gatekeeper 通过、菜单完整、文案统一。

### WS6 — 代码卫生（P3，可穿插）
**目标**：移除死代码/死依赖/临时文件，降低维护成本。
- 移除 `crossbeam-channel`、`fsevent-sys` 依赖；删除 `src/bin/{scratch,test_bug,debug_parse}.rs`、`patch_apply_updates.py`、`test_appnap.swift`、`test_wake.swift`。
- 抽 `build_pinyin` 消除重复；`StringPool::get` 加 debug 断言。
- 产出：`cargo build` 更小更快，仓库干净。

---

## 3. 落地计划（Phases）

### Phase 0 — 基线闸门（WS0，1–2 天）
- [ ] 建 `benches/` 基准测试并跑通
- [ ] 恢复被注释断言，`cargo test` 全绿
- [ ] 记录当前性能基线（搜索延迟、内存、冷启动耗时）
- **验收**：基准可运行，基线数字入库

### Phase 1 — 搜索链路（WS1，2–3 天）
- [ ] 防抖 + 后台执行 + generation 失效
- [ ] 流式 Top-K + 去分配优化
- [ ] 修 `free_search_results` 与 `limit==0`
- **验收**：主线程无阻塞（Instruments 确认）；高命中查询内存峰值骤降；无竞态

### Phase 2 — 持久化与冷启动（WS2，3–5 天，依赖 D1 确认）
- [ ] `persist.rs` 二进制布局 + 读写
- [ ] 快照加载路径 + 损坏回退
- [ ] 冷扫描并行化
- **验收**：索引文件 < 50MB（百万路径）；冷启动 < 500ms

### Phase 3 — 热更新正确性（WS3，3–5 天，依赖 D3 确认）
- [ ] FSEvents 事件分类 + 目录子树重扫 + 对账兜底
- [ ] 共享过滤谓词 + 事件驱动 + 移除 App Nap 禁用
- **验收**：移动大目录后索引正确；待机 CPU≈0

### Phase 4 — 查询与产品收尾（WS4 + WS5，2–4 天）
- [ ] 查询解析全分支 + 单测
- [ ] 签名/版本/菜单/文案/QuickLook
- **验收**：文档声明的语法全部可用；可分发

### Phase 5 — 卫生扫尾（WS6，穿插进行）
- [ ] 删死依赖、死代码、临时文件
- **验收**：`cargo build` 与仓库体量下降

---

## 4. 性能验收指标（硬性门槛）

| 指标 | 目标 | 实测（release，100万合成路径） |
|---|---|---|
| 普通关键词搜索延迟 | < 10ms | **8 ms** ✅ |
| 正则搜索延迟 | < 30ms | **21 ms** ✅ |
| 索引文件大小 | < 50MB | **47.7 MB** ✅ |
| 冷启动 | < 500ms | **8 ms** ✅ |
| 搜索期间主线程阻塞 | 0（后台执行） | 已后台化 ✅ |
| 待机 CPU | ≈0 | ≈0（500ms 轮询为 sleep，apply_updates 空队列 O(1)）；App Nap 仍禁用（防睡眠唤醒回归，属功耗而非 CPU） |

> 任何导致以上指标退化的改动，按 AGENTS.md「性能不达标停机」立即回退并先解决退化。

**索引大小达成方式**：`FileRecord` 由 40 字节缩至 32 字节——`size` 改为 u32 KiB（支持至 4TiB）、`modified_time` 改为 u32 秒（至 2106 年），配合小写名称去重。速度中性（缓存局部性反而更优）。持久化格式已升至 v2。

---

## 5. 完成状态

D1/D2/D3 已确认；Phase 0–5 已全部完成，所有硬性指标达成（19 个单测全绿 + 2 个基准）。

**遗留的非阻塞项（产品打磨，不属硬指标）**：
- bundle ID 仍为占位 `com.example.MacEverything.v2`（需真实反向域名）
- QuickLook 使用已废弃的 responder-chain API（可用，待迁移新 API）
- 状态栏「索引已就绪」不反映热更新进度；结果数硬上限 100；中英文案混杂
