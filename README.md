# Android Performance Skills

Android 性能分析的 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 插件集合。通过自然语言驱动 Perfetto trace 分析，覆盖启动、内存、渲染等性能场景。

## 当前包含的 Skills

| Skill | 命令 | 说明 |
|-------|------|------|
| 启动分析 | `/analyze-startup <trace文件> [包名]` | 分析 Android 应用启动性能，输出结构化中文报告 |

> 更多 skill 持续添加中（内存分析、渲染性能、ANR 分析等）。

## 安装

### 一键安装（推荐）

```bash
git clone https://github.com/zhangshuxiaocn/android_performance_skills.git
cd android_performance_skills
bash install.sh
```

`install.sh` 会做两件事：

1. 将仓库软链接到 `~/.claude/plugins/local/analyze-startup`（辅助脚本查找路径）
2. 将 `commands/*.md` 软链接到 `~/.claude/commands/`（Claude Code 命令注册）

安装完成后，**重启 Claude Code** 使命令生效。

### 手动安装

```bash
git clone https://github.com/zhangshuxiaocn/android_performance_skills.git ~/android_performance_skills

# 1. 注册自定义命令（必须，否则 /命令名 不可用）
mkdir -p ~/.claude/commands
ln -s ~/android_performance_skills/commands/analyze-startup.md ~/.claude/commands/analyze-startup.md

# 2. 插件目录链接（辅助脚本依赖此路径）
mkdir -p ~/.claude/plugins/local
ln -s ~/android_performance_skills ~/.claude/plugins/local/analyze-startup
```

安装完成后，**重启 Claude Code** 使命令生效。

### 工作原理

Claude Code 加载自定义斜杠命令（`/命令名`）的机制：

- **`~/.claude/commands/`** — 全局自定义命令目录。Claude Code 启动时扫描此目录下的 `.md` 文件，每个文件注册为一个 `/命令名`。这是命令能被识别的**必要条件**。
- **`.claude/commands/`**（项目根目录下）— 项目级自定义命令，仅在该项目中可用。
- **`~/.claude/plugins/local/`** — 本地插件目录。目前 Claude Code 不会自动从此目录发现命令，但 skill 的辅助脚本（如 `query-startup.sh`）会通过此路径查找。

因此本仓库的 `commands/` 目录需要通过软链接"注册"到 `~/.claude/commands/`，而仓库本身链接到 `plugins/local/` 供脚本定位。`install.sh` 自动完成这两步。

## Skills 详解

### /analyze-startup — 启动性能分析

基于 [Perfetto](https://perfetto.dev/) trace 文件，自动执行 17 个 SQL 查询，并根据结果动态触发递归依赖链追踪，输出 5 节结构化中文分析报告。

#### 使用方法

```
/analyze-startup <trace文件路径> [包名]
```

- `<trace文件路径>` — `.perfetto-trace` 或 `.pb` 文件（必填）
- `[包名]` — 要分析的 Android 包名（可选，不提供则从 trace 自动检测）

#### 示例

```
/analyze-startup ~/traces/cold-start.perfetto-trace
/analyze-startup ~/traces/app-launch.pb com.example.myapp
```

#### 功能亮点

- **一键分析**: 一条命令获得完整报告
- **17 个专项查询**: 覆盖启动全维度 — 生命周期、线程状态、Binder、锁竞争、GC、类加载、调度优先级、唤醒链优先级反转等
- **智能深度分析**: 根据查询结果自动触发 Binder 服务端分解、调度优先级时间线和唤醒链优先级反转分析
- **递归依赖链追踪**: 对锁阻塞 >50ms 或 CFS 唤醒阻塞 >30ms 的事件，自动递归追踪"阻塞者在干什么、被谁阻塞"，最多展开 10 层，直到找到 CPU 工作、I/O 或内核等待等根因
- **结构化报告**: 5 节报告，从概览到根因链路图（含递归展开的多层依赖链）

#### 报告结构

1. **概览** — 包名、启动类型、耗时、TTID/TTFD、评定
2. **阶段耗时分解** — 各生命周期阶段耗时
3. **线程状态分析** — Running/Runnable/Sleep/IO 分布
4. **耗时 Slice 排行** — 主线程 Top 10-15 耗时操作
5. **问题总结与根因分析** — 核心结论、根因链路图（含调度优先级分析、依赖链优先级反转、递归依赖链展开）、问题清单

此外，当检测到显著锁阻塞或 CFS 唤醒阻塞时，会在报告中插入**递归依赖链追踪**章节，逐层展开阻塞者的内部状态（Running/Sleep/D-IO 占比）、唤醒者、抢占者，直到找到终端根因。

#### 辅助脚本

`scripts/query-startup.sh` 可以脱离 Claude Code 独立运行:

```bash
bash scripts/query-startup.sh /path/to/trace_processor_shell /path/to/trace.perfetto-trace [包名]
```

## 如何贡献新 Skill

1. 在 `commands/` 下创建新的 `.md` 文件（文件名即命令名）
2. 在 `scripts/` 下添加对应的辅助脚本（如有需要）
3. 更新本 README 的 Skills 列表
4. 提交 PR

Skill 文件格式参考 `commands/analyze-startup.md`，需包含 frontmatter（description、allowed-tools 等）和完整的分析指令。

> **注意**: 添加新 skill 后，用户需重新运行 `bash install.sh` 将新的 `.md` 文件链接到 `~/.claude/commands/`。

## 前置条件

- **Claude Code**: 需安装 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- **trace_processor_shell**: Perfetto 的命令行查询工具
  - AOSP 中位于 `prebuilts/tools/linux-x86_64/perfetto/trace_processor_shell`
  - 也可从 [Perfetto 官网](https://perfetto.dev/) 下载独立版本并放入 PATH
- **Perfetto trace 文件**: 需包含对应分析场景所需的数据类别

## 许可证

[MIT](LICENSE)
