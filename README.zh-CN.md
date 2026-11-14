<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="CcinnStarRocks 图标">
</p>

<h1 align="center">CcinnStarRocks</h1>

<p align="center">
  <b>为 StarRocks 打造的快速、原生 macOS 客户端。</b><br>
  一眼看清分区、Tablet 与数据倾斜，掌握物化视图的健康状况与正在运行的任务，并把任意查询直接变成图表。
</p>

<p align="center">
  <a href="https://github.com/whiteCcinn/ccinnstarrocks/actions/workflows/ci.yml"><img src="https://github.com/whiteCcinn/ccinnstarrocks/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/whiteCcinn/ccinnstarrocks/releases/latest"><img src="https://img.shields.io/github/v/release/whiteCcinn/ccinnstarrocks?sort=semver" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/StarRocks-3.x%20%E2%86%92%204.x-5b5bd6" alt="StarRocks 3.x 至 4.x">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="MIT 许可证"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

<p align="center">
  <img src="docs/screenshots/overview-starrocks41.png" alt="StarRocks 4.1 上的表概览" width="900">
</p>

## 为什么选择 CcinnStarRocks？

通用 SQL 客户端把 StarRocks 当成"另一个 MySQL"：一个扁平的表列表加一个查询框。而真正运维 StarRocks 集群时最需要的信息，仍然只能靠 `SHOW PARTITIONS`、`SHOW TABLET`、`information_schema.task_runs` 和大量复制粘贴来拼凑：

- 哪些表其实是物化视图；
- 这些物化视图是否是最新的；
- 表是如何分区、如何分桶的；
- Tablet 是否存在倾斜；
- 此刻有哪些导入和刷新正在运行。

CcinnStarRocks 把这些信息都放在一次点击之内。它是原生的 SwiftUI/AppKit 应用，内置纯 Swift 实现的 MySQL 协议客户端。没有 Electron，没有 JDBC，不捆绑运行时，也不收集任何数据。

## 功能特性

- **一眼识别每个对象**：表、异步物化视图、同步物化视图（Rollup）、视图、外表各有专属图标和颜色。表带有数据模型徽标（**DUP / AGG / UNI / PK**），异步物化视图在侧边栏直接显示刷新健康状态，同步物化视图显示其基表。
- **表洞察**
  - 数据模型、键、分区、分布、分桶与属性；
  - 各索引的存储占用；
  - 分区的范围边界、行数、大小，以及分布图表；
  - **Tablet** 列表、**倾斜检测**（超过平均值 1.5 倍的 Tablet 会被标出）以及各 BE 的副本分布；
  - DDL 与数据预览。
- **物化视图**
  - 刷新状态、调度策略、最近一次运行、耗时、查询改写状态与错误信息；
  - 基于 task runs 的刷新历史；
  - 一键刷新、强制刷新、取消刷新、重新激活。
- **SQL 工作台**
  - 语法高亮，以及上下文感知补全，覆盖：
    - Catalog、数据库、表；
    - 通过别名、子查询和 CTE 解析出的列；
    - StarRocks 函数。
  - 可执行当前语句、选中内容或整个脚本，普通 `SELECT` 会自动加上 `LIMIT`。
  - `EXPLAIN` / `EXPLAIN COSTS`，以及**基于 `KILL QUERY` 的真正取消**。
  - 错误会在精确位置下划线标出；历史记录可搜索。
  - 支持导出为 CSV / TSV / `INSERT`。
- **任意查询一键成图**
  - 自动推荐图表：日期列配数值生成折线图，分类配数值生成柱状图，两个分类生成分组柱状图，两个数值生成散点图。
  - 可切换柱状、折线、面积、散点、饼图，自选坐标轴、系列与聚合方式。
  - 大结果集在后台线程中缩减到最多 2,000 个点。
- **运维视图**
  - **正在运行**：一屏汇总查询、导入、物化视图刷新与任务、Routine Load、Schema Change，并自动刷新。
  - 会话列表，可*终止查询 / 终止连接*。
  - 导入任务；Routine Load 支持暂停 / 恢复 / 停止。
  - 任务运行记录、Schema Change 任务，以及 FE / BE / CN 节点的磁盘、CPU 与内存使用率。
- **连接能力**
  - 多 Catalog（内部与外部）。
  - 通过系统 OpenSSH 建立 SSH 隧道（agent、密钥或密码）。
  - 可选启用 `mysql_clear_password` 以支持 LDAP 用户。
  - 可选在执行修改数据或结构的语句前二次确认。
- **通过 MCP 接入 AI**：内置 Model Context Protocol 服务，让 Claude Code、Codex、Claude Desktop 查询你授权的连接（默认只读），详见 [MCP 服务](#mcp-服务让-ai-查询-starrocks)。
- **默认安全**：密码保存在 macOS 钥匙串中；除非启用 AI 访问，不会收集或发送任何数据。

## 兼容性

| StarRocks | 部署形态 | 测试情况 |
|---|---|---|
| 3.3 | 存算一体 | ✅ 每个版本均测试 |
| 4.1 | 存算一体 | ✅ 每个版本均测试 |
| 3.1 – 4.x | 存算一体 / 存算分离 | 预期可用 |

元数据优先读取 `information_schema`（`tables_config`、`materialized_views`、`partitions_meta`、`task_runs`、`loads`、`routine_load_jobs`），不可用时回退到 `SHOW` 命令。所有结果都**按列名解析**，新版本增加或调整列顺序不会影响使用。需要额外权限的功能（如 `ADMIN SHOW REPLICA DISTRIBUTION`）会给出说明并优雅降级，而不是直接报错。CcinnStarRocks 支持 **macOS 14 Sonoma 及以上**（Apple 芯片与 Intel）。

## 截图

| 分区：范围边界与大小 | Tablet：倾斜检测与各 BE 副本分布 |
|---|---|
| ![分区](docs/screenshots/partitions-starrocks41.png) | ![Tablet](docs/screenshots/tablets-starrocks41.png) |
| **异步物化视图健康状态** | **由查询生成的图表** |
| ![物化视图](docs/screenshots/materialized-view-starrocks41.png) | ![图表](docs/screenshots/chart-starrocks41.png) |
| **SQL 工作台与结果表格** | **集群节点** |
| ![SQL](docs/screenshots/sql-starrocks33.png) | ![集群](docs/screenshots/cluster-starrocks33.png) |

## 安装

1. 从 [最新 Release](https://github.com/whiteCcinn/ccinnstarrocks/releases/latest) 下载 `CcinnStarRocks-<版本>.dmg`（或 `.zip`）。
2. 打开磁盘映像，把 **CcinnStarRocks** 拖入 **应用程序**。
3. 应用使用 ad-hoc 签名，未经过 Apple 公证。首次打开时请右键点击应用并选择**打开**，或执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/CcinnStarRocks.app
   ```

每个 Release 都附带 `SHA256SUMS.txt` 校验和。

## 快速开始

1. 点击**新建连接**，填写 FE 地址与查询端口（默认 **9030**）、用户名和密码；可选填默认数据库 / Catalog，或配置 SSH 隧道。
2. 点击**测试**，然后**保存并连接**。
3. 在侧边栏展开数据库，选择表或物化视图即可查看分区、Tablet 与刷新情况；也可以按 **⌘T** 打开 SQL 编辑器。

常用快捷键：

| 快捷键 | 作用 |
|---|---|
| **⌘↩** | 执行选中内容或当前语句 |
| **⇧⌘↩** | 执行全部语句 |
| **⌘E** | 查看执行计划 |
| **⌘.** | 取消正在执行的语句 |
| **⌃Space** | 显示补全 |
| **⌘/** | 注释 / 取消注释所选行 |
| **⌘T** | 新建查询 |
| **⇧⌘R** | 刷新 Catalog |
| **⇧⌘D** | 断开连接 |

## MCP 服务：让 AI 查询 StarRocks

CcinnStarRocks 内置 **Model Context Protocol** 服务，**Claude Code**、**Codex**、**Claude Desktop**、Cursor 等 AI 助手可以通过你保存的连接探索集群并执行查询。

1. 在 CcinnStarRocks 中打开连接，把 **AI 访问 (MCP)** 设为**只读**或**读写**（默认关闭）。
2. 注册服务。**设置 → MCP** 中提供了带正确路径、可直接复制的配置：

   ```bash
   # Claude Code
   claude mcp add ccinnstarrocks -- /Applications/CcinnStarRocks.app/Contents/MacOS/CcinnStarRocks mcp
   ```

   ```toml
   # Codex（~/.codex/config.toml）
   [mcp_servers.ccinnstarrocks]
   command = "/Applications/CcinnStarRocks.app/Contents/MacOS/CcinnStarRocks"
   args = ["mcp"]
   ```

   ```json
   // Claude Desktop（claude_desktop_config.json）及其他使用 JSON 配置的客户端
   { "mcpServers": { "ccinnstarrocks": { "command": "/Applications/CcinnStarRocks.app/Contents/MacOS/CcinnStarRocks", "args": ["mcp"] } } }
   ```

3. 直接提问，例如：*"shop 库里哪些物化视图最近一次刷新失败了？"*、*"shop.orders 有没有数据倾斜？哪个城市的营收最高？"*

**工具列表**

| 分组 | 工具 |
|---|---|
| 连接 | `list_connections` |
| 目录 | `list_catalogs`、`list_databases`、`list_tables`、`describe_table` |
| 表洞察 | `get_partitions`、`analyze_tablet_skew`、`get_materialized_view` |
| 集群 | `get_running_tasks`、`list_cluster_nodes` |
| SQL | `run_query`、`explain_query`，以及 `execute_statement`（仅限读写连接） |

`list_tables` 会返回每个对象的类型（表、异步或同步物化视图、视图、外表）、数据模型，以及物化视图的刷新健康状态。

**安全**

- 密码保存在钥匙串中，AI 永远看不到。
- 只有你启用的连接才可见。
- `run_query` 只接受单条只读语句（`SELECT`、`WITH`、`SHOW`、`DESC`、`EXPLAIN`），由应用自带的 SQL 词法分析器校验，而不是依赖模型自觉。
- 结果最多 1,000 行（默认 200 行）、约 256 KB；语句默认 30 秒超时。
- 在 AI 客户端取消请求时会发送 `KILL QUERY`。
- `--read-only` 把所有连接限制为只读；`--profile <名称>` 指定默认连接。
- 每次调用都会记录到 `~/Library/Application Support/CcinnStarRocks/mcp-audit.jsonl`。

## 从源码构建

环境要求：macOS 14+，Xcode 16 或更高版本（Swift 6）。

```bash
git clone https://github.com/whiteCcinn/ccinnstarrocks.git
cd ccinnstarrocks
swift build                          # Debug 构建
swift test --skip IntegrationTests   # 单元测试
scripts/build-app.sh --open          # 构建 dist/CcinnStarRocks.app 并启动
scripts/package-release.sh 1.0.0     # 在 dist/ 中生成通用架构 .app、.zip、.dmg 与校验和
```

### 针对真实集群的集成测试

需要 Docker。脚本会启动 StarRocks 3.3 与 4.1 的 all-in-one 容器，并导入演示数据库 `shop`。其中包含每种数据模型的表、按月分区、一个视图，以及异步和同步物化视图各一个。

```bash
eval "$(scripts/sr-up.sh)"           # 导出 CCINNSR_IT_URIS
swift test --filter IntegrationTests
scripts/sr-down.sh
```

## 架构

```
CcinnStarRocks（SwiftUI 应用）
 └─ CcinnStarRocksKit   连接配置与钥匙串、SQL 词法/拆分/自动 LIMIT、补全、图表、导出、倾斜分析、历史
     └─ StarRocksKit    传输层、连接 actor、连接池、会话与 KILL QUERY、SSH、元数据、洞察与运维
         └─ MySQLWire   报文分帧、握手与认证插件、OK/ERR/EOF、文本结果集
```

- **一个词法分析器贯穿始终**：高亮、语句拆分、自动 LIMIT、错误定位与补全共用同一套分词，结果始终一致。
- **有界且可取消**：结果集有上限，超大结果会直接断开连接而不是继续读取；取消语句时会通过另一条连接发送 `KILL QUERY`。
- **并发安全**：连接、连接池与会话均为 Swift actor，项目在 Swift 6 严格并发模式下编译；排序、图表准备与导出都在后台线程执行。
- **健壮解析**：协议解析带边界检查并经过模糊测试，畸形报文只会抛出错误而不会导致崩溃。

## ccinn 系列

同样注重设计、速度与细节的原生 macOS 数据工具：

| 应用 | 简介 |
|---|---|
| [**CcinnMongo**](https://github.com/whiteCcinn/ccinnmongo) | 原生 MongoDB 客户端，支持 2.6 到 8.x 的所有版本，同时支持旧版 `OP_QUERY` 与新版 `OP_MSG` 协议。 |
| **CcinnStarRocks** *（本项目）* | 原生 StarRocks 客户端，涵盖分区、Tablet 与倾斜分析、异步/同步物化视图、运行中任务，以及带补全和图表的 SQL。 |
| [**CcinnRedis**](https://github.com/whiteCcinn/ccinnredis) | 原生 Redis 客户端，支持 Redis 2.8 → 8.x 与 Valkey，覆盖单机、Sentinel、Cluster 与代理部署。 |
| [**CcinnBucket**](https://github.com/whiteCcinn/ccinnbucket) | 对象存储浏览器，支持 Amazon S3、S3 兼容服务与阿里云 OSS。 |

## 贡献者

- [whiteCcinn](https://github.com/whiteCcinn)

<a href="https://github.com/whiteCcinn/ccinnstarrocks/graphs/contributors"><img src="https://contrib.rocks/image?repo=whiteCcinn/ccinnstarrocks" alt="贡献者"></a>

## Star 趋势

[![Star 趋势图](https://api.star-history.com/svg?repos=whiteCcinn/ccinnstarrocks&type=Date)](https://star-history.com/#whiteCcinn/ccinnstarrocks&Date)

## 参与贡献

欢迎贡献！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；安全问题请按照 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

[MIT](LICENSE) © 2026 whiteCcinn。StarRocks 是 Linux 基金会的商标；本项目与 StarRocks 项目或 CelerData 无关，也未获得其背书。
